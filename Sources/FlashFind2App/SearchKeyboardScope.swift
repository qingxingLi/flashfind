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
///   ⌘↵        Finder 中显示   Space  快速查看（焦点须在结果列表）
///   ⌘C        复制路径        esc  隐藏窗口
///
/// 具体决策见 `FlashFindCore.SearchKeyRouter`；这里只做「取上下文 → 执行」。
struct SearchKeyboardScope: NSViewRepresentable {
    let enabled: Bool
    let searchFocused: Bool
    let move: (Int) -> Void
    let submit: () -> Void
    let reveal: () -> Void
    let quickLook: () -> Void
    let copyPath: () -> Void
    let hide: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        context.coordinator.install(on: view)
        return view
    }
    func updateNSView(_ view: NSView, context: Context) {
        let c = context.coordinator
        c.enabled = enabled
        c.searchFocused = searchFocused
        c.move = move; c.submit = submit; c.reveal = reveal
        c.quickLook = quickLook; c.copyPath = copyPath; c.hide = hide
    }
    static func dismantleNSView(_ view: NSView, coordinator: Coordinator) { coordinator.uninstall() }

    final class Coordinator {
        var enabled = false
        var searchFocused = false
        var move: ((Int) -> Void)?
        var submit: (() -> Void)?
        var reveal: (() -> Void)?
        var quickLook: (() -> Void)?
        var copyPath: (() -> Void)?
        var hide: (() -> Void)?
        weak var view: NSView?
        private var monitor: Any?

        func install(on view: NSView) {
            self.view = view
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self, self.enabled, let window = self.view?.window,
                      event.window === window, window.isKeyWindow, window.attachedSheet == nil else { return event }
                let editor = window.firstResponder as? NSTextView
                var responderView = window.firstResponder as? NSView
                var inResults = false
                while let candidate = responderView {
                    if candidate is NSTableView { inResults = true; break }
                    responderView = candidate.superview
                }
                let flags = event.modifierFlags
                let context = SearchKeyContext(
                    keyCode: event.keyCode,
                    hasCommand: flags.contains(.command),
                    hasOtherModifier: !flags.intersection([.option, .control, .shift]).isEmpty,
                    inSearchField: self.searchFocused && editor != nil,
                    inResults: inResults,
                    isComposing: editor?.hasMarkedText() == true)
                switch SearchKeyRouter.route(context) {
                case .move(let delta): self.move?(delta); return nil
                case .submit: self.submit?(); return nil
                case .reveal: self.reveal?(); return nil
                case .quickLook: self.quickLook?(); return nil
                case .copyPath: self.copyPath?(); return nil
                case .hide: self.hide?(); return nil
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
