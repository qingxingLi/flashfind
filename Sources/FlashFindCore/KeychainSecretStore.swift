import Foundation
import Security

/// 系统钥匙串后端。**GUI App 的默认后端**。
///
/// ## 为什么先 DP 后经典
///
/// Data Protection 钥匙串（`kSecUseDataProtectionKeychain`）要求 App 带
/// `keychain-access-groups` entitlement。本机实测（macOS 15.6，build 24G84）：
/// 试用包走 ad-hoc 签名、**不带**任何 entitlement，此时
///
///   SecItemAdd(DP)  → -34018 errSecMissingEntitlement
///   SecItemAdd(经典) → 0
///
/// 于是这里先按 DP 试；一旦摸到 -34018，就把后续操作整体退到经典钥匙串，
/// 并把 `usesDataProtectionKeychain` 如实报出去。
/// 签好 Developer ID、 entitlement 到位的那一天，DP 自动生效，代码不用动。
///
/// ## 跨构建读取（旧结论已纠正）
///
/// 旧记录称「ad-hoc 每次构建 cdhash 都变，读旧条目必然弹窗」。
/// 本机复测**未复现**：同一 bundle ID、cdhash 不同的两个包，
/// 后建的能改也能读前建写的条目（新增 / 更新 / 读回全部 errSecSuccess，
/// 纯读的第 3 个 cdhash 也没被拦，25 秒内无卡顿）。
/// 判断：ACL 弹窗不是 ad-hoc 的必然结果，不用再为它推迟切 Keychain。
///
/// ## 使用约束
///
/// - **迁移只写不读**：写入后不读回校验，成功与否看返回码。
/// - 不要在启动路径上枚举（`allAccounts` 会碰系统授权）。
public struct KeychainSecretStore: SecretStore {

    /// 走哪一层钥匙串。
    ///
    /// `.automatic` 是日常用的那一档（先 DP、缺 entitlement 自动退经典）。
    /// 另两档**只在升迁时用**：判断「DP 现在到底能不能用」不能靠自动降级——
    /// 一降级就永远看不出 entitlement 已经到位了，升迁也就永远不会发生。
    public enum Tier: Sendable {
        /// 先 DP，摸到 -34018 退经典并记住选择。
        case automatic
        /// 固定走 Data Protection 钥匙串，失败就是失败，不降级。
        case dataProtection
        /// 固定走经典钥匙串。
        case classic
    }

    private let service: String
    /// 共享钥匙串的访问组。**当前未使用**：App 私有与 App/CLI 共享是两种访问模型，
    /// 需要哪种 entitlement/provisioning 取决于最终访问模型，尚未定。
    private let accessGroup: String?

    private let tier: Tier
    private let lastStatus = StatusBox()
    private let dataProtection = Box(true)

    public init(service: String = "com.flashfind.v2.credentials", accessGroup: String? = nil) {
        self.service = service
        self.accessGroup = accessGroup
        self.tier = .automatic
    }

    /// 钉住层级的构造入口。**新增重载而不是给上面的 init 加默认参数**——
    /// 加默认值会让旧的 `init(service:accessGroup:)` 符号消失，
    /// 未重编的调用方在链接期就会报 Undefined symbols。
    public init(service: String = "com.flashfind.v2.credentials",
                accessGroup: String? = nil, tier: Tier) {
        self.service = service
        self.accessGroup = accessGroup
        self.tier = tier
        switch tier {
        case .classic: dataProtection.value = false
        case .automatic, .dataProtection: break
        }
    }

    /// 当前实际走的是不是 Data Protection 钥匙串。诊断与自检用：
    /// 掉到 `false` 说明本机构建缺 entitlement，密码退到了经典钥匙串而不是没存上。
    ///
    /// 钉在 `.dataProtection` 的实例恒为 `true`：它不许降级，失败要如实报出来。
    public var usesDataProtectionKeychain: Bool { dataProtection.value }

    public func save(_ value: String, account: String) throws {
        guard !account.isEmpty else { throw CredentialStoreError.invalidAccount }
        let data = Data(value.utf8)
        let status = perform { protecting in
            var query = baseQuery(account: account, dataProtection: protecting)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecDuplicateItem else { return added }
            return SecItemUpdate(baseQuery(account: account, dataProtection: protecting) as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary)
        }
        lastStatus.value = status
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
    }

    public func read(account: String) -> String? {
        var result: CFTypeRef?
        let status = perform { protecting in
            var query = baseQuery(account: account, dataProtection: protecting)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        lastStatus.value = status
        guard status == errSecSuccess, let data = result as? Data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        let status = perform { protecting in
            SecItemDelete(baseQuery(account: account, dataProtection: protecting) as CFDictionary)
        }
        lastStatus.value = status
        // errSecItemNotFound 也算成功：移除来源时会无条件调用。
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 列出已存的 account。**会触碰系统授权**，不在启动路径上调用。
    public func allAccounts() -> [String] {
        var result: CFTypeRef?
        let status = perform { protecting in
            var query = baseQuery(dataProtection: protecting)
            query[kSecReturnAttributes as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitAll
            return SecItemCopyMatching(query as CFDictionary, &result)
        }
        lastStatus.value = status
        guard status == errSecSuccess, let items = result as? [[String: Any]] else { return [] }
        return items.compactMap { $0[kSecAttrAccount as String] as? String }.sorted()
    }

    public var unreadableReason: CredentialStoreProblem? {
        guard let status = lastStatus.value, status != errSecSuccess else { return nil }
        return .keychain("状态码 \(status)")
    }

    /// 钥匙串后端**不参与枚举审计**：列全部条目要触碰系统授权。
    public func auditableAccounts() -> [String]? { nil }

    /// 同理：查「在不在」也是一次授权，审计宁可少报一条也不弹窗。
    public func existsForAudit(_ account: String) -> Bool? { nil }

    // MARK: - 内部

    /// 先按 DP 跑，摸到缺 entitlement 就退到经典钥匙串重试一次，并记住选择。
    ///
    /// 钉住层级的两档**不走这条降级路**：升迁要靠「DP 真的写成功了吗」来判断，
    /// 一降级就把 entitlement 到位这件事永远藏起来了。
    private func perform(_ operation: (Bool) -> OSStatus) -> OSStatus {
        switch tier {
        case .dataProtection: return operation(true)
        case .classic: return operation(false)
        case .automatic: break
        }
        let protecting = dataProtection.value
        let status = operation(protecting)
        guard status == errSecMissingEntitlement, protecting else { return status }
        dataProtection.value = false
        return operation(false)
    }

    private func baseQuery(account: String? = nil, dataProtection protecting: Bool) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
        ]
        if protecting { query[kSecUseDataProtectionKeychain as String] = true }
        if let account { query[kSecAttrAccount as String] = account }
        if let accessGroup { query[kSecAttrAccessGroup as String] = accessGroup }
        return query
    }

    private final class StatusBox: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: OSStatus?
        var value: OSStatus? {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: Bool
        init(_ value: Bool) { raw = value }
        var value: Bool {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }
}
