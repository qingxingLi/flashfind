import AppKit
import QuickLook
import FlashFindCore

/// 搜索结果的动作：打开、在访达中定位、快速查看、复制路径 / 文件名，以及失败提示。
///
/// 从 AppModel 里切出来的理由和 `ShortcutController` 一样：这些动作只依赖
/// 「当前结果行怎么解析 / 文件 URL 怎么拿 / 状态写到哪」这几个入口，
/// 把它们做成注入的闭包后，这块就能独立于 AppModel 那 20 多个 `@Published` 存在。
///
/// 反过来也说明它的边界：解析要用的状态一个都没搬过来，仍由宿主提供闭包。
/// 硬搬只会换来一个要 6 个回调、还和搜索状态互相引用的类型。
@MainActor
final class ResultActionController: ObservableObject {
    /// 打开失败时弹出的可操作提示。空白处点击或 Esc 即消失。
    struct Failure: Identifiable {
        let id = UUID()
        let message: String
        /// 非空时提示条上多一个「在访达中连接」按钮。
        var smbURL: String? = nil
    }

    @Published var failure: Failure?

    // MARK: - 宿主注入的入口

    /// 取「当前仍可操作」的结果行。搜索或权限已变化时返回 nil。
    ///
    /// 判定要读结果集、来源开关、运行时权限版本等一堆状态，那些留在宿主；
    /// 这里只要结论。
    var resolveRow: (SearchResult) -> SearchResult? = { _ in nil }
    /// 解析结果的本地 URL。NAS 来源未挂载时会**发起挂载**，因此是 async。
    var fileURL: (SearchResult) async throws -> URL = { _ in
        throw FlashFindError.message("尚未就绪")
    }
    /// 只查已挂载的解析结果，不触发挂载。复制路径用（没挂载时给逻辑路径更有用）。
    var fileURLWithoutMounting: (SearchResult) throws -> URL = { _ in
        throw FlashFindError.message("尚未就绪")
    }
    var preferredOpenTarget: (SearchResult) async throws -> SearchOpenTarget = { _ in
        throw FlashFindError.message("尚未就绪")
    }
    /// 状态栏文案。动作过程中的「正在连接…」和最后的提示都走这里。
    var onStatus: (String) -> Void = { _ in }
    /// 让浮窗收起。定位到访达后必须让位，否则浮窗还压在访达上面。
    var onHidePanel: () -> Void = {}

    // MARK: - 动作

    func open(_ result: SearchResult, reveal: Bool = false) {
        guard !AppEnvironment.isPreview else { onStatus("UI 预览 · 文件操作已隔离"); return }
        guard let row = resolveRow(result) else {
            onStatus("搜索或权限已变化，请重新选择结果"); return
        }
        onStatus("正在检查打开位置…")
        Task {
            do {
                let target = try await preferredOpenTarget(row)
                guard resolveRow(row) != nil else {
                    onStatus("搜索或权限已变化，请重新选择结果"); return
                }
                if case .webURL(let url) = target {
                    guard !reveal else {
                        onStatus("此文件没有可用的本机挂载路径，请直接打开以使用浏览器"); return
                    }
                    if NSWorkspace.shared.open(url) {
                        onStatus(""); onHidePanel()
                    } else {
                        onStatus("系统没有可用的浏览器打开这个链接")
                    }
                    return
                }
                guard case .mountedFile(let url) = target else {
                    throw FlashFindError.message("没有可用的打开位置，请重新搜索")
                }
                // 网络路径已在后台核验；这里再次 stat 会把等待带回主线程。
                if reveal {
                    // 系统默认的文件查看器可能是 Path Finder，这里显式要 Finder。
                    // activateFileViewerSelecting(_:) 走 Launch Services 而不是
                    // Apple Event：无需用户授权「控制 Finder」，命令行与 GUI 行为一致。
                    //
                    // ★ 此后不能再来一句 NSApp.activate：它会把焦点从访达抢回闪寻，
                    // 表现为「访达打开了，但闪寻又弹回前台」，等于定位没生效。
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    onHidePanel()
                } else {
                    if NSWorkspace.shared.open(url) {
                        // 成功打开才收起浮窗：失败时要留着浮窗显示错误提示。
                        // 与 reveal 分支同一教训：打开动作之后闪寻必须让位，
                        // NSWorkspace.open 自己会激活目标 App，不许再抢焦点。
                        onHidePanel()
                    } else {
                        onStatus("系统无法打开此文件，请检查文件权限和关联应用")
                    }
                }
                onStatus("")
            } catch {
                let banner = OpenFailureText.banner(error)
                failure = Failure(message: banner.message, smbURL: banner.smbURL)
                onStatus("")
            }
        }
    }

