import XCTest
@testable import FlashFindCore

/// 「浏览器授权码」这一格：该不该出现在表单里、粘进来的串怎么洗。
///
/// 这两条都是**改流程时最容易静默走样**的判定：
///   * 摆错品牌 → 账密品牌多出一个永远用不上的框，或者飞牛根本没有框可粘
///     （上一版给飞牛摆密码框就是这么错的）；
///   * 洗不干净 → 屏幕上那串明明一样，设备却回「授权码没有被接受」，
///     用户只会反复重抄，不知道是自己多带了一个换行。
final class AuthorizeCodeFieldTests: XCTestCase {

    private var allVendors: [NASSourceConfig.Vendor] {
        [.synology, .qnap, .ugreen, .fnos, .webdav, .smb, .generic, .openlist]
    }

    /// 只有「浏览器授权」的品牌才有这一行。
    ///
    /// 用全量枚举逐条写死而不是只判飞牛：将来新增品牌时，这条会立刻告诉
    /// 作者「你也得为它做一个决定」，而不是悄悄沿用某个默认值。
    func testOnlyBrowserAuthorizationVendorsGetTheField() {
        for vendor in allVendors {
            XCTAssertEqual(AuthorizeCodeField.isInline(for: vendor),
                           vendor == .fnos,
                           "\(vendor) 是否该有授权码输入框判错了")
        }
    }

    /// 首尾空白与换行必须剪掉 —— 从网页上三击复制带进来的就是这两样。
    func testNormalizeTrimsSurroundingWhitespaceAndNewlines() {
        XCTAssertEqual(AuthorizeCodeField.normalize("  abc123\n"), "abc123")
        XCTAssertEqual(AuthorizeCodeField.normalize("\nabc123\r\n"), "abc123")
        XCTAssertEqual(AuthorizeCodeField.normalize("abc123"), "abc123")
        // 中间不动：想当然地删掉所有空白会把带分隔符的码悄悄拼错。
        XCTAssertEqual(AuthorizeCodeField.normalize("ab c1"), "ab c1")
    }

    /// 空串必须归一成 nil。
    ///
    /// `nil` 与 `""` 在核心那边不是一回事：`login` 只在非 nil 时才把
    /// `authorizeCode` 发给适配器。传空串等于带着一个空码去换令牌，
    /// 设备只会回一句拒绝，而用户以为自己还没开始授权。
    func testBlankBecomesNilSoItIsNotSentAsAnEmptyCode() {
        XCTAssertNil(AuthorizeCodeField.optional("   \n "))
        XCTAssertNil(AuthorizeCodeField.optional(""))
        XCTAssertEqual(AuthorizeCodeField.optional(" code-123 "), "code-123")
    }

    // MARK: - 内联状态行文案

    /// 状态行必须把用户指到**表单里那一格**，且说清下一步是点「连接」。
    func testInlinePromptPointsAtTheFormFieldsThatActuallyExist() {
        let text = ConnectionFailureText.authorizeInlinePrompt(
            sourceName: "书房 NAS", rejected: false, validFor: 300)
        XCTAssertTrue(text.contains("浏览器") && text.contains("打开"), "要说浏览器已经开了：\(text)")
        XCTAssertTrue(text.contains("「授权码」框"), "要指到表单里那一格：\(text)")
        XCTAssertTrue(text.contains("「连接」"), "要说清下一步点哪个按钮：\(text)")
        XCTAssertTrue(text.contains("5 分钟"), "有效期要说：\(text)")
        // 弹窗那条路才有「重新打开授权页面」这个按钮，内联这里叫「获取授权码」。
        XCTAssertFalse(text.contains("重新打开授权页面"),
                       "不许把用户指去内联界面上不存在的按钮：\(text)")
        XCTAssertFalse(text.contains("**"), "状态行是纯文本，不许出现 Markdown 记号")
    }

    /// 码被拒时必须直说「没有被接受」，否则用户会以为自己没点对地方。
    func testRejectedWordingSaysTheCodeWasNotAccepted() {
        let ok = ConnectionFailureText.authorizeInlinePrompt(sourceName: "NAS", rejected: false,
                                                             validFor: 300)
        let rejected = ConnectionFailureText.authorizeInlinePrompt(sourceName: "NAS", rejected: true,
                                                                   validFor: 300)
        XCTAssertTrue(rejected.contains("没有被接受"), "实际：\(rejected)")
        XCTAssertFalse(ok.contains("没有被接受"), "第一次拿码就说被拒，会让人以为已经错过一步")
    }

    /// 有效期不足一分钟也要说「1 分钟」，不许出现「0 分钟」。
    func testValidityNeverRoundsDownToZeroMinutes() {
        let text = ConnectionFailureText.authorizeInlinePrompt(sourceName: "NAS", rejected: false,
                                                               validFor: 20)
        XCTAssertTrue(text.contains("1 分钟"), "实际：\(text)")
    }

    // MARK: - 纯文本里不许出现 Markdown 记号

    /// 界面文案里不许出现 `**`。
    ///
    /// 这些句子最终进的是 `Text(变量)` / `Label` / `NSAlert.informativeText`，
    /// **三者都不解析 Markdown** —— 用户看到的就是两个星号。
    /// 2026-10-29 在向导第 2 步的真实截图上真的看到了
    /// 「但\*\*还没在真机上验证过\*\*」，所以这条从「记得别写」变成用例。
    func testHintsNeverCarryMarkdownAsterisks() {
        var texts: [String] = []
        for vendor in allVendors {
            texts.append(vendor.supportMessage)
            texts.append(vendor.serviceHint)
        }
        texts.append(PlainHTTPRetryOffer.message(reason: "TLS 握手失败"))
        for rejected in [false, true] {
            texts.append(ConnectionFailureText.authorizeInlinePrompt(
                sourceName: "NAS", rejected: rejected, validFor: 300))
            texts.append(ConnectionFailureText.authorizationPromptText(
                sourceName: "NAS", url: URL(string: "https://nas.local:5666/oauth")!,
                validFor: 300, rejected: rejected))
        }
        for text in texts {
            XCTAssertFalse(text.contains("**"), "纯文本里出现 Markdown 记号，用户会看到星号：\(text)")
        }
    }
}
