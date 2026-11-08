import Foundation

/// 「在文件管理器中显示」该交给谁 —— **判定只有这一处**。
///
/// 2026-11-06 用户报障（第一轮）：把 Path Finder 设成默认文件管理器后，闪寻的
/// ⌘↩ / 右键「在 Finder 中显示」仍硬开访达。原实现用的是
/// `NSWorkspace.activateFileViewerSelecting`，Apple 文档写死 "Activates the
/// Finder"，它根本不看用户偏好。
///
/// 同日第二轮报障：**双击打开文件夹**仍开访达。原因是那条路走
/// `NSWorkspace.open(目录URL)`，而 Launch Services 的 `public.folder` 默认
/// handler 在本机实测是 `com.apple.finder`（尽管 `NSFileViewer` 已指向 Path
/// Finder）。也就是说「定位」和「双击打开」是两条独立的硬绑访达路径，
/// 只修一条不够 —— 所以两条链共用下面这份判据。
///
/// ★ 判定必须放 Core：App 是 executableTarget，testTarget 依赖不了它，写在
///   App 层就是没测（与 `ResultMenuPlan` / `SMBMountCandidate` 同一条纪律）。
///   App 层只负责读系统偏好、按这里给出的结论执行。
///
/// ★ macOS 没有「让任意第三方文件管理器选中某个文件」的通用接口：
///   Apple Event 需要用户授权且得按每款 App 的脚本字典适配。所以第三方那条路
///   只能打开**目录**（定位时是父目录，双击文件夹时是该目录本身）。
public enum FileViewerRoute: Equatable, Sendable {
    /// 系统默认文件查看器就是访达：沿用 `activateFileViewerSelecting` 选中文件。
    case finderReveal(URL)
    /// 用户选了第三方文件管理器：把文件所在目录交给它打开。
    case openParentFolder(URL, appBundleIdentifier: String)
}

/// 双击 / Return 打开一条结果时该交给谁。
public enum FileViewerOpenRoute: Equatable, Sendable {
    /// 交系统默认应用：**普通文件**必须走这里，否则 .pdf / .xlsx 的默认程序
    /// 会被文件管理器顶掉；访达用户的文件夹也走这里（行为与旧版一致）。
    case systemDefault(URL)
    /// 用户选了第三方文件管理器，且这一条是文件夹：把这个目录交给它打开。
    case preferredViewer(URL, appBundleIdentifier: String)
}

public enum FileViewerRouting {
    /// 访达的 bundle id。唯一出处，App 层不许再写一遍字符串。
    public static let finderBundleIdentifier = "com.apple.finder"
    /// `SearchResult.kind` 表示目录的取值。Spotlight / NAS / 预览数据三处一致。
    public static let directoryKind = "directory"

    // MARK: - 单一出处：用户偏好的文件管理器

    /// - Parameters:
    ///   - preferredViewer: 全局偏好 `NSFileViewer`。Path Finder / ForkLift 这类
    ///     管理器「设为默认文件查看器」写的就是这一项；本机实测
    ///     `defaults read -g NSFileViewer` = `com.cocoatech.PathFinder`。
    ///   - folderHandler: Launch Services 对**文件夹**的默认 handler。
    ///     有些第三方只改 Launch Services、不写 `NSFileViewer`，所以两条证据都要看。
    /// - Returns: 第三方 bundle id；`nil` 表示「按访达 / 系统默认处理」。
    ///
    /// ★ `nil` 的含义是**没有第三方偏好这条证据**，不是「用户明确拒绝第三方」——
    ///   缺证据不是反证据。显式写回访达时，Launch Services 里残留的第三方不翻案。
    ///
    /// ★ reveal 与 open 两条链都必须调这个函数。各写一份判据就会出现
    ///   「⌘↩ 认 Path Finder、双击文件夹又开访达」这种前后矛盾。
    public static func preferredViewerBundleIdentifier(preferredViewer: String?,
                                                       folderHandler: String?) -> String? {
        let chosen = normalized(preferredViewer) ?? normalized(folderHandler)
        guard let chosen, chosen != finderBundleIdentifier else { return nil }
        return chosen
    }

    // MARK: - ⌘↩ / 右键「在 Finder 中显示」

    /// - Parameter fileURL: 要定位的**文件**（不是目录）。
    public static func route(for fileURL: URL,
                             preferredViewer: String?,
                             folderHandler: String?) -> FileViewerRoute {
        guard let viewer = preferredViewerBundleIdentifier(preferredViewer: preferredViewer,
                                                           folderHandler: folderHandler) else {
            return .finderReveal(fileURL)
        }
        return .openParentFolder(fileURL.deletingLastPathComponent(),
                                 appBundleIdentifier: viewer)
    }

    // MARK: - 双击 / Return 打开

    /// - Parameters:
    ///   - url: 要打开的本地 URL（`.mountedFile`）。
    ///   - itemKind: 结果行的 `SearchResult.kind`。实际链路必填；`nil` 只在
    ///     夹具/老数据里出现，此时退回 URL 自身的目录形态。
    ///   - preferredViewer / folderHandler: 同 `preferredViewerBundleIdentifier`。
    ///
    /// ★ 只改派**文件夹**：普通文件继续交系统默认应用。把文件也递给第三方，
    ///   等于替用户改掉所有文件的默认打开方式，比原 bug 更糟。
    /// ★ `itemKind` 与 URL 形态都没有目录证据时按普通文件处理。这不是「判定它是
    ///   文件」，而是「没有任何理由改变现状」；结果行 `kind` 是 init 必填字段，
    ///   真实搜索链路不会走到这个兜底。
    public static func openingRoute(for url: URL,
                                    itemKind: String?,
                                    preferredViewer: String?,
                                    folderHandler: String?) -> FileViewerOpenRoute {
        guard let viewer = preferredViewerBundleIdentifier(preferredViewer: preferredViewer,
                                                           folderHandler: folderHandler),
              isDirectory(itemKind: itemKind, url: url) else {
            return .systemDefault(url)
        }
        return .preferredViewer(url, appBundleIdentifier: viewer)
    }

    /// 目录的两条正向证据：`kind == "directory"`（NAS / Spotlight / 预览统一口径），
    /// 或 file URL 构造时就带 `isDirectory: true`（`hasDirectoryPath`）。
    /// `.app` 虽然是目录，但 `kind == "app"`，双击该启动应用而不是拿管理器浏览。
    private static func isDirectory(itemKind: String?, url: URL) -> Bool {
        if normalized(itemKind) == directoryKind { return true }
        return url.hasDirectoryPath
    }

    private static func normalized(_ identifier: String?) -> String? {
        guard let trimmed = identifier?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
    }
}
