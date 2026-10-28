import AppKit
import SwiftUI
import QuartzCore
import FlashFindCore

private final class SearchPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

private final class TransparentHostingView<Content: View>: NSHostingView<Content> {
    override var isOpaque: Bool { false }
}

/// 搜索区的两块窗口都登记在这里，键盘监视器据此判断「这个事件算不算在搜索区里」。
///
/// ★ 为什么需要一份登记表：键盘监视器挂在搜索框那一块的视图上，但它必须对
///   **结果那一块窗口**里的按键同样生效（点过结果再按 ↑↓ / 空格 / 回车的场景）。
///   逐个窗口 `===` 比较散在几处，删一块窗口就会漏一处，所以集中在这里。
@MainActor
final class SearchWindowRegistry {
    static let shared = SearchWindowRegistry()
    private weak var field: NSWindow?
    private weak var results: NSWindow?

    func register(field: NSWindow, results: NSWindow) {
        self.field = field
        self.results = results
    }

    func contains(_ window: NSWindow) -> Bool {
        window === field || window === results
    }

    /// 搜索框那一块窗口的 frame。
    ///
    /// ★ 钉住时要拿它当锚点：「钉住」出来的是一块 10 行高的窗口，
    ///   按「key window 的原点」摆的话会正好盖住搜索框（第一次跑就盖住了）。
    var fieldFrame: NSRect? { field?.frame }
}

