import Foundation

/// 「这一次窗口移动，算不算用户亲手拖的？」
///
/// 搜索结果窗（要不要停止自动贴回搜索框下方）和搜索框（要不要把位置记成
/// 「用户设定的位置」）问的是同一个问题，所以判定只有这一处。
///
/// ## 为什么不能靠通知时序（2026-10-30）
///
/// `NSWindow.didMoveNotification` 在程序化 `setFrame` / `animator().setFrame`
/// 之后**照样发**，而且发得比动画的 `completionHandler` 还晚——实测连发 11 条，
/// 全部落在「正在摆位」标志复位之后。于是「设标志 → 下一拍复位」这套永远赶不上车：
/// 每一次自动摆位都被记成「用户拖过」，抬升搜索框的逻辑整条失效
/// （证据：预览壳里 `resultsUserMoved` 首屏就是 true，结果窗位置从此不再自动摆）。
///
/// 用户拖动的充要条件就是**鼠标按着**：程序化摆位不可能发生在按着鼠标的时刻。
/// 所以判据取这个，而不是去猜「这段通知是程序发的还是人发的」。
public enum WindowDragIntent {
    /// - Parameters:
    ///   - pointerDown: 此刻鼠标左键按着吗（App 层从 `NSEvent.pressedMouseButtons` 取）。
    ///   - autoPlaced: 这次移动是不是程序摆的（正在摆位 / 处于被抬高等临时位置）。
    public static func isUserDrag(pointerDown: Bool, autoPlaced: Bool) -> Bool {
        pointerDown && !autoPlaced
    }
}
