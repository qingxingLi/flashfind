import XCTest
@testable import FlashFindCore

/// 连接向导里的失败文案 + 连接尝试的竞态闸门。
///
/// 这两个原本都是 `AppModel` 的私有实现（`diagnose` 与 `connectionAttempt`），
/// **一行测试都写不了**。搬进 Core 才能锁住它们——而它们一个决定
/// 「连接失败时用户看到什么」，一个决定「双击连接会不会跑出两条并行的登录流程」。
final class ConnectionFailureTextTests: XCTestCase {

    // MARK: - 具体的网络错误优先

    func testHTTP401IsPasswordProblem() {
        let text = ConnectionFailureText.describe(HTTPFailure(status: 401), host: "h", port: 5001)
        XCTAssertEqual(text, "账号或密码不正确")
    }

    /// 「连不上」与「证书不可信」要用户做的事完全不同，必须分开说。
    func testURLErrorsAreDistinguished() {
        let unreachable = ConnectionFailureText.describe(
            URLError(.cannotConnectToHost), host: "192.168.1.96", port: 5001)
        XCTAssertTrue(unreachable.contains("连不上"), "实际：\(unreachable)")
        XCTAssertTrue(unreachable.contains("192.168.1.96:5001"), "要带上地址与端口")

        let tls = ConnectionFailureText.describe(
            URLError(.serverCertificateUntrusted), host: "h", port: 443)
        XCTAssertTrue(tls.contains("证书"), "实际：\(tls)")

        let timeout = ConnectionFailureText.describe(URLError(.timedOut), host: "h", port: 5001)
        XCTAssertTrue(timeout.contains("超时"), "实际：\(timeout)")
    }

    // MARK: - 核心错误

    /// 核心写好的现场原因优先——「TLS 握手失败」与「密码错」要用户做的事完全不同。
    func testCoreReasonBeatsAnyGuess() {
        let error = FlashFindError.coreFailure(kind: "AuthenticationFailed",
                                               reason: "TLS 握手失败：端口只讲明文 HTTP",
                                               apiCode: nil)
        XCTAssertEqual(ConnectionFailureText.describe(error, host: "h", port: 5001),
                       "TLS 握手失败：端口只讲明文 HTTP")
    }

    /// ★ 这条是搬进 Core 的理由：reason 为空时，旧实现走 `localizedDescription`，
    /// 而它返回的是 **kind** ⇒ 用户看到 "TLSRejected" 这种技术名词。
    func testCoreFailureWithoutReasonIsNotRawKind() {
        for kind in ["TLSRejected", "NeedsOTP", "AuthenticationFailed"] {
            let error = FlashFindError.coreFailure(kind: kind, reason: nil, apiCode: nil)
            let text = ConnectionFailureText.describe(error, host: "h", port: 5001)
            XCTAssertNotEqual(text, kind, "\(kind) 的文案缺失，只剩类型名")
            XCTAssertTrue(text.contains("（错误类型 \(kind)）"),
                          "排查用的类型后缀要保留，实际：\(text)")
        }
    }

    /// 旧版单独处理过、但中文表里查不到的 kind，仍要有可理解的话。
    func testLegacyAdminIdentityWordingSurvives() {
        let error = FlashFindError.coreFailure(kind: "UnexpectedAdminIdentity",
                                               reason: nil, apiCode: nil)
        let text = ConnectionFailureText.describe(error, host: "h", port: 5001)
        XCTAssertTrue(text.contains("管理员"), "实际：\(text)")
    }

    /// 连接 / 打开 / 搜索三条链路必须是同一套中文。
    func testAllThreeFailurePathsShareWording() {
        for kind in ["SessionExpired", "PermissionDenied", "RateLimited"] {
            let error = FlashFindError.coreFailure(kind: kind, reason: nil, apiCode: nil)
            let connect = ConnectionFailureText.describe(error, host: "h", port: 5001)
            let open = OpenFailureText.describe(error)
            let search = NASSearchFailureText.describe(kind: kind, apiCode: nil)
            XCTAssertEqual(connect, open, "kind=\(kind)：连接与打开文案不一致")
            XCTAssertEqual(open, search, "kind=\(kind)：打开与搜索文案不一致")
        }
    }

    func testFlashFindMessageIsUsedVerbatim() {
        let error = FlashFindError.message("尚未选择搜索位置")
        XCTAssertEqual(ConnectionFailureText.describe(error, host: "h", port: 5001), "尚未选择搜索位置")
    }

    // MARK: - 动态口令（OTP）判定

    /// ★ 的根因：自动重连带的是 `otp: nil`，设备要 OTP 就一定失败。
    /// 界面必须能认出「这次失败是缺动态码」，才能弹输入框。
    func testNeedsOTPIsRecognisedAsOTPRequired() {
        let error = FlashFindError.coreFailure(kind: "NeedsOTP", reason: nil, apiCode: 403)
        XCTAssertTrue(ConnectionFailureText.isOTPRequired(error))
    }

    /// 用户填错一次码之后必须还能再弹一次，否则就把人扔在「设备拒绝了」上无路可走。
    func testRejectedOTPIsAlsoRecognised() {
        let error = FlashFindError.coreFailure(kind: "OTPRejected", reason: nil, apiCode: nil)
        XCTAssertTrue(ConnectionFailureText.isOTPRequired(error))
    }

