import XCTest
@testable import FlashFindCore

/// 两块**固定尺寸**与**玻璃描边**的取值。
///
/// 这两组数看着只是几个常量，但它们各自钉着一件真机报障（2026-10-28，1.1.23 试用件）：
///
/// * 「搜索结果的区域大小固定，否则切换的时候侧边栏大小频繁跳动，影响筛选」
///   → 结果区高度不许再随结果条数变化；
/// * 「动态玻璃效果如果屏幕是纯白背景时显示效果不好……建议增强一下边框」
///   → 玻璃在白底上必须有一条**深色**的外描边，否则整块消失。
///
/// 写成断言的理由：这两件事都没有「编译不过」或「崩」的形态，改错了只会
/// 在某台机器、某个壁纸上悄悄变丑 —— 那正是最难被发现的那类回归。
final class SearchPanelFixedSizeTests: XCTestCase {

    // MARK: - 结果区固定高度

    /// 一屏固定 7 行：行数变了，高度不许变。
    ///
    /// 这个函数**根本没有「结果条数」这个参数**——这就是「固定」最硬的写法：
    /// 想让它随条数变，得先改签名，改签名就会撞上这条断言。
    func testResultsListHeightIsFixedRegardlessOfRowCount() {
        let height = SearchModuleLayout.resultsListHeight(rowHeight: 56)
        let expected = CGFloat(SearchModuleLayout.resultsVisibleRows) * 56
            + SearchModuleLayout.resultsListPadding
            + SearchModuleLayout.resultsStatusBarHeight
        XCTAssertEqual(height, expected)
        XCTAssertEqual(height, 436, "7 行 × 56 + 留白 12 + 状态栏 32 = 436")
        // 同一个入参永远同一个结果（不是算出来的，是常量）。
        XCTAssertEqual(SearchModuleLayout.resultsListHeight(rowHeight: 56), height)
    }

    /// 结果模块 = 类型条 + 结果区。
    func testResultsModuleHeightIncludesTypeBar() {
        XCTAssertEqual(SearchModuleLayout.resultsModuleHeight(rowHeight: 56),
                       SearchModuleLayout.typeBarHeight + SearchModuleLayout.resultsListHeight(rowHeight: 56))
        XCTAssertEqual(SearchModuleLayout.resultsModuleHeight(rowHeight: 56), 470)
    }

    /// 状态栏那一截必须算进去。
    ///
    /// 空状态时状态栏不画，但高度要留着——否则「有结果 / 没结果」两种状态差 32pt，
    /// 切换时侧边栏仍会抖一下，等于这次改动白做。
    func testStatusBarHeightIsReservedEvenWhenNotDrawn() {
        XCTAssertGreaterThan(SearchModuleLayout.resultsStatusBarHeight, 0,
                             "状态栏预留高度为 0 就等于没固定：有无状态栏会差出一条")
    }

    // MARK: - 玻璃描边

    /// 浅色外观下外描边必须是**深色**。
    ///
    /// 这条是「白底上看不见玻璃」的直接解法：白描边压在白桌面上等于没画。
    func testOuterStrokeIsDarkInLightAppearance() {
        let light = SearchGlassEdge.outer(dark: false)
        XCTAssertEqual(light.red, 0)
        XCTAssertEqual(light.green, 0)
        XCTAssertEqual(light.blue, 0)
        XCTAssertGreaterThanOrEqual(light.alpha, 0.10,
                                    "低于 10% 在纯白背景上几乎看不出边界（用户报的就是这个）")
    }

    /// 深色外观下反过来：黑边在深玻璃上等于没有。
    func testOuterStrokeIsLightInDarkAppearance() {
        let dark = SearchGlassEdge.outer(dark: true)
        XCTAssertEqual(dark.red, 1)
        XCTAssertEqual(dark.green, 1)
        XCTAssertEqual(dark.blue, 1)
        XCTAssertGreaterThanOrEqual(dark.alpha, 0.12)
        XCTAssertNotEqual(dark, SearchGlassEdge.outer(dark: false))
    }

    /// 内高光要比外描边更亮/更不透：它是「厚边」，压不过分界线就不成层次。
    func testInnerHighlightIsStrongerThanOuterStroke() {
        XCTAssertGreaterThan(SearchGlassEdge.innerHighlight(dark: false).alpha,
                             SearchGlassEdge.outer(dark: false).alpha)
        XCTAssertGreaterThan(SearchGlassEdge.innerHighlight(dark: true).alpha,
                             SearchGlassEdge.outer(dark: true).alpha)
        XCTAssertEqual(SearchGlassEdge.innerHighlightBottomAlpha, 0,
                       "高光收到 0：留一点会在下半圈描一圈白，深色上像个亮框")
    }

    /// 描边线宽不能小到看不见。
    ///
    /// 0.5pt 在非 Retina 与「降低透明度」下会被画成一排半透明点，
    /// 白底上看起来仍然像没画——这次特意定成 1pt。
    func testStrokeWidthIsAtLeastOnePoint() {
        XCTAssertGreaterThanOrEqual(SearchGlassEdge.strokeWidth, 1)
        XCTAssertGreaterThan(SearchGlassEdge.highlightWidth, 0)
        XCTAssertLessThan(SearchGlassEdge.lensStrokeWidth, SearchGlassEdge.strokeWidth,
                          "跟随鼠标的遮罩比模块细：它一直在动，粗了会晃眼")
    }

    /// 结果行遮罩同样两边都要有：只描白的话，白底上悬停完全看不出来。
    func testLensStrokeAlsoAdaptsToAppearance() {
        XCTAssertEqual(SearchGlassEdge.lens(dark: false).red, 0, "浅色下遮罩描边是深色")
        XCTAssertEqual(SearchGlassEdge.lens(dark: true).red, 1, "深色下是白色")
        XCTAssertNotEqual(SearchGlassEdge.lens(dark: true), SearchGlassEdge.lens(dark: false))
    }
}
