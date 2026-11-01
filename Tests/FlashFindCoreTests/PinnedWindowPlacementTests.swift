import XCTest
@testable import FlashFindCore

/// 「钉住的那一批」摆在哪、开多高。
///
/// ★★ 这条用例守的是 2026-11-01 的报障（用户原话）：
///   「钉住的时候应该是搜索的数量变多了，导致钉住的内容钻到搜索框下方了」
///   （附截图：钉住窗只剩半截，题头与类型条整块不见）。
///
/// 旧行为不是「没算位置」，而是**只有三条路**：下方 / 上方 / 退回下方，
/// 一条都不是「把窗口开矮一点」。退回下方之后 App 又把窗口夹回屏幕内，
/// 上沿正好压在搜索框上 —— 于是「条数越多越容易钻到搜索框底下」，条数一多必现。
///
/// 这里钉死的是：**窗口永远不与锚点搜索框重叠**，放不下就按整行收高度。
final class PinnedWindowPlacementTests: XCTestCase {
    /// 真机实测的那块屏幕（1.1.59 复现用，已扣掉菜单栏与程序坞）。
    private let screen = CGRect(x: 0, y: 87, width: 1470, height: 836)
    private let rowHeight: CGFloat = 56
    private let gap: CGFloat = 10
    /// 搜索框实测高 64。
    private let fieldHeight: CGFloat = 64

    private func field(x: CGFloat = 395, y: CGFloat) -> CGRect {
        CGRect(x: x, y: y, width: 680, height: fieldHeight)
    }

    private func intrinsic(rows: Int) -> CGFloat {
        PinnedWindowPlacement.height(rows: rows, rowHeight: rowHeight)
    }

    /// 与锚点搜索框是否有重叠（竖向 + 横向都算）。
    private func overlaps(_ plan: PinnedWindowPlacement.Plan, field: CGRect) -> Bool {
        let window = CGRect(x: field.minX, y: plan.originY, width: SearchModuleLayout.pinnedWidth, height: plan.height)
        return window.intersects(field)
    }

    // MARK: - 报障本身

    /// ★★ 200 条结果、搜索框在默认位置：钉住窗必须**整个**落在搜索框下面。
    ///
    /// 真机读数：搜索框 `y 625..689`、理想高度 588、下方只剩 516。
    /// 旧行为把窗口顶到 `y 99..687` —— 上沿 687 越过搜索框下沿 625，盖掉 62pt。
    func testTallPinnedWindowShrinksInsteadOfSlidingUnderTheField() {
        let field = field(y: 625)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertFalse(plan.above, "下方收几行就放得下，不该翻到上方去")
        XCTAssertFalse(overlaps(plan, field: field),
                       "★ 钉住窗不许与搜索框重叠：重叠就是用户看到的「内容钻到搜索框下面」")
        XCTAssertLessThanOrEqual(plan.originY + plan.height, field.minY - gap,
                                 "窗口上沿要留在搜索框下沿之上（中间那 10pt 空隙不能吃掉）")
        XCTAssertGreaterThanOrEqual(plan.originY, screen.minY + PinnedWindowPlacement.margin,
                                    "下沿要留在屏幕可见区内")
        // 516 的净空间：(516-84)/56 = 7.71 ⇒ 整行收 7 行，高度 84+392=476。
        XCTAssertEqual(plan.visibleRows, 7, "按整行收，不能留半行")
        XCTAssertEqual(plan.height, intrinsic(rows: 7), accuracy: 0.5,
                       "高度必须正好是整数行算出来的值")
        XCTAssertLessThan(plan.height, intrinsic(rows: 200), "确实比理想高度矮")
    }

