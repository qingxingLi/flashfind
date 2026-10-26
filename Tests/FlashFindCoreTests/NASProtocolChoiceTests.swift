import XCTest
@testable import FlashFindCore

/// ★ 协议选择的界面契约。
///
/// ## 背景：这里曾经是一个**反向开关**
///
/// 原实现是 `Toggle`，绑的是「是否用明文 HTTP」，而标签在开关**关着**时
/// 写「使用加密连接 HTTPS」。于是用户看到的是「一个叫"使用加密连接"的开关，
/// 现在是关的」—— 把「勾上」读成「启用加密」。可实际勾上会把 `usePlainHTTP`
/// 置成 `true`，真的切到**明文**。
///
/// 后果有两层，都很糟：
/// 1. 想用加密的人拿到明文连接，而界面看上去一切正常；
/// 2. 账号密码在局域网里裸奔，用户不会知道。
///
/// 开关天生表达「某项功能开着」，协议却是**二选一**、两边都是有效状态。
/// 因此改成两段并列的选择器：两个选项都写在脸上，当前生效的被选中。
///
/// 这些断言守的是**语义**，不是文案长相。
final class NASProtocolChoiceTests: XCTestCase {

    // MARK: 选项与「是否明文」的对应

    /// 两个选项必须与底层布尔值**双向**对得上，且方向相反的那一侧也测到。
    ///
    /// 只测一侧会漏掉「get/set 方向搞反」这种错：
    /// 那种错在界面上完全看不出来——两段都点得动，测试却全绿。
    func testChoiceMapsBothWaysToPlainHTTPFlag() {
        XCTAssertEqual(NASProtocolChoice(usesPlainHTTP: false), .https,
                       "不加密就是加密连接")
        XCTAssertEqual(NASProtocolChoice(usesPlainHTTP: true), .plainHTTP,
                       "要明文就是明文连接")

        XCTAssertFalse(NASProtocolChoice.https.usesPlainHTTP,
                       "加密连接不能被当成明文")
        XCTAssertTrue(NASProtocolChoice.plainHTTP.usesPlainHTTP,
                      "明文连接必须被当成明文")
    }

    /// ★ 这一条守的是**方向**：两个选项互为反面，
    /// 只要有一个被写反，选「加密」就会去写 `usePlainHTTP = true`。
    func testTheTwoChoicesAreOpposites() {
        XCTAssertNotEqual(NASProtocolChoice.https.usesPlainHTTP,
                           NASProtocolChoice.plainHTTP.usesPlainHTTP)
        XCTAssertFalse(NASProtocolChoice.allCases.allSatisfy(\.usesPlainHTTP),
                       "不可能两个选项都是明文")
        XCTAssertFalse(NASProtocolChoice.allCases.allSatisfy { !$0.usesPlainHTTP },
                       "不可能两个选项都是加密")
    }

    /// 选项名必须**自解释**：用户只看见这两个词，就要能判断当前连的是哪个。
    ///
    /// 不接受「使用…」这种动作句式——它描述的是点击后的效果而不是当前状态，
    /// 而这正是原来那个反向开关出错的根源。
    func testTitlesNameTheProtocolItselfNotAnAction() {
        XCTAssertEqual(NASProtocolChoice.https.title, "加密 HTTPS")
        XCTAssertEqual(NASProtocolChoice.plainHTTP.title, "明文 HTTP")

        for choice in NASProtocolChoice.allCases {
            XCTAssertFalse(choice.title.hasPrefix("使用"),
                           "选项名不该写成动作句式「使用…」，那正是反向开关的成因：\(choice.title)")
        }
    }

    /// 两个选项的名字必须能区分开。
    ///
    /// 一旦两个选项文案相同或只差一个字（"HTTP" / "HTTPS"），
    /// 用户就分不清自己选的是哪个——那比开关还糟。
    func testTheTwoTitlesAreDistinguishable() {
        let titles = NASProtocolChoice.allCases.map(\.title)
        XCTAssertEqual(Set(titles).count, titles.count, "两个选项的名字不能重复")
        for (a, b) in [(titles[0], titles[1])] {
            XCTAssertNotEqual(a, b)
            // 一个必须点明加密，另一个必须点明不加密。
            XCTAssertTrue(a.contains("加密") || b.contains("加密"))
            XCTAssertTrue(a.contains("明文") || b.contains("明文"))
        }
    }

    /// 选项集合固定为两个 —— 协议只有这两种。
    func testExactlyTwoChoices() {
        XCTAssertEqual(NASProtocolChoice.allCases.count, 2)
        XCTAssertEqual(Set(NASProtocolChoice.allCases).count, 2)
    }

    // MARK: 与来源配置的关系

    /// 来源配置里的「是否明文」三态，落到界面上必须只剩两个选项。
    ///
    /// `usePlainHTTP` 存成 `Bool?`（`nil` = 按品牌默认），
    /// 但界面不能出现第三种「跟随品牌」的选项 —— 那是内部实现，
    /// 且品牌默认已经解析成具体的加密/明文了。
    func testSourceConfigResolvesToExactlyOneChoice() {
        var config = NASSourceConfig()
        config.vendor = .webdav
        config.usePlainHTTP = nil
        XCTAssertFalse(config.usesPlainHTTP,
                       "WebDAV 的品牌默认是加密")
        XCTAssertEqual(NASProtocolChoice(usesPlainHTTP: config.usesPlainHTTP), .https)

        config.usePlainHTTP = true
        XCTAssertEqual(NASProtocolChoice(usesPlainHTTP: config.usesPlainHTTP), .plainHTTP)

        config.usePlainHTTP = false
        XCTAssertEqual(NASProtocolChoice(usesPlainHTTP: config.usesPlainHTTP), .https)
    }

    /// 群晖不给这个选择（它走证书固定，核心只接受 https）。
    /// 界面上那个二选一控件因此**对群晖不出现**。
    func testSynologyDoesNotOfferTheProtocolChoice() {
        XCTAssertFalse(NASSourceConfig.Vendor.synology.allowsPlainHTTPChoice)
    }
}
