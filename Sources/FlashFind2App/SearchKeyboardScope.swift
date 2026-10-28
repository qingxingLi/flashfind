import AppKit
import SwiftUI
import FlashFindCore

/// 搜索窗口内的键盘处理。
///
/// 事件只在这个 key window 的搜索框或结果表里生效：输入法、弹窗、修饰键
/// 以及其它响应者都保留自己的按键行为，不会被这里截走。
///
/// 绑定：
///   ↑↓ / ⌃P⌃N  选择      ↵  打开文件
///   ⌘↵        Finder 中显示   Space  快速查看（先用 ↑↓ 或点击选择结果）
///   ⌘C        复制路径        esc  隐藏窗口
///
/// 具体决策见 `FlashFindCore.SearchKeyRouter`；这里只做「取上下文 → 执行」。
struct SearchKeyboardScope: NSViewRepresentable {
    let enabled: Bool
    /// 哪些窗口算「搜索区」。
    ///
    /// ★ 2026-10-28 搜索框与结果拆成**两个窗口**之后才有这一项：以前事件只认
    ///   本视图所在的那个窗口，点在结果窗上按 ↑↓ 会被整条忽略。
    ///   由调用方给判据（`SearchWindowRegistry`），这里不认识任何具体窗口类型。
    let accepts: (NSWindow) -> Bool
    let searchFocused: Bool
    let query: String
    let hasSelectableResult: Bool
    /// 焦点虽然不在输入框，但「现在是在结果区操作」。
    ///
    /// ★ 2026-10-27 起结果区是 `ScrollView` + `LazyVStack`，不再是 `List`
    /// （`List` 画不了跟随鼠标的玻璃遮罩）。于是响应链里**没有 `NSTableView`**，
    /// 下面沿响应链的探测会一路走到头都找不到「结果区」——
    /// 表现为「点了一条结果之后，方向键/空格/回车全部失效」。
    /// 所以这一项必须由调用方按「焦点 + 有没有结果」明说，不能靠猜。
    let resultsActive: Bool
    let move: (Int) -> Void
    let submit: () -> Void
    let reveal: () -> Void
    let quickLook: () -> Void
    let copyPath: () -> Void
    let hide: () -> Void
    /// 有没有已选定的限定（位置 / 类型）。
    let hasSearchToken: Bool
    /// 输入框里除限定外还有没有关键词。
    let keywordEmpty: Bool
    /// 删除键删掉一个前置限定。
    let deleteSearchToken: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.enabled = enabled
        c.accepts = accepts
        if c.query != query || !hasSelectableResult { c.navigation.reset() }
        c.query = query
        c.hasSelectableResult = hasSelectableResult
        c.searchFocused = searchFocused
        c.resultsActive = resultsActive
        c.move = move; c.submit = submit; c.reveal = reveal
        c.quickLook = quickLook; c.copyPath = copyPath; c.hide = hide
        c.hasSearchToken = hasSearchToken; c.keywordEmpty = keywordEmpty
        c.deleteSearchToken = deleteSearchToken
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    final class Coordinator {
        var enabled = false
        var accepts: ((NSWindow) -> Bool)?
        var searchFocused = false
        var query = ""
        var hasSelectableResult = false
        var resultsActive = false
        var navigation = SearchResultNavigation()
        var move: ((Int) -> Void)?
        var submit: (() -> Void)?
        var reveal: (() -> Void)?
        var quickLook: (() -> Void)?
        var copyPath: (() -> Void)?
        var hide: (() -> Void)?
        var hasSearchToken = false
        var keywordEmpty = true
        var deleteSearchToken: (() -> Void)?
        weak var view: NSView?
        private var monitor: Any?

        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                // ★ 判据是「事件落在**我们的哪一块**窗口上」，不是「落在本视图所在的窗口上」：
                //   结果那一块已经是独立窗口了，还按老写法判断的话，
                //   用户点过结果再按 ↑↓ / 空格 / 回车全部没反应。
                guard let self, self.enabled, let window = event.window,
                      self.accepts?(window) == true else { return event }
                if event.type == .leftMouseDown {
                    self.navigation.reset()
                    return event
                }
                guard window.isKeyWindow, window.attachedSheet == nil else { return event }
                let editor = window.firstResponder as? NSTextView
                var responderView = window.firstResponder as? NSView
                var inResults = false
                while let candidate = responderView {
                    if candidate is NSTableView || candidate is NSCollectionView { inResults = true; break }
                    responderView = candidate.superview
                }
                let navigating = self.navigation.isActive && self.hasSelectableResult
                let flags = event.modifierFlags
                let context = SearchKeyContext(
                    keyCode: event.keyCode,
                    hasCommand: flags.contains(.command),
                    hasOtherModifier: !flags.intersection([.option, .control, .shift]).isEmpty,
                    inSearchField: self.searchFocused && editor != nil && !navigating,
                    inResults: inResults || navigating || self.resultsActive,
                    isComposing: editor?.hasMarkedText() == true,
                    hasSearchToken: self.hasSearchToken,
                    keywordEmpty: self.keywordEmpty && (editor?.string.isEmpty ?? true))
                let route = SearchKeyRouter.route(context)
                self.navigation.record(route, hasResult: self.hasSelectableResult)
                switch route {
                case .move(let delta): self.move?(delta); return nil
                case .submit: self.submit?(); return nil
                case .reveal: self.reveal?(); return nil
                case .quickLook: self.quickLook?(); return nil
                case .copyPath: self.copyPath?(); return nil
                case .hide: self.hide?(); return nil
                case .deleteSearchToken: self.deleteSearchToken?(); return nil
                case .passThrough: return event
                }
            }
        }
        func uninstall() {
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
        }
        deinit { uninstall() }
    }
}
