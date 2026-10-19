import Foundation

/// 界面外观：浅色 / 深色 / 跟随系统。
///
/// 外观必须能在产品内选择：只能说不能选的话，深色模式用户只能整机切系统外观，
/// 而闪寻自己的窗口（搜索浮窗、设置、引导）没有独立选项。
///
/// 判定放在 Core：App 层是 `executableTarget`，测试目标 import 不到，
/// 而「默认跟随系统、认不出的值退回跟随系统」是每次启动都会走的路径——
/// 退回任何一个具体外观都是替用户做决定。
public enum AppearanceChoice: String, CaseIterable, Identifiable, Sendable {
    /// 跟随系统：`NSApp.appearance = nil`，明暗由系统负责。
    case system
    /// 浅色。
    case light
    /// 深色。
    case dark

    public var id: String { rawValue }

    /// 设置页里显示的选项名。
    public var title: String {
        switch self {
        case .system: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    /// 偏好 key。沿用 `ff2.` 前缀。
    public static let storageKey = "ff2.appearance.v1"

    /// 由偏好值恢复选择。**默认跟随系统**；认不出的值（旧版写坏的、手改的）
    /// 同样退回跟随系统。
    public static func resolve(stored: String?) -> AppearanceChoice {
        guard let stored, let choice = AppearanceChoice(rawValue: stored) else { return .system }
        return choice
    }
}
