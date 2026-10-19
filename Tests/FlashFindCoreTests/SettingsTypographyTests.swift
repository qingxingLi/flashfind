import XCTest
@testable import FlashFindCore

/// 设置界面的字号阶梯。
///
/// 为什么要锁这条阶梯：
/// 1. 分段标题与正文若只差字重、字号相同，扫一眼分不出层级。
/// 2. 页面标题要向 macOS 系统设置「外观与语言」页收敛，不再用 20pt 那种大字号。
///
/// 这条阶梯锁的是**大小本身**：顺序必须是「页面标题 > 分段标题 > 正文 > 辅助说明」，
/// 且分段标题必须明显大于正文。
final class SettingsTypographyTests: XCTestCase {

    /// ★ 四个层级必须严格递减，且相邻级至少差 1pt。
    ///
    /// 只断言「不相等」不够：15 与 14.5 也是两个值，但肉眼分不出来——
    /// 那正是这条阶梯要解决的问题。相邻差从 2pt 放宽到 1pt 是因为页面标题要
    /// 贴近系统设置（实测约 15.7pt，取 17），而分段标题保持 16 不动，两者只差 1pt；
    /// 「分段标题明显大于正文」由下面那条 ≥3pt 的断言单独锁，不在这里重复。
    func testLevelsStepDownByAPerceptibleAmount() {
        let levels = [SettingsTypography.pageTitle, SettingsTypography.sectionHeader,
                      SettingsTypography.body, SettingsTypography.caption]
        for (upper, lower) in zip(levels, levels.dropFirst()) {
            XCTAssertGreaterThanOrEqual(upper - lower, 1,
                                        "相邻层级至少差 1pt，实际差 \(upper - lower)")
        }
        XCTAssertEqual(Set(levels).count, levels.count, "四个层级必须是四个不同的字号")
    }

    /// 页面标题要贴近 macOS 系统设置的标题大小。
    ///
    /// 参考是系统设置「外观与语言」页：实测该页标题约 15.7pt。
    /// 取 17pt：既贴近系统观感（不像 20pt 那样头重脚轻），又仍比分段标题大一档。
    /// 改这个值必须同步改这里的注释依据，不能悄悄调。
    func testPageTitleMatchesSystemSettingsScale() {
        XCTAssertEqual(SettingsTypography.pageTitle, 17,
                       "页面标题应贴近 macOS 系统设置标题（实测约 15.7pt，取 17）")
    }

    /// 分段标题要明显大于正文。
    func testSectionHeaderStandsOutFromBody() {
        XCTAssertGreaterThanOrEqual(SettingsTypography.sectionHeader, SettingsTypography.body + 3,
                                    "分段标题必须比正文大 3pt 以上，否则用户分不清层级")
    }

    /// 辅助说明必须小于正文，且小到不抢注意力。
    func testCaptionIsSmallerThanBody() {
        XCTAssertLessThan(SettingsTypography.caption, SettingsTypography.body)
        XCTAssertLessThanOrEqual(SettingsTypography.caption, 12)
    }

    /// 所有字号都是正数且在合理范围内（防止误写成 0 或 200）。
    func testAllSizesAreSane() {
        for (name, size) in [("pageTitle", SettingsTypography.pageTitle),
                             ("sectionHeader", SettingsTypography.sectionHeader),
                             ("body", SettingsTypography.body),
                             ("caption", SettingsTypography.caption)] {
            XCTAssertGreaterThan(size, 0, "\(name) 必须是正数")
            XCTAssertLessThan(size, 40, "\(name) 不该超过 40pt")
        }
    }
}
