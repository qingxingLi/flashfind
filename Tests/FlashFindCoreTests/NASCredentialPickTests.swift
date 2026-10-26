import XCTest
@testable import FlashFindCore

/// 登录凭据取值规则的回归测试。
///
/// ## 真实故障（2026-10-24 用户报障）
///
/// 用户在「编辑 openlist」里**密码框留空**（凭据存在钥匙串里），
/// 点「连接」后**动态码弹窗一遍接一遍地弹**，停不下来。
///
/// 根因不在「弹窗」，在**取密码的那一路**：
///
/// | 取密码的路 | 动态码 |
/// |---|---|
/// | 密码框里手输 | 带上了 ⇒ 一次成功 |
/// | 钥匙串里已存 | **丢了** ⇒ 服务端仍回 402 ⇒ 又弹一次 ⇒ 无限循环 |
///
/// 两条路的差别是当年写代码时留下的：手输那条写了
/// `otp: nativeNASOTP.isEmpty ? nil : nativeNASOTP`，
/// 钥匙串那条图省事写了 `otp: nil`。
/// 于是现象长得像「只有空密码才会一直弹」，其实是「只有走钥匙串那条路才会」。
///
/// 修法：取值规则搬进 Core（`NASCredentialPick`），两条路**共用**同一个出口，
/// 动态码**必然**跟着走。App 层那行只是调用。
final class NASCredentialPickTests: XCTestCase {

    // MARK: 常规路径

    func testTypedPasswordWins() {
        let picked = NASCredentialPick.pick(typedPassword: "typed",
                                            storedPassword: "stored",
                                            otp: nil)
        XCTAssertEqual(picked?.password, "typed", "手输的密码优先")
    }

    func testStoredPasswordUsedWhenFieldIsEmpty() {
        let picked = NASCredentialPick.pick(typedPassword: "",
                                            storedPassword: "stored",
                                            otp: nil)
        XCTAssertEqual(picked?.password, "stored", "框里没输就该用钥匙串里那把")
    }

    func testNothingAvailableReturnsNil() {
        XCTAssertNil(NASCredentialPick.pick(typedPassword: "", storedPassword: nil, otp: nil))
        XCTAssertNil(NASCredentialPick.pick(typedPassword: "", storedPassword: "", otp: nil),
                     "空串不是一把密码")
    }

    // MARK: ★ 动态码必须跟着走（死循环的修法）

    /// 钥匙串那条路**也必须**带上动态码。
    /// 少了这一句就是用户报的「不断地跳 OTP 弹窗」。
    func testStoredPasswordStillCarriesTheOTP() {
        let picked = NASCredentialPick.pick(typedPassword: "",
                                            storedPassword: "stored",
                                            otp: "123456")
        XCTAssertEqual(picked?.password, "stored")
        XCTAssertEqual(picked?.otp, "123456",
                       "钥匙串那条路丢了动态码 ⇒ 重连不带码 ⇒ 服务端再回 402 ⇒ 又弹一次")
    }

    func testTypedPasswordAlsoCarriesTheOTP() {
        let picked = NASCredentialPick.pick(typedPassword: "typed",
                                            storedPassword: nil,
                                            otp: "654321")
        XCTAssertEqual(picked?.otp, "654321")
    }

    /// 两条路都要带——这是这次修法的要点：
    /// 以前只有一条路带，于是「哪条路会死循环」取决于用户有没有手输密码。
    func testBothPathsCarryTheOTPIdentically() {
        let typed = NASCredentialPick.pick(typedPassword: "typed", storedPassword: nil, otp: "111111")
        let stored = NASCredentialPick.pick(typedPassword: "", storedPassword: "stored", otp: "111111")
        XCTAssertEqual(typed?.otp, stored?.otp, "两条路对动态码的处理必须一致")
    }

    /// 空串不算「有码」：把空串当码发出去，服务端照样回 402，等于没带。
    func testEmptyOTPIsTreatedAsNoOTP() {
        let picked = NASCredentialPick.pick(typedPassword: "typed",
                                            storedPassword: nil,
                                            otp: "")
        XCTAssertNil(picked?.otp, "空串动态码等于没码")
    }
}
