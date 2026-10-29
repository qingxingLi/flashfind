import XCTest
@testable import FlashFindCore

/// 字体阶梯的守卫。
///
/// 用户 2026-10-28 的原话是「我想要聚焦搜索的加粗字体效果」——
/// 这类诉求最容易在后续改动里被慢慢稀释：某天有人把结果行改回 14 regular，
/// 界面「看起来还行」，但当初那口气就没了，而且没有任何东西会提醒。
/// 所以把阶梯的形状锁成断言。
final class FlashFindTypographyTests: XCTestCase {

    private var allStyles: [(String, FlashFindTextStyle)] {
        [
            ("searchField", FlashFindTypography.searchField),
            ("fieldHint", FlashFindTypography.fieldHint),
            ("resultName", FlashFindTypography.resultName),
            ("resultPath", FlashFindTypography.resultPath),
            ("sourceBadge", FlashFindTypography.sourceBadge),
            ("segmentLabel", FlashFindTypography.segmentLabel),
            ("segmentLabelSelected", FlashFindTypography.segmentLabelSelected),
            ("sidebarTitle", FlashFindTypography.sidebarTitle),
            ("sidebarTitleSelected", FlashFindTypography.sidebarTitleSelected),
            ("sidebarSubtitle", FlashFindTypography.sidebarSubtitle),
            ("stateTitle", FlashFindTypography.stateTitle),
            ("stateDetail", FlashFindTypography.stateDetail),
            ("statusBar", FlashFindTypography.statusBar),
            ("sectionHeader", FlashFindTypography.sectionHeader),
            ("footer", FlashFindTypography.footer),
            ("bannerTitle", FlashFindTypography.bannerTitle),
            ("pinnedTitle", FlashFindTypography.pinnedTitle),
            ("pinnedCount", FlashFindTypography.pinnedCount),
            ("pinnedEmpty", FlashFindTypography.pinnedEmpty),
            ("settingsPageTitle", FlashFindTypography.settingsPageTitle),
            ("settingsSectionHeader", FlashFindTypography.settingsSectionHeader),
            ("settingsBody", FlashFindTypography.settingsBody),
            ("settingsBodyEmphasis", FlashFindTypography.settingsBodyEmphasis),
            ("settingsBodyStrong", FlashFindTypography.settingsBodyStrong),
            ("settingsCaption", FlashFindTypography.settingsCaption),
        ]
    }

    /// 字号阶梯必须严格递减，且没有两档撞在同一个字号上。
    ///
    /// 撞了就意味着「这两个层级看起来一样大」——`sizeLadder` 里的每一项
    /// 都是用户能同时看到的一屏内的文字（搜索框、空状态、结果名、正文、
    /// 类型条、路径）。
    func testSizeLadderStrictlyDecreases() {
        let ladder = FlashFindTypography.sizeLadder
        XCTAssertGreaterThanOrEqual(ladder.count, 5, "阶梯少于五档就撑不起层级")
        for (index, size) in ladder.enumerated().dropFirst() {
            XCTAssertLessThan(size, ladder[index - 1],
                              "第 \(index) 档（\(size)pt）没有比上一档（\(ladder[index - 1])pt）小")
        }
        XCTAssertEqual(Set(ladder).count, ladder.count, "阶梯里出现了重复字号")
    }

    /// 字重只许三档：regular 0 / medium 0.4 / semibold 0.6。
    ///
    /// 不加 bold（0.7）：中文落到苹方，11–14pt 的 bold 在小字号下笔画会并成一块，
    /// 边缘发毛。要「更重」只能靠字号或颜色，不能靠继续加粗。
    func testWeightsStayWithinThreeLevels() {
        let allowed: Set<CGFloat> = [0, 0.4, 0.6]
        for (name, style) in allStyles {
            XCTAssertTrue(allowed.contains(style.weight),
                          "\(name) 的字重 \(style.weight) 不在三档之内")
        }
    }

    /// 字距不许为正，也不许紧到并字（中文超过 -0.4 就开始贴）。
    func testTrackingStaysTightButNotCrushed() {
        for (name, style) in allStyles {
            XCTAssertLessThanOrEqual(style.tracking, 0, "\(name) 的字距是正的，会把字拉开")
            XCTAssertGreaterThanOrEqual(style.tracking, -0.4, "\(name) 的字距过紧，中文会并字")
        }
    }

    /// **文件名是全界面最重的一档**，且比它自己的路径重。
    ///
    /// 这是「加粗感」的核心：一屏里最该被眼睛抓住的是文件名，
    /// 如果路径和文件名的字重一样，整列就糊成一片灰。
    func testResultNameOutweighsItsOwnPath() {
        XCTAssertGreaterThan(FlashFindTypography.resultName.weight,
                             FlashFindTypography.resultPath.weight)
        // 0.6 = semibold。低于它就只是「普通标题」，不是用户要的那口气。
        XCTAssertGreaterThanOrEqual(FlashFindTypography.resultName.weight, 0.6,
                                    "文件名必须到 semibold 才有 Spotlight 那种扎实感")
    }

    /// 标题类必须重于正文类（跨界面的同一条判据）。
    func testHeadersAreHeavierThanBody() {
        XCTAssertGreaterThan(FlashFindTypography.sectionHeader.weight,
                             FlashFindTypography.stateDetail.weight)
        XCTAssertGreaterThan(FlashFindTypography.settingsPageTitle.weight,
                             FlashFindTypography.settingsBody.weight)
        XCTAssertGreaterThan(FlashFindTypography.settingsBodyStrong.weight,
                             FlashFindTypography.settingsBody.weight)
    }

    /// 设置页四档字号必须与 `SettingsTypography` 同源。
    ///
    /// 这里重新写一个 17 / 16 / 13 / 11 就会「改了一处、另一处没动」，
    /// 而设置页的字号阶梯是 2026-10 实测系统设置定下来的。
    func testSettingsStylesReuseSettingsTypographySizes() {
        XCTAssertEqual(FlashFindTypography.settingsPageTitle.size, SettingsTypography.pageTitle)
        XCTAssertEqual(FlashFindTypography.settingsSectionHeader.size, SettingsTypography.sectionHeader)
        XCTAssertEqual(FlashFindTypography.settingsBody.size, SettingsTypography.body)
        XCTAssertEqual(FlashFindTypography.settingsCaption.size, SettingsTypography.caption)
    }

    /// 结果名 13.5pt 落在 2x 屏的整数像素上（27px）。
    ///
    /// 半像素字号在 Retina 上不会糊，在 1x 屏上会——这条锁的是「当初为什么是 13.5」。
    func testResultNameIsPixelAlignedOnRetina() {
        let pixels = FlashFindTypography.resultName.size * 2
        XCTAssertEqual(pixels, pixels.rounded(), accuracy: 0.0001,
                       "结果名字号在 2x 下不是整数像素")
    }
}
