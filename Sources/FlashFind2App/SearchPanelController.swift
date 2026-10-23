import AppKit
import SwiftUI

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// One material owns the entire floating search surface, including expanded results.
@MainActor
final class SearchPanelController {
    private let panel: NSPanel
    private let model: AppModel
#if DEBUG
    private var hasValidatedPreview = false
#endif
    private var showObserver: NSObjectProtocol?
    private var toggleObserver: NSObjectProtocol?

    init(model: AppModel) {
        self.model = model
        panel = SearchPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: SearchLayout.searchHeight),
                            styleMask: [.borderless], backing: .buffered, defer: false)
        if AppEnvironment.isPreview, let width = ProcessInfo.processInfo.environment["FF_UI_WIDTH"].flatMap(Double.init) {
            panel.setContentSize(NSSize(width: min(900, max(640, width)), height: SearchLayout.searchHeight))
        }
        panel.title = "闪寻"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 640, height: SearchLayout.searchHeight)
        panel.maxSize = NSSize(width: 900, height: 620)
        panel.appearance = AppEnvironment.previewAppearance
        let material = NativeMaterialView.makeView()
        let host = TransparentHostingView(rootView: SearchView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        host.translatesAutoresizingMaskIntoConstraints = false
        material.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: material.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: material.trailingAnchor),
            host.topAnchor.constraint(equalTo: material.topAnchor),
            host.bottomAnchor.constraint(equalTo: material.bottomAnchor)
        ])
        panel.contentView = material
        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.28 - SearchLayout.searchHeight))
        }
        showObserver = NotificationCenter.default.addObserver(forName: .showFlashFind2, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.show() }
        }
        toggleObserver = NotificationCenter.default.addObserver(forName: .toggleFlashFind2, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.toggle() }
        }
        hideObserver = NotificationCenter.default.addObserver(forName: .flashFindPanelHidden, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.removeClickOutsideMonitor() }
        }
        // 把「收起浮窗」这件事交回给面板自己。
        // AppModel 不持有窗口，以前它用 `NSApplication.shared.keyWindow` 猜，
        // 而点在**其它应用**上时闪寻已失去前台、keyWindow 常为 nil，
        // 于是「点了外面，浮窗还杵在那儿」。谁持有窗口谁负责收。
        model.hidePanel = { [weak self] in self?.panel.orderOut(nil) }
        // 与上一句成对：关掉设置/向导后若屏幕上没有别的窗口，由这里把浮窗放回来。
        // 走 `show()` 而不是 `orderFront`，是为了和「按快捷键唤起」完全同一条路径——
        // 查询词恢复、键位提示、点击外部关闭的监视都在里面，少走一样就会出现
        // 「浮窗回来了但点外面关不掉」这种只在某条路径上坏掉的缺陷。
        model.showPanel = { [weak self] in self?.show() }
    }
    func toggle() {
        if let modal = NSApplication.shared.modalWindow ?? panel.attachedSheet {
            NSApplication.shared.activate(ignoringOtherApps: true); modal.makeKeyAndOrderFront(nil); return
        }
        if panel.isVisible && panel.isKeyWindow { model.hideSearch() }
        else { NotificationCenter.default.post(name: .showFlashFind2, object: nil) }
    }
    /// 「是否已安装点击监视」的标记，兼作本地监视句柄。
    private var clickMonitor: Any?
    private var localClickMonitor: Any?
    /// 失焦后补挂的全局监视句柄。只在非前台期间存在。
    private var globalClickMonitor: Any?
    private var resignObserver: NSObjectProtocol?
    private var hideObserver: NSObjectProtocol?

    /// 浮窗显示期间，点击面板之外的任何位置都关闭——包括点其它应用的窗口。
    ///
    /// 用两个监视器配合，缺一不可：
    /// - `addLocalMonitorForEvents` 收**本应用**内的事件（点自己的设置窗口等）；
    /// - `addGlobalMonitorForEvents` 收**其它应用**的事件，但按文档它
    ///   只在应用**不处于前台**时触发——浮窗显示时闪寻已在前台，
    ///   所以还要靠 `NSApp.didResignActiveNotification` 在失去焦点后补挂，
    ///   否则「点其它应用窗口关闭」这个最常见的场景会失效。
    ///
    /// 只监听 `leftMouseDown`：判断成本极低，且不需要辅助功能权限。
    private func installClickOutsideMonitor() {
        guard clickMonitor == nil else { return }
        let handle: (NSEvent) -> Void = { [weak self] _ in
            Task { @MainActor in self?.dismissIfClickOutside() }
        }
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown], handler: handle)
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown]) { event in
            handle(event)
            return event
        }
        // 失去前台焦点后补挂全局监视，覆盖「点其它应用窗口关闭」。
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didResignActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refreshGlobalMonitor() }
        }
        refreshGlobalMonitor()
    }

    /// 失去前台时补挂、回到前台时摘掉全局监视。
    ///
    /// 全局事件监视不是免费的：挂着时每次点击都会进一次回调。
    /// 闪寻在前台时用不着它（点击都在本地监视范围内），摘掉省开销。
    private func refreshGlobalMonitor() {
        guard clickMonitor != nil || localClickMonitor != nil else { return }
        if let existing = globalClickMonitor { NSEvent.removeMonitor(existing); globalClickMonitor = nil }
        guard !NSApp.isActive else { return }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown]) { [weak self] _ in
            Task { @MainActor in self?.dismissIfClickOutside() }
        }
    }

    private func dismissIfClickOutside() {
        guard panel.isVisible else { return }
        // 点在本浮窗之内一律不关。这一条同时覆盖两件事：
        // 「点结果行/输入框」和「按住浮窗空白处拖动」——拖动时按下点仍在窗内。
        //
        // 这里以前还有一句 `guard NSEvent.pressedMouseButtons == 0 else { return }`，
        // 意图是「正在拖拽就不算点击」。但监视的事件是 `leftMouseDown`，
        // 此刻左键必然处于按下状态，这个条件**恒为假** ——
        // 结果是「点击外部关闭」这个功能从未真正生效过。已删除。
        guard !panel.frame.contains(NSEvent.mouseLocation) else { return }
        // 点在**闪寻自己的其它窗口**上（设置窗口、添加 NAS 向导）不算「外面」。
        // 少了这一条会出真问题：从搜索窗点「设置…」，设置窗口刚要打开，
        // 同一次点击被判成「点了外面」把浮窗关掉，用户看到的是设置窗口一闪就没。
        //
        // 判据用**点击位置**而不是 `NSApp.keyWindow`：应用一失活 keyWindow
        // 常常就是 nil，而「设置窗口开着、用户去点桌面」这种场景下，
        // 用 keyWindow 会误把桌面点击豁免掉，浮窗又关不上了。
        let location = NSEvent.mouseLocation
        if NSApp.windows.contains(where: { $0 !== panel && $0.isVisible && $0.frame.contains(location) }) {
            return
        }
        model.hideSearch()   // 通知会顺带卸载监视，这里不用重复
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
        clickMonitor = nil; localClickMonitor = nil; globalClickMonitor = nil; resignObserver = nil
    }

    func show() {
        model.showSearch()
        // 首次使用的那行键位提示：只显示一次，输入或操作后收起（见 `SearchHintGuide`）。
        model.showSearchHintsIfNeeded()
        installClickOutsideMonitor()
        if AppEnvironment.isPreview, ProcessInfo.processInfo.environment["FF_UI_PASSIVE"] == "1" {
            panel.orderFrontRegardless()
        } else {
            NSApplication.shared.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
        }
        panel.invalidateShadow()
#if DEBUG
        if AppEnvironment.isPreview {
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
                self?.writePreviewEvidence()
                if ProcessInfo.processInfo.environment["FF_UI_VALIDATE"] == "1", let self, !self.hasValidatedPreview {
                    self.hasValidatedPreview = true
                    PreviewInteractionValidation.run(panel: self.panel, model: self.model)
                }
            }
        }
