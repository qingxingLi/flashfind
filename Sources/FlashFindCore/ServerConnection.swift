import Foundation

public struct HTTPFailure: LocalizedError {
    public let status: Int
    public let code: String?
    public init(status: Int, code: String? = nil) { self.status = status; self.code = code }
    public var errorDescription: String? {
        switch status {
        case 401: return "NAS 账号或密码无效，或登录已过期"
        case 403: return "当前账号无权访问该目录"
        case 409: return "索引或权限已更新，请重新同步"
        case 429: return "登录尝试过多，请稍后再试"
        case 503 where code == "setup_required": return "NAS 索引服务尚未初始化，请先在管理页面完成初始化"
        case 503: return "暂时无法验证 NAS 文件权限，请检查 SMB 服务后重试"
        default: return "服务器返回 HTTP \(status)"
        }
    }
}

/// 凭据存储的**门面**，实现已迁到 `CredentialStore`（本机凭据文件）。
///
/// 名字保留 `SecureStorage` 而不改：它是 20 多处既有调用的入口，
/// 逐处改名换不来任何行为收益，只会把这一轮的改动面撑大。
/// 只把实现换掉 —— 语义（`save` / `read` / `delete`、读不到返回 nil）与钥匙串时代完全一致，
/// 因此调用方一行都不用动。
///
/// 实现已迁到 `CredentialStore`，后端由 App 装配（GUI 走系统钥匙串）。
///
/// 历史判断的来龙去脉见 `KeychainSecretStore`： 本机复测纠正了
/// 「ad-hoc 换 cdhash 必然弹窗」这条旧结论；真正的硬门槛是 Data Protection
/// 钥匙串要 entitlement，缺了会自动退到经典钥匙串（见同名文件的实测状态码）。
public enum SecureStorage {
    /// - Parameter reason: 哪一步动的（诊断用）。见 `CredentialStore.Mutation`。
    public static func save(_ value: String, account: String,
                            identity: CredentialIdentity? = nil,
                            reason: String = "未标注") throws {
        try CredentialStore.save(value, account: account, identity: identity, reason: reason)
    }
    /// 只有用户主动登录才传 true；默认只读取已解锁的进程内钥匙串缓存。
    ///
    /// `identity` 非空时按信封校验归属：**与目标不匹配的凭据视同不存在**。
    public static func read(account: String, identity: CredentialIdentity? = nil,
                            allowInteraction: Bool = false) -> String? {
        CredentialStore.read(account: account, identity: identity, allowInteraction: allowInteraction)
    }
    /// 删除已保存的凭据。移除 NAS 时调用，避免文件里留下无人认领的条目。
    ///
    /// - Parameter reason: 哪一步动的（诊断用）。
    @discardableResult
    public static func delete(account: String, reason: String = "未标注") -> Bool {
        CredentialStore.delete(account: account, reason: reason)
    }
}
