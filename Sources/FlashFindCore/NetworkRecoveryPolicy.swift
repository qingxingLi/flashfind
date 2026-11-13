import Foundation

/// 网络恢复后要不要补跑自动连接（纯策略，不引 Network / AppKit）。
///
/// 2026-11-13 报障：「切换/关闭网络的重新打开」后闪寻不会自己连回来。
/// 原实现只在开机那 120 秒里重试 5 次，试满就永久停在「需要登录」；
/// 网络什么时候恢复、恢复了几次，都没人再问。
public enum NetworkRecoveryPolicy {
    /// 同一波网络抖动会连发多次 satisfied，别每次都把在飞的连接打断。
    public static let replayDebounce: TimeInterval = 2

    /// 只在「不可用 → 可用」的那一跳补跑。
    /// 首次收到 satisfied 不算恢复（开机那一轮由 `autoConnectSavedSources()` 负责）。
    public static func shouldReplay(wasSatisfied: Bool, isSatisfied: Bool,
                                    secondsSinceLastReplay: TimeInterval?) -> Bool {
        guard isSatisfied, !wasSatisfied else { return false }
        if let gap = secondsSinceLastReplay, gap < replayDebounce { return false }
        return true
    }

    /// 单台来源该不该补跑。已连上 / 正在连 / 没勾记住密码 / 已禁用 一律跳过。
    ///
    /// `needsLogin` 来自状态卡片（`requiredAction == .login/.retry` 或 health 异常），
    /// 不是「有没有配置」——没坏的来源不该被一次网络抖动重连一遍。
    public static func shouldReplaySource(isEnabled: Bool,
                                          isConnectConfigured: Bool,
                                          rememberPassword: Bool,
                                          providerReady: Bool,
                                          connectTaskRunning: Bool,
                                          needsLogin: Bool) -> Bool {
        guard isEnabled, isConnectConfigured, rememberPassword, needsLogin else { return false }
        return !providerReady && !connectTaskRunning
    }
}
