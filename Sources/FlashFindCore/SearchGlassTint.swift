import Foundation

/// 玻璃模块**底色**的取值：决定「这块玻璃有多实」。
///
/// ## 深色：压在玻璃后面的一层黑
///
/// 2026-10-30 用户拿聚焦搜索对标：「暗色模式下闪寻的颜色和聚焦搜索不一样，
/// 聚焦搜索更暗一些，感觉更舒服」。`.glassEffect(.regular)` 在浅色壁纸上会被
/// 折射得发白，压一层半透明黑才靠近系统那块深灰玻璃。
/// 三档实拍（0.28 / 0.45 / 0.62，见
/// `04-测试与验收/UI-搜索框抬高与深色玻璃-20261030/`）后，用户定 **0.62**。
///
/// ## 浅色：背景高斯模糊之上的一层白
///
/// 用户 2026-10-30：「浅色模式改成底部背景高斯模糊质感」。
/// 浅色不再用 `.regular` 玻璃（它把背景洗成一片白），改成**背景真高斯模糊**
/// （`SearchBackdropBlur`）+ 一层很薄的白膜——白膜只负责把文字从花哨壁纸上按住，
/// 不是用来「染白玻璃」的。
///
/// 两者都画在 `content` **之前**，所以正文、图标、结果行一律不受影响。
public enum SearchGlassTint {

    /// 深色外观：压在玻璃后面的黑。
    ///
    /// 0.62 是用户从三档实拍里挑的。再往上就真成了实心板（玻璃的折射彻底消失），
    /// 那条线由 `testDarkGlassIsDarkerThanTheSystemDefault` 钉着。
    public static let darkAlpha: Double = 0.62

    /// 浅色外观：压在高斯模糊背景上的白。
    ///
    /// 0.14 足够让文字在花壁纸上站得住，又不至于把模糊质感糊掉。
    public static let lightAlpha: Double = 0.14

    public static func alpha(dark: Bool) -> Double { dark ? darkAlpha : lightAlpha }
}
