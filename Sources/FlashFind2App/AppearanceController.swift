import AppKit
import FlashFindCore

/// 界面外观（浅色 / 深色 / 跟随系统）。
///
/// 外观要能在产品内三选一，不能是写死的 `Text("跟随系统")` —— 只能说、不能选。
///
/// 从 AppModel 里切出来的理由和 `LocalSourceController` 一样：这一块只依赖
/// 「偏好存在哪」一个入口，做成注入的类型后就能独立于 AppModel 那 20 多个
/// `@Published` 存在。判定本身在 Core 的 `AppearanceChoice`（可测），
/// 这里只负责落盘与把选择应用到窗口。
///
/// ★ 状态搬过来之后界面观察的仍是 AppModel，所以宿主必须桥接
/// `objectWillChange`——不桥接的表现是「设置里改了外观，那一行还是旧的」，
/// 编译能过、也不报错。
@MainActor
final class AppearanceController: ObservableObject {
    @Published var choice: AppearanceChoice = .system

    private let preferences: any ClientPreferences
    private let isPreview: Bool
    private let fixtureMode: Bool

    init(preferences: any ClientPreferences, isPreview: Bool, fixtureMode: Bool) {
        self.preferences = preferences
        self.isPreview = isPreview
        self.fixtureMode = fixtureMode
    }

    // MARK: - 宿主注入的入口

    /// 状态栏文案。预览态下拒绝修改时要告诉用户为什么没变。
    var onStatus: (String) -> Void = { _ in }

    // MARK: - 启动装配

    func loadFromPreferences() {
        choice = AppearanceChoice.resolve(stored: preferences.string(forKey: AppearanceChoice.storageKey))
    }

    // MARK: - 修改

    func set(_ newValue: AppearanceChoice) {
        // 纯预览（截图）不修改真实设置；可交互样例可以改，方便核对三种外观。
        guard !isPreview || fixtureMode else {
            onStatus("UI 预览不修改真实外观设置")
            return
        }
        choice = newValue
        preferences.set(newValue.rawValue, forKey: AppearanceChoice.storageKey)
        apply()
    }

    /// 把当前选择应用到整个应用的所有窗口（搜索浮窗 / 设置 / 引导）。
    ///
    /// `nil` 表示跟随系统——不是「浅色」，是把决定权交回去。
    /// 启动时也要调一次：用户上次选了深色，重启后必须还是深色。
    func apply() {
        NSApp.appearance = nsAppearance(for: choice)
    }

    private func nsAppearance(for choice: AppearanceChoice) -> NSAppearance? {
        switch choice {
        case .system: return nil
        case .light: return NSAppearance(named: .aqua)
        case .dark: return NSAppearance(named: .darkAqua)
        }
    }
}
