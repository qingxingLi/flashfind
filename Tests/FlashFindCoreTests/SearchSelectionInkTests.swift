import XCTest
@testable import FlashFindCore

/// 选中行的文字染色（2026-10-30 用户：「选中不动时字体变成天蓝色，移动时字体慢慢变蓝色」）。
///
/// 这一组盯的是**曲线**，不是「有没有蓝」：
/// 一个恒返回蓝色的实现也能让「选中变蓝」通过，但会让「慢慢变」这条全废。
final class SearchSelectionInkTests: XCTestCase {

    /// 深色：遮罩正中的那一行，字要**完全**变成天蓝（#64D2FF）、不透明的实色。
    ///
    /// 期望值直接写死十六进制：拿 `SearchSelectionInk.settled` 跟自己比是同义反复，
    /// 常量被改成别的蓝也照样绿。
    func testLensCentreIsTheSettledSkyBlue() {
        let ink = SearchSelectionInk.ink(rowDistance: 0, dark: true)
        XCTAssertEqual(ink.red, 0x64 / 255 as Double, accuracy: 1e-9, "R = 0x64")
        XCTAssertEqual(ink.green, 0xD2 / 255 as Double, accuracy: 1e-9, "G = 0xD2")
        XCTAssertEqual(ink.blue, 1.0, accuracy: 1e-9, "B = 0xFF")
        XCTAssertEqual(ink.alpha, 1, accuracy: 1e-9,
                       "停稳后的蓝要实：压在玻璃上还要发灰就等于没染")
    }

    /// 浅色：停稳的那一档**不是**天蓝，要压到系统蓝——否则浅玻璃上读不出来。
    func testLightAppearanceSettlesOnTheSystemBlue() {
        let ink = SearchSelectionInk.ink(rowDistance: 0, dark: false)
        XCTAssertEqual(ink.red, 0x0A / 255 as Double, accuracy: 1e-3)
        XCTAssertEqual(ink.green, 0x84 / 255 as Double, accuracy: 1e-3)
        XCTAssertEqual(ink.blue, 1.0, accuracy: 1e-3)
    }

    /// ★ 浅色下必须**读得出来**：这是 2026-10-30 第一版实拍暴露的问题——
    /// 浅色照抄深色的天蓝，字被浅玻璃冲成一层淡影（对比度约 1.7:1）。
    /// 这条把「能读」变成数字，免得下次又靠眼睛。
    func testLightInkIsReadableOnLightGlass() {
        let ink = SearchSelectionInk.ink(rowDistance: 0, dark: false)
        let contrast = (1.0 + 0.05) / (relativeLuminance(ink) + 0.05)
        XCTAssertGreaterThan(contrast, 3.0,
                             "浅色选中字的对比度只有 \(contrast):1，压在浅玻璃上会读不出来")
    }

    /// 「天蓝」必须真的比「移动蓝」亮——两个值写反了，用户看到的就是
    /// 「静止时发暗、移动时发亮」，跟他要的正好相反。深浅两套都要成立。
    func testSettledBlueIsLighterThanTheMovingBlue() {
        for dark in [true, false] {
            let settled = relativeLuminance(SearchSelectionInk.ink(rowDistance: 0, dark: dark))
            let moving = relativeLuminance(SearchSelectionInk.ink(rowDistance: 0.5, dark: dark))
            XCTAssertGreaterThan(settled, moving,
                                 "\(dark ? "深色" : "浅色")：停稳那一档必须比移动中更亮")
        }
        // 深色下两者要差得开一点，否则「停下变天蓝」看不出来。
        let darkSettled = relativeLuminance(SearchSelectionInk.ink(rowDistance: 0, dark: true))
        let darkMoving = relativeLuminance(SearchSelectionInk.ink(rowDistance: 0.5, dark: true))
        XCTAssertGreaterThan(darkSettled, darkMoving + 0.15)
    }

    private func relativeLuminance(_ ink: SearchSelectionInk.Ink) -> Double {
        func linear(_ channel: Double) -> Double {
            channel <= 0.03928 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
        }
        return 0.2126 * linear(ink.red) + 0.7152 * linear(ink.green) + 0.0722 * linear(ink.blue)
    }

