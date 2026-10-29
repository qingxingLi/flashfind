import Foundation

/// 玻璃模块**边缘那一圈**的取值。
///
/// ## 为什么必须自己画描边（2026-10-28 报障）
///
/// 用户在纯白桌面上截图：搜索框与结果块「白得和桌面一样」，
/// 只剩一点阴影，边界基本看不出（他的原话：「动态玻璃效果如果屏幕是纯白背景时
/// 显示效果不好……建议增强一下边框的显示效果」）。
///
/// Liquid Glass 的材质本身没有轮廓：它靠「背景有东西」才能折射出层次。
/// 背景也是白的，就没有层次可折——所以玻璃在白底上看起来就是一块更白的白。
/// 系统自己在白底上也会消失，唯一能保证边界的只有**一条明确的描边**。
///
/// 三层结构（自外向内）：
/// 1. 外描边：**深色**（浅色外观下是黑 12%）——负责「白玻璃 vs 白桌面」的分界；
/// 2. 内高光：**白色**、只在上半段——负责玻璃的厚边与受光，深色外观靠它立起来；
/// 3. 内深边：极淡的一圈，把圆角处的高光收住，否则高光会在圆角上断掉。
///
/// 数值放在 Core 而不是视图里：深浅色各一套、四个通道，写在视图里既测不到，
/// 也会随「下一个人在另一个文件里再写一套」而分叉。
public enum SearchGlassEdge {

    /// 一种描边颜色（不依赖 SwiftUI，Core 只 import Foundation）。
    public struct Stroke: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double

        public init(red: Double, green: Double, blue: Double, alpha: Double) {
            self.red = red
            self.green = green
            self.blue = blue
            self.alpha = alpha
        }

        /// 纯黑 / 纯白两档 + 透明度，够用了，也免得写出「0.06 的蓝」这种看不出意图的值。
        public static func black(_ alpha: Double) -> Stroke { Stroke(red: 0, green: 0, blue: 0, alpha: alpha) }
        public static func white(_ alpha: Double) -> Stroke { Stroke(red: 1, green: 1, blue: 1, alpha: alpha) }
    }

    /// 外描边的线宽。
    ///
    /// 1pt 而不是 0.5：0.5 在非 Retina 与「降低透明度」下会被画成一排半透明的点，
    /// 白底上看起来像没画。1pt 在 Retina 上是两像素，仍然是一条线，不是一圈边。
    public static let strokeWidth: CGFloat = 1

    /// 内高光的线宽：比外描边细，只负责「厚度」，不参与分界。
    public static let highlightWidth: CGFloat = 1

    /// 外描边：把模块从桌面上分开的那一条。
    ///
    /// * 浅色外观（白桌面）——**深色**才看得见：黑 **22%**，压在 #FFFFFF 上约 #C7C7C7；
    /// * 深色外观——反过来用白 18%：黑边在深色玻璃上等于没有。
    ///
    /// ★ 2026-10-29 从 12% 提到 22%：12% 时压在纯白桌面上约 #E0E0E0，用户第二次报
    ///   「边框颜色可以再加深一些，白色背景下不明显」。玻璃本身在白底上折射不出层次，
    ///   这条线是唯一的边界 —— 宁可明显一点，也不要「看起来像没画」。
    ///   下限由 `testOuterStrokeIsDarkInLightAppearance` 钉住。
    public static func outer(dark: Bool) -> Stroke {
        dark ? .white(0.18) : .black(0.22)
    }

    /// 内高光：玻璃的「厚边」，只在上半段最亮，往下淡出。
    ///
    /// 深色外观下它是主要的那条线（外描边只是兜底），所以给得比外描边亮。
    ///
    /// ★ 2026-10-29 浅色从 85% 降到 35%：这层高光是**画在外描边之上**的，85% 的白
    ///   会把刚加深的黑边重新冲掉 —— 实测上边缘亮度 246（#F6F6F6），在白底上等于没画，
    ///   而同一时刻的底边是 199（#C7C7C7）。用户看到的「边框不明显」正是上边缘这一条。
    ///   用户给的另一个选项是「玻璃效果减弱一些」，这层高光就是玻璃厚度错觉本身，减弱它同理。
    public static func innerHighlight(dark: Bool) -> Stroke {
        dark ? .white(0.30) : .white(0.35)
    }

    /// 内高光在高光渐变**底部**的透明度（顶部用 `innerHighlight` 的值）。
    ///
    /// 收到 0 而不是留一点：留一点点会在下半圈也描一圈白，白底上看不出来、
    /// 深色上看像是给模块套了个亮框。
    public static let innerHighlightBottomAlpha: Double = 0

    /// 结果行遮罩（跟着鼠标滑的那块）的描边。
    ///
    /// 比模块的淡一档：它每跨一行就扫过整块区域，太重会像「一块被反复刷的色块」。
    /// ★ 同样要**两边都有**：只描白的话，白底上悬停完全看不出来。
    public static func lens(dark: Bool) -> Stroke {
        dark ? .white(0.35) : .black(0.10)
    }

    /// 遮罩内高光。
    public static func lensHighlight(dark: Bool) -> Stroke {
        dark ? .white(0.22) : .white(0.70)
    }

    /// 遮罩描边的线宽（比模块细一半：它跟着动，粗了会晃眼）。
    public static let lensStrokeWidth: CGFloat = 0.8
}
