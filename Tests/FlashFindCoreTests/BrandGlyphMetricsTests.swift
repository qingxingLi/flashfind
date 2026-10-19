import XCTest
import CoreGraphics
@testable import FlashFindCore

/// 品牌字形（圆环 + 闪电）的尺寸换算。
///
/// 为什么单独测：同一枚素材要用在两处高度不同的位置（状态栏 18pt、
/// 搜索框 22pt），而素材本身是 @2x 的 36px 画布。换算写死在 App 层里
/// 因为 executableTarget 测不了；抽成 Core 的纯函数就是为了能锁住。
///
/// 最要防的一条：把宽直接设成高度（拉成正方形）。方形素材看不出来，
/// 一旦换了非正方形素材就变形——而且这类缺陷只有肉眼在真机上能发现。
final class BrandGlyphMetricsTests: XCTestCase {

    /// ★ 等比缩放：高度定，**宽度由原始比例算出**。
    func testFittedSizePreservesAspectRatio() {
        let square = BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 36, height: 22)
        XCTAssertEqual(square.height, 22, accuracy: 0.001, "目标高度必须原样落到结果上")
        XCTAssertEqual(square.width, 22, accuracy: 0.001, "方形素材缩放后仍是方形")

        // 非正方形素材才是真正会把「直接拉方」的实现打出来的用例。
        let wide = BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 24, height: 18)
        XCTAssertEqual(wide.height, 18, accuracy: 0.001)
        XCTAssertEqual(wide.width, 27, accuracy: 0.001,
                       "36:24 的素材压到 18pt 高，宽必须是 27，不能是 18")

        let tall = BrandGlyphMetrics.fittedSize(naturalWidth: 24, naturalHeight: 36, height: 18)
        XCTAssertEqual(tall.height, 18, accuracy: 0.001)
        XCTAssertEqual(tall.width, 12, accuracy: 0.001,
                       "24:36 的素材压到 18pt 高，宽必须是 12，不能是 18")
    }

    /// 高度非法（≤ 0）返回 `.zero`：调用方不必各自再加一次判空。
    func testFittedSizeReturnsZeroForNonPositiveHeight() {
        XCTAssertEqual(BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 36, height: 0), .zero)
        XCTAssertEqual(BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 36, height: -4), .zero)
    }

    /// 非有限值（inf / nan）同样按非法处理——别让 NaN 宽度进 NSImage。
    func testFittedSizeReturnsZeroForNonFiniteHeight() {
        XCTAssertEqual(BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 36,
                                                    height: .infinity), .zero)
        XCTAssertEqual(BrandGlyphMetrics.fittedSize(naturalWidth: 36, naturalHeight: 36,
                                                    height: .nan), .zero)
    }

    /// 读不到素材尺寸时按正方形兜底：至少不会算出 NaN / 除零。
    func testFittedSizeFallsBackToSquareWhenArtworkSizeIsUnknown() {
        for (w, h) in [(CGFloat(0), CGFloat(36)), (CGFloat(36), CGFloat(0)),
                       (CGFloat(-1), CGFloat(36)), (CGFloat(36), CGFloat(-1))] {
            let size = BrandGlyphMetrics.fittedSize(naturalWidth: w, naturalHeight: h, height: 22)
            XCTAssertEqual(size.width, 22, accuracy: 0.001, "素材尺寸非法时应按正方形兜底")
            XCTAssertEqual(size.height, 22, accuracy: 0.001)
            XCTAssertTrue(size.width.isFinite && size.height.isFinite, "兜底也不能吐出非有限值")
        }
    }

    /// 两处高度是**界面约定**，写错不会报错、只会看着不对。
    func testDocumentedHeights() {
        XCTAssertEqual(BrandGlyphMetrics.menuBarHeight, 18, "状态栏图标高 18pt（macOS 惯例）")
        XCTAssertEqual(BrandGlyphMetrics.searchFieldHeight, 22,
                       "搜索框前导图标高 22pt：与输入文字同高")
    }
}
