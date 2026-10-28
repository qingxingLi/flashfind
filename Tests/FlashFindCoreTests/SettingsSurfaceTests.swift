import XCTest
@testable import FlashFindCore

/// 设置窗口的表面策略（2026-10-27 用户定稿；当晚追加「跟着搜索这一块走」）。
///
/// 要求原文：「设置界面不要大片灰白阴影，浅色整体可以使用纯白背景，原先更深的
/// 阴影的位置改为使用一个玻璃遮罩效果，深色背景维持现在。」
/// 深夜追加：「设置页 UI 界面跟着搜索这一块走」——浅色卡片换成搜索模块那套
/// Liquid Glass，同圆角、同描边。
///
/// 这几半的答案**不一样**，所以每一条都要**分开**断言：只测「浅色是纯白」的话，
/// 有人顺手让深色也跟着改成纯白，测试照样全绿——而用户会立刻看出来。
final class SettingsSurfaceTests: XCTestCase {

    func testLightBackdropIsPureWhite() {
        let style = SettingsSurface.style(isDark: false, liquidGlassAvailable: true)
        XCTAssertEqual(style.backdrop, .pureWhite,
                       "浅色整窗要纯白：半透明桌面材质正是那片灰白的来源")
    }

    /// 浅色卡片 = 搜索模块那一套：同一个 `glassEffect`、同一个圆角、同一道描边、零投影。
    func testLightCardUsesTheSameLiquidGlassAsTheSearchModules() {
        let style = SettingsSurface.style(isDark: false, liquidGlassAvailable: true)
        XCTAssertEqual(style.card, .liquidGlass, "浅色卡片要用与搜索模块同一套 Liquid Glass")
        XCTAssertFalse(style.cardShadow, "★ 浅色卡片不许有投影：用户要的就是去掉那片灰白阴影")
        XCTAssertGreaterThan(style.cardStroke, 0,
                             "没有投影之后，卡片只能靠一道描边从白底上分出来")
        // ★ 圆角必须**引用**搜索模块那个常量，不是另写一个 20：
        //   抄一个数字进来，下次改搜索区圆角时这两处就悄悄不一致了。
        XCTAssertEqual(style.cardRadius, SearchModuleLayout.moduleRadius,
                       "卡片圆角要跟搜索模块同值（「跟着搜索这一块走」）")
    }

    /// 拿不到玻璃（macOS 15 / 降低透明度）：退回玻璃遮罩，但**形状不变**。
    ///
    /// 「换的只是材质，不是另一套形状」—— 圆角与描边跟着一起走，
    /// 否则同一台机器上两代外观会在粗细与圆角上一起错位。
    func testLightFallsBackToGlassMaskWithTheSameGeometry() {
        let style = SettingsSurface.style(isDark: false, liquidGlassAvailable: false)
        XCTAssertEqual(style.card, .glassMask, "没有玻璃能力时退回玻璃遮罩")
        XCTAssertFalse(style.cardShadow, "替身同样不许有投影")
        XCTAssertEqual(style.cardRadius,
                       SettingsSurface.style(isDark: false, liquidGlassAvailable: true).cardRadius,
                       "有没有玻璃能力，形状必须是同一个")
    }

    func testDarkKeepsTodayAppearance() {
        let style = SettingsSurface.style(isDark: true, liquidGlassAvailable: true)
        XCTAssertEqual(style.backdrop, .windowVibrancy,
                       "深色维持现状：系统窗口毛玻璃")
        XCTAssertEqual(style.card, .elevatedMaterial,
                       "深色维持现状：带层次的材质卡，不是玻璃卡")
        XCTAssertTrue(style.cardShadow, "深色的投影要留着，这次只改浅色")
    }

    /// 深色**不许**被玻璃能力牵着走：这台机器有没有玻璃，深色都长一样。
    ///
    /// 这条防的是「顺手把 `if` 写在外层」：一旦深色也跟着能力分支走，
    /// 用户换台机器就发现深色两副面孔，而我们谁都没改过深色。
    func testDarkDoesNotDependOnGlassAvailability() {
        XCTAssertEqual(SettingsSurface.style(isDark: true, liquidGlassAvailable: true),
                       SettingsSurface.style(isDark: true, liquidGlassAvailable: false))
    }

    /// 圆角**不跟着深浅色走**：形状是产品的事，不是外观的事。
    ///
    /// 反例（第一版就写错了）：浅色 20、深色 12 —— 换个外观卡片就从圆角变方角。
    func testCardRadiusIsTheSameInBothAppearances() {
        XCTAssertEqual(SettingsSurface.style(isDark: false, liquidGlassAvailable: true).cardRadius,
                       SettingsSurface.style(isDark: true, liquidGlassAvailable: true).cardRadius,
                       "深浅色不许各用一套圆角")
    }

    /// 两套必须是**同一个入口**给出的：视图里若各写一份三元表达式，
    /// 「深色别动」这条约定就没人守得住。
    func testStyleIsDecidedInOnePlace() {
        XCTAssertNotEqual(SettingsSurface.style(isDark: false, liquidGlassAvailable: true),
                          SettingsSurface.style(isDark: true, liquidGlassAvailable: true),
                          "浅色与深色必须是两套不同的表面，否则用户看不到这次改动")
        XCTAssertEqual(SettingsSurface.style(isDark: false, liquidGlassAvailable: true),
                       SettingsSurface.light)
        XCTAssertEqual(SettingsSurface.style(isDark: false, liquidGlassAvailable: false),
                       SettingsSurface.lightMask)
        XCTAssertEqual(SettingsSurface.style(isDark: true, liquidGlassAvailable: true),
                       SettingsSurface.dark)
    }
}
