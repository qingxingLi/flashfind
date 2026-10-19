import Foundation

/// 开机自动连接的节奏（纯策略，不含任何进程 / 网络 / 界面副作用）。
///
/// 存在的理由：Mac 重启后闪寻随登录项自动启动，那一刻网络往往**还没就绪**
/// （Wi-Fi 尚未连上、DHCP 还没拿到地址），设备侧的 DSM 也可能还在起服务。
/// 以前 `autoConnectSavedSources()` 只发一次连接，撞上这个窗口就永久停在离线——
/// 用户看到的正是「重启后不会自动登录」，只能自己手动点一次。
///
/// 策略只回答两件事：失败后等多久再试、这类失败值不值得重试。
public struct NASAutoConnectPolicy: Sendable {
    public static let maxAttempts = 5
    /// 每次失败后的等待：越往后越久，覆盖「网络还没起来 / DSM 还在启动」这段窗口。
    ///
    /// 元素个数 = `maxAttempts - 1`（最后一次失败后不再等）。
    public static let backoff: [TimeInterval] = [5, 15, 40, 60]

    /// 第 `attempt` 次失败（从 0 起）后要等多久；`nil` = 不再重试。
    public static func delay(afterFailure attempt: Int) -> TimeInterval? {
        guard attempt >= 0, attempt < backoff.count else { return nil }
        return backoff[attempt]
    }

    /// 这类失败该不该自动重试。
    ///
    /// ★ 设备要求动态码（两步验证）时**必须停手**：本机凭据里没有码，
    /// 重试多少次都是同一个 403，而连续登录失败会加速设备侧的限流。
    /// 这种情况如实报给用户，由他点「重新登录」在弹框里填——
    /// 这正是用户确认要保留的现状，不静默重试。
    public static func shouldRetry(_ error: Error) -> Bool {
        !ConnectionFailureText.isOTPRequired(error)
    }
}

/// 一次开机自动连接的结果。
///
/// 只有三种终态：连上了 / 试满次数仍失败（带最后一次原因）/ 已自行处理。
/// 「已自行处理」指流程内部已经写好了自己的状态卡片（例如证书要重新确认），
/// 宿主不该再用一句通用失败文案覆盖回去。
public enum NASAutoConnectOutcome: Sendable {
    case connected
    case failed(attemptsMade: Int, lastError: Error)
    /// 连接意图被作废（用户在重试间隙点了「断开」）或已自行写明状态 ⇒ 不要写状态。
    case settled
}

/// 开机自动连接的驱动器：连 → 失败按退避重试 → 仍失败则交回最后一次原因。
///
/// 连接动作由宿主注入，因此这里可以脱离子进程与真实网络做确定性测试
/// （退避间隔、放弃条件、作废后不再重试）。
@MainActor
public final class NASAutoConnectRunner {
    /// 一次连接尝试。**返回是否连上**；未连上但已自行写明状态时返回 false，
    /// 宿主据此决定要不要补一句失败文案。
    public var attempt: () async throws -> Bool = { true }
    /// 这次意图还有效吗（用户断开 / 来源被删后为 false）。
    public var stillValid: () -> Bool = { true }
    /// 睡眠。测试里换假钟，不真等。
    public var sleep: (TimeInterval) async -> Void = { _ in }
    public var log: (String) -> Void = { _ in }

    public init() {}

    public func run() async -> NASAutoConnectOutcome {
        var attemptsMade = 0
        var lastError: Error?
        for index in 0..<NASAutoConnectPolicy.maxAttempts {
            // ★ 每一轮开始和每个 `await` 之后都复核意图：用户可能在重试间隙
        // 点了「断开」，那时必须立刻停手。
            guard stillValid() else { return .settled }
            attemptsMade += 1
            do {
                if try await attempt() { return .connected }
                // 自行写明状态（例如证书要确认）⇒ 不再重试，也不覆盖文案。
                return .settled
            } catch {
                lastError = error
                // 断开之后的迟到失败：来源已离线，不许重试、也不许写状态。
                guard stillValid() else { return .settled }
                // 要动态码的失败重试无意义（见 `shouldRetry`）；次数用尽也到此为止。
                // 失败原因不在这里拼：Core 拿不到 host/port，而「同一个 kind
                // 两种说法」正是要避免的。最后一次失败由宿主统一落诊断。
                guard NASAutoConnectPolicy.shouldRetry(error),
                      let delay = NASAutoConnectPolicy.delay(afterFailure: index) else {
                    return .failed(attemptsMade: attemptsMade, lastError: error)
                }
                log("自动连接第 \(attemptsMade) 次失败，\(Int(delay)) 秒后重试")
                await sleep(delay)
            }
        }
        if let lastError { return .failed(attemptsMade: attemptsMade, lastError: lastError) }
        return .settled
    }
}
