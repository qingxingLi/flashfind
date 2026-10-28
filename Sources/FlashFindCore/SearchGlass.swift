import Foundation

/// 搜索区（输入框 + 结果列表）的表面与「遮罩」策略。
///
/// ## 为什么要一份策略，而不是把判断写在视图里
///
/// 用户 2026-10-27 的要求有三段，而且**第二段与第一段相反**：
///
/// * 输入框与结果列表都用**动态玻璃**（透明、跟随、会折射）；
/// * 原来那两片实心色块——悬停的灰、选中的蓝——换成一块**更透明的玻璃遮罩**，
///   遮罩跟着鼠标 / 键盘选中项滑过去，滑过时边缘的字能看到「放大—缩小」；
/// * **macOS 15 及以下（没有 Liquid Glass）保持原方案不变**。
///
/// 把「什么时候用玻璃、什么时候回到老方案」写成视图里的三元表达式，等于
/// 每加一处就要重判一次，而且测不到。放这里，App 只按结论画，
/// 于是「降低透明度时必须退回实心」这种要求可以被一条断言钉住。
public enum SearchGlassStyle: Equatable, Sendable {
    /// macOS 26 起的动态玻璃遮罩。
    case glass
    /// macOS 15 及以下的老方案：悬停一层灰、选中一片系统蓝。
    case legacy

    /// 两个条件**都要**满足才用玻璃。
    ///
    /// * `liquidGlassAvailable`：编译期（`compiler(>=6.2)`）与运行期
    ///   （`#available(macOS 26)`）双门都过。任一不过，`glassEffect` 根本画不出来。
    /// * `reduceTransparency`：辅助功能「降低透明度」开着时**必须**退回实心。
    ///   玻璃是半透明的，用户专门开这个开关就是为了不要半透明——
    ///   这时还硬上玻璃，等于把无障碍设置当摆设。
    public static func resolve(liquidGlassAvailable: Bool, reduceTransparency: Bool) -> SearchGlassStyle {
        (liquidGlassAvailable && !reduceTransparency) ? .glass : .legacy
    }
}

/// 跟随鼠标/选中项的遮罩，其形状与「透过它看字」的放大曲线。
///
/// ## 为什么是「放大 + 边缘微缩」而不是整体放大
///
/// 参考的是 iOS 26 / macOS 26 的玻璃胶囊：遮罩正中的那一条被**放大**，
/// 紧邻的一条被**压小**（透镜边缘的挤压），再远就回到原样。
/// 遮罩滑过去的时候，同一个字会先变大、再变小——这就是用户要的
/// 「边缘位置明显看到字体逐渐放大和缩小」。
///
/// 曲线是纯函数，所以「中心必为峰值」「一行之外必然小一点」「远处必须是 1」
/// 都能用断言钉住；改数值不会悄悄改坏观感。
public enum SearchLens {

    /// 遮罩正中的放大倍率。**不要**超过 1.08：结果行高 56，
    /// 再大就会把标题顶出行的可视范围（截断感）。
    public static let peakScale: CGFloat = 1.055

    /// 紧邻遮罩的那一行（距离 1 行）的倍率。小于 1 = 被透镜挤小。
    public static let neighborScale: CGFloat = 0.972

    /// 影响范围（行数）。超过这个距离一律 1.0，不再有任何形变。
    public static let falloff: CGFloat = 1.8

    /// 遮罩中心落在 `rowDistance`（行，可为小数）处时，某一行应取的缩放。
    ///
    /// 分段线性，四段端点连成一条连续的曲线：
    /// `0 → 峰值`、`0.5 → 1`、`1 → neighborScale`、`falloff → 1`。
    /// 第二段（0…0.5）负责「进入遮罩即放大」，第三段负责「边缘挤压」，
    /// 第四段负责「平滑收回」。
    public static func scale(rowDistance: CGFloat) -> CGFloat {
        // 非有限值（NaN/∞）会让下面所有比较都为假，最后落到 1.0——
        // 那是安全值，但仍然先判掉，免得调用方把这条当「曲线」用。
        guard rowDistance.isFinite else { return 1 }
        let distance = abs(rowDistance)

        if distance <= 0.5 {
            return peakScale + (1 - peakScale) * (distance / 0.5)
        }
        if distance <= 1 {
            return 1 - (1 - neighborScale) * ((distance - 0.5) / 0.5)
        }
        if distance < falloff {
            return neighborScale + (1 - neighborScale) * ((distance - 1) / (falloff - 1))
        }
        return 1
    }
}
