import AppKit
import SwiftUI
import FlashFindCore

/// 搜索结果那一块窗口的**页面**。
///
/// ## 为什么它现在是独立窗口（2026-10-28）
///
/// 用户：「钉住前后的搜索框和搜索结果都应该可以单独移动」。同一个窗口里的两块
/// 只能一起动，所以结果那一块搬出来单独一窗。拆开之后：
/// * 拖动互不影响（用户选的「完全不跟」）；
/// * 「钉住」与不钉住是同一个窗口的两种命运——钉住只是把它复制一份留在桌面上，
///   原来这块继续跟着搜索走。
///
/// ★ 这一块的高度与宽度都由内容算：高度给 `SearchPanelSizing`（上沿固定、向下长），
///   宽度取窗口宽度。它不再参与「搜索窗总高」的加法，页面与 `SearchView` 之间
///   没有任何共享状态。
struct SearchResultsPanelView: View {
    @ObservedObject var model: AppModel
    /// 这块窗口的「显示 / 收起 / 尺寸变化」都要叫一声。
    ///
    /// ★ 2026-10-30 之前只叫「从隐藏变成显示」的这一次，于是它收起之后没人负责
    ///   把搜索框放回原位（抬上去就下不来了）。现在收、放、变高都走同一个回调，
    ///   由控制器统一算一遍位置——**判定只有一处**。
    let onLayoutNeeded: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    private var style: SearchGlassStyle {
        SearchGlass.style(reduceTransparency: reduceTransparency)
    }

    // MARK: - 派生状态（与页面共用，只算一次）

    private var hasQuery: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pending: Bool { hasQuery && !model.canUseDisplayedResults && model.searchFailure == nil }
    private var visibleResults: [SearchResult] {
        hasQuery && model.searchFailure == nil ? model.results : (model.canUseDisplayedResults ? model.results : [])
    }
    private var showsStatus: Bool { !visibleResults.isEmpty || !model.searchWarnings.isEmpty }

    private var context: SearchResultsContext {
        SearchResultsContext(hasQuery: hasQuery,
                             results: visibleResults,
                             pending: pending,
                             showsStatus: showsStatus)
    }

    /// 这一块到底该不该在屏幕上（判定在 Core，界面不自己拼条件）。
    private var isVisible: Bool { model.hasSearchContent }

    // MARK: - 高度

    /// 结果区的高度：**恒定**，与结果条数无关。
    ///
    /// ★★ 2026-10-28 报障（原话）：「搜索结果的区域大小固定，否则切换的时候
    ///   侧边栏大小频繁跳动，影响筛选」。
    ///
    ///   之前这里是 `min(结果数, 7) × 行高 + 44`：搜到 48 条时是一屏 604，
    ///   切到一个空位置就塌成 112，连侧边栏一起缩——正在点的那一行会从指头下面
    ///   移开，等于「筛选中途被换了一块面板」。结果少的时候底下留白，
    ///   而不是把整块缩回去，这既是用户要的，也让「换页」不再带着窗口尺寸动。
    ///
    ///   值只有一处：`SearchModuleLayout.resultsListHeight`（Core，可测）。
    private var expandedHeight: CGFloat {
        SearchModuleLayout.resultsListHeight(rowHeight: SearchLayout.rowHeight)
    }

    /// 打开失败提示条占的高度。它不是结果区的一部分，也不在 `expandedHeight` 里，
    /// 所以必须自己加进窗口高度——否则提示条会被挤成一条窄边，正文整段被切掉。
    private var openFailureBannerHeight: CGFloat {
        model.openFailure == nil ? 0 : SearchLayout.openFailureBannerHeight
    }

    /// 结果模块的总高：**顶部类型条** + 结果区 + 打开失败提示条。
    ///
    /// ★ 类型条 2026-10-28 搬进来（用户：「搜索结果顶部文件类型」），
    ///   少算这一截它就会被模块底边裁掉一半——而它是常驻的。
    private var contentModuleHeight: CGFloat {
        SearchModuleLayout.typeBarHeight + expandedHeight + openFailureBannerHeight
    }

    var body: some View {
        SearchResultsModule(model: model,
                            context: context,
                            style: style,
                            // 结果已在独立窗口里：点一行时搜索框那一侧本来就没有焦点，
                            // 这里没有「交还焦点」的事可做。
                            leaveSearchField: {},
                            openSettings: openSettings,
                            selectType: { model.selectTypeBarSegment($0) },
                            pin: { model.pinCurrentResults() })
        .frame(maxWidth: .infinity)
        .frame(height: contentModuleHeight)
        .background(SearchPanelSizing(height: contentModuleHeight, animate: !reduceMotion).frame(width: 0, height: 0))
        .background(SearchResultsPanelVisibility(visible: isVisible, onLayoutNeeded: onLayoutNeeded)
            .frame(width: 0, height: 0))
    }

