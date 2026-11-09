import XCTest
import Foundation
import CoreGraphics
@testable import FlashFindCore

/// 父子窗口组的 Core 契约。
///
/// ★ 这些是**契约测试**，不是「拖起来不卡」的红证。
/// 运行时是否真的同帧，唯一的判据是 1.1.68 诊断包吐出的帧日志
/// （`~/Library/Logs/FlashFind2/drag-trace.log`）。别再拿单测绿当成验收。
final class WindowGroupPolicyTests: XCTestCase {

    func testAttachOnlyWhenResultsAreVisibleAndNotYetAttached() {
        XCTAssertTrue(WindowGroupPolicy.shouldAttach(resultsVisible: true, isAttached: false))
        XCTAssertFalse(WindowGroupPolicy.shouldAttach(resultsVisible: true, isAttached: true))
        XCTAssertFalse(WindowGroupPolicy.shouldAttach(resultsVisible: false, isAttached: false))
        XCTAssertFalse(WindowGroupPolicy.shouldAttach(resultsVisible: false, isAttached: true))
    }

    func testDetachOnlyWhenHiddenAndAttached() {
        XCTAssertTrue(WindowGroupPolicy.shouldDetach(resultsVisible: false, isAttached: true))
        XCTAssertFalse(WindowGroupPolicy.shouldDetach(resultsVisible: true, isAttached: true))
        XCTAssertFalse(WindowGroupPolicy.shouldDetach(resultsVisible: false, isAttached: false))
    }

    func testExpectedChildOriginKeepsTheObservedOffset() {
        let parentBefore = CGPoint(x: 320, y: 700)
        let childBefore = CGPoint(x: 320, y: 210)
        let parentAfter = CGPoint(x: 401, y: 664)
        let expected = WindowGroupPolicy.expectedChildOrigin(parentBefore: parentBefore,
                                                              parentAfter: parentAfter,
                                                              childBefore: childBefore)
        XCTAssertEqual(expected.x, 401, accuracy: 0.0001)
        XCTAssertEqual(expected.y, 174, accuracy: 0.0001)
        // 相对偏移必须逐字不变：这就是「两块作为一个实体」的定义。
        let before = CGVector(dx: childBefore.x - parentBefore.x, dy: childBefore.y - parentBefore.y)
        let after = CGVector(dx: expected.x - parentAfter.x, dy: expected.y - parentAfter.y)
        XCTAssertEqual(before.dx, after.dx, accuracy: 0.0001)
        XCTAssertEqual(before.dy, after.dy, accuracy: 0.0001)
    }

    func testExpectedChildOriginSurvivesMissedFrames() {
        // 一次跨两帧的大位移，期望值只由「起点 + 当前位置」决定，不累计。
        let before = CGPoint(x: 100, y: 500)
        let child = CGPoint(x: 100, y: 100)
        let one = WindowGroupPolicy.expectedChildOrigin(parentBefore: before,
                                                         parentAfter: CGPoint(x: 110, y: 495),
                                                         childBefore: child)
        let two = WindowGroupPolicy.expectedChildOrigin(parentBefore: before,
                                                         parentAfter: CGPoint(x: 130, y: 480),
                                                         childBefore: child)
        XCTAssertEqual(two.y - one.y, -15, accuracy: 0.0001)
        XCTAssertEqual(two.x - one.x, 20, accuracy: 0.0001)
    }

    func testAttachedGroupNeverFallsBackToDidMoveChasing() {
        XCTAssertFalse(WindowGroupPolicy.shouldFollowByNotification(isAttached: true))
        // 挂不上时退回追赶，保证联动不至于完全不可用（兜底不能比实际更悲观）。
        XCTAssertTrue(WindowGroupPolicy.shouldFollowByNotification(isAttached: false))
    }

    func testAutoLayoutIsDeferredOnlyWhilePointerIsDown() {
        XCTAssertTrue(WindowGroupPolicy.shouldDeferAutoLayout(pointerDown: true))
        XCTAssertFalse(WindowGroupPolicy.shouldDeferAutoLayout(pointerDown: false))
    }

    /// ★★ 用户 2026-11-08 22:19 原话：「我要求的是只有固定以后才能拖动，
    ///   否则就是整体移动」。未固定的结果窗是 child，**不是把手**。
    func testOnlyPinnedSnapshotMayBeDraggedIndependently() {
        XCTAssertFalse(WindowGroupPolicy.mayDragResultsWindowIndependently(isPinnedSnapshot: false),
                       "★ 未固定的结果窗不许自己被拖走，只能跟搜索框整体移动")
        XCTAssertTrue(WindowGroupPolicy.mayDragResultsWindowIndependently(isPinnedSnapshot: true),
                      "★ 钉住后的快照窗是独立窗口，必须仍能按住背景任意拖")
    }

    /// 判据只看「有没有钉住」，不许被父子关系挂没挂上这种运行时状态改写。
    func testDragPermissionDoesNotDependOnAttachmentState() {
        for attached in [true, false] {
            _ = attached
            XCTAssertFalse(WindowGroupPolicy.mayDragResultsWindowIndependently(isPinnedSnapshot: false))
        }
        XCTAssertTrue(WindowGroupPolicy.mayDragResultsWindowIndependently(isPinnedSnapshot: true))
    }
}
