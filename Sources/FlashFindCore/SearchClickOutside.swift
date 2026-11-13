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
                                     overlayBlocksDismissal: Bool = false,
                                     systemPromptBlocksDismissal: Bool = false) -> Bool {
        // ★ 2026-10-30 报障：「闪寻无法被截图，一截图就直接消失了」。
        //   截图工具的选区遮罩是一块**盖满整屏、层级高于浮窗**的窗口。用 ⌘⇧5 或
        //   第三方截图工具时，它一启动就把闪寻挤成「非前台」，那一下鼠标按下正好
        //   落进下面的全局监视里 —— 于是浮窗在选区画到一半时被收掉，截出来的图里
        //   自然没有闪寻。判据见 `blocksDismissal`：点在这种遮罩上不算「点了外面」。
        if overlayBlocksDismissal { return false }
        // ★ 2026-11-13 报障：「第一次打开，弹出输入钥匙串密码后，输入后闪寻的
        //   搜索框直接关闭了」。系统授权框属于 SecurityAgent，用户点它里面任何一处
        //   （密码输入框、「始终允许」）在屏幕坐标上都落在闪寻窗口之外；而框一弹出
        //   闪寻就失去前台，全局点击监视恰好在这时被补挂上 —— 那一下被判成「点外部」。
        //   保护期由 `SystemPromptFocusPolicy` 判定，快照里带的是事件时刻的结论。
        if systemPromptBlocksDismissal { return false }
        if field.contains(point) { return false }
        for frame in otherVisibleWindows where frame.contains(point) { return false }
        return true
    }

    /// 事件到达那一刻的判定输入。
    ///
    /// ## 为什么必须是快照（2026-11-13 报障）
    /// 用户原话：「拖动搜索框移动时有时候会直接关闭」。
    /// 原实现在 `leftMouseDown` 回调里 `Task { @MainActor in dismissIfClickOutside() }`，
    /// 判定却在 Task 真正执行时**重新读** `NSEvent.mouseLocation` 与 `panel.frame`。
    /// AppKit 的窗口拖动跟踪循环会把这个 Task 推迟到松手附近，而松手的
    /// `settleLayoutAfterDrag()` 又会 `setFrame` 重新摆位 —— 于是「按下时明明在窗口内」
    /// 被换成「松手后落在窗口外的指针」，`field.contains(point)` 变 false，浮窗被收起。
    /// 判据因此必须取**按下那一刻**的坐标与 frame；异步只允许消费这份快照。
    public struct Snapshot: Sendable {
        public let click: CGPoint
        public let field: CGRect
        public let otherVisibleWindows: [CGRect]
        public let overlayBlocksDismissal: Bool
        /// 这一下按下时，是不是正处在系统授权框及其刚结束的宽限期内。
        /// 必须进快照：异步判定再读一次「现在」会把宽限期读没，界面照样消失。
        public let systemPromptBlocksDismissal: Bool

        public init(click: CGPoint, field: CGRect,
                    otherVisibleWindows: [CGRect],
                    overlayBlocksDismissal: Bool,
                    systemPromptBlocksDismissal: Bool = false) {
            self.click = click
            self.field = field
            self.otherVisibleWindows = otherVisibleWindows
            self.overlayBlocksDismissal = overlayBlocksDismissal
            self.systemPromptBlocksDismissal = systemPromptBlocksDismissal
        }
    }

    /// 用事件时刻的快照判定。判定口径与逐参版本完全一致，只是输入不许再被时间改写。
    public static func shouldDismiss(_ snapshot: Snapshot) -> Bool {
        shouldDismiss(click: snapshot.click,
                      field: snapshot.field,
                      otherVisibleWindows: snapshot.otherVisibleWindows,
                      overlayBlocksDismissal: snapshot.overlayBlocksDismissal,
                      systemPromptBlocksDismissal: snapshot.systemPromptBlocksDismissal)
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