    /// 打开独立设置窗口（与搜索框那一侧的入口同义）。
    private func openSettings() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show(model: model, page: .search)
    }
}

/// 「结果窗口该不该显示」这件事的落地处。
///
/// ★ 为什么不放在控制器里盯 `model.query`：可见性本身是**算出来的**
///   （`SearchModuleLayout.showsContentModule`），在 AppKit 那侧再算一遍
///   就是第二份真相，两边迟早不一致（表现为「有关键词但结果窗不出现」）。
///   SwiftUI 算好传下来，这里只做 `orderFront/orderOut`，再把「变了」通知出去。
private struct SearchResultsPanelVisibility: NSViewRepresentable {
    let visible: Bool
    let onLayoutNeeded: () -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        // 延到下一拍：`updateNSView` 可能在布局过程中被调用，
        // 此时改窗口的显隐会触发重入（表现为窗口闪烁或半张图）。
        DispatchQueue.main.async {
            guard let panel = view.window as? NSPanel else { return }
            if visible {
                panel.orderFront(nil)
            } else if panel.isVisible {
                panel.orderOut(nil)
            } else {
                return   // 已经是「不显示」，再通知一次没有意义
            }
            onLayoutNeeded()
        }
    }
}

/// 结果那一块窗口的控制器。
///
/// 三件它必须自己管、别人管不了的事：
/// 1. **拖动**：`isMovableByWindowBackground`（表面不吞 `hitTest` 才真的能动，见 `SearchModuleSurface`）；
/// 2. **摆放**：第一次显示时贴到搜索框下方 10pt；用户拖过之后不再自动摆；
/// 3. **谁是 key**：点进来之后 `model.resultsWindowIsKey` 要为真，
///    否则键盘路由会以为「焦点还在输入框」，↑↓ 与空格全部落空。
@MainActor
final class SearchResultsPanelController {
    let panel: NSPanel
    private let model: AppModel
    /// 正在程序化摆位。
    ///
    /// ★ 原来是一个「设 true → 下一拍设回 false」的抑制标志，动画一上来就失效：
    ///   `animator().setFrame` 的通知在标志复位**之后**继续发，于是每次自动摆位都被记成
    ///   「用户拖过」，之后的自动摆位全部停摆（首屏就把结果钉死在错误位置）。
    ///   现在用动画的 `completionHandler` 收尾，覆盖整段动画。
    private var isPlacing = false
    /// 用户亲手拖过没有。拖过之后就不再自动贴回搜索框下方——
    /// 用户把它放到右边是有意的，下一次搜索又拽回来等于白摆。
    ///
    /// ★★ 判据是「鼠标按着的时候移动了」，不是「移动过」（见 `PointerButton`）。
    private(set) var userMoved = false
#if DEBUG
    /// 每一条 `didMove` 的判定依据（`[isPlacing, 鼠标按下]`），只给取证用。
    private(set) var moveTrace: [[Int]] = []
#endif
    private var observers: [NSObjectProtocol] = []

