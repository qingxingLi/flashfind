import Foundation
import CoreGraphics

/// 未固定时，搜索框与结果窗必须是 **AppKit 的父子窗口组**，由 WindowServer
/// 作为一个实体一起移动；不允许再靠 `didMove` 通知追赶另一块窗。
///
/// ## 为什么这是一次架构修正（2026-11-08 第二次真机反馈）
///
/// 1.1.67 把 `didMove` 改成 `queue: nil` 同步投递、把增量 delta 换成绝对对齐，
/// 用户真机依旧反馈「移动一个界面，另一个界面一卡一卡，有掉帧的感觉」。
/// 根因不是投递时序，而是**两个独立 NSWindow 各自向 WindowServer 提交位置**：
/// 被手拖的那块由 WindowServer 在事件阶段直接移动，另一块要等通知 → 主线程 →
/// `setFrame` → 再单独提交一次。两次提交不可能落在同一帧。
///
/// Apple 文档 `addChildWindow(_:ordered:)` 明确：附着生效时，移动父窗会带动子窗，
/// 移动子窗不会带动父窗。官方论坛「Moving 2 windows in sync in OS X」里同样的
/// 「companion moves only when one stops moving the parent」症状，答复正是改用
/// child window。所以这里把**搜索框当父、结果窗当子**，联动交给系统。
///
/// ★ 子窗被拖不会带动父窗。1.1.68 试着用 `performDrag(with:)` 把结果窗背景的
/// mouseDown 转发给父窗，好让两块都能当把手 —— 真机帧日志（22:19）证明这条路是错的：
/// 两段 `FIELD_DID_MOVE=0 / RESULTS_DID_MOVE=27、26` 的记录，就是结果窗被单独拖走、
/// 父窗一帧没动。用户随即把契约说死（2026-11-08 第三次反馈）：
/// 「**只有固定以后才能拖动，否则就是整体移动**」。
///
/// 所以：**未固定时结果窗不是把手**，唯一把手是搜索框；整体移动由父子窗口组负责。
/// 只有点图钉生成的独立快照窗（`PinnedResultsWindow`）才允许按住背景任意拖。
public enum WindowGroupPolicy {

    /// 能不能独立拖动一块结果窗：只有「钉住后的快照窗」可以。
    ///
    /// ★ 判据用「有没有被钉住」，不用「当前是否挂在父子组里」—— 未固定就是未固定，
    ///   哪怕 child 关系暂时没挂上，也不许把结果窗偷偷变回可拖窗口（缺证据 ≠ 反证据）。
    public static func mayDragResultsWindowIndependently(isPinnedSnapshot: Bool) -> Bool {
        isPinnedSnapshot
    }

    /// 结果窗可见时才挂着：隐藏时解绑，避免父窗 `orderOut` 把子窗一起带走的
    /// 时序副作用（父窗收起 / 再次唤起时 child 会被系统自动重新显示）。
    public static func shouldAttach(resultsVisible: Bool, isAttached: Bool) -> Bool {
        resultsVisible && !isAttached
    }

    /// 结果窗不可见（或整组收起）时解绑。
    public static func shouldDetach(resultsVisible: Bool, isAttached: Bool) -> Bool {
        !resultsVisible && isAttached
    }

    /// 子窗「应该」在哪：跟父窗走同样的位移。
    ///
    /// 帧日志用它做基准：把 WindowServer 报回来的两窗实际屏幕位置与本式的
    /// 期望值比对，偏差恒为 0 才说明它们真的是作为一个实体被移动的。
    public static func expectedChildOrigin(parentBefore: CGPoint,
                                            parentAfter: CGPoint,
                                            childBefore: CGPoint) -> CGPoint {
        CGPoint(x: childBefore.x + parentAfter.x - parentBefore.x,
                y: childBefore.y + parentAfter.y - parentBefore.y)
    }

    /// 父子组生效时**绝不能**再走 `didMove` 追赶：那会二次提交，把同帧破坏掉。
    /// 只有挂不上（例如系统拒绝建立关系）时才允许退回追赶，保证功能不至于完全不可用。
    public static func shouldFollowByNotification(isAttached: Bool) -> Bool {
        !isAttached
    }

    /// 拖动期间不许自动重排：两段 0.18s 动画会在拖动中被自己反复打断。
    /// 松手后由协调者补一次无动画重排。
    public static func shouldDeferAutoLayout(pointerDown: Bool) -> Bool {
        pointerDown
    }
}
