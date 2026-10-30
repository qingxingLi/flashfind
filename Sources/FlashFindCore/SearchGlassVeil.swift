import Foundation

/// 悬停时盖在模块上的那层**液态玻璃遮罩**的取值。
///
/// 用户 2026-10-30：「搜索鼠标滑动时覆盖一层液态玻璃遮罩」。
///
/// 两层叠起来才像玻璃，缺一层都不像：
/// * **膜**：铺满整块模块的一层极淡白——让「鼠标进来了」这件事整块看得见，
///   而不是只有光标附近亮了一下；
/// * **高光**：跟着光标走的一团柔光（半径 `radius`），玻璃的「液态」感来自它。
///
/// 膜必须淡：它压在整个模块上，浓一点就会把结果标题一起提亮，看着像发了霉。
public enum SearchGlassVeil {

    /// 整块膜的亮度。
    public static func filmAlpha(dark: Bool) -> Double { dark ? 0.10 : 0.14 }

    /// 光标处那团高光的峰值。
    ///
    /// 浅色外观给得更高：白玻璃在白背景上，同样的透明度几乎看不出来。
    public static func specularAlpha(dark: Bool) -> Double { dark ? 0.22 : 0.30 }

    /// 高光半径（pt）。太小像手电筒、太大小半边模块都在亮。
    public static let radius: CGFloat = 220

    /// 淡入淡出时长（秒）。要短——悬停反馈慢半拍就像卡了。
    public static let fade: Double = 0.18
}
