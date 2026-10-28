import XCTest
@testable import FlashFindCore

/// 搜索窗的模块化布局（用户 2026-10-27 定稿）。
///
/// 要求原文：「搜索框是一个模块，搜索结果是一个模块……搜索框和搜索结果中间有一段空白，
/// 详见参考图……这样搜索框可以恢复之前的透明玻璃效果，搜索结果保持现在的这样的形式，
/// 注意圆角大小要统一，否则很难看。」
///
/// 三件事都能用断言钉住：两块模块什么时候同时存在、中间那道空白有多宽、圆角是不是同一套。
final class SearchModuleLayoutTests: XCTestCase {

    /// 只有搜索框（没关键词、没打开失败）时**只该有一块**。
    ///
    /// 这正是用户报的那个丑：原来搜索框外面还裹着一整块面板，胶囊四周多出一圈遮罩。
    func testOnlyTheFieldModuleWhenThereIsNothingToShow() {
        XCTAssertFalse(SearchModuleLayout.showsContentModule(hasQuery: false,
                                                             hasOpenFailure: false),
                       "★ 没搜索、也没出错时不该出现第二块——那正是「胶囊四周还有遮罩」的来源")
    }

    func testContentModuleAppearsForEveryKindOfContent() {
        XCTAssertTrue(SearchModuleLayout.showsContentModule(hasQuery: true,
                                                            hasOpenFailure: false),
                      "有结果就要有结果模块")
        // 打开失败时即使关键词被清空，提示条也得有地方待着。
        XCTAssertTrue(SearchModuleLayout.showsContentModule(hasQuery: false,
                                                            hasOpenFailure: true),
                      "打开失败的提示条不许被裁掉")
    }

    func testGapIsWideEnoughToReadAsTwoModules() {
        XCTAssertGreaterThan(SearchModuleLayout.moduleGap, 0,
                             "没有缝隙就还是一块玻璃，只是中间多了条线")
        XCTAssertLessThan(SearchModuleLayout.moduleGap, SearchModuleLayout.moduleRadius,
                          "缝隙比圆角还宽就不像一个窗口里的两块了")
    }

    /// ★ 两个模块的圆角必须同值——用户原话「圆角大小要统一，否则很难看」。
    ///
    /// 视图里不许自己写数字：`SearchModuleSurface` 的默认值就是这一个，
    /// `SearchFieldModule` / `SearchResultsModule` 都不传 radius。
    func testModulesShareOneRadius() {
        XCTAssertEqual(SearchModuleLayout.moduleRadius, 20,
                       "改圆角要连着改行内遮罩与参考图观感，别顺手调")
    }

    /// 行内遮罩的圆角必须**小于**模块圆角：它离模块边缘只有 8pt，
    /// 用同值会贴着模块的圆角露出尖角。
    func testRowLensRadiusIsSmallerThanModuleRadius() {
        XCTAssertLessThan(SearchModuleLayout.rowLensRadius, SearchModuleLayout.moduleRadius)
        XCTAssertLessThan(SearchModuleLayout.rowLensInset, SearchModuleLayout.rowLensRadius,
                          "内缩大于圆角时，遮罩会离开行边缘太远，看着像浮在中间")
    }
}
