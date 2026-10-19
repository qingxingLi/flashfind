import Foundation

/// 核心进程重启后，把一台已经连过的 NAS 重新连上（P1-03）。
///
/// 重放顺序必须与手工连接完全一致：
///
/// ```text
/// discover（能力协商 / 证书握手）
///     ↓
/// login（身份）
///     ↓
/// selectScopes（重新绑定此前选好的搜索位置）
/// ```
///
/// 三步缺一不可。`discover` 只代表「设备在线」，`login` 只代表「身份通过」，
/// 少了最后一步核心就会拒绝搜索（范围未绑定）——
/// 这也是 `NASSearchProvider.login` 之后 `ready` 仍可能为 false 的原因。
@MainActor public enum NASAutoReconnect {
    public struct Credential: Sendable {
        public let account: String
        public let password: String
        public let otp: String?
        public init(account: String, password: String, otp: String? = nil) {
            self.account = account; self.password = password; self.otp = otp
        }
        /// 凭据是否完整可用。缺任一项都不许拿去撞设备——
        /// 空密码撞上去只会触发设备侧的防暴力破解封禁。
        public var isUsable: Bool { !account.isEmpty && !password.isEmpty }
    }

    /// 重放一次连接。**返回是否恢复到「可搜索」**，不含任何「大概好了」的中间态。
    ///
    /// - 没有选过搜索位置 ⇒ 直接放弃：无从恢复，交给用户。
    /// - 证书固定需要人工确认时 ⇒ 放弃（见下）。
    public static func recover(
        _ provider: NASSearchProvider,
        credential: () -> Credential?,
        log: ((String) -> Void)? = nil
    ) async -> Bool {
        let scopes = provider.config.scopes
        guard !scopes.isEmpty else {
            log?("跳过自动重连：这台 NAS 从未选定搜索位置，无从恢复")
            return false
        }
        guard let credential = credential(), credential.isUsable else {
            log?("跳过自动重连：本机没有这台 NAS 的可用凭据")
            return false
        }
        do {
            let response = try await provider.discover()
            // 群晖走证书固定：若核心要求重新确认证书，这一步会拿到 trustState。
            // 证书指纹变了必须由用户看一眼再决定，无人值守地"自动信任"
            // 等于把中间人攻击自动化——所以这里放弃，如实交给用户。
            if let event = response["event"] as? String, event == "trustState" {
                log?("自动重连中止：设备要求确认证书指纹，需用户手动连接")
                return false
            }
            try await provider.login(account: credential.account, password: credential.password, otp: credential.otp)
            let ready = try await provider.selectScopes(scopes)
            log?(ready ? "自动重连成功：范围已重新绑定 \(scopes.joined(separator: ", "))"
                       : "自动重连失败：核心未确认搜索范围")
            return ready
        } catch {
            log?("自动重连失败：\(error.localizedDescription)")
            return false
        }
    }
}
