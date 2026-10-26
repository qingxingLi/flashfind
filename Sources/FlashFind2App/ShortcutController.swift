import AppKit
import FlashFindCore

/// 全局快捷键的录制、保存与生效。
///
/// ## 为什么从 AppModel 里分出来
///
/// 它跟搜索、连接、结果**一点关系都没有**：
/// 唯一的外界依赖是 `preferences`。分出来之后，这一块的全部状态与生命周期
/// 都收在一个 100 行上下的类型里，出问题时不用在 AppModel 里翻。
///
/// ## 真正容易错的地方：事件监视器的生命周期
///
/// 录制快捷键要装一个 `NSEvent` 本地监视器，并且要盯住窗口失焦/关闭两个通知。
/// 这两个东西**装了就必须卸**，而且有两条卸的路径：
///
/// * 正常结束（录到组合键、按 Esc、窗口失焦或关闭）→ `cancelRecording()`；
/// * 对象被释放 → `deinit`。
///
/// 这段逻辑若散在别处，`deinit` 里那两行清理与 `cancelShortcutRecording()`
/// 是两份重复代码——改一处忘了另一处，就会留下一个永远不摘的全局事件监视器。
/// 现在**只有这一个类型**持有它们，卸的路径也只有这两处，写在同一个文件里。
///
/// `deinit` 只做清理、不改状态：对象都要没了，再去写 `status` 没有意义，
/// 而且 `@Published` 在 deinit 里触发刷新是没定义的。
@MainActor
final class ShortcutController: ObservableObject {
    @Published private(set) var spec = GlobalShortcutSpec.default
    @Published private(set) var status = ""
    @Published private(set) var available = false
    @Published private(set) var isRecording = false
    /// 最近一次失败是不是「这个组合被系统/别的应用占用了」。
    ///
    /// 与「组合本身不合法」分开记：设置页两种都照原文显示（用户在排查，
    /// 错误码有用），而引导页对新用户只能说人话 —— 见 `OnboardingShortcutText`。
    /// 不靠解析 `status` 的文本来判：那种判据会在改文案时静默失效。
    @Published private(set) var registrationRefused = false

    private let preferences: any ClientPreferences
    private let storageKey = "ff2.globalShortcut.v1"
    private var registrar: ((GlobalShortcutSpec) -> String?)?
    private var monitor: Any?
    private var observers: [NSObjectProtocol] = []

    init(preferences: any ClientPreferences) {
        self.preferences = preferences
        if let data = preferences.data(forKey: storageKey) {
            if let saved = try? JSONDecoder().decode(GlobalShortcutSpec.self, from: data),
               saved.validationMessage == nil {
                spec = saved
            } else {
                // 已存的数据坏了：不覆盖它（用户可能想自己看），但要把原因说清。
                status = "已保存的快捷键无效，暂用 ⌥Space；原数据保留，录制后可重新保存"
            }
        }
    }

    deinit {
        // 只清理，不碰状态。与 cancelRecording() 的区别见文件头说明。
        if let monitor { NSEvent.removeMonitor(monitor) }
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }

    func configureRegistrar(_ register: @escaping (GlobalShortcutSpec) -> String?) {
        registrar = register
        if let error = register(spec) {
            available = false
            // 启动时注册失败几乎只有一个原因：默认的 ⌥Space 被别的应用占了。
            // 这也要让引导页说得出来，否则用户会以为「快捷键本来就该不工作」。
            registrationRefused = true
            status = error
        } else {
            available = true
            registrationRefused = false
            // 成功时**不写任何说明**。界面上快捷键那一行已经把组合显示出来了，
            // 再补一句「按 ⌥Space 唤出或收起搜索」是同义重复。
            // `status` 从此只承载一件事：出问题时告诉用户为什么。
            status = ""
        }
    }

    @discardableResult
    func apply(_ spec: GlobalShortcutSpec) -> Bool {
        if let error = spec.validationMessage {
            registrationRefused = false
            status = error
            return false
        }
        guard let register = registrar else {
            registrationRefused = false
            status = "全局快捷键尚未启用；仍可从菜单栏打开闪寻"
            return false
        }
        guard let data = try? JSONEncoder().encode(spec) else {
            registrationRefused = false
            status = "无法保存快捷键，原组合保留"
            return false
        }
        if let error = register(spec) {
            registrationRefused = true
            status = error
            return false
        }
        preferences.set(data, forKey: storageKey)
        self.spec = spec
        available = true
        registrationRefused = false
        cancelRecording()
        // 同上：改成功了就安静。这一行原来会写「已保存 ⌥Space；下次启动继续使用…」，
        // 而按钮上的组合已经变了，用户看得出改成了什么。
        status = ""
        return true
    }

    @discardableResult
    func reset() -> Bool { apply(.default) }

    func beginRecording() {
        cancelRecording()
        guard let window = NSApplication.shared.keyWindow else {
            status = "请先打开设置，再录制快捷键"
            return
        }
        isRecording = true
        // 录制中的提示由那一行自己画（见 `ShortcutSettingRow`），这里只清旧状态，
        // 免得上一次的失败信息一直挂在正在录制的行下面。
        status = ""
        // 显式标注 `-> NSEvent?`：返回 nil 表示「这个事件已被消费，别再往下传」。
        // 不标注时 Swift 会把闭包返回类型推断成非可选的 NSEvent（因为多数分支
        // `return event`），两条 `return nil` 就都过不了编译。
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self, weak window] (event: NSEvent) -> NSEvent? in
            guard let self, self.isRecording, let window else { return event }
            // 焦点跑到别的窗口上就放弃录制：继续收键会录到一个用户没打算给的组合。
            guard event.window === window, window.isKeyWindow else {
                self.cancelRecording()
                return event
            }
            // 输入法有未确认的候选时，这一下按键是给输入法的，不是给快捷键的。
            guard (window.firstResponder as? NSTextView)?.hasMarkedText() != true else { return event }
            if event.keyCode == 53 {
                self.cancelRecording()
                return nil
            }
            _ = self.apply(GlobalShortcutSpec(keyCode: UInt32(event.keyCode),
                                              modifiers: GlobalShortcutSpec.modifiers(cocoaFlags: event.modifierFlags.rawValue)))
            return nil
        }
        for name in [NSWindow.didResignKeyNotification, NSWindow.willCloseNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.cancelRecording() }
            })
        }
    }

    func cancelRecording() {
        // 取消是用户自己按的 Esc，组合没变，不需要一句话来解释。
        if isRecording { status = "" }
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecording = false
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
    }
}
