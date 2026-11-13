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

    /// 搜索框**用户设定的位置**（抬高、贴边那些临时位移都不算）。
    ///
    /// ★★ 钉住要用它、不能用 `fieldFrame`（2026-11-01 报障「钉住的内容钻到搜索框下方」）：
    ///   钉住那一刻搜索框往往正因为「结果放不下」被 `SearchWindowLift` 抬着，
    ///   而钉住会立刻清空这一轮（`clearSearchSession`）⇒ 搜索框马上回位。
    ///   按抬起时的位置摆，钉住的窗口就落在搜索框**将要回去的地方**，被它盖掉半截。
    var homeFieldFrame: (@MainActor () -> NSRect?)?
}

/// 搜索框那一块窗口 + 结果那一块窗口的**协调者**。
///
/// ## 2026-10-28：一块拆成两块
///
/// 历史契约（2026-10-28）：「钉住前后的搜索框和搜索结果都应该可以单独移动」。
/// 同一个窗口里两块只能一起动，所以这里从此管**两**个 `NSPanel`：
/// * 搜索框那一块（`SearchView`）：固定高，只由「有没有键位提示」决定；
/// * 结果那一块（`SearchResultsPanelView`）：有内容才出现，高度随结果变；
///   第一次出现时贴在搜索框下方 10pt。
///
/// ★★ 2026-11-08 契约经三次真机反馈定稿：
///   1.1.67 的「各自 `didMove` 追赶」被否（两窗永远差一帧）；
///   1.1.68 改成 **AppKit 父子窗口组** —— 搜索框当父、结果窗当子，由 WindowServer
///   作为一个实体整体移动，这一条真机确认有效（「动画拖动搜索框部分是可以了」）。
///   但 1.1.68 仍让结果窗自己可拖、并把背景 mouseDown 转发给父窗，真机又出现
///   「单独拖动搜索结果还是可以的」。用户随即把契约说死：
///   「**只有固定以后才能拖动，否则就是整体移动**」。
///   ⇒ 1.1.69：未固定的结果窗**不是把手**（拖动能力由 Core `WindowGroupPolicy`
///   关掉），唯一把手是搜索框；只有钉住后的快照窗（`PinnedResultsWindow`）独立可拖。
///
/// ★ 两块窗口都**没有任何表面**：玻璃由各自的模块画（`SearchModuleSurface`），
///   中间那道 10pt 是两块窗口之间的真实空隙——桌面从里面透过来。
@MainActor
final class SearchPanelController {
    private let panel: NSPanel
    private let results: SearchResultsPanelController
    var isKeyWindow: Bool { panel.isKeyWindow }
    /// 系统授权框前后用它判「浮窗还在不在」。判据在
    /// `SystemPromptFocusPolicy.VisibilityBeforePrompt`，这里只报真实窗口状态。
    var isVisible: Bool { panel.isVisible }
    private let model: AppModel
#if DEBUG
    private var hasValidatedPreview = false
#endif
    private var showObserver: NSObjectProtocol?
    private var toggleObserver: NSObjectProtocol?
    private var focusObserver: NSObjectProtocol?
    private var homeObserver: NSObjectProtocol?
    /// 松手监视器：拖动期间跳过的重排在 `leftMouseUp` 这一刻补一次（无动画）。
    private var dragEndMonitor: Any?

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
        results.onLayoutNeeded = { [weak self] in self?.layoutForResults() }
        // ★ 1.1.68：可见性真翻转时同步 AppKit 父子窗口关系。
        //   联动由 WindowServer 负责，这里不再有「拖结果窗通知协调者追赶」的回调。
        results.onVisibilityChanged = { [weak self] visible in
            self?.syncWindowGroup(resultsVisible: visible)
        }
        SearchWindowRegistry.shared.register(field: panel, results: results.panel)
        // 钉住时的锚点走「用户设定的位置」，见 `homeFieldFrame` 的注释。
        SearchWindowRegistry.shared.homeFieldFrame = { [weak self] in self?.homeFrame }

        if let screen = NSScreen.main {
            let frame = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: frame.midX - panel.frame.width / 2, y: frame.maxY - frame.height * 0.28 - SearchLayout.searchHeight))
            homeOrigin = panel.frame.origin
        }