    /// 条数少的时候一步都不动：高度按快照行数，位置贴搜索框下沿。
    func testSmallPinnedWindowKeepsItsIntrinsicHeight() {
        let field = field(y: 625)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 3),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertFalse(plan.above)
        XCTAssertEqual(plan.height, intrinsic(rows: 3), accuracy: 0.5,
                       "放得下就不许收行——收行会让「钉住」看起来像掉了内容")
        XCTAssertEqual(plan.originY, field.minY - gap - plan.height, accuracy: 0.5,
                       "贴着搜索框下沿 10pt")
        XCTAssertEqual(plan.visibleRows, 3)
    }

    // MARK: - 三条退路

    /// 搜索框被拖到屏幕下方：下方连一行都放不下 ⇒ 摆在**上方**，而且整批都放得下。
    func testPinnedWindowGoesAboveWhenNothingFitsBelow() {
        let field = field(y: 224)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertTrue(plan.above, "下方放不下一行时必须换到上方（用户 2026-10-28 定的第二条规矩）")
        XCTAssertEqual(plan.originY, field.maxY + gap, accuracy: 0.5)
        XCTAssertGreaterThanOrEqual(plan.originY, field.maxY + gap, "上方同样不许压住搜索框")
        XCTAssertEqual(plan.height, intrinsic(rows: 200), accuracy: 0.5,
                       "上方空间够，就别收行")
        XCTAssertLessThanOrEqual(plan.originY + plan.height,
                                 screen.maxY - PinnedWindowPlacement.margin + 0.5,
                                 "整块要留在可见区内")
    }

    /// 搜索框贴着屏幕顶部：下方空间充足 ⇒ 照常贴在下沿，整批放得下。
    func testPinnedWindowSitsBelowAFieldNearTheTop() {
        let field = field(y: 830)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertFalse(plan.above)
        XCTAssertEqual(plan.height, intrinsic(rows: 200), accuracy: 0.5)
        XCTAssertEqual(plan.originY, field.minY - gap - plan.height, accuracy: 0.5)
    }

    /// 搜索框在屏幕中段：下方只够 1 行、上方能放 8 行 ⇒ 换到上方，别把 200 条塞进一条缝。
    ///
    /// ★ 这是「下方优先」唯一的例外，门槛是 `comfortableRows`。
    func testPinnedWindowMovesUpWhenBelowOnlyFitsASliver() {
        let field = field(y: 300)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertTrue(plan.above, "下方只够一行、上方空着一大片，这时该换到上方")
        XCTAssertEqual(plan.visibleRows, 8, "上方能放几行就放几行")
        XCTAssertGreaterThanOrEqual(plan.originY, field.maxY + gap)
        XCTAssertLessThanOrEqual(plan.originY + plan.height,
                                 screen.maxY - PinnedWindowPlacement.margin + 0.5)
    }

    // MARK: - 错开量

    /// ★ 钉第二、三块时的错开量要**算进空间里**。
    ///
    /// 错开量把窗口往下推，若不计入可用空间，窗口会被推出屏幕、再被夹回原位 ——
    /// 夹回来就又一次压住搜索框（旧代码的第二层成因）。
    func testStaggerOffsetIsCountedAsSpace() {
        let field = field(y: 625)
        let far = PinnedWindowPlacement.plan(field: field,
                                             intrinsicHeight: intrinsic(rows: 200),
                                             rowHeight: rowHeight,
                                             offset: 130,
                                             screen: screen)
        XCTAssertFalse(overlaps(far, field: field))
        XCTAssertGreaterThanOrEqual(far.originY, screen.minY + PinnedWindowPlacement.margin,
                                    "错开之后仍然整块在屏幕里")
        let near = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: screen)
        XCTAssertLessThan(far.originY, near.originY, "错开量确实把窗口挪下去了")
    }

    // MARK: - 极小屏兜底

    /// 两侧都放不下一行（屏幕极小）：只留一行，仍然**不重叠**。
    ///
    /// 这一步会贴着搜索框，但绝不会把题头藏到它后面 —— 宁可矮，不能藏。
    func testDegenerateScreenKeepsOneRowAndNeverOverlaps() {
        let tiny = CGRect(x: 0, y: 0, width: 800, height: 200)
        let field = CGRect(x: 60, y: 68, width: 680, height: 64)
        let plan = PinnedWindowPlacement.plan(field: field,
                                              intrinsicHeight: intrinsic(rows: 200),
                                              rowHeight: rowHeight,
                                              offset: 0,
                                              screen: tiny)
        XCTAssertEqual(plan.visibleRows, 1, "退到只剩一行")
        XCTAssertEqual(plan.height, intrinsic(rows: 1), accuracy: 0.5)
        XCTAssertFalse(overlaps(plan, field: field), "退到只剩一行也不许压住搜索框")
    }

    // MARK: - 公式只有一个出处

    /// `PinnedResults.windowHeight` 与摆位用**同一个**高度式子，否则「算 7 行、画 6 行半」。
    func testHeightFormulaHasASingleSource() {
        let rows = (0..<40).map {
            SearchResult(id: "f\($0)", name: "f\($0).pdf", relativePath: "/Book/f\($0).pdf",
                         sourceID: "src1", sourceName: "来源", kind: "file", size: 1, localURL: nil)
        }
        let snapshot = PinnedResults(query: "x", rows: rows, totalMatched: 40, locationTitle: nil)
        for rows in [0, 1, 5, 9, 40] {
            XCTAssertEqual(snapshot.windowHeight(rowCount: rows, rowHeight: rowHeight),
                           PinnedWindowPlacement.height(rows: rows, rowHeight: rowHeight),
                           "行数 \(rows) 的窗口高度必须与摆位那边一致")
        }
        XCTAssertEqual(PinnedWindowPlacement.height(rows: 40, rowHeight: rowHeight),
                       PinnedWindowPlacement.height(rows: SearchModuleLayout.pinnedMaximumRows, rowHeight: rowHeight),
                       "超过上限就按上限算，别再长高")
    }
}
