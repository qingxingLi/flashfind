import AppKit
import WebKit

/// 只展示离线 HTML 的教学搜索窗；不接入真实查询、文件或凭据。
@MainActor
final class OnboardingSearchDemoWindow: NSObject, NSWindowDelegate, WKScriptMessageHandler {
    static let shared = OnboardingSearchDemoWindow()
    private var window: NSWindow?
    private var webView: WKWebView?
    private var onFinish: ((Bool) -> Void)?
    private var advancing = false

    var isVisible: Bool { window?.isVisible == true }

    func show(onFinish: @escaping (Bool) -> Void) {
        guard window == nil else { return }
        guard let url = Self.documentURL else {
            let alert = NSAlert()
            alert.messageText = "搜索演示暂时无法打开"
            alert.informativeText = "演示文件缺失，可以先继续设置。"
            alert.addButton(withTitle: "继续设置")
            alert.runModal()
            onFinish(true)
            return
        }
        self.onFinish = onFinish
        advancing = false
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.userContentController.add(self, name: "onboarding")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        self.webView = webView
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 620),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "闪寻 · 搜索演示"
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.contentView = webView
        window.center()
        self.window = window
        webView.loadFileURL(url, allowingReadAccessTo: url.deletingLastPathComponent())
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(webView)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    private static var documentURL: URL? {
        if let bundled = Bundle.main.url(forResource: "search-demo", withExtension: "html", subdirectory: "Onboarding") {
            return bundled
        }
        #if DEBUG
        let local = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Resources/Onboarding/search-demo.html")
        if FileManager.default.fileExists(atPath: local.path) { return local }
        #endif
        return nil
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == "onboarding", message.frameInfo.isMainFrame,
              message.body as? String == "continue" else { return }
        advancing = true
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        webView?.configuration.userContentController.removeScriptMessageHandler(forName: "onboarding")
        webView?.stopLoading()
        webView = nil
        window = nil
        let finish = onFinish
        onFinish = nil
        finish?(advancing)
    }
}