#endif
    }

#if DEBUG
    /// 写一份「面板此刻真的长这样」的证据 JSON 到包外 Evidence/。
    private func writePreviewEvidence() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? panel.frame.maxY
        let frame = panel.frame
        let captureFrame = panel.attachedSheet.map { frame.union($0.frame) } ?? frame
        let record: [String: Any] = [
            "windowNumber": panel.windowNumber,
            "screenRect": [Int(captureFrame.minX - 24), Int(screenHeight - captureFrame.maxY - 24), Int(captureFrame.width + 48), Int(captureFrame.height + 48)],
            "windowSize": [frame.width, frame.height],
            "windowOpaque": panel.isOpaque,
            "hostingOpaque": panel.contentView?.subviews.first?.isOpaque ?? true,
            "material": "NSVisualEffectView.popover",
            "blendingMode": "behindWindow",
            "glassClassAvailable": NSClassFromString("NSGlassEffectView") != nil,
            "preview": true,
            "backdrop": ProcessInfo.processInfo.environment["FF_UI_DESKTOP"] == "1" ? "temporary native window displaying the system desktop wallpaper" : "actual windows behind panel",
            "desktopImageAvailable": NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { NSImage(contentsOf: $0) } != nil,
            "query": model.query,
            "resultCount": model.results.count,
            "appearance": panel.effectiveAppearance.name.rawValue,
            "keyWindow": panel.isKeyWindow,
            "firstResponder": panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
            "roundedMaterialMask": (panel.contentView as? NSVisualEffectView)?.maskImage != nil,
            "mainMenuTitles": NSApplication.shared.mainMenu?.items.map(\.title) ?? [],
            "sheetAttached": panel.attachedSheet != nil,
            "sheetSize": panel.attachedSheet.map { [$0.frame.width, $0.frame.height] } ?? [],
            "cacheRoot": AppEnvironment.previewRoot.path,
            "networkEnabled": model.enabled,
            "rememberPassword": model.rememberPassword
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("current-window.json"), options: .atomic)
        }
    }
