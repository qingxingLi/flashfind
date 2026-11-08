import XCTest
import Foundation
import CoreGraphics
@testable import FlashFindCore

/// 未固定时两块窗「保持一起移动」的数值契约。
final class LinkedWindowFollowerTests: XCTestCase {

    private let field = CGPoint(x: 400, y: 700)
    private let results = CGPoint(x: 400, y: 220)

    func testRelativeOffsetIsObservedNotAssumed() {
        let delta = LinkedWindowFollower.relativeOffset(field: field, results: results)
        XCTAssertEqual(delta.dx, 0, accuracy: 0.0001)
        XCTAssertEqual(delta.dy, -480, accuracy: 0.0001)
    }

    func testDraggingTheFieldMovesTheResultsByTheSameDelta() {
        let moved = CGPoint(x: field.x + 120, y: field.y - 35)
        let companion = LinkedWindowFollower.companionOrigin(moving: .field,
                                                             moverBefore: field,
                                                             moverAfter: moved,
                                                             companionBefore: results)
        XCTAssertEqual(companion.x, results.x + 120, accuracy: 0.0001)
        XCTAssertEqual(companion.y, results.y - 35, accuracy: 0.0001)
        XCTAssertEqual(LinkedWindowFollower.relativeOffset(field: moved, results: companion).dy,
                       LinkedWindowFollower.relativeOffset(field: field, results: results).dy,
                       accuracy: 0.0001)
    }

    /// ★ 用户 2026-11-08 明确要的新语义：拖**结果窗**时搜索框也一起走。
    func testDraggingTheResultsMovesTheFieldByTheSameDelta() {
        let moved = CGPoint(x: results.x - 90, y: results.y + 60)
        let companion = LinkedWindowFollower.companionOrigin(moving: .results,
                                                             moverBefore: results,
                                                             moverAfter: moved,
                                                             companionBefore: field)
        XCTAssertEqual(companion.x, field.x - 90, accuracy: 0.0001)
        XCTAssertEqual(companion.y, field.y + 60, accuracy: 0.0001)
    }

    /// `SearchWindowLift` 把结果窗下沿夹在屏幕底边时，两块距离不等于 gap+height；
    /// 联动必须保留这个「被夹过」的观测偏移，而不是重新贴一次。
    func testClampedResultsKeepTheirObservedOffset() {
        let clampedResults = CGPoint(x: 400, y: 12)   // 贴着可见区底边
        let moved = CGPoint(x: field.x + 50, y: field.y - 200)
        let companion = LinkedWindowFollower.companionOrigin(moving: .field,
                                                             moverBefore: field,
                                                             moverAfter: moved,
                                                             companionBefore: clampedResults)
        XCTAssertEqual(companion.x, 450, accuracy: 0.0001)
        XCTAssertEqual(companion.y, -188, accuracy: 0.0001)
        XCTAssertEqual(LinkedWindowFollower.relativeOffset(field: moved, results: companion).dy,
                       LinkedWindowFollower.relativeOffset(field: field, results: clampedResults).dy,
                       accuracy: 0.0001)
    }

    func testZeroDeltaLeavesTheCompanionAlone() {
        let companion = LinkedWindowFollower.companionOrigin(moving: .field,
                                                             moverBefore: field,
                                                             moverAfter: field,
                                                             companionBefore: results)
        XCTAssertEqual(companion.x, results.x, accuracy: 0.0001)
        XCTAssertEqual(companion.y, results.y, accuracy: 0.0001)
    }

    func testOnlyARealPointerDragStartsFollowing() {
        XCTAssertTrue(LinkedWindowFollower.shouldFollow(pointerDown: true, resultsVisible: true,
                                                        isProgrammaticPlacement: false, isSyncing: false))
        XCTAssertFalse(LinkedWindowFollower.shouldFollow(pointerDown: false, resultsVisible: true,
                                                         isProgrammaticPlacement: false, isSyncing: false))
        XCTAssertFalse(LinkedWindowFollower.shouldFollow(pointerDown: true, resultsVisible: false,
                                                         isProgrammaticPlacement: false, isSyncing: false))
    }

    func testProgrammaticPlacementDoesNotStartFollowing() {
        XCTAssertFalse(LinkedWindowFollower.shouldFollow(pointerDown: true, resultsVisible: true,
                                                         isProgrammaticPlacement: true, isSyncing: false))
    }

    /// ★ 防反馈循环：同步另一块窗时，那一块的 didMove 不许再触发一次反向跟随。
    func testSyncingDoesNotStartAReverseFollow() {
        XCTAssertFalse(LinkedWindowFollower.shouldFollow(pointerDown: true, resultsVisible: true,
                                                         isProgrammaticPlacement: false, isSyncing: true))
    }
}
