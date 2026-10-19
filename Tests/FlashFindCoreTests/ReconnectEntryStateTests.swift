import XCTest
@testable import FlashFindCore

/// 断开之后「重新连接」该怎么走（回归）。
///
/// ## 锁的是什么
///
/// 用户断开一台 NAS 之后想连回来，界面给的是**写死的一句**
/// 「请输入密码以重新连接」——本机凭据文件里明明存着这把密码也照这么说，
/// 用户只能再输一遍。这一轮把「能不能用已保存的密码」变成显式判定，
/// 这里把那张判定表钉住，免得下一个人又把它简化成一句固定文案。
final class ReconnectEntryStateTests: XCTestCase {

    /// 本机真有密码 → 静默用，不问用户。这是**用户报障时缺的那条路**。
    func testUsesStoredCredentialWhenItActuallyExists() {
        XCTAssertEqual(ReconnectEntryState.route(rememberPassword: true, hasStoredCredential: true),
                       .storedCredential)
        XCTAssertTrue(ReconnectEntryState.canReconnectSilently(rememberPassword: true,
                                                              hasStoredCredential: true))
    }

    /// 勾了记住但本机没有：必须要求输入，且**说清为什么**。
    func testAsksForPasswordWhenRememberedButNothingStored() {
        guard case .askForPassword(let reason) = ReconnectEntryState.route(rememberPassword: true,
                                                                          hasStoredCredential: false)
        else { return XCTFail("勾了记住却没有密码时，不能走静默重连") }
        XCTAssertEqual(reason, ReconnectEntryState.missingStoredReason)
        // 不猜原因：既承认「可能没存上」，也承认「可能刚被清除」。
        XCTAssertTrue(reason.contains("没存上"))
        XCTAssertTrue(reason.contains("清除"), "两种可能都要说，不能编一个确定的原因：\(reason)")
        // 必须告诉用户怎么才能不再输。
        XCTAssertTrue(reason.contains("记住"), "要说清怎样以后不用再输：\(reason)")
    }

    /// 用户自己没勾记住 —— 说明里不许暗示「程序忘了」。
    func testAsksForPasswordWhenRememberWasTurnedOff() {
        guard case .askForPassword(let reason) = ReconnectEntryState.route(rememberPassword: false,
                                                                          hasStoredCredential: true)
        else { return XCTFail("没勾记住时不该宣称能用已保存的密码") }
        XCTAssertEqual(reason, ReconnectEntryState.notRememberedReason)
        XCTAssertTrue(reason.contains("没有勾选"), "要如实说是用户的选择：\(reason)")
        XCTAssertTrue(reason.contains("勾上之后"), "要给出下一步：\(reason)")
    }

    /// 必须同时看两件事：只看 `rememberPassword` 就会在「勾了但没存上」时骗人。
    func testRememberFlagAloneIsNotEnough() {
        XCTAssertFalse(ReconnectEntryState.canReconnectSilently(rememberPassword: true,
                                                               hasStoredCredential: false),
                       "配置里勾了记住 ≠ 本机真有密码")
    }
}

/// 来源卡片行内按钮「断开 / 重新连接」的判定（回归）。
///
/// ## 锁的是什么
///
/// 用户点「断开」后状态文字立刻变成「已断开」，但 Provider 的 `ready`
/// 要等异步收尾才翻转。按钮若只认 `ready`，就会停留在「断开」，
/// 用户得再点一次才能看到「重新连接」。判定必须同时看
/// 「状态是否已显式标记离线」，断开意图确立后按钮立刻切换。
final class NASRowActionTests: XCTestCase {

    /// 已连接且未标记离线 → 显示「断开」。
    func testShowsDisconnectWhenReadyAndNotMarkedOffline() {
        XCTAssertEqual(NASRowAction.decide(ready: true, markedOffline: false), .disconnect)
    }

    /// 核心回归：ready 还没翻转但状态已标记离线 → 必须立刻给「重新连接」。
    func testShowsReconnectImmediatelyAfterDisconnectMarked() {
        XCTAssertEqual(NASRowAction.decide(ready: true, markedOffline: true), .reconnect,
                       "断开意图已确立，按钮不许等异步收尾才切换")
    }

    /// 没连上 → 「重新连接」（无论是否标记离线）。
    func testShowsReconnectWhenNotReady() {
        XCTAssertEqual(NASRowAction.decide(ready: false, markedOffline: false), .reconnect)
        XCTAssertEqual(NASRowAction.decide(ready: false, markedOffline: true), .reconnect)
    }
}
