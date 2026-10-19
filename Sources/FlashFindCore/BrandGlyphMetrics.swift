import CoreGraphics
import Foundation

/// 品牌字形（圆环 + 闪电）的尺寸换算。
///
/// 为什么住 Core：同一枚素材要出现在两个高度差一档的位置——状态栏 18pt、
/// 搜索框 22pt——而且必须**等比缩放**。拉伸变形这类问题只有肉眼能发现，
/// 而 App 层是 executableTarget、测不了；把换算抽成纯函数就能锁住。
public enum BrandGlyphMetrics {
    /// 状态栏标准高度（macOS 菜单栏图标惯例 18pt）。
    public static let menuBarHeight: CGFloat = 18
    /// 搜索框前那枚图标的高度：与输入文字（22pt）齐平。
    public static let searchFieldHeight: CGFloat = 22

    /// 按目标高度等比缩放，宽度由原始宽高比算出——**绝不拉成正方形**。
    ///
    /// - 高度非法（≤ 0）：返回 `.zero`，调用方不必自己判。
    /// - 素材尺寸非法（宽或高为 0）：按正方形处理，至少不会得到 NaN 宽度。
    public static func fittedSize(naturalWidth: CGFloat, naturalHeight: CGFloat,
                                  height: CGFloat) -> CGSize {
        guard height > 0, height.isFinite else { return .zero }
        guard naturalWidth > 0, naturalHeight > 0,
              naturalWidth.isFinite, naturalHeight.isFinite else {
            return CGSize(width: height, height: height)
        }
        return CGSize(width: height * (naturalWidth / naturalHeight), height: height)
    }
}
