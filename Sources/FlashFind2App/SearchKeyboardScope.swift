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
    let searchFocused: Bool
    let query: String
    let hasSelectableResult: Bool
    let move: (Int) -> Void
    let submit: () -> Void
    let reveal: () -> Void
    let quickLook: () -> Void
    let copyPath: () -> Void
    let hide: () -> Void
    /// 搜索框是否处于命令模式（`/` 唤起命令面板）。
    let commandMode: Bool
    /// ↑ / ↓ 在命令候选之间移动。
    let commandMove: (Int) -> Void
    /// ↩ 执行选中的命令。
    let commandSubmit: () -> Void
    /// esc 退出命令模式。
    let commandCancel: () -> Void
    /// 数字键 0–9 直接选中对应候选。
    let commandPick: (Int) -> Void
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
        if c.query != query || !hasSelectableResult { c.navigation.reset() }
        c.query = query
        c.hasSelectableResult = hasSelectableResult
        c.searchFocused = searchFocused
        c.move = move; c.submit = submit; c.reveal = reveal
        c.quickLook = quickLook; c.copyPath = copyPath; c.hide = hide
        c.commandMode = commandMode
        c.commandMove = commandMove; c.commandSubmit = commandSubmit; c.commandCancel = commandCancel
        c.commandPick = commandPick
        c.hasSearchToken = hasSearchToken; c.keywordEmpty = keywordEmpty
        c.deleteSearchToken = deleteSearchToken
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    final class Coordinator {
        var enabled = false
        var searchFocused = false
        var query = ""
        var hasSelectableResult = false
        var navigation = SearchResultNavigation()
        var move: ((Int) -> Void)?
        var submit: (() -> Void)?
        var reveal: (() -> Void)?
        var quickLook: (() -> Void)?
        var copyPath: (() -> Void)?
        var hide: (() -> Void)?
        var commandMode = false
        var commandMove: ((Int) -> Void)?
        var commandSubmit: (() -> Void)?
        var commandCancel: (() -> Void)?
        var commandPick: ((Int) -> Void)?
        var hasSearchToken = false
        var keywordEmpty = true
        var deleteSearchToken: (() -> Void)?
        weak var view: NSView?
        private var monitor: Any?

        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown]) { [weak self] event in
                guard let self, self.enabled, let window = self.view?.window,
                      event.window === window else { return event }
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
                    inResults: inResults || navigating,
                    isComposing: editor?.hasMarkedText() == true,
                    inCommandMode: self.commandMode,
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
                case .commandMove(let delta): self.commandMove?(delta); return nil
                case .commandSubmit: self.commandSubmit?(); return nil
                case .commandCancel: self.commandCancel?(); return nil
                case .commandPick(let digit): self.commandPick?(digit); return nil
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
