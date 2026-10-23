import AppKit
import SwiftUI
import FlashFindCore

/// 首次启动引导的独立窗口。
///
/// 不复用设置窗口：设置是「已经会用的人来调参数」的地方，引导是
/// 「第一次见面，边问边配好」的地方。塞进设置会让新用户一上来就看到
/// 三条来源、诊断按钮、实验性开关——那正是这一版要避免的。
@MainActor
final class OnboardingWindow: NSObject, NSWindowDelegate {
    static let shared = OnboardingWindow()

    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    private var controller: OnboardingController?
    private weak var model: AppModel?

    /// 引导窗口是否正在屏幕上。
    ///
    /// `AppDelegate` 靠它决定「按下全局快捷键」是什么意思：引导开着时按一下
    /// 只表示「这个快捷键能用」，不该把搜索浮窗弹到引导页前面去。
    var isVisible: Bool { window?.isVisible == true }

    func show(model: AppModel, startAt: OnboardingStep = .welcome) {
        self.model = model
        // 引导占满屏幕中央，搜索浮窗浮在更高层级会盖住它的上半部分。
        model.hideSearch()
        let controller = OnboardingController(
            preferences: model.onboardingPreferences,
            startAt: startAt,
            // 只捕获 weakly：控制器 → 闭包 → 模型 → 快捷键回调 → 控制器
            // 会绕成一个环，而这个窗口是单例、活到进程结束。
            facts: { [weak model] in model?.onboardingState ?? .empty })
        self.controller = controller
        // 引导里按一次快捷键只做标记，不弹搜索窗。
        model.pushOnboardingShortcutPressed = { [weak controller] in controller?.noteShortcutWorked() }

        let content = AnyView(OnboardingView(model: model, controller: controller))
        if let hosting, let window {
            hosting.rootView = content
            window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let hostingController = NSHostingController(rootView: content)
        hosting = hostingController
        let panel = NSWindow(contentViewController: hostingController)
        panel.title = "欢迎使用闪寻"
        // 可关闭：中途退出是允许的（配置已经写进去了），下次启动会问一句要不要接着配。
        panel.styleMask = [.titled, .closable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setContentSize(NSSize(width: 720, height: 520))
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // 关窗只记「停在哪一步」，**不动任何配置**：快捷键、权限、
        // 搜索范围、已添加的 NAS 都是用户已经做完的事，不能因为关个窗就丢。
        controller?.noteStepLeft()
        model?.pushOnboardingShortcutPressed = nil
        window?.orderOut(nil)
        // 引导窗口也是「唯一窗口」的候选：用户还没配来源、先把引导关掉时，
        // 若不放回搜索浮窗，屏幕上零窗口 → 系统会把进程回收。
        restoreSearchPanelIfNeeded(closing: notification.object as? NSWindow, model: model)
    }
}
