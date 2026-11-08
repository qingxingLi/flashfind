import AppKit
import FlashFindCore

/// 文件查看器动作的**唯一执行点**：⌘↩ / 右键定位，以及双击 / Return 打开。
///
/// 判定在 Core 的 `FileViewerRouting`（可测），这里只读系统偏好、按结论调用
/// AppKit。两条链都走这里 —— 2026-11-06 第二轮报障就是「定位认 Path Finder、
/// 双击文件夹却仍开访达」：双击那条路走 `NSWorkspace.open(目录URL)`，问的是
/// Launch Services 的 `public.folder` handler（本机是 `com.apple.finder`），
/// 完全不读 `NSFileViewer`。
///
/// ★ 不能只问一次「系统默认应用」就完事：本机实测
///   `defaults read -g NSFileViewer` = `com.cocoatech.PathFinder`，
///   而 Launch Services 的 `public.folder` handler 仍是 `com.apple.finder`。
///   只问后者会得出「用户用访达」的错误结论。两条证据都交给 Core 裁决。
///
/// ★ 第三方打开必须用**异步回调的真实结果**：`open(_:withApplicationAt:)` 没有
///   同步返回值，上一版无条件 `return true` 会让「其实没打开」也被当成成功，
///   浮窗照样收起、错误提示永远不出现。回调不在主线程，完成后回 MainActor。
@MainActor
enum FileViewerRevealer {
    typealias Completion = @MainActor (Bool) -> Void

    /// ⌘↩ / 右键「在 Finder 中显示」、下载到…完成后的定位、Quick Look 兜底。
    /// - Parameter completion: 是否真的把打开动作交给了系统。调用方据此决定
    ///   收浮窗还是留在屏幕上显示错误提示。
    static func reveal(_ fileURL: URL, completion: @escaping Completion = { _ in }) {
        let folder = fileURL.deletingLastPathComponent()
        let preferred = UserDefaults.standard.string(forKey: preferredViewerKey)
        let handler = folderHandler(for: folder)
        switch FileViewerRouting.route(for: fileURL,
                                       preferredViewer: preferred,
                                       folderHandler: handler) {
        case .finderReveal(let url):
            // 访达：保留「打开并选中文件」。activateFileViewerSelecting 走
            // Launch Services 而非 Apple Event，不需要「控制访达」授权。
            NSWorkspace.shared.activateFileViewerSelecting([url])
            completion(true)

        case .openParentFolder(let folder, let bundleID):
            // 第三方没有通用的「选中文件」接口，只能打开所在目录。
            openInPreferredViewer(folder, bundleID: bundleID, completion: completion)
        }
    }

    /// 双击 / Return 打开一条结果。
    ///
    /// ★ 只有**文件夹**才会改派给第三方；普通文件继续交系统默认应用，
    ///   否则 .pdf / .xlsx 的默认程序会被文件管理器顶掉。判据在 Core
    ///   `openingRoute(for:itemKind:…)`，这里只把结果行的 `kind` 递过去。
    static func open(_ url: URL, itemKind: String, completion: @escaping Completion) {
        let preferred = UserDefaults.standard.string(forKey: preferredViewerKey)
        let handler = folderHandler(for: url.deletingLastPathComponent())
        switch FileViewerRouting.openingRoute(for: url, itemKind: itemKind,
                                              preferredViewer: preferred,
                                              folderHandler: handler) {
        case .systemDefault(let url):
            completion(NSWorkspace.shared.open(url))

        case .preferredViewer(let url, let bundleID):
            openInPreferredViewer(url, bundleID: bundleID, completion: completion)
        }
    }

    /// 把目录显式交给用户选的文件管理器。
    private static func openInPreferredViewer(_ url: URL, bundleID: String,
                                              completion: @escaping Completion) {
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            // 偏好指向的 App 找不到了：交回系统默认，绝不退回「强制访达」——
            // 用户明明选过第三方，找不到 App 不是「他改回访达了」的证据。
            completion(NSWorkspace.shared.open(url))
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        // ★ 显式置前：本机实测不写这一行时窗口会开在访达后面，用户看到的
        //   仍是访达，会以为「改了没生效」。Path Finder 实测窗口标题就是目标目录。
        configuration.activates = true
        NSWorkspace.shared.open([url], withApplicationAt: appURL,
                                configuration: configuration) { app, error in
            let succeeded = app != nil && error == nil
            Task { @MainActor in completion(succeeded) }
        }
    }

    /// `defaults write -g NSFileViewer -string <bundle id>` —— Path Finder /
    /// ForkLift 这类管理器「设为默认文件查看器」写的就是这一项。
    /// `UserDefaults.standard` 的搜索列表包含全局域，实测能读到。
    private static let preferredViewerKey = "NSFileViewer"

    private static func folderHandler(for folder: URL) -> String? {
        // 用 isDirectory 的 URL 问 Launch Services，避免目标文件万一已不在时
        // 落到「按普通文件找默认 App」上去。
        let directory = URL(fileURLWithPath: folder.path, isDirectory: true)
        return NSWorkspace.shared.urlForApplication(toOpen: directory)
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
    }
}