    init(model: AppModel) {
        self.model = model
        // ★ 初建高度就用**固定高度**（不是「先给个 112 再撑开」）：
        //   固定高度下每次搜索面板都该是这个尺寸，先小后大会让每一次搜索都
        //   演一遍「面板长出来」的动画，看起来像界面在抖。
        let fixedHeight = SearchModuleLayout.resultsModuleHeight(rowHeight: SearchLayout.rowHeight)
        panel = SearchResultsPanel(contentRect: NSRect(x: 0, y: 0, width: 680, height: fixedHeight),
                                   styleMask: [.borderless], backing: .buffered, defer: false)
        if AppEnvironment.isPreview, let width = ProcessInfo.processInfo.environment["FF_UI_WIDTH"].flatMap(Double.init) {
            panel.setContentSize(NSSize(width: min(900, max(640, width)), height: fixedHeight))
        }
        panel.title = "闪寻"
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 与搜索框那一块同一条：窗口自己没有任何表面，玻璃由模块画；
        // 透明窗的阴影按窗口矩形算，会把圆角外画成一整块方影。
        panel.hasShadow = false
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.moveToActiveSpace, .fullScreenAuxiliary]
        panel.minSize = NSSize(width: 640, height: SearchModuleLayout.typeBarHeight)
        panel.maxSize = NSSize(width: 900, height: 620)
        panel.appearance = AppEnvironment.previewAppearance
        let host = NSHostingView(rootView: SearchResultsPanelView(model: model,
                                                                  onLayoutNeeded: { [weak self] in
            self?.onLayoutNeeded?()
        }))
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        observe()
    }

    /// 显示 / 收起 / 高度变化都通知协调者重排一次（它才知道搜索框在哪、屏幕有多高）。
    ///
    /// ★ 用户**亲手拖过**就不再自动回位：把它放到右边是有意的，清空关键词再搜一次
    ///   就把它拽回搜索框下面是抢用户的位置。这条判断在协调者那边（`layoutForResults`），
    ///   因为「放不放下」和「搜索框抬不抬」是**同一个决定**，分成两处必然对不上。
    var onLayoutNeeded: (() -> Void)?

    /// 新一轮搜索开始（快捷键唤起）：撤销「用户拖过」的记忆。
    func beginSession() {
        userMoved = false
    }

    /// 按「此刻有没有内容」同步显示状态。
    ///
    /// 与 `SearchResultsPanelVisibility` 是同一条规则的另一条触发路径：
    /// 那条管「内容变了」，这条管「窗口刚被叫出来」。两边都只做 orderFront/orderOut，
    /// 重复调用没有副作用。
    func refreshVisibility(hasContent: Bool) {
        if hasContent {
            panel.orderFront(nil)
        } else {
            hide()
        }
    }

    /// 由协调者算好的位置，照搬。
    ///
    /// ★ 位置**只在协调者那一处算**：它同时知道搜索框（可能被抬起）、屏幕可见区
    ///   和这块窗口的高度。旧代码把「贴到搜索框下方」写在这、把「放不下时往上顶」
    ///   也写在这，于是「结果压在搜索框上」成了唯一出路（2026-10-30 报障）。
    /// ★ 三样都得摆，不只是 y：这块窗口是 `new` 出来的，初值在 (0,0)——
    ///   只对 y 的话它会贴在屏幕**左下角**，看起来像「结果跑到别处去了」。
    func place(_ frame: NSRect, animated: Bool) {
        guard frame != panel.frame else { return }
        isPlacing = true
        if animated && panel.isVisible {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.18
                context.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                panel.animator().setFrame(frame, display: true)
            } completionHandler: { [weak self] in
                Task { @MainActor in self?.isPlacing = false }
            }
        } else {
            panel.setFrame(frame, display: false)
            DispatchQueue.main.async { [weak self] in self?.isPlacing = false }
        }
    }

    func show() {
        guard !panel.isVisible else { return }
        panel.orderFront(nil)
    }

    func hide() {
        guard panel.isVisible else { return }
        let wasKey = panel.isKeyWindow
        panel.orderOut(nil)
        // 结果窗一收，键盘必须回到搜索框：不交还的话用户接着打字一个字都进不去。
        if wasKey { NotificationCenter.default.post(name: .focusFlashFindField, object: nil) }
    }

    private func observe() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didMoveNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            guard let self else { return }
            let dragging = PointerButton.isDown
#if DEBUG
            self.moveTrace.append([self.isPlacing ? 1 : 0, dragging ? 1 : 0])
            if self.moveTrace.count > 12 { self.moveTrace.removeFirst() }
#endif
            guard WindowDragIntent.isUserDrag(pointerDown: dragging,
                                              autoPlaced: self.isPlacing) else { return }
            self.userMoved = true
        })
        // 结果条数不变但高度会变（打开失败提示条显隐）：高度一改，位置就得重算。
        observers.append(center.addObserver(forName: NSWindow.didResizeNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            self?.onLayoutNeeded?()
        })
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            self?.setKeyFlag(true)
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification,
                                            object: panel, queue: .main) { [weak self] _ in
            self?.setKeyFlag(false)
        })
    }

    /// `model` 是 `@Published`：在窗口通知里直接写会在 SwiftUI 更新途中触发
    /// 「Publishing changes from within view updates」，所以推到下一拍。
    private func setKeyFlag(_ isKey: Bool) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.model.resultsWindowIsKey != isKey else { return }
            self.model.resultsWindowIsKey = isKey
        }
    }

    deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}

/// 无标题栏的结果窗口：能成为 key（否则键盘路由收不到事件）。
private final class SearchResultsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
