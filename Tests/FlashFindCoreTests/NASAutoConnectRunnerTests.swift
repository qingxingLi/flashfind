import XCTest
@testable import FlashFindCore

/// 开机自动连接的重试节奏（Mac 重启后不自动登录）。
///
/// 这些测试锁的是**节奏与放弃条件**，不是连接本身：
/// 连接动作由 `attempt` 注入，所以每条都能确定性复现。
@MainActor
final class NASAutoConnectRunnerTests: XCTestCase {
    private struct Boom: Error { let tag: String }

    private func otpError() -> FlashFindError {
        .coreFailure(kind: "NeedsOTP", reason: nil, apiCode: 403)
    }

    /// 第一次就成功 ⇒ 立刻收工，不睡不等，不重试。
    func testFirstAttemptSucceeds() async {
        var attempts = 0; var sleeps: [TimeInterval] = []
        let runner = NASAutoConnectRunner()
        runner.attempt = { attempts += 1; return true }
        runner.sleep = { sleeps.append($0) }

        let outcome = await runner.run()
        XCTAssertEqual(attempts, 1)
        XCTAssertEqual(sleeps, [])
        if case .connected = outcome { } else { XCTFail("应当是 connected") }
    }

    /// 网络还没起来：前两次失败后第三次连上 ⇒ 按退避表等 5、15 秒。
    func testRetriesUntilNetworkComesBack() async {
        var attempts = 0; var sleeps: [TimeInterval] = []
        let runner = NASAutoConnectRunner()
        runner.attempt = {
            attempts += 1
            if attempts < 3 { throw URLError(.cannotConnectToHost) }
            return true
        }
        runner.sleep = { sleeps.append($0) }

        let outcome = await runner.run()
        XCTAssertEqual(attempts, 3)
        XCTAssertEqual(sleeps, [5, 15])
        if case .connected = outcome { } else { XCTFail("应当是 connected") }
    }

    /// 一直连不上 ⇒ 试满 5 次后把最后一次原因交回宿主，全程按退避表等待。
    func testGivesUpAfterBudgetedAttempts() async {
        var attempts = 0; var sleeps: [TimeInterval] = []
        let runner = NASAutoConnectRunner()
        runner.attempt = { attempts += 1; throw URLError(.timedOut) }
        runner.sleep = { sleeps.append($0) }

        let outcome = await runner.run()
        XCTAssertEqual(attempts, NASAutoConnectPolicy.maxAttempts)
        XCTAssertEqual(sleeps, NASAutoConnectPolicy.backoff)
        guard case let .failed(count, error) = outcome else { return XCTFail("应当是 failed") }
        XCTAssertEqual(count, NASAutoConnectPolicy.maxAttempts)
        XCTAssertTrue(error is URLError)
    }

    /// ★ 要动态码的失败**一次就停**：重试也只是同一个 403，还会加速设备侧限流。
    func testDoesNotRetryWhenDeviceWantsOTP() async {
        var attempts = 0; var sleeps: [TimeInterval] = []
        let runner = NASAutoConnectRunner()
        runner.attempt = { attempts += 1; throw self.otpError() }
        runner.sleep = { sleeps.append($0) }

        guard case .failed = await runner.run() else { return XCTFail("应当是 failed") }
        XCTAssertEqual(attempts, 1, "OTP 失败重试无意义，且会加速设备侧限流")
        XCTAssertEqual(sleeps, [])
        XCTAssertFalse(NASAutoConnectPolicy.shouldRetry(otpError()))
        // 填错一次码同样停手，交给用户在弹框里重填。
        XCTAssertFalse(NASAutoConnectPolicy.shouldRetry(
            FlashFindError.coreFailure(kind: "OTPRejected", reason: nil, apiCode: 403)))
    }

    /// ★ 用户在重试间隙点了「断开」⇒ 立刻停手，不再尝试。
    func testStopsRetryingAfterUserDisconnects() async {
        var attempts = 0; var valid = true
        let runner = NASAutoConnectRunner()
        runner.attempt = { attempts += 1; throw URLError(.timedOut) }
        runner.stillValid = { valid }
        runner.sleep = { _ in if attempts >= 2 { valid = false } }

        guard case .settled = await runner.run() else { return XCTFail("应当是 settled") }
        XCTAssertEqual(attempts, 2, "意图作废后不该再发起新的连接")
    }

    /// 退避表与次数必须对得上：少一个元素就等于少一次重试。
    func testBackoffCoversEveryRetryGap() {
        XCTAssertEqual(NASAutoConnectPolicy.backoff.count,
                       NASAutoConnectPolicy.maxAttempts - 1)
        for index in 0..<NASAutoConnectPolicy.backoff.count {
            XCTAssertEqual(NASAutoConnectPolicy.delay(afterFailure: index),
                           NASAutoConnectPolicy.backoff[index])
        }
        XCTAssertNil(NASAutoConnectPolicy.delay(afterFailure: NASAutoConnectPolicy.maxAttempts))
        XCTAssertNil(NASAutoConnectPolicy.delay(afterFailure: -1))
    }
}