    /// 两行之间是交叉染色：正中间（0.5 行）两行都满色且各带一半天蓝，
    /// 到一整行之外完全退掉。
    func testRowsBetweenTwoPositionsCrossFade() {
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: 0), 1, accuracy: 1e-9)
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: 0.5), 1, accuracy: 1e-9)
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: 0.75), 0.5, accuracy: 1e-9)
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: 1), 0, accuracy: 1e-9)
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: 4), 0, accuracy: 1e-9)

        // 0.5 行处两行都在过渡中段，谁也没被完全丢掉（否则遮罩滑过时中间会空一拍）。
        let upper = SearchSelectionInk.ink(rowDistance: 0.5, dark: true)
        let lower = SearchSelectionInk.ink(rowDistance: -0.5, dark: true)
        XCTAssertEqual(upper, lower, "上下两行的曲线必须对称，否则遮罩上滑下滑观感不一样")
    }

    /// 颜色是**连续**的：从一行扫到另一行，相邻 0.01 行的颜色差不能有台阶。
    ///
    /// 这条防的正是「阈值写法」——`distance < 0.06 ? 天蓝 : 深蓝` 在落位那一帧
    /// 会从 #0A84FF 直接跳到 #64D2FF，肉眼能看见闪一下。
    func testColourHasNoStepAlongTheWholeRamp() {
        var previous = SearchSelectionInk.ink(rowDistance: 1.2, dark: true)
        var largestStep = 0.0
        for step in stride(from: 1.19, through: 0.0, by: -0.01) {
            let ink = SearchSelectionInk.ink(rowDistance: CGFloat(step), dark: true)
            let delta = abs(ink.red - previous.red)
                + abs(ink.green - previous.green)
                + abs(ink.blue - previous.blue)
                + abs(ink.alpha - previous.alpha)
            largestStep = max(largestStep, delta)
            previous = ink
        }
        XCTAssertLessThan(largestStep, 0.06,
                          "0.01 行内颜色跳了 \(largestStep)：曲线上有台阶，遮罩落位时会闪")
    }

    /// 没被遮罩盖住的行：还是系统字色（浅色纯黑 / 深色纯白，alpha 0.847 实测值）。
    ///
    /// ★ 0.847 是**实测**的 `labelColor` alpha，不是 1。照着 1 写，
    ///   未选中的字会突然变实——一屏文字整体变重，比染色没生效更难解释。
    func testRowOutsideTheLensKeepsTheSystemLabelColour() {
        let light = SearchSelectionInk.ink(rowDistance: 3, dark: false)
        XCTAssertEqual(light.red, 0, accuracy: 1e-9)
        XCTAssertEqual(light.green, 0, accuracy: 1e-9)
        XCTAssertEqual(light.blue, 0, accuracy: 1e-9)
        XCTAssertEqual(light.alpha, SearchSelectionInk.baseAlpha, accuracy: 1e-9)

        let dark = SearchSelectionInk.ink(rowDistance: 3, dark: true)
        XCTAssertEqual(dark.red, 1, accuracy: 1e-9)
        XCTAssertEqual(dark.alpha, SearchSelectionInk.baseAlpha, accuracy: 1e-9)
    }

    /// 遮罩淡出时整行一起退色，而不是「先变灰再消失」。
    func testFadingLensFadesTheInk() {
        let full = SearchSelectionInk.ink(rowDistance: 0, presence: 1, dark: true)
        let half = SearchSelectionInk.ink(rowDistance: 0, presence: 0.5, dark: true)
        XCTAssertLessThan(half.alpha, full.alpha)
        XCTAssertGreaterThan(half.alpha, SearchSelectionInk.baseAlpha)
        XCTAssertGreaterThan(half.red, 0.5, "退到一半时仍偏蓝，不能先掉回白")

        let gone = SearchSelectionInk.ink(rowDistance: 0, presence: 0, dark: true)
        XCTAssertEqual(gone.alpha, SearchSelectionInk.baseAlpha, accuracy: 1e-9)
        XCTAssertEqual(gone.red, 1, accuracy: 1e-9, "遮罩不在了就是普通字色")
    }

    /// 坏值不许把字变成「透明」或「全蓝」：行距算出 NaN 时退回系统字色。
    func testNonFiniteDistanceFallsBackToTheLabelColour() {
        let ink = SearchSelectionInk.ink(rowDistance: .nan, dark: true)
        XCTAssertEqual(ink.alpha, SearchSelectionInk.baseAlpha, accuracy: 1e-9)
        XCTAssertEqual(ink.red, 1, accuracy: 1e-9)
        XCTAssertEqual(SearchSelectionInk.weight(rowDistance: .infinity), 0)
    }
}