#if DEBUG
        // `FF_UI_FIELD_Y=40`：把搜索框摆到屏幕下方，拍「结果展开时它往上让」的证据。
        // 只在预览包里存在（`AppEnvironment.isPreview` + DEBUG），发布构建整段编译掉。
        if AppEnvironment.isPreview,
           let y = ProcessInfo.processInfo.environment["FF_UI_FIELD_Y"].flatMap(Double.init) {
            panel.setFrameOrigin(NSPoint(x: panel.frame.origin.x, y: y))
            homeOrigin = panel.frame.origin
        }
#endif
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
            // 收窗之前先回到「用户设定的位置」：结果展开时抬上去的位移属于**这一轮**，
            // 下一次唤起要从原位开始（用户：「最后关闭的时候会跳到设定好的位置」）。
            self?.snapHome()
            self?.panel.orderOut(nil)
            self?.results.hide()
            // ★ 父子组必须先解绑：父窗 orderOut 会连带子窗，收起/再次唤起时
            //   系统会把 child 自动重新显示，造成「结果凭空冒出来」。
            self?.syncWindowGroup(resultsVisible: false)
        }
        // 与上一句成对：关掉设置/向导后若屏幕上没有别的窗口，由这里把浮窗放回来。
        // 走 `show()` 而不是 `orderFront`，是为了和「按快捷键唤起」完全同一条路径——
        // 查询词恢复、键位提示、点击外部关闭的监视都在里面，少走一样就会出现
        // 「浮窗回来了但点外面关不掉」这种只在某条路径上坏掉的缺陷。
        model.showPanel = { [weak self] in self?.show() }
        // 用户把搜索框拖到哪儿，「设定好的位置」就更新到哪儿。
        //
        // ★ 这一条**故意**不用 `Task { @MainActor in }`（本文件其余几条通知用的是它）：
        //   `rememberHome()` 读的是 `PointerButton.isDown` 的**即时值**——「这一刻是不是
        //   人手在拖」。多跳一拍就可能读到松开之后的 false，把拖动的最后一次位移丢掉。
        //   它只写 `homeOrigin` / `fieldLift` 两个标量、不发任何事件，同步执行没有重入风险。
        // ★★ 1.1.68：这一条只做「记 home」与帧日志，**不再摆另一块窗**。
        //   父子窗口组由 WindowServer 整体移动；在这里 setFrame 就是第二次提交，
        //   必然把它刚做好的同帧拆成两帧。1.1.67 的真机失败正是这么来的。
        homeObserver = NotificationCenter.default.addObserver(forName: NSWindow.didMoveNotification,
                                                             object: panel, queue: nil) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.rememberHome()
                guard PointerButton.isDown else { return }
                DragFrameTrace.record("FIELD_DID_MOVE",
                                      field: self.panel.frame.origin,
                                      results: self.results.panel.frame.origin,
                                      note: "attached=\(self.windowGroupAttached)")
                DragFrameTrace.sampleWindowServer(fieldNumber: self.panel.windowNumber,
                                                 resultsNumber: self.results.panel.windowNumber)
            }
        }
        // 松手后结算：拖动期间被 `shouldDeferAutoLayout` 挡下的重排在这里补一次，
        // 并把本轮帧日志一次落盘（拖动期间只拼字符串，不做磁盘 I/O）。
        dragEndMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseUp]) { [weak self] event in
            MainActor.assumeIsolated {
                self?.settleLayoutAfterDrag()
                DragFrameTrace.record("MOUSE_UP")
                DragFrameTrace.flush()
            }
            return event
        }
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
        // ★★ 2026-11-13 报障：「拖动搜索框移动时有时候会直接关闭」。
        // 判定输入必须在**事件到达这一刻**拍下来，不能在异步 Task 里重新读。
        // AppKit 的窗口拖动跟踪循环会把那个 Task 推迟到松手附近，而松手的
        // `settleLayoutAfterDrag()` 又会 `setFrame` 重新摆位；于是「按下时明明在窗口内」
        // 被换成「松手后落在窗口外的指针」，`field.contains(point)` 变 false ⇒ 浮窗被收起。
        let handle: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated {
                guard let snapshot = self?.makeClickOutsideSnapshot() else { return }
                Task { @MainActor in self?.dismissIfClickOutside(snapshot) }
            }
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

    /// 把「这一下按下」的判定输入一次性拍好。**只有这里**读实时坐标与实时 frame。
    private func makeClickOutsideSnapshot() -> SearchClickOutside.Snapshot {
        let point = NSEvent.mouseLocation
        // 点在自己这几块窗口之内一律不关（含「按住浮窗空白处拖动」）。
        // 豁免列表只能收**此刻可见**的窗口：`orderOut` 不清 frame，隐藏窗口留在
        // 原地的矩形会变成一片看不见的禁点区（2026-10-28 报障）。
        // `canBecomeKey` 再收一道：菜单、提示、状态栏这类辅助窗口弹出瞬间
        // `isVisible` 也为真，把它们算成「自家窗口」会误豁免点击。
        let ownVisibleFrames = NSApp.windows
            .filter { $0 !== panel && $0.isVisible && $0.canBecomeKey }
            .map(\.frame)
        return SearchClickOutside.Snapshot(
            click: point,
            field: panel.frame,
            otherVisibleWindows: ownVisibleFrames,
            overlayBlocksDismissal: ScreenOverlayProbe.blocksDismissal(at: point),
            // ★ 系统钥匙串授权框（SecurityAgent）弹出时闪寻已失去前台，
            //   用户点授权框里的任何一处，在屏幕坐标上都落在闪寻窗口之外。
            //   保护期结论必须在**事件到达这一刻**拍下来，异步再读会被读没。
            systemPromptBlocksDismissal: SystemPromptGuard.shared.blocksDismissal)
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
            MainActor.assumeIsolated {
                guard let snapshot = self?.makeClickOutsideSnapshot() else { return }
                Task { @MainActor in self?.dismissIfClickOutside(snapshot) }
            }
        }
    }

    private func dismissIfClickOutside(_ snapshot: SearchClickOutside.Snapshot) {
        guard panel.isVisible else { return }
        guard SearchClickOutside.shouldDismiss(snapshot) else { return }
        model.hideSearch()   // 通知会顺带卸载监视，这里不用重复
    }

    private func removeClickOutsideMonitor() {
        if let monitor = clickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = resignObserver { NotificationCenter.default.removeObserver(observer) }
        clickMonitor = nil; localClickMonitor = nil; globalClickMonitor = nil; resignObserver = nil
    }

    /// 系统授权框关掉之后把浮窗找回来。
    ///
    /// ★ 与 `show()` 分开：窗口还在时**只**激活 + 提回最前。
    /// `show()` 会走 `showSearch()`（恢复上次的查询）、`snapHome()`（重新摆位）和
    /// `installClickOutsideMonitor()`，在用户刚输完密码那一刻做这些既多余、
    /// 又会把用户刚拖好的位置改掉。窗口真被收掉了才走完整的 `show()`。
    func bringForward(showIfHidden: Bool) {
        if !panel.isVisible {
            guard showIfHidden else { return }
            show()
            return
        }
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func show() {
        model.showSearch()
        // 首次使用的那行键位提示：只显示一次，输入或操作后收起（见 `SearchHintGuide`）。
        model.showSearchHintsIfNeeded()
        installClickOutsideMonitor()
        // 每次唤起都从「用户设定的位置」开始（见 `snapHome` 的说明）。
        snapHome()
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
        results.refreshVisibility(hasContent: model.hasSearchContent)
        // ★ 结果窗是「唤起时就有内容」这条路径，不会经过 SwiftUI 的可见性翻转，
        //   父子关系要在这里补挂；`syncWindowGroup` 幂等，重复调没有副作用。
        syncWindowGroup(resultsVisible: model.hasSearchContent)
        layoutForResults()
        panel.invalidateShadow()
        // ★ 唤起搜索窗时按需验一次设备在不在线（异步、短超时、有冷却，不阻塞显示）。
        //   侧边栏与来源行的「已连接」不该只是登录成功后就没复核过的粘性标志。
        model.probeDevicePresence()
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

    // MARK: - 未固定时两窗是一个 AppKit 父子窗口组（2026-11-08 二次修正）

    /// 结果窗此刻是否真的挂在搜索框上。
    /// ★ 以 AppKit 的实际关系为准，不另存一份布尔真相（两份状态迟早会不一致）。
    private var windowGroupAttached: Bool { results.panel.parent === panel }

    /// 拖动期间被挡下的重排：松手时补一次无动画结算。
    private var deferredLayout = false

    /// 按可见性挂 / 解绑 child window。
    ///
    /// ★ 父 = 搜索框、子 = 结果窗。Apple 文档 `addChildWindow(_:ordered:)`：
    ///   附着生效时移动父窗会带动子窗，两块由 WindowServer 作为一个实体提交；
    ///   移动子窗不会带动父窗 —— 所以 1.1.69 起**结果窗根本不许被拖**，
    ///   拖动能力由 Core `WindowGroupPolicy` 关掉，唯一把手是搜索框。
    ///   （1.1.68 试过把结果窗的 mouseDown 转发给父窗，真机仍被单独拖走。）
    /// ★ 结果窗隐藏时要解绑：父窗 `orderOut` 会连带 child，收起/再次唤起时
    ///   系统可能把 child 自动重新显示。判据在 Core，这里不另写一套。
    private func syncWindowGroup(resultsVisible: Bool) {
        let attached = windowGroupAttached
        if WindowGroupPolicy.shouldAttach(resultsVisible: resultsVisible, isAttached: attached) {
            panel.addChildWindow(results.panel, ordered: .above)
            DragFrameTrace.record("ATTACH",
                                  field: panel.frame.origin,
                                  results: results.panel.frame.origin,
                                  note: "ok=\(windowGroupAttached)")
        } else if WindowGroupPolicy.shouldDetach(resultsVisible: resultsVisible, isAttached: attached) {
            panel.removeChildWindow(results.panel)
            DragFrameTrace.record("DETACH",
                                  field: panel.frame.origin,
                                  results: results.panel.frame.origin)
        }
        // 挂不上时不假装成功，也不退回按帧追赶（那正是被真机否掉的旧路）：
        // 如实记一行，让帧日志能解释「为什么这两块没一起走」。
        if resultsVisible, !windowGroupAttached {
            DragFrameTrace.record("ATTACH_FAILED",
                                  note: "fallbackAllowed=\(WindowGroupPolicy.shouldFollowByNotification(isAttached: false))")
        }
    }

    /// 松手后补一次**无动画**重排：拖动期间被 `shouldDeferAutoLayout` 挡下的
    /// 抬升量在这里结算，绝不启动 0.18s 动画（那会再「滑一段」）。
    private func settleLayoutAfterDrag() {
        guard deferredLayout else { return }
        deferredLayout = false
        DragFrameTrace.record("SETTLE",
                              field: panel.frame.origin,
                              results: results.panel.frame.origin,
                              note: "attached=\(windowGroupAttached)")
        layoutForResults(animated: false, allowDefer: false)
    }

    /// 搜索框「用户设定的位置」：没被抬高时的原点。收窗 / 结果收起时回到这里。
    private var homeOrigin: NSPoint?

    /// 用户设定的位置配上**当前**尺寸（抬高之前的那块矩形）。钉住时当锚点用。
    var homeFrame: NSRect? {
        guard let homeOrigin else { return nil }
        var frame = panel.frame
        frame.origin = homeOrigin
        return frame
    }
    /// 当前为了让结果放下而抬高的量（0 = 没抬）。
    ///
    /// ★ 标志位在**动窗之前**就得置上：动画期间 `didMove` 会成串地到，
    ///   那一刻起窗口的位置就是临时位置了，不能再被当成「用户设定的位置」。
    private var fieldLift: CGFloat = 0

    /// 搜索区重排一次：结果放得下就原地，放不下就把**搜索框抬上去**。
    ///
    /// ★ 2026-10-30 报障（用户）：「把搜索框拉到屏幕下方，输入文字后搜索框直接被搜索结果
    ///   盖住；聚焦搜索是随着结果变大逐渐往上走，关闭时跳回设定好的位置。」
    ///   旧代码把**结果窗**往上顶到屏幕底边，于是它压在搜索框身上——几何判定搬到了
    ///   `SearchWindowLift`（Core，可测），这里只负责把两块的 frame 摆上去。
    private func layoutForResults(animated: Bool = true, allowDefer: Bool = true) {
        // ★★ 2026-11-08：拖动期间一律不重排，松手由 `settleLayoutAfterDrag()` 无动画结算。
        //   两段 0.18s 动画会在拖动中被自己反复打断，而且重排会改两块窗的 frame。
        if allowDefer && WindowGroupPolicy.shouldDeferAutoLayout(pointerDown: PointerButton.isDown) {
            deferredLayout = true
            return
        }
        guard panel.isVisible, let screen = visibleFrame(for: panel.frame) else { return }
        // ★ 摆位前先把父子关系对齐到「此刻该有的状态」：SwiftUI 的可见性通知是
        //   异步派发的，收起/唤起这条路径可能还没走到 `syncWindowGroup`。
        syncWindowGroup(resultsVisible: results.panel.isVisible)
        // ★ 2026-11-08 契约反转：未固定时两块联动，拖过结果窗**不再**阻止重摆。
        //   那时搜索框已经在 `syncField` 里跟着一起走、homeOrigin 也更新了，
        //   按新 home 重算出来的正是用户最后放的位置。
        guard results.panel.isVisible else { restoreHome(); return }
        let home = homeOrigin ?? panel.frame.origin
        // ★★ `plan` 永远有解：放得下时 `lifted == 0`、结果照样贴在搜索框下面。
        //   2026-10-30 这里是 `guard let plan = … else { restoreHome(); return }`，
        //   于是「放得下」这条最常见的处境根本没摆结果窗 —— 用户装上 1.1.56 报
        //   「第一次打开的搜索结果不在搜索框下方了」，证据里 `resultsWindowOrigin`
        //   是 [0, 0]、`fieldLift` 是 0。别再让摆位有「只走一半」的分支。
        let plan = SearchWindowLift.plan(field: NSRect(origin: home, size: panel.frame.size),
                                         resultsHeight: results.panel.frame.height,
                                         gap: SearchModuleLayout.moduleGap,
                                         screen: screen)
        // 先记账再动窗：`fieldLift` 是「此刻的位置是这一轮的临时位置」的标志，
        // 任何一次摆位之前就得置上，之后到访的 `didMove` 才看得见它。
        fieldLift = plan.lifted
        var fieldFrame = panel.frame
        fieldFrame.origin.y = plan.fieldY
        if animated {
            animate(panel, to: fieldFrame)
        } else {
            panel.setFrame(fieldFrame, display: false)
        }
        var resultsFrame = results.panel.frame
        resultsFrame.origin = NSPoint(x: fieldFrame.minX, y: plan.resultsY)
        // ★ 宽度只在真不同时才写：无谓的 `didResize` 会再触发一次 `onLayoutNeeded`。
        if abs(resultsFrame.size.width - fieldFrame.width) > 0.5 {
            resultsFrame.size.width = fieldFrame.width
        }
        results.place(resultsFrame, animated: animated)
    }

    /// 回到用户设定的位置（结果收起、切换筛选、收窗时）。
    private func restoreHome() {
        guard fieldLift > 0 else { return }
        snapHome()
        if results.panel.isVisible {
            var resultsFrame = results.panel.frame
            resultsFrame.origin = NSPoint(x: panel.frame.minX,
                                          y: panel.frame.minY - SearchModuleLayout.moduleGap - resultsFrame.height)
            results.place(resultsFrame, animated: true)
        }
    }

    /// 立刻回到原位（不带动画）：收窗时动画看不见，只会多一次无谓的绘制。
    private func snapHome() {
        guard let home = homeOrigin else { return }
        fieldLift = 0
        guard panel.frame.origin != home else { return }
        var frame = panel.frame
        frame.origin = home
        panel.setFrame(frame, display: false)
    }

    /// 记住用户把搜索框拖到了哪里。
    ///
    /// ★ 判据只有一条：**鼠标按着**。程序化摆位不可能发生在按着鼠标的时刻
    ///   （同 `WindowDragIntent` 的论证）。
    ///
    /// ★★ 这里**故意不传** `autoPlaced: fieldLift > 0`（2026-11-01 修，曾是一处真缺陷）。
    ///   传了等于说「搜索框被抬高的这一段，人手拖动也算程序摆的」，后果是：
    ///   输入出结果后框被 `SearchWindowLift` 抬上去，此时用户再把它拖到别处也**记不住**，
    ///   `homeOrigin` 还停在抬起前那个位置；而收窗（`hidePanel` → `snapHome`）与下次唤起
    ///   （`show` → `snapHome`）都按 `homeOrigin` 摆位 —— 用户看到的是「拖了又跳回原处」。
    ///
    ///   `WindowDragIntent.isUserDrag` 里的 `autoPlaced` 那一维回答的是另一个问题：
    ///   「这次移动要不要算作用户拖动，从而**停止自动贴回**」（结果窗在用）。
    ///   对「记不记 home」来说它没有信息量：鼠标按着就已经排除了程序摆位。
    private func rememberHome() {
        guard panel.isVisible, PointerButton.isDown else { return }
        // 用户亲手接管了位置 ⇒ 这一轮「抬高」就此作废：留在抬升位移里的账会让
        // `restoreHome()` 在结果收起时把窗口按旧 home 拉回去，正好抵消他刚做的拖动。
        fieldLift = 0
        homeOrigin = panel.frame.origin
        // ★★ 1.1.68：这里**只记账**。结果窗是 child window，父窗一动
        //   WindowServer 自然把它带走；任何额外的 setFrame 都会拆掉同帧。
    }

    private func visibleFrame(for frame: NSRect) -> CGRect? {
        (NSScreen.screens.first { $0.frame.intersects(frame) } ?? NSScreen.main)?.visibleFrame
    }

    private func animate(_ window: NSWindow, to frame: NSRect) {
        guard window.isVisible else { window.setFrame(frame, display: false); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.18
            context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
            window.animator().setFrame(frame, display: true)
        }
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

    /// 几个定点上「这一下会不会被当成点了外面」（真的调 `dismissIfClickOutside` 用的那条判据）。
    private static func dismissProbe(points: [String: NSPoint]) -> [String: Bool] {
        points.mapValues { ScreenOverlayProbe.blocksDismissal(at: $0) }
    }

    /// 写一份「面板此刻真的长这样」的证据 JSON 到包外 Evidence/。
    private func writePreviewEvidence() {        let root = Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("Evidence", isDirectory: true)
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
            // 「结果窗被记成用户拖过」这件事的判据：每一对 `[程序化摆位中, 鼠标按下]`。
            // 全是 `[1,0]` / `[0,0]` 才算正常；出现 `[0,1]` 才是真拖过。
            "resultsMoveTrace": results.moveTrace,
            // 「抬高了多少 / 用户设定的位置在哪」：动画中途的坐标一旦漏进来，
            // 这两个数就会和 `fieldOrigin` 对不上（2026-10-30 就是这么坏的）。
            "fieldOrigin": [panel.frame.minX, panel.frame.minY],
            "homeOriginY": homeOrigin?.y ?? -1,
            "fieldLift": fieldLift,
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
            "networkEnabled": model.enabled,
            "hoverForced": PreviewHover.isForced,
            // 「此刻在这一点按下鼠标，会不会被当成点了外面」——报障 3 的唯一判据。
            // 没有截图界面时三处必须全 false；截图选区遮罩弹起时中间那处必须为 true。
            "dismissProbe": Self.dismissProbe(points: [
                "screenCenter": NSPoint(x: (NSScreen.main?.frame.midX ?? 0),
                                        y: (NSScreen.main?.frame.midY ?? 0)),
                "desktopCorner": NSPoint(x: (NSScreen.main?.frame.minX ?? 0) + 20,
                                         y: (NSScreen.main?.frame.minY ?? 0) + 20),
                "fieldCenter": NSPoint(x: panel.frame.midX, y: panel.frame.midY),
            ])
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
        if let homeObserver { NotificationCenter.default.removeObserver(homeObserver) }
        if let dragEndMonitor { NSEvent.removeMonitor(dragEndMonitor) }
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
