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
                                     otherVisibleWindows: [CGRect]) -> Bool {
        if field.contains(point) { return false }
        for frame in otherVisibleWindows where frame.contains(point) { return false }
        return true
    }
}
