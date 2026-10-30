import XCTest
@testable import FlashFindCore

/// 「结果展开时把搜索框抬上去」的几何。
///
/// ★ 这条用例守的是 2026-10-30 的报障（原话）：
///   「把搜索框拉到屏幕下方，输入文字闪寻的搜索框会直接被搜索结果盖住；聚焦搜索的
///     做法是随着搜索框的变大而逐渐往上走，最后关闭的时候会跳到设定好的位置」。
///
/// 旧行为不是「没算位置」，而是**算反了**：只把结果窗往里顶到屏幕底边，
/// 于是结果压住搜索框。这里把三种处境钉死：放得下 / 抬得动 / 抬不动。
final class SearchWindowLiftTests: XCTestCase {
    /// 屏幕可见区（已扣掉菜单栏与程序坞）。
    private let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let fieldHeight: CGFloat = 52
    private let gap: CGFloat = 10
    private let resultsHeight: CGFloat = 470

    private func field(y: CGFloat) -> CGRect {
        CGRect(x: 380, y: y, width: 680, height: fieldHeight)
    }

    /// ★★ 放得下的时候**搜索框不动，但结果必须贴到它下面**。
    ///
    /// 2026-10-30 装上 1.1.56 的报障（用户原话）：「第一次打开的搜索结果不在搜索框
    /// 下方了」。当时的 `plan` 用 `nil` 表示「放得下」，协调者拿到 `nil` 只把搜索框
    /// 放回原位就 return 了 —— 结果窗压根没人摆，停在原点。
    /// 所以这条用例守的不是「lifted == 0」，而是「lifted == 0 时 resultsY 仍然对」。
    func testResultsSitRightUnderTheFieldWhenTheyFit() {
        let plan = SearchWindowLift.plan(field: field(y: 600),
                                         resultsHeight: resultsHeight,
                                         gap: gap,
                                         screen: screen)
        XCTAssertEqual(plan.lifted, 0, "屏幕中上部放得下就一步都不动——动一下都是多余的抖动")
        XCTAssertEqual(plan.fieldY, 600, "搜索框留在用户设定的位置")
        XCTAssertEqual(plan.resultsY, 600 - gap - resultsHeight, accuracy: 0.5,
                       "★ 放得下也要给出结果的位置：结果上沿 = 搜索框下沿 + 空隙")
    }

    /// ★ 就是这次报障本身：搜索框在屏幕下方。
    func testFieldNearTheBottomIsLiftedSoTheResultsFitUnderIt() {
        let plan = SearchWindowLift.plan(field: field(y: 60),
                                         resultsHeight: resultsHeight,
                                         gap: gap,
                                         screen: screen)
        XCTAssertGreaterThan(plan.lifted, 0, "下方放不下，搜索框必须往上让")
        XCTAssertEqual(plan.resultsY, screen.minY + SearchWindowLift.margin, accuracy: 0.5,
                       "抬到位之后结果正好压在可见区下沿留 12pt")
        XCTAssertEqual(plan.fieldY, plan.resultsY + gap + resultsHeight, accuracy: 0.5,
                       "结果上沿 = 搜索框下沿 + 空隙，两块不许重叠")
        // 反过来说：抬完之后结果窗**整块**在搜索框下面，而不是压着它。
        XCTAssertLessThanOrEqual(plan.resultsY + resultsHeight, plan.fieldY + 0.5,
                                 "结果窗的上沿不许高过搜索框的下沿")
    }

    /// 抬不动的时候不许把搜索框推出屏幕 —— 宁可裁结果，也不能连输入框都看不见。
    ///
    /// 这个上限只在「结果块比屏幕还高」这种退化情形下会咬住（正常 470 高的结果块
    /// 永远不会撞上它），但它是一条**安全阀**：没有它，搜索框会被顶到屏幕外面去。
    func testLiftNeverPushesTheFieldOffScreen() {
        let tall: CGFloat = 880   // 比可见区还高的结果块
        let plan = SearchWindowLift.plan(field: field(y: 100),
                                         resultsHeight: tall,
                                         gap: gap,
                                         screen: screen)
        XCTAssertGreaterThan(plan.lifted, 0)
        XCTAssertEqual(plan.fieldY + fieldHeight,
                       screen.maxY - SearchWindowLift.margin, accuracy: 0.5,
                       "★ 顶到「距屏幕上沿留 12pt」为止：再抬就把输入框推出屏幕了")
        XCTAssertGreaterThanOrEqual(plan.resultsY, screen.minY + SearchWindowLift.margin - 0.5,
                                    "抬不动时兜底：结果留在可见区内，只允许它被裁")
    }
}