/// 搜索框那一块窗口 + 结果那一块窗口的**协调者**。
///
/// ## 2026-10-28：一块拆成两块
///
/// 用户：「钉住前后的搜索框和搜索结果都应该可以单独移动」。同一个窗口里两块
/// 只能一起动，所以这里从此管**两**个 `NSPanel`：
/// * 搜索框那一块（`SearchView`）：固定高，只由「有没有键位提示」决定；
/// * 结果那一块（`SearchResultsPanelView`）：有内容才出现，高度随结果变；
///   第一次出现时贴在搜索框下方 10pt，**之后各自独立**（拖搜索框不再带着它走）。
///
/// ★ 两块窗口都**没有任何表面**：玻璃由各自的模块画（`SearchModuleSurface`），
///   中间那道 10pt 是两块窗口之间的真实空隙——桌面从里面透过来。
@MainActor
final class SearchPanelController {
    private let panel: NSPanel
    private let results: SearchResultsPanelController
    var isKeyWindow: Bool { panel.isKeyWindow }
    private let model: AppModel
#if DEBUG
    private var hasValidatedPreview = false
#endif
    private var showObserver: NSObjectProtocol?
    private var toggleObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?

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
        // ★ 窗口自己**不再有任何表面**（2026-10-27 模块化）。
        //
        // 原来是「一整块玻璃 + 里面一行一行」，于是只有搜索框时外面还裹着一层壳、
        // 胶囊四周多出遮罩。现在窗口只提供一块透明画布，模块自己画玻璃。
        //
        // 阴影必须关掉：透明窗口的 `hasShadow` 是按**窗口矩形**算的，
        // 会在圆角外面画一整块方形阴影。两块窗口各关各的。
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 640, height: SearchLayout.searchHeight)
        panel.maxSize = NSSize(width: 900, height: SearchLayout.searchHeight + 38)
        panel.appearance = AppEnvironment.previewAppearance
        let host = TransparentHostingView(rootView: SearchView(model: model))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        results = SearchResultsPanelController(model: model)
        results.onBecameVisible = { [weak self] in self?.placeResultsBelowField() }
        SearchWindowRegistry.shared.register(field: panel, results: results.panel)

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
        // 结果窗收起来 / 点了「钉住」之后，把 key 交回搜索框。
        focusObserver = NotificationCenter.default.addObserver(forName: .focusFlashFindField, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.focusField() }
        }
        hideObserver = NotificationCenter.default.addObserver(forName: .flashFindPanelHidden, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.removeClickOutsideMonitor() }
        }
        // 把「收起浮窗」这件事交回给面板自己。
        // AppModel 不持有窗口，以前它用 `NSApplication.shared.keyWindow` 猜，
        // 而点在**其它应用**上时闪寻已失去前台、keyWindow 常为 nil，
        // 于是「点了外面，浮窗还杵在那儿」。谁持有窗口谁负责收。
        model.hidePanel = { [weak self] in
            self?.panel.orderOut(nil)
            self?.results.hide()
        }
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
        // 点在自己这几块窗口之内一律不关。这一条同时覆盖三件事：
        // 「点结果行 / 输入框」「按住浮窗空白处拖动」以及 2026-10-28 之后
        // **点在那块独立的结果窗口上**——两块窗不再是同一个窗口，只判一个 frame 就会
        // 出现「点一下结果，两块窗口一起消失」。
        //
        // ★★ 豁免列表只能收**此刻可见**的窗口（2026-10-28 报障：
        //   「搜索结果钉住后，关闭搜索结果，搜索框不再点击任意位置关闭」）。
        //   `orderOut` **不清 frame**：结果窗被收起来之后，那块 680×470 的矩形
        //   仍然原地不动地留在搜索框正下方，于是变成一片看不见的禁点区——
        //   用户看着是空桌面，点下去却不收窗。而钉住的窗口关掉之后也是一样
        //   （`isReleasedWhenClosed = false`，窗口对象与 frame 都还在）。
        //   判定住 Core（`SearchClickOutside`，可测），这里只负责把「可见」筛对。
        //
        // ★ 用 `canBecomeKey` 再收一道：菜单、提示、状态栏这类辅助窗口
        //   在弹出瞬间 `isVisible` 也为真，把它们算成「自家窗口」会误豁免点击。
        //   搜索框、结果窗、钉住窗、设置窗都是能成为 key 的，不受影响。
        let ownVisibleFrames = NSApp.windows
            .filter { $0 !== panel && $0.isVisible && $0.canBecomeKey }
            .map(\.frame)
        guard SearchClickOutside.shouldDismiss(click: NSEvent.mouseLocation,
                                               field: panel.frame,
                                               otherVisibleWindows: ownVisibleFrames) else { return }
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
        // 结果那一块：有内容就摆到搜索框下方并显示。
        //
        // ★ 这里与 `SearchResultsPanelVisibility` 是**同一条规则的两条触发路径**
        //   （一个是「显示时补一次」，一个是「内容变了跟着变」），两处都只会
        //   orderFront / orderOut，重复调用没有副作用。
        // ★ `beginSession()` 在最前面：一次新的唤起 = 回到「结果贴在搜索框下面」的默认，
        //   用户上一轮把结果拖到哪儿都翻篇。
        results.beginSession()
        placeResultsBelowField()
        results.refreshVisibility(hasContent: model.hasSearchContent)
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

    /// 把结果窗口的上沿贴到搜索框下沿下方 `moduleGap` 处。
    ///
    /// ★ 只在「第一次显示」与「每次唤起」时做：用户把它拖到别处之后，
    ///   任何自动回位都是在跟用户抢位置。拖动搜索框也不带着它走（用户明确选的）。
    private func placeResultsBelowField() {
        results.align(under: panel.frame, gap: SearchModuleLayout.moduleGap)
    }

    /// 把键盘交回搜索框。
    ///
    /// ★ 先 `activate` 再 `makeKey`：非激活态下 `makeKeyAndOrderFront` 会返回 true
    ///   但 `keyWindow` 仍是 nil，窗口整组留在前台 App 下面（真机踩过）。
    private func focusField() {
        guard panel.isVisible else { return }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

#if DEBUG
    /// 三处「空白处」的命中测试结果：视图类型 + 是否允许窗口背景拖动。
    ///
    /// ★ 两块窗口各测一遍：拖动这条缺陷（2026-10-28）在拆窗之后仍然只可能
    ///   出在「表面把 `hitTest` 吃掉了」这一处，而两块用的是同一个修饰器——
    ///   任何一块测出非 nil 的 hit 都说明修饰器又被绕过了。
    private static func dragProbes(panel: NSPanel, results: NSPanel?) -> [[String: Any]] {
        var output: [[String: Any]] = []
        func probe(_ window: NSPanel, _ label: String, _ name: String, _ point: NSPoint) {
            guard let host = window.contentView else { return }
            let hit = host.hitTest(point)
            output.append([
                "window": label,
                "name": name,
                "point": [Int(point.x), Int(point.y)],
                "hit": hit.map { String(describing: type(of: $0)) } ?? "nil",
                "canMoveWindow": hit?.mouseDownCanMoveWindow ?? false,
                "hostCanMoveWindow": host.mouseDownCanMoveWindow,
            ])
        }
        if let host = panel.contentView {
            let size = host.bounds.size
            probe(panel, "field", "field-leading-padding",
                  NSPoint(x: 6, y: size.height - SearchLayout.searchHeight / 2))
            probe(panel, "field", "field-trailing-padding",
                  NSPoint(x: size.width - 4, y: size.height / 2))
        }
        if let results, let host = results.contentView {
            let size = host.bounds.size
            // 结果窗：类型条左端与状态栏左下都是空白。
            probe(results, "results", "type-bar-leading-padding",
                  NSPoint(x: 4, y: size.height - SearchModuleLayout.typeBarHeight / 2))
            probe(results, "results", "status-bar-left", NSPoint(x: 6, y: 6))
        }
        return output
    }

    /// 写一份「面板此刻真的长这样」的证据 JSON 到包外 Evidence/。
    private func writePreviewEvidence() {
        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Evidence", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let screenHeight = NSScreen.screens.first?.frame.maxY ?? panel.frame.maxY
        // 截图要能同时框住两块窗口：只看搜索框那一块的话，
        // 「结果窗在哪、贴没贴住」这件事在证据里根本看不见。
        var captureFrame = panel.frame
        if results.panel.isVisible { captureFrame = captureFrame.union(results.panel.frame) }
        let record: [String: Any] = [
            "windowNumber": panel.windowNumber,
            "resultsWindowNumber": results.panel.isVisible ? results.panel.windowNumber : 0,
            "screenRect": [Int(captureFrame.minX - 24), Int(screenHeight - captureFrame.maxY - 24), Int(captureFrame.width + 48), Int(captureFrame.height + 48)],
            "windowSize": [panel.frame.width, panel.frame.height],
            "resultsWindowSize": [results.panel.frame.width, results.panel.frame.height],
            "resultsWindowOrigin": [results.panel.frame.minX, results.panel.frame.minY],
            "resultsWindowOffset": results.panel.frame.minY - (panel.frame.minY - SearchModuleLayout.moduleGap),
            "resultsUserMoved": results.userMoved,
            "windowOpaque": panel.isOpaque,
            "hostingOpaque": false,
            "material": String(describing: type(of: panel.contentView!)),
            "glassClassAvailable": NSClassFromString("NSGlassEffectView") != nil,
            "preview": true,
            "backdrop": ProcessInfo.processInfo.environment["FF_UI_DESKTOP"] == "1" ? "temporary native window displaying the system desktop wallpaper" : "actual windows behind panel",
            "desktopImageAvailable": NSScreen.main.flatMap { NSWorkspace.shared.desktopImageURL(for: $0) }.flatMap { NSImage(contentsOf: $0) } != nil,
            "query": model.query,
            "resultCount": model.results.count,
            // 上限（200）之外的**真实**匹配数：截图脚本据此判断「是 200 条截断态」
            // 还是「本来就只有这么多」，不必靠数像素。
            "matchedResultCount": model.matchedResultCount,
            "appearance": panel.effectiveAppearance.name.rawValue,
            "keyWindow": panel.isKeyWindow,
            "resultsIsKeyWindow": results.panel.isKeyWindow,
            "firstResponder": panel.firstResponder.map { String(describing: type(of: $0)) } ?? "none",
            "roundedMaterialMask": (panel.contentView as? NSVisualEffectView)?.maskImage != nil,
            "mainMenuTitles": NSApplication.shared.mainMenu?.items.map(\.title) ?? [],
            "sheetAttached": panel.attachedSheet != nil,
            "sheetSize": panel.attachedSheet.map { [$0.frame.width, $0.frame.height] } ?? [],
            // ★ 「能不能拖」的判据（2026-10-28 报障：搜索框不能拖动了）。
            //
            // AppKit 决定「按在窗口背景上要不要开始拖动」只有两步：
            // ① `hitTest` 找出光标下那个视图；② 问它 `mouseDownCanMoveWindow`。
            // 所以这两个量就是这条缺陷的唯一判据——截图看不出来，肉眼也看不出来。
            "dragProbes": Self.dragProbes(panel: panel, results: results.panel.isVisible ? results.panel : nil),
            "cacheRoot": AppEnvironment.previewRoot.path,
            "networkEnabled": model.enabled
        ]
        if let data = try? JSONSerialization.data(withJSONObject: record, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: root.appendingPathComponent("current-window.json"), options: .atomic)
        }
    }
#endif

    deinit {
        if let showObserver { NotificationCenter.default.removeObserver(showObserver) }
        if let toggleObserver { NotificationCenter.default.removeObserver(toggleObserver) }
        if let focusObserver { NotificationCenter.default.removeObserver(focusObserver) }
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
///
/// ★ 两块窗口共用：搜索框那块高度基本不变（只在键位提示显隐时变一次），
///   结果那块随结果增减而变——两者都必须**上沿固定**，否则窗口会往上蹿。
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
            if animate && panel.isVisible {
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.18
                    context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                    panel.animator().setFrame(frame, display: true)
                }
            } else {
                panel.setFrame(frame, display: true)
            }
            panel.invalidateShadow()
        }
    }
}
