import AppKit
import QuickLook
import QuickLookUI

/// Quick Look 宿主。
///
/// 系统的 `QLPreviewPanel` 需要一个 responder 充当 `QLPreviewPanelDataSource`，
/// 否则面板能打开却是一片空白。这里由本类直接提供单个预览项——
/// 闪寻一次只预览一个文件，不需要列表。
///
/// QuickLook 面板在自己的线程上回调 datasource，而写入发生在主线程。
/// 这里用一把锁做同步：`urls` 只有一个元素，读写都很短，
/// 不需要为了这点数据引入 actor 或 `assumeIsolated`（后者在非主线程会崩）。
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate, @unchecked Sendable {
    private static let lock = NSLock()
    private static var shared: QuickLookPreview?
    private var urls: [URL] = []
    @MainActor private static let controller = QuickLookPanelController()

    @MainActor
    static func present(_ url: URL) {
        lock.lock()
        let host = shared ?? QuickLookPreview()
        shared = host
        let sameItem = host.urls.first == url
        host.urls = [url]
        lock.unlock()

        guard let panel = QLPreviewPanel.shared() else {
            // 系统关闭了 Quick Look：退回打开文件，至少不静默无响应。
            if !NSWorkspace.shared.open(url) { NSWorkspace.shared.activateFileViewerSelecting([url]) }
            return
        }
        if panel.isVisible, sameItem {
            panel.orderOut(nil)
            return
        }
        controller.dataSource = host
        if NSApp.nextResponder !== controller {
            controller.nextResponder = NSApp.nextResponder
            NSApp.nextResponder = controller
        }
        panel.updateController()
        panel.makeKeyAndOrderFront(nil)
        panel.reloadData()
    }

    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard event.type == .keyDown, event.keyCode == 49,
              event.modifierFlags.intersection([.command, .control, .option, .shift]).isEmpty else { return false }
        panel.orderOut(nil)
        return true
    }

    private func snapshot() -> [URL] {
        Self.lock.lock(); defer { Self.lock.unlock() }
        return urls
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { snapshot().count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> any QLPreviewItem {
        let items = snapshot()
        // 索引越界说明面板与数据不同步，返回一个根路径而不是崩溃。
        guard items.indices.contains(index) else { return URL(fileURLWithPath: "/") as NSURL }
        return items[index] as NSURL
    }

    func previewPanelDidClose(_ panel: QLPreviewPanel!) {
        Self.lock.lock(); urls = []; Self.lock.unlock()
    }
}

/// 控制权属于主线程响应链；数据源保留独立的加锁实现，供 Quick Look 后台回调。
@MainActor
private final class QuickLookPanelController: NSResponder {
    var dataSource: QuickLookPreview?

    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { dataSource != nil }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = dataSource
        panel.delegate = dataSource
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        panel.dataSource = nil
        panel.delegate = nil
    }



}
