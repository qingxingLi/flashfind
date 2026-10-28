import XCTest
@testable import FlashFindCore

/// 「全选 / 取消全选」的判定（`ScopeBulkSelection`）。
///
/// 这套用例守的是「界面那两个按钮什么时候亮、按下之后交出去的是什么集合」。
/// 这些判断如果在 App 层写，`FlashFind2App` 是 executableTarget、测试依赖不上，
/// 等于没测 —— 所以它们全在 Core，这里逐条钉住。
final class ScopeBulkSelectionTests: XCTestCase {

    // MARK: 集合归一

    func testNormalizedDeduplicatesAndSorts() {
        // 底层按顺序比较，重复项会让「已选 N 个」数错，顺序不定则会出现
        // 「同一份选择、两次提交内容不同」。
        XCTAssertEqual(ScopeBulkSelection.normalized(["/B", "/A", "/B"]), ["/A", "/B"])
        XCTAssertEqual(ScopeBulkSelection.normalized([]), [])
    }

    // MARK: 提供与否

    func testBulkActionsAreOfferedOnlyWithMoreThanOneShare() {
        XCTAssertFalse(ScopeBulkSelection.isOffered(available: []),
                       "一个位置都没有时不该给全选")
        XCTAssertFalse(ScopeBulkSelection.isOffered(available: ["/A"]),
                       "只有一个位置时，全选和「勾上那一个」是同一件事")
        XCTAssertTrue(ScopeBulkSelection.isOffered(available: ["/A", "/B"]))
        // 重复项不能把「一个位置」凑成两个。
        XCTAssertFalse(ScopeBulkSelection.isOffered(available: ["/A", "/A"]),
                       "同一个位置写两遍还是一个位置")
    }

    // MARK: 全选

    func testAllSelectedRequiresEveryAvailableShare() {
        XCTAssertTrue(ScopeBulkSelection.isAllSelected(available: ["/A", "/B"], selected: ["/A", "/B"]))
        XCTAssertFalse(ScopeBulkSelection.isAllSelected(available: ["/A", "/B"], selected: ["/A"]),
                       "少一个就不是全选")
        // 已选里多出来的（界面看不见的旧位置）不影响「全选」这个判断。
        XCTAssertTrue(ScopeBulkSelection.isAllSelected(available: ["/A"], selected: ["/A", "/旧"]))
        // 空集不算全选：没有位置可勾时，界面不该显示成「全都勾上了」。
        XCTAssertFalse(ScopeBulkSelection.isAllSelected(available: [], selected: []))
    }

    func testSelectAllIsEnabledOnlyWhileSomethingIsMissing() {
        XCTAssertTrue(ScopeBulkSelection.canSelectAll(available: ["/A", "/B"], selected: []))
        XCTAssertTrue(ScopeBulkSelection.canSelectAll(available: ["/A", "/B"], selected: ["/A"]))
        XCTAssertFalse(ScopeBulkSelection.canSelectAll(available: ["/A", "/B"], selected: ["/A", "/B"]),
                       "已经全勾完了，「全选」该灰掉")
        XCTAssertFalse(ScopeBulkSelection.canSelectAll(available: [], selected: []))
    }

    func testSelectAllDropsSharesThatAreNoLongerAvailable() {
        // 共享被删之后，草稿里可能还留着它。全选交出去的必须只有「现在的可用位置」，
        // 否则一次全选反而把一个已经不存在的路径重新提交出去。
        XCTAssertEqual(ScopeBulkSelection.selectAll(available: ["/B", "/A"]), ["/A", "/B"])
    }

    // MARK: 取消全选

    func testClearAllIsEnabledOnlyWhenSomethingVisibleIsSelected() {
        XCTAssertTrue(ScopeBulkSelection.canClearAll(available: ["/A", "/B"], selected: ["/A"]))
        XCTAssertFalse(ScopeBulkSelection.canClearAll(available: ["/A", "/B"], selected: []))
        // ★ 只勾了界面看不见的旧位置时，按钮不该亮：按下去用户会发现「本来就没勾啊」。
        XCTAssertFalse(ScopeBulkSelection.canClearAll(available: ["/A", "/B"], selected: ["/旧"]),
                       "看不见的勾不该让「取消全选」亮起来")
        XCTAssertFalse(ScopeBulkSelection.canClearAll(available: [], selected: ["/旧"]))
    }

    func testClearAllReturnsEmptySelection() {
        XCTAssertEqual(ScopeBulkSelection.clearAll(), [],
                       "取消全选就是一个都不勾，包括界面看不见的旧位置")
    }
}
