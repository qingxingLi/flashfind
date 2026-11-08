import Foundation
import CoreGraphics

/// 未固定时，搜索框与结果窗是一个整体：拖其中一块，另一块保持相对位置一起走。
///
/// ## 2026-11-08 功能更新（用户原话）
///
/// 「搜索结果模块改为在未固定时，随搜索框拖动而移动，固定后可任意拖动位置」；
/// 追问「未固定时拖结果窗」时用户明确：**「结果窗和搜索框保持一起移动」**。
///
/// ## 这是一次契约反转，不是补一个通知
///
/// 2026-10-28 定的旧契约是「两块窗各自独立，拖搜索框不再带着它走」，并被
/// `SearchPanelController` / `SearchResultsPanel` 三处注释与一条结构断言钉死。
/// 现在反过来：**未固定 = 联动**，只有点图钉生成的快照窗才是独立的、可任意拖。
///
/// ## ★ 相对偏移不能假设是常量
///
/// 「结果贴在搜索框下沿 gap」在放得下时成立；但 `SearchWindowLift.plan` 在搜索框
/// 贴近屏幕底部、又抬不动时会把结果窗的下沿夹在可见区底边，此时两块窗的距离
/// **不等于** `gap + 结果窗高度`。所以联动不能写死 `(0, -(gap+height))`，
/// 只能是「另一块跟着走同样的位移」——保留拖动开始那一刻的真实相对位置。
///
/// ## ★ 必须防反馈循环
///
/// 程序化移动另一块窗会触发它自己的 `NSWindow.didMoveNotification`；
/// 若那一边也照着跟随一次，就会 A→B→A→B 无限来回，直到鼠标松开。
/// `isSyncing` 这一维由协调者在同步期间置位，是这条判据的一部分，不是可省的优化。
public enum LinkedWindowFollower {

    /// 这次移动是被用户拖动的哪一块。
    public enum Moved: String, Sendable, Equatable {
        case field
        case results
    }

    /// 两块窗此刻的相对位置（结果窗原点 − 搜索框原点）。
    public static func relativeOffset(field: CGPoint, results: CGPoint) -> CGVector {
        CGVector(dx: results.x - field.x, dy: results.y - field.y)
    }

    /// 该不该联动。
    ///
    /// - `pointerDown`：鼠标是否按着（`PointerButton.isDown`）。这是「人手在拖」的
    ///   唯一可靠判据：程序化摆位不会发生在按着鼠标的时刻。
    /// - `resultsVisible`：结果窗没显示时没有跟随对象。
    /// - `isProgrammaticPlacement`：正在跑 `layoutForResults()` / `place()` 的动画。
    /// - `isSyncing`：正在因为另一块窗而同步自己，用来掐断反馈循环。
    ///
    /// ★ 钉住的快照窗**不在这个注册表里**（`SearchWindowRegistry` 只登记搜索框与
    ///   当前结果窗），所以它天然不参与联动；这里不需要也不该有 `isPinned` 参数。
    public static func shouldFollow(pointerDown: Bool,
                                    resultsVisible: Bool,
                                    isProgrammaticPlacement: Bool,
                                    isSyncing: Bool) -> Bool {
        pointerDown && resultsVisible && !isProgrammaticPlacement && !isSyncing
    }

    /// 另一块窗该去哪儿：跟着走**同样的位移**。
    ///
    /// `moving` 只用于把语义写进调用点与测试——无论是拖搜索框还是拖结果窗，
    /// 另一块的位移都相同，这正是「保持一起移动」。
    public static func companionOrigin(moving: Moved,
                                       moverBefore: CGPoint,
                                       moverAfter: CGPoint,
                                       companionBefore: CGPoint) -> CGPoint {
        let dx = moverAfter.x - moverBefore.x
        let dy = moverAfter.y - moverBefore.y
        return CGPoint(x: companionBefore.x + dx, y: companionBefore.y + dy)
    }
}
