import Foundation

/// 「这一点点击算不算在浮窗外」——决定搜索浮窗要不要收起来。
///
/// ## 为什么这件事要从界面里搬出来（2026-10-28 报障）
///
/// 用户原话：「搜索结果钉住后,关闭搜索结果,搜索框不再点击任意位置关闭」。
///
/// 原来的判定写在 `SearchPanelController.dismissIfClickOutside` 里，豁免条件之一是
/// **结果那一块窗口的 frame**：只要点落在那块矩形里就当成「点在自己身上」，不收。
/// 而 `orderOut` 不清窗口的 frame —— 结果窗一旦被收起来（钉住之后查询词被清空，
/// 它必然被收起来），屏幕上那块 680×470 的位置就变成**一片看不见的禁点区**。
/// 用户看到的是空桌面，点下去却没反应；而那块区域恰好就在搜索框正下方，
/// 也就是钉住窗原来的位置——他关掉钉住窗之后最自然要点的就是那儿。
///
/// 所以规则写死成一句：**只有此刻真的看得见的窗口才豁免**。
/// 判定本身是纯函数，可以脱离 AppKit 测（隐藏窗、钉住窗、点内部/外部各一条）。
public enum SearchClickOutside {
    /// 这一点该不该收起浮窗。
    ///
    /// - Parameters:
    ///   - point: 点击位置（屏幕坐标，与 `window.frame` 同一坐标系）。
    ///   - field: 搜索框那一块窗口的 frame。
    ///   - otherVisibleWindows: 本应用**此刻可见**的其它窗口的 frame。
    ///     ★ 传进来的必须是**已过滤**的：隐藏窗口的 frame 留在原地不动，
    ///     把它算进来就等于在屏幕上留了一片看不见的禁点区。
    public static func shouldDismiss(click point: CGPoint,
                                     field: CGRect,
                                     otherVisibleWindows: [CGRect],
                                     overlayBlocksDismissal: Bool = false) -> Bool {
        // ★ 2026-10-30 报障：「闪寻无法被截图，一截图就直接消失了」。
        //   截图工具的选区遮罩是一块**盖满整屏、层级高于浮窗**的窗口。用 ⌘⇧5 或
        //   第三方截图工具时，它一启动就把闪寻挤成「非前台」，那一下鼠标按下正好
        //   落进下面的全局监视里 —— 于是浮窗在选区画到一半时被收掉，截出来的图里
        //   自然没有闪寻。判据见 `blocksDismissal`：点在这种遮罩上不算「点了外面」。
        if overlayBlocksDismissal { return false }
        if field.contains(point) { return false }
        for frame in otherVisibleWindows where frame.contains(point) { return false }
        return true
    }

    /// 这一点是不是落在**截图遮罩**上（盖满整屏、且层级高于所有常驻界面元素）。
    ///
    /// 两条同时成立才算：光看层级，程序坞会一直命中；光看铺满整屏，任何 App 的
    /// 全屏窗口都会命中——两种误判下面都有用例钉着。
    ///
    /// ## 门槛为什么是 25（实测出来的，不是估的）
    ///
    /// 2026-10-30 拿 `CGWindowListCopyWindowInfo` 在同一次截图操作里量到的：
    ///
    /// | 窗口 | 层级 | 占屏 |
    /// | --- | --- | --- |
    /// | 系统截图选区遮罩（`screencapture`） | **1498** | 100%（要放行的就是它） |
    /// | 程序坞 | **20** | **100%**（常驻！只按「高于浮窗」判就永远命中） |
    /// | 菜单栏 | 25 | 一条薄片 |
    ///
    /// `NSWindow.Level.statusBar` 就是 25，写成数字是为了 Core 不引 AppKit。
    /// 常驻界面元素都不高于它，真正为了「盖住屏幕」而生的临时遮罩一定在它之上。
    public static let overlayLayerFloor = 25

    public static func blocksDismissal(windowLayer: Int,
                                       windowBounds: CGRect,
                                       screen: CGRect) -> Bool {
        guard windowLayer > overlayLayerFloor, screen.width > 0, screen.height > 0 else { return false }
        let covered = windowBounds.intersection(screen)
        guard !covered.isNull else { return false }
        return covered.width * covered.height >= screen.width * screen.height * 0.9
    }
}
