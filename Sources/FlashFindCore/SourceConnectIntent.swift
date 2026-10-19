import Foundation

/// 逐来源的「连接意图」登记。
///
/// ## 为什么必须有它
///
/// 「连接一台 NAS」在 App 里不是原子的：静默自动连接与向导都会**先建一个
/// Provider**，走完 `discover → login → selectScopes`，最后才把它 `install` 给
/// 连接管理器。中间每一个 `await` 都可能跨过用户点「断开」的那一刻。
///
/// 只关掉管理器里当前那个实例是不够的：那条在飞的连接握着**另一个**实例，
/// 它晚到的成功照样会 `install`。而 `install` 会发布「Provider 集合变化」，
/// 上层据此整体重建搜索协调器 —— 于是：
///   * 刚被用户断开的 B 重新变回「已连接」（复活）；
///   * **其它来源在飞的查询被一起取消**（这才是用户看到的「全部断开」）。
///
/// ## 语义
///
/// 每次连接开始 `begin(config)` 拿到一张凭证；用户点「断开」时
/// `invalidate(sourceID)` 把该来源的代次 +1，所有在飞的旧凭证立刻作废。
/// 代次**单调递增**，所以后来重新发起的新连接拿到的是更大的代次，
/// 不会被上一次的作废误伤 —— 这就是「清理不能伤到后来的同 sourceID 新会话」。
///
/// 凭证里同时带上**配置指纹**（主机 / 端口 / 账号 / 品牌 / 协议，不含搜索位置）：
/// 连接进行中用户把地址或账号改掉了，那次连接的目标已经不是现在的配置，
/// 走到 install 之前必须发现这一点（否则会把 A 机器的密码拿去连 B 机器）。
public final class SourceConnectIntent {

    /// 一次连接尝试的凭证。
    public struct Token: Equatable, Sendable {
        public let sourceID: String
        public let epoch: UInt64
        /// 连接开始时的配置指纹。
        public let fingerprint: String
        public init(sourceID: String, epoch: UInt64, fingerprint: String) {
            self.sourceID = sourceID; self.epoch = epoch; self.fingerprint = fingerprint
        }
    }

    private var epochs: [String: UInt64] = [:]

    public init() {}

    /// 开始一次连接尝试，拿到本轮凭证。
    @discardableResult
    public func begin(_ config: NASSourceConfig) -> Token {
        let next = (epochs[config.sourceID] ?? 0) &+ 1
        epochs[config.sourceID] = next
        return Token(sourceID: config.sourceID, epoch: next, fingerprint: Self.fingerprint(config))
    }

    /// 作废某来源的全部在飞连接意图。用户点「断开」时同步调用。
    ///
    /// - Returns: 作废后的代次（仅供诊断）。
    @discardableResult
    public func invalidate(_ sourceID: String) -> UInt64 {
        let next = (epochs[sourceID] ?? 0) &+ 1
        epochs[sourceID] = next
        return next
    }

    /// 这张凭证现在还有效吗？
    ///
    /// - Parameters:
    ///   - token: `begin` 时拿到的凭证。
    ///   - config: 该来源**现在**的配置。传入时一并核对配置指纹；
    ///     传 `nil` 表示只核对代次。
    public func isCurrent(_ token: Token, config: NASSourceConfig?) -> Bool {
        guard epochs[token.sourceID] == token.epoch else { return false }
        guard let config else { return true }
        return Self.fingerprint(config) == token.fingerprint
    }

    /// 只核对代次的便捷入口。
    public func isCurrent(_ token: Token) -> Bool { isCurrent(token, config: nil) }

    /// 连接目标指纹。**刻意不含搜索位置**：连接流程本身会写回 scopes
    /// （`performConnectQuietly` / `finishLogin` 都会），把 scopes 算进来会让
    /// 每一次连接都自我作废。
    public static func fingerprint(_ config: NASSourceConfig) -> String {
        [config.hostName,
         String(config.effectivePort),
         config.username,
         config.vendor.rawValue,
         config.usesPlainHTTP ? "http" : "https"].joined(separator: "|")
    }
}
