import AppKit
import SwiftUI
import FlashFindCore

/// 独立的设置窗口。
///
/// 之前设置是搜索浮窗的 `.sheet`：没有红绿灯、没有独立关闭入口，
/// 而且关掉搜索窗设置也跟着消失，用户会觉得「关不掉」。
/// 这里改为标准 NSWindow，具备红绿灯、可自由切换、可最小化。
@MainActor
final class SettingsWindow: NSObject, NSWindowDelegate {
    static let shared = SettingsWindow()

    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    /// 当前停留的页面。切页不重建窗口，避免丢失滚动位置。
    private var page: SettingsPane = .search

    func show(model: AppModel, page requested: SettingsPane) {
        page = requested
        // 打开设置时收起搜索浮窗：它浮在屏幕上方且层级更高，
        // 不收起来会盖住设置窗口的上半部分——包括「添加搜索来源」按钮，
        // 用户看到的就是「点不到」。
        model.hideSearch()
        let content = AnyView(SettingsView(model: model, initialPage: page))
        if let hosting, let window {
            hosting.rootView = content
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content)
        hosting = controller
        let panel = NSWindow(contentViewController: controller)
        // 标题只写「设置」，页面名由顶部分段控件自己显示——
        // 标题栏再写一遍就是信息重复。
        panel.title = SettingsWindowTitle.text
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        panel.titlebarAppearsTransparent = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        // 宽度跟着导航走：去掉 170–230pt 的侧栏列，不需要 880 了。
        panel.setContentSize(NSSize(width: 640, height: 620))
        panel.minSize = NSSize(width: 520, height: 520)
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        // 关闭窗口只隐藏，不销毁：再次打开时保持位置与大小。
        window?.orderOut(nil)
    }

    func windowShouldClose(_ sender: NSWindow) -> Bool { true }
}

/// NAS 添加/编辑向导的独立窗口。
///
/// 与设置窗口同理：向导需要红绿灯与独立关闭按钮，
/// 而且连接过程可能持续几十秒，不该把整个设置窗口卡在 sheet 状态。
@MainActor
final class NASWizardWindow: NSObject, NSWindowDelegate {
    static let shared = NASWizardWindow()

    private var window: NSWindow?
    private var hosting: NSHostingController<AnyView>?
    /// 关闭窗口时需要收回这次连接留下的一切，所以要拿到模型。
    private weak var model: AppModel?
    /// 每次打开向导递增一次，用作视图标识。
    ///
    /// 这是「输入密码 → 关窗口 → 再打开，密码还在」的直接修法。
    /// 成因是一条很隐蔽的链：
    ///   1. 密码框是 `PlainSecureField`（`NSSecureTextField`）——
    ///      **AppKit 控件自己持有文本**，不是每次都从绑定读；
    ///   2. 它的回写判定 `SecureFieldEcho.shouldWrite` 在 `isEditing` 时
    ///      故意不写（否则会顶掉光标、吞掉正在敲的字符）；
    ///   3. `windowWillClose` 里 `cancelDraft()` 已把模型清空，但那一刻
    ///      输入框仍是第一响应者 → 依然判定为「编辑中」→ 不回写；
    ///   4. 窗口只 `orderOut` 不销毁（`isReleasedWhenClosed = false`），
    ///      `NSHostingController` 也被复用，于是**同一个文本框实例**带着
    ///      旧文本留到了下一次打开。
    /// 给每次展示一个新的 identity，SwiftUI 就会重建整棵视图树，
    /// 输入框从模型重建 —— 模型已清空（见 `cancelDraft`），框里也就是空的。
    /// 这比去改 `shouldWrite` 稳妥：那里放松一点就可能弄坏「密码框只能打一个字」
    /// 那个已经踩过的坑。
    private var presentationSeq = 0

    func show(model: AppModel) {
        // 同上：向导窗口在屏幕中央，浮窗会盖住它的顶部（含地址输入区）。
        model.hideSearch()
        self.model = model
        presentationSeq += 1
        let content = AnyView(NASSourceWizardView(model: model).id(presentationSeq))
        if let hosting, let window {
            hosting.rootView = content
            window.makeKeyAndOrderFront(nil)
            return
        }
        let controller = NSHostingController(rootView: content)
        hosting = controller
        let panel = NSWindow(contentViewController: controller)
        panel.title = "添加搜索来源"
        panel.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setContentSize(NSSize(width: 560, height: 620))
        panel.center()
        window = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func close() { window?.close() }

    func windowWillClose(_ notification: Notification) {
        // 走红绿灯关闭时也要把连接流程收干净。
        // 否则后台的 discover/login Task 照跑，几秒后还会回来改状态；
        // 已建立的 DSM 会话与暂存的内存密码也一直留着。
        // `cancelDraft` 是幂等的：刚保存成功的路径上再调一次也不会破坏已落库的配置。
        model?.cancelDraft()
        window?.orderOut(nil)
    }
}
