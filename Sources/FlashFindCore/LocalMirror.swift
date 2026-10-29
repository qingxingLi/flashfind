import Foundation

/// 「把这个本地路径拷一份到临时目录」——群晖、OpenList 的下载走的这条。
///
/// ── 为什么需要它 ────────────────────────────────────────────────
/// 飞牛（fnOS）有设备侧下载接口（见 `DownloadableAdapter`），群晖和 OpenList
/// 没有。但它们的结果在本机**已经可读**（SMB 挂载 / WebDAV 挂载，必要时由
/// 打开链先挂上），所以「下载」= 从那个路径拷一份出来。这条路不需要任何
/// 设备协议，也就不需要为两家各写一套下载器。
///
/// 收在 Core 里而不是 App：拷贝的几条规矩（不覆盖任何已有文件、失败就把
/// 半成品删掉、目录也能拷）都得能被测试钉住。App 层只调一行。
public enum LocalMirror {
    /// 复制到一个**新建**的临时目录，返回副本的 URL。
    ///
    /// - 每次都用新目录：两次下载同名文件互不覆盖，用户也不会拿到上一次的残留。
    /// - 目录也照拷（访达里右键文件夹「下载」是合理要求）。
    /// - 失败时把这次建的目录删掉，**不留下半份文件**——那会看起来像下载成功了。
    public static func copyToTemporaryDirectory(_ source: URL,
                                                prefix: String = "flashfind-download-") throws -> URL {
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path) else {
            throw FlashFindError.message("文件可能已被移动或删除，请重新搜索")
        }
        let name = source.lastPathComponent
        guard !name.isEmpty, name != "/" else {
            throw FlashFindError.message("这个位置没有可下载的文件名")
        }
        let workDirectory = fm.temporaryDirectory.appendingPathComponent(prefix + UUID().uuidString)
        try fm.createDirectory(at: workDirectory, withIntermediateDirectories: true)
        let destination = workDirectory.appendingPathComponent(name)
        do {
            try fm.copyItem(at: source, to: destination)
            return destination
        } catch {
            try? fm.removeItem(at: workDirectory)
            throw FlashFindError.message("下载没有完成：\(error.localizedDescription)")
        }
    }
}