    /// 快速查看。文件已不可访问时给出可理解的提示，而不是静默失败。
    ///
    /// QLPreviewPanel 需要一个 responder（`QLPreviewPanelDataSource`）才能显示内容，
    /// 这里用自带的预览宿主承载，避免在 App 里实现完整 datasource 协议。
    func quickLook(_ result: SearchResult) {
        guard !AppEnvironment.isPreview else { onStatus("UI 预览 · 文件操作已隔离"); return }
        guard let row = resolveRow(result) else {
            onStatus("搜索或权限已变化，请重新选择结果"); return
        }
        if case .webURL = row.openTarget {
            // 快速查看只认本地文件。这里显式说清「该怎么做」，而不是弹一句
            // 「文件可能已被移动或删除」——那句会让用户以为文件没了。
            onStatus("这个来源的文件在网页上，无法快速查看；按 Return 用浏览器打开")
            return
        }
        Task {
            do {
                let url = try await fileURL(row)
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw FlashFindError.message("文件可能已被移动或删除。")
                }
                QuickLookPreview.present(url)
            } catch {
                onStatus(OpenFailureText.describe(error))
            }
        }
    }

    /// 复制网页链接。**只有网页来源有**，与「复制路径」是两件不同的事。
    ///
    /// 路径是「站点里的位置」（`/A0002/…`），粘到哪里都得先知道是哪个站；
    /// 链接是「能直接点开的地址」（带域名、带百分号编码）。两个菜单项都给，
    /// 标题写清各是什么——只留一个，用户复制出来的东西经常不是他想要的。
    func copyWebLink(_ result: SearchResult) {
        guard !AppEnvironment.isPreview, let row = resolveRow(result) else { return }
        guard case .webURL(let url) = row.openTarget else {
            onStatus("这条结果没有网页链接")
            return
        }
        let board = NSPasteboard.general
        board.clearContents()
        board.setString(url.absoluteString, forType: .string)
        onStatus("已复制网页链接")
    }

    /// 复制路径。**不需要挂载**：没挂载时给 NAS 逻辑路径比给一个不存在的本地路径更有用。
    ///
    /// 网页来源（OpenList）复制的是**站点内的逻辑路径**（`/A0002/…`），
    /// 不是能直接点开的网页链接——那是另一个菜单项。状态栏要如实说一句，
    /// 否则用户粘到浏览器地址栏里会得到「找不到页面」。
    func copyPath(_ result: SearchResult) {
        guard !AppEnvironment.isPreview, let row = resolveRow(result) else { return }
        if case .webURL = row.openTarget {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(row.relativePath, forType: .string)
            onStatus("已复制站点内路径（要在浏览器打开请用「复制网页链接」）")
            return
        }
        let text = (try? fileURLWithoutMounting(row).path) ?? row.relativePath
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// 复制文件名（不含路径）。
    func copyName(_ result: SearchResult) {
        guard !AppEnvironment.isPreview else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(result.name, forType: .string)
    }

    /// 用户在提示条上点「重试」。
    func retryOpen(_ row: SearchResult?) {
        guard let row else { return }
        failure = nil
        open(row)
    }

    /// 用户主动要求时才请访达发起 SMB 连接。
    ///
    /// 这是全 App **唯一**会弹出系统连接窗口的入口。
    func connectInFinder(_ smbURL: String) {
        guard !AppEnvironment.isPreview, let url = URL(string: smbURL) else { return }
        failure = Failure(message: "已请访达发起连接。完成登录后点「重试」即可打开文件。",
                          smbURL: smbURL)
        NSWorkspace.shared.open(url)
    }
}
