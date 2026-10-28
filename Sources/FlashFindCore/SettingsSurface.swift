import Foundation

/// 设置窗口的表面策略（用户 2026-10-27 定稿，当晚追加「跟着搜索这一块走」）。
///
/// ## 为什么要有一份策略，而不是把颜色写在视图里
///
/// 这条要求有几半，而且**几半的答案不一样**：
///
/// * 浅色：整窗换成**纯白**，卡片不用投影（那片灰白阴影正是要删掉的东西）；
/// * 浅色卡片的材质：2026-10-27 深夜改成**与搜索模块同一套 Liquid Glass**
///   （用户：「设置页 UI 界面跟着搜索这一块走」）——同一份 `glassEffect(.regular)`、
///   同一个圆角（`SearchModuleLayout.moduleRadius`）、同一道 0.5pt 描边；
/// * 拿不到玻璃的机器（macOS 15）与开了「降低透明度」时：退回**玻璃遮罩**
///   （极浅的膜 + 上沿高光 + 描边，零投影）——降透明度时铺一层真玻璃
///   等于让文字漂在桌面上，这条在搜索区也是同一条规矩；
/// * 深色：**维持现状**——毛玻璃窗底 + 带层次的材质卡（投影照旧）。
///
/// 把「浅色改成什么、深色保持不变」写成视图里的一串三元表达式，改一次配色
/// 要在四个页面里各改一遍，也测不到。放在 Core，App 只负责按这个策略画，
/// 于是「深色不许跟着改」这件事可以被一条断言钉住。
public enum SettingsSurface {

    /// 窗口底。
    public enum Backdrop: Equatable, Sendable {
        /// 纯白。浅色的底色不再是半透明的桌面材质——那层材质正是「大片灰白」的来源。
        case pureWhite
        /// 系统窗口毛玻璃（深色沿用）。
        case windowVibrancy
    }

    /// 分组卡片的表面。
    public enum Card: Equatable, Sendable {
        /// 与搜索框/结果面板同一套 Liquid Glass（浅色，macOS 26 起）。
        case liquidGlass
        /// 玻璃遮罩：一层极浅的膜 + 一道描边，没有投影。玻璃用不了时的替身。
        case glassMask
        /// 带层次的材质卡（深色沿用）。
        case elevatedMaterial
    }

    public struct Style: Equatable, Sendable {
        public let backdrop: Backdrop
        public let card: Card
        /// 卡片要不要投影。浅色为 `false`：投影正是这次要去掉的东西。
        public let cardShadow: Bool
        /// 卡片描边的不透明度（0…1）。深色比浅色重一点才看得见边。
        public let cardStroke: Double
        /// 卡片圆角。浅色取搜索模块的圆角（「跟着搜索这一块走」）；
        /// 深色维持原来那个更方正的值。
        public let cardRadius: CGFloat
    }

    /// 浅色默认：纯白底 + **搜索模块那套 Liquid Glass**、不投影。
    public static let light = Style(backdrop: .pureWhite,
                                    card: .liquidGlass,
                                    cardShadow: false,
                                    cardStroke: 0.07,
                                    cardRadius: SearchModuleLayout.moduleRadius)

    /// 浅色、但拿不到 Liquid Glass（macOS 15 / 降低透明度）：退回玻璃遮罩。
    ///
    /// 圆角与描边跟着一起走 —— 换的只是材质，不是另一套形状。
    public static let lightMask = Style(backdrop: .pureWhite,
                                        card: .glassMask,
                                        cardShadow: false,
                                        cardStroke: 0.07,
                                        cardRadius: SearchModuleLayout.moduleRadius)

    /// 深色：维持现状（毛玻璃底 + 有投影的材质卡）。
    ///
    /// ★ 圆角**不跟着深浅色走**：形状是产品的事，不是外观的事。
    ///   深色仍是材质 + 投影（用户定的「深色维持现在」），但圆角与浅色同值 ——
    ///   否则换个外观卡片就从圆角变方角，像两代设计。
    public static let dark = Style(backdrop: .windowVibrancy,
                                   card: .elevatedMaterial,
                                   cardShadow: true,
                                   cardStroke: 0.10,
                                   cardRadius: SearchModuleLayout.moduleRadius)

    /// 策略的唯一入口。
    ///
    /// ★ 玻璃**能力**必须由调用方传进来（编译期 + 运行期两门在 App 层探测，
    /// 见 `SearchGlass.isAvailable`）：Core 不知道这台机器跑的是哪个系统，
    /// 也不该假装知道。「有没有能力」与「有这个能力时该长什么样」分开，
    /// 才能在 macOS 15 上被回归到。
    public static func style(isDark: Bool, liquidGlassAvailable: Bool) -> Style {
        if isDark { return dark }
        return liquidGlassAvailable ? light : lightMask
    }
}