    /// 别的失败不能误触发 OTP 弹窗——否则用户会为一个跟动态码无关的问题被反复索要验证码。
    func testOtherFailuresDoNotTriggerOTPPrompt() {
        for kind in ["AuthenticationFailed", "NetworkFailure", "SessionExpired", "HttpDenied"] {
            let error = FlashFindError.coreFailure(kind: kind, reason: nil, apiCode: nil)
            XCTAssertFalse(ConnectionFailureText.isOTPRequired(error), "\(kind) 不该触发 OTP 弹窗")
        }
        XCTAssertFalse(ConnectionFailureText.isOTPRequired(URLError(.timedOut)))
        XCTAssertFalse(ConnectionFailureText.isOTPRequired(FlashFindError.message("尚未选择搜索位置")))
    }

    /// 旧核心可能只把 kind 拼进描述里，这条兜底必须还在。
    func testOTPKindInsideDescriptionStillCounts() {
        struct LegacyError: LocalizedError { var errorDescription: String? { "NeedsOTP" } }
        XCTAssertTrue(ConnectionFailureText.isOTPRequired(LegacyError()))
    }

    /// 弹窗正文要说清「为什么要再填一次」，并且带上来源名让用户知道是哪台设备。
    func testOTPPromptNamesTheSourceAndExplainsWhy() {
        let text = ConnectionFailureText.otpPromptText(sourceName: "OEC")
        XCTAssertTrue(text.contains("OEC"), "要指出是哪台设备，实际：\(text)")
        XCTAssertTrue(text.contains("每次登录都不一样"), "要说清动态码为什么必须重填，实际：\(text)")
    }

    // MARK: - 弹窗式动态码（2026-10-22 起所有登录路径统一）

    /// 弹窗标题与「再点一次就能叫回来」那句提示必须同时存在。
    ///
    /// ## 这条守的是什么
    ///
    /// 动态码换了三版形态，每一版坏法都不同：
    ///   1. 表单里的折叠区 —— 默认收起，且没有一条路径会打开它；
    ///   2. 模型持有开关、失败自动展开 —— 但用户得回表单再点一次「连接」；
    ///   3. **弹窗**（现在）：失败即弹、填完自动续连。
    ///
    /// 第 1 版的坏法正是「指路指到一个不存在的位置」：提示让你去填某个框，
    /// 界面上根本没有那个框。所以现在只指一个确定还在的控件 —— **「连接」按钮**，
    /// 并且要求弹窗标题本身非空、住 Core（两处登录路径共用同一句）。
    func testTheOTPRetryHintPointsAtAButtonThatStillExists() {
        XCTAssertFalse(ConnectionFailureText.otpDialogTitle.isEmpty, "弹窗标题不能是空的")
        let hint = ConnectionFailureText.otpRetryHint
        XCTAssertTrue(hint.contains("「连接」"), "指路只能指界面上确定还在的控件，实际：\(hint)")
        XCTAssertFalse(hint.contains(ConnectionFailureText.otpDialogTitle),
                       "弹窗标题不该再被拼进状态行：怎么说填是弹窗的事，两处各说一遍必然走样")
    }

    /// 取消弹窗之后，用户还得知道「填什么、怎么再来一次」。
    func testTheOTPRetryHintSaysWhatToTypeAndHowToComeBack() {
        let hint = ConnectionFailureText.otpRetryHint
        XCTAssertTrue(hint.contains("6 位数字"), "要说清填什么，实际：\(hint)")
        XCTAssertTrue(hint.contains("再点一次"), "要说清怎么把它叫回来，实际：\(hint)")
    }

    // MARK: - 连接尝试闸门

    /// 双击「连接」时，第一次尝试必须立刻失效——否则两条 discover→login
    /// 并行跑，互相覆盖会话与证书确认。
    func testNewAttemptInvalidatesThePreviousOne() {
        let gate = ConnectionAttemptGate()
        let first = gate.next()
        XCTAssertTrue(gate.isCurrent(first))

        let second = gate.next()
        XCTAssertFalse(gate.isCurrent(first), "旧尝试必须失效，否则会回来写状态")
        XCTAssertTrue(gate.isCurrent(second))
    }

    /// 取消不是「再连一次」：不该留下一个当前尝试。
    func testCancelLeavesNoCurrentAttempt() {
        let gate = ConnectionAttemptGate()
        let attempt = gate.next()
        gate.invalidate()
        XCTAssertFalse(gate.isCurrent(attempt))
        // invalidate 只作废旧的、不开新的：此后若真要再连，序号仍从 next() 单调递增。
        let afterCancel = gate.next()
        XCTAssertGreaterThan(afterCancel, attempt)
        XCTAssertTrue(gate.isCurrent(afterCancel))
        XCTAssertFalse(gate.isCurrent(attempt))
    }

    /// 序号单调递增，永不回退——回退会让一次早已结束的尝试重新变成「最新」。
    func testAttemptNumbersNeverRepeat() {
        let gate = ConnectionAttemptGate()
        var seen = Set<Int>()
        for _ in 0..<50 { seen.insert(gate.next()) }
        XCTAssertEqual(seen.count, 50, "序号重复会让过期尝试复活")
    }
}