#endif

    deinit {
        if let showObserver { NotificationCenter.default.removeObserver(showObserver) }
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        if let hideObserver { NotificationCenter.default.removeObserver(hideObserver) }
        Self.tearDown(global: globalClickMonitor,
                       local: localClickMonitor,
                       marker: clickMonitor,
                       observer: resignObserver)
    }

    /// 从 deinit 调用的清理入口。
    ///
    /// deinit 不在主 actor 上，不能直接调 actor 隔离的方法，
    /// 因此这里显式标 `nonisolated`——它只做系统调用，不碰任何状态。
    private nonisolated static func tearDown(global: Any?, local: Any?, marker: Any?, observer: NSObjectProtocol?) {
        if let monitor = global { NSEvent.removeMonitor(monitor) }
        if let monitor = local { NSEvent.removeMonitor(monitor) }
        if let observer { NotificationCenter.default.removeObserver(observer) }
        _ = marker   // clickMonitor 与 localClickMonitor 是同一批句柄
    }
}

/// SwiftUI supplies the content height. Keep the top edge fixed when results unfold.
struct SearchPanelSizing: NSViewRepresentable {
    let height: CGFloat
    let animate: Bool
    func makeNSView(context: Context) -> NSView { NSView() }
    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async { [weak view] in
            guard let panel = view?.window as? NSPanel, abs(panel.frame.height - height) > 0.5,
                  panel.attachedSheet == nil else { return }
            var frame = panel.frame
            frame.origin.y += frame.height - height
            frame.size.height = height
            panel.setFrame(frame, display: true, animate: animate && panel.isVisible)
            panel.invalidateShadow()
        }
    }
}
