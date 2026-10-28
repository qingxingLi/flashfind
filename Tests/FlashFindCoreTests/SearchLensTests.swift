import XCTest
@testable import FlashFindCore

/// 搜索区的玻璃表面与「跟随遮罩」的放大曲线（2026-10-27 用户要求）。
///
/// 要求原文：「搜索结果和搜索框保持一致，均为动态玻璃效果；可以跟随鼠标和移动选择
/// 当前的目标，设置一个更加透明的玻璃遮罩替换当前的灰色背景和蓝色背景；遮罩移动时
/// 能够在边缘位置明显看到字体逐渐放大和缩小的效果；根据 mac 15 以下系统保持原方案不变。」
final class SearchGlassStyleTests: XCTestCase {

    func testGlassWhenAvailableAndTransparencyAllowed() {
        XCTAssertEqual(SearchGlassStyle.resolve(liquidGlassAvailable: true, reduceTransparency: false),
                       .glass)
    }

    /// ★ 不支持 Liquid Glass 的系统（macOS 15 及以下）**必须**回到老方案。
    /// 这条是用户明确要求的「向下兼容不变」，不是可选优化。
    func testLegacyWhenGlassUnavailable() {
        XCTAssertEqual(SearchGlassStyle.resolve(liquidGlassAvailable: false, reduceTransparency: false),
                       .legacy)
    }

    /// ★ 辅助功能「降低透明度」开着时必须退回实心：
    /// 用户开这个开关就是为了不要半透明，这时还画玻璃等于把设置当摆设。
    func testReduceTransparencyFallsBackToLegacy() {
        XCTAssertEqual(SearchGlassStyle.resolve(liquidGlassAvailable: true, reduceTransparency: true),
                       .legacy)
    }

    /// 两个条件都不满足时也只能是老方案——写这份断言是为了防止有人把
    /// `&&` 写成 `||`（那样「降低透明度」在旧系统上会反转成玻璃）。
    func testBothConditionsRequired() {
        XCTAssertEqual(SearchGlassStyle.resolve(liquidGlassAvailable: false, reduceTransparency: true),
                       .legacy)
    }
}

final class SearchLensTests: XCTestCase {

    func testPeakIsAtTheLensCentre() {
        XCTAssertEqual(SearchLens.scale(rowDistance: 0), SearchLens.peakScale, accuracy: 1e-9)
        XCTAssertGreaterThan(SearchLens.scale(rowDistance: 0), 1,
                             "遮罩正中的字要变大——这是用户要的效果本体")
    }

    /// 「边缘能看到字变小」：紧邻遮罩的那一行被压小。
    func testNeighbourRowIsSlightlyCompressed() {
        XCTAssertEqual(SearchLens.scale(rowDistance: 1), SearchLens.neighborScale, accuracy: 1e-9)
        XCTAssertLessThan(SearchLens.scale(rowDistance: 1), 1,
                          "★ 只看放大是不够的：没有这一档的「挤小」，遮罩滑过时看不到一涨一落")
    }

    func testFarRowsAreUntouched() {
        XCTAssertEqual(SearchLens.scale(rowDistance: SearchLens.falloff), 1, accuracy: 1e-9)
        XCTAssertEqual(SearchLens.scale(rowDistance: 4), 1, accuracy: 1e-9)
        XCTAssertEqual(SearchLens.scale(rowDistance: 99), 1, accuracy: 1e-9)
    }

    /// 曲线必须对称：遮罩从上面滑下来和从下面滑上去，同一个字看到的形变要一样。
    func testCurveIsSymmetric() {
        for distance in stride(from: CGFloat(0), through: 3, by: 0.1) {
            XCTAssertEqual(SearchLens.scale(rowDistance: distance),
                           SearchLens.scale(rowDistance: -distance),
                           accuracy: 1e-9, "距离 \(distance) 两侧不对称")
        }
    }

    /// 分段处不许跳变：跳变会让滑过去的字「啪」一下，而不是逐渐变化。
    func testCurveIsContinuousAtSegmentJoints() {
        let joints: [CGFloat] = [0.5, 1, SearchLens.falloff]
        for joint in joints {
            let before = SearchLens.scale(rowDistance: joint - 1e-4)
            let after = SearchLens.scale(rowDistance: joint + 1e-4)
            XCTAssertEqual(before, after, accuracy: 1e-3, "距离 \(joint) 处有跳变")
        }
    }

    /// 整段单调性：从中心往外，倍率先降后升，不许出现第二个峰。
    func testCurveDecreasesThenReturnsToIdentity() {
        var previous = SearchLens.scale(rowDistance: 0)
        for distance in stride(from: CGFloat(0.05), through: 1, by: 0.05) {
            let current = SearchLens.scale(rowDistance: distance)
            XCTAssertLessThanOrEqual(current, previous + 1e-9, "距离 \(distance) 处不该回升")
            previous = current
        }
        previous = SearchLens.scale(rowDistance: 1)
        for distance in stride(from: CGFloat(1.05), to: SearchLens.falloff, by: 0.05) {
            let current = SearchLens.scale(rowDistance: distance)
            XCTAssertGreaterThanOrEqual(current, previous - 1e-9, "距离 \(distance) 处该往 1 收")
            previous = current
        }
    }

    /// 倍率有上下界：超过 1.08 会把标题顶出行高，低于 0.95 会看成「字变小了」的故障。
    func testScaleStaysWithinReadableRange() {
        for distance in stride(from: CGFloat(0), through: 3, by: 0.02) {
            let scale = SearchLens.scale(rowDistance: distance)
            XCTAssertLessThanOrEqual(scale, 1.08)
            XCTAssertGreaterThanOrEqual(scale, 0.95)
        }
    }

    /// 非有限值不参与运算：`abs(nan)` 之后的比较全为假，会静默给出 1.0，
    /// 但这不该由调用方去猜——显式钉一条。
    func testNonFiniteDistanceIsIdentity() {
        XCTAssertEqual(SearchLens.scale(rowDistance: .nan), 1)
        XCTAssertEqual(SearchLens.scale(rowDistance: .infinity), 1)
    }
}
