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
/// ★ 实测补充（2026-10-23）：**给 ad-hoc 包补 `keychain-access-groups` 也行不通**——
/// 进程启动时被 AMFI 直接 SIGKILL（签名与受限 entitlement 不匹配）。
/// 所以「不换正式签名也把凭据搬进 DP 钥匙串」这条路是死的，别再试。
///
/// ## 跨构建读取（旧结论已纠正）
///
/// 旧记录称「ad-hoc 每次构建 cdhash 都变，读旧条目必然弹窗」。
/// 本机复测：同一 bundle ID、cdhash 不同的两个包，后建的能改也能读前建写的条目
/// （新增 / 更新 / 读回全部 errSecSuccess）。但**授权记忆是按条目、按 cdhash**：
/// `codesign -d -r-` 显示本包的 designated requirement 就是 `cdhash H"…"`，
/// 换一个版本 cdhash 就换一次身份，ACL 里记的那个「已授权 App」随之作废 ——
/// 用户看到的是「每装一个新版本，每台 NAS 各要确认一次」。
///
/// 对抗手段是**把条目数压到 1 条**（`CredentialVault`）：授权次数跟 NAS 台数脱钩，
/// 不管存了几台，一次启动最多问一次。想彻底不问，只有换稳定签名。
///
/// ## 使用约束
///
/// - **迁移只写不读**：写入后不读回校验，成功与否看返回码。
/// - 不要在启动路径上枚举（`allAccounts` 在合并布局下读的是同一条条目，代价已降到 1 次）。
public struct KeychainSecretStore: SecretStore {

    /// 自动档下，一次「查不到」该怎么继续。
    ///
    /// ## 为什么必须换一层再问
    ///
    /// 真机实测（2026-10-23，ad-hoc 试装包）：
    ///
    ///   SecItemCopyMatching(DP)      → -25300 errSecItemNotFound
    ///   SecItemCopyMatching(经典)    → 0（101 字节，就是存着的那条）
    ///   SecItemAdd(DP)               → -34018 errSecMissingEntitlement
    ///
    /// **写**的时候 DP 直接 -34018，`perform` 会降级到经典并把选择记进
    /// `dataProtection.value`，所以同一次运行里前后都正常。
    /// **读**是新进程的第一件事：先问 DP 拿到的是「找不到」而不是「缺权限」，
    /// 旧实现只认 -34018、不换层，于是明明存着密码却读成 `nil`。
    /// 用户看到的现象正是「彻底退出再打开，两台 NAS 全变成需要重新登录」——
    /// 而且同一次运行里怎么重连都正常，因为那时档位早降过了。
    ///
    /// 「找不到」与「这层根本用不了」都属于**换一层再问一次**的理由，
    /// 其余状态（授权被拒、数据损坏…）不换：那换一层只会再多弹一次窗。
    public enum LookupPolicy {
        /// 这个状态值不值得去另一层再查一次。
        public static func shouldTryTheOtherTier(after status: OSStatus) -> Bool {
            status == errSecItemNotFound || status == errSecMissingEntitlement
        }

        /// 这次失败是不是「用户没授权」（点了拒绝，或被系统挡住没法问）。
        ///
        /// 单列出来是因为**文案完全不同**：这两种情况下密码其实好好地躺在钥匙串里，
        /// 说「本机没有保存密码」会让用户白重输一遍密码，问题却在授权上。
        public static func meansAuthorizationWasRefused(_ status: OSStatus) -> Bool {
            status == errSecUserCanceled
                || status == errSecAuthFailed
                || status == errSecInteractionNotAllowed
                || status == errSecNoAccessForItem
        }
    }

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

    /// 条目怎么摆。
    public enum Layout: Sendable {
        /// 全部凭据收在同一条条目里（`CredentialVault`）。**现行默认**。
        case vault
        /// 一个 account 一条条目。1.1.4 及以前的形式，现在只作为**迁移的来源**存在：
        /// 升级后第一次启动要能把老密码读出来、搬进合并条目，再把老的删掉。
        case perAccount
    }

    private let service: String
    /// 共享钥匙串的访问组。**当前未使用**：App 私有与 App/CLI 共享是两种访问模型，
    /// 需要哪种 entitlement/provisioning 取决于最终访问模型，尚未定。
    private let accessGroup: String?

    private let tier: Tier
    private let layout: Layout
    private let lastStatus = StatusBox()
    private let dataProtection = Box(true)
    /// 合并条目的进程内副本。**只读一次**——这正是「几台 NAS 都只问一次」的由来。
    private let vaultCache = VaultBox()
    /// 解码层面的坏消息（损坏 / 版本过新）。比状态码更准，优先报它。
    private let vaultProblem = ProblemBox()

    public init(service: String = "com.flashfind.v2.credentials", accessGroup: String? = nil) {
        self.init(service: service, accessGroup: accessGroup, tier: .automatic, layout: .vault)
    }

    /// 钉住层级的构造入口。**新增重载而不是给上面的 init 加默认参数**——
    /// 加默认值会让旧的 `init(service:accessGroup:)` 符号消失，
    /// 未重编的调用方在链接期就会报 Undefined symbols。
    public init(service: String = "com.flashfind.v2.credentials",
                accessGroup: String? = nil, tier: Tier) {
        self.init(service: service, accessGroup: accessGroup, tier: tier, layout: .vault)
    }

    public init(service: String = "com.flashfind.v2.credentials",
                accessGroup: String? = nil, tier: Tier, layout: Layout) {
        self.service = service
        self.accessGroup = accessGroup
        self.tier = tier
        self.layout = layout
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

    /// 条目布局。迁移代码用它确认「对面那个实例确实是老式的一 account 一条」。
    public var entryLayout: Layout { layout }

    // MARK: - 读写

    public func save(_ value: String, account: String) throws {
        guard !account.isEmpty else { throw CredentialStoreError.invalidAccount }
        switch layout {
        case .perAccount: return try savePerAccount(value, account: account)
        case .vault: return try saveIntoVault(value, account: account)
        }
    }

    public func read(account: String) -> String? {
        guard !account.isEmpty else { return nil }
        switch layout {
        case .perAccount: return readPerAccount(account: account)
        case .vault: return readFromVault(account: account)
        }
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        guard !account.isEmpty else { return false }
        switch layout {
        case .perAccount: return deletePerAccount(account: account)
        case .vault: return deleteFromVault(account: account)
        }
    }

    /// 列出已存的 account。合并布局下就是**同一条条目里**的键，不再是一次系统授权；
    /// 老式布局仍会触碰授权，所以调用方还是按「不能在启动路径上枚举」来对待。
    public func allAccounts() -> [String] {
        switch layout {
        case .perAccount: return allPerAccountAccounts()
        case .vault:
            guard let vault = decodedVault() else { return [] }
            return vault.accounts
        }
    }

    public var unreadableReason: CredentialStoreProblem? {
        // 解码层面的问题优先：它比状态码更能说明「为什么读不出来」。
        if let problem = vaultProblem.value { return problem }
        guard let status = lastStatus.value, status != errSecSuccess else { return nil }
        // 「没有这条」不是故障：调用方问的就是「有没有」，如实回答即可。
        // 否则每次「没存过密码」都会被上层当成存储坏了。
        if status == errSecItemNotFound { return nil }
        if LookupPolicy.meansAuthorizationWasRefused(status) { return .notAuthorized }
        return .keychain("状态码 \(status)")
    }

    /// 钥匙串后端**不参与枚举审计**：列全部条目曾经要触碰系统授权。
    /// 合并布局下这条已经不那么贵，但审计口径保持不变——少报一条好过悄悄多一次授权。
    public func auditableAccounts() -> [String]? { nil }

    /// 同理：查「在不在」也是一次授权，审计宁可少报一条也不弹窗。
    public func existsForAudit(_ account: String) -> Bool? { nil }

    /// **只探测、不读写任何真实凭据**：往 DP 层写一条探针再删掉。
    ///
    /// 用途是给「经典 → DP」升迁做前置判断：升不上去的时候，先去读一遍经典
    /// 只会白花一次用户授权（每台 NAS 一次），而这一轮注定搬不走任何东西。
    /// 探针落的是 DP 层，缺 entitlement 时返回 -34018，**不会弹任何窗**。
    public func dataProtectionIsWritable() -> Bool {
        // ★ service 必须换一个：探针写完是要删的，用同一个 service 会删到真实凭据那条
        //   （同名条目在 DP 层就是用户密码的落点）。
        let probe = KeychainSecretStore(service: service + ".probe", accessGroup: accessGroup,
                                        tier: .dataProtection, layout: .vault)
        do {
            try probe.save("probe", account: Self.probeAccount)
        } catch {
            return false
        }
        probe.delete(account: Self.probeAccount)
        return true
    }

    /// 探针专用账号名。**不会与真实账号冲突**：真实账号一律带 `nas-source:` / `nas:` 前缀。
    static let probeAccount = "__ff_probe__"

    // MARK: - 合并条目（vault）

    /// 读出并解析合并条目。`nil` = 读不出来或读不懂（原因记在 `vaultProblem`）。
    private func decodedVault() -> CredentialVault? {
        if let cached = vaultCache.value { return cached }
        if vaultProblem.value != nil { return nil }
        var raw: String?
        let status: OSStatus = acrossTiers { protecting in
            var query = baseQuery(account: CredentialVault.itemAccount, dataProtection: protecting)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let code = SecItemCopyMatching(query as CFDictionary, &result)
            if let data = result as? Data { raw = String(data: data, encoding: .utf8) }
            return (code, data: nil as Bool?)
        }.status
        lastStatus.value = status
        switch CredentialVault.decode(raw) {
        case .empty:
            // 条目不存在 ≠ 出错：首次运行、或用户把 NAS 全删了。
            let empty = CredentialVault()
            vaultCache.value = empty
            return empty
        case let .ok(vault):
            vaultCache.value = vault
            return vault
        case let .damaged(problem):
            // ★ 这里**不能**退回空表：空表会在下一次保存时把全部密码覆盖掉（OSS-04）。
            vaultProblem.value = problem
            return nil
        }
    }

    private func readFromVault(account: String) -> String? {
        guard let vault = decodedVault() else { return nil }
        if vault.value(for: account) == nil, vault.isEmpty {
            // 空表且条目本来就不在：保持 errSecItemNotFound，别把「没有」说成「授权失败」。
            lastStatus.value = errSecItemNotFound
        } else {
            lastStatus.value = errSecSuccess
        }
        return vault.value(for: account)
    }

    private func saveIntoVault(_ value: String, account: String) throws {
        guard var vault = decodedVault() else {
            // 读不懂就不写：宁可这次保存失败，也不能拿一份新表盖掉旧密码。
            throw CredentialStoreError.storeUnreadable(vaultProblem.value ?? .undecodable)
        }
        vault.set(value, for: account)
        let status = writeVault(vault)
        lastStatus.value = status
        guard status == errSecSuccess else { throw CredentialStoreError.keychainStatus(status) }
        vaultCache.value = vault
    }

    private func deleteFromVault(account: String) -> Bool {
        guard var vault = decodedVault() else { return false }
        guard vault.value(for: account) != nil else {
            // 本来就没有：不写盘、不改存储，只报「算删掉了」。
            lastStatus.value = errSecItemNotFound
            return true
        }
        vault.remove(account)
        let status: OSStatus = vault.isEmpty ? removeVaultItem() : writeVault(vault)
        lastStatus.value = status
        let done = status == errSecSuccess || status == errSecItemNotFound
        if done { vaultCache.value = vault }
        return done
    }

    /// 把整份 vault 写回钥匙串。先试新增、撞重复再更新——与单条目时代的写法一致。
    private func writeVault(_ vault: CredentialVault) -> OSStatus {
        let data = Data(vault.encoded().utf8)
        return perform { protecting in
            var query = baseQuery(account: CredentialVault.itemAccount, dataProtection: protecting)
            query[kSecValueData as String] = data
            query[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            let added = SecItemAdd(query as CFDictionary, nil)
            guard added == errSecDuplicateItem else { return added }
            return SecItemUpdate(baseQuery(account: CredentialVault.itemAccount,
                                           dataProtection: protecting) as CFDictionary,
                                 [kSecValueData as String: data] as CFDictionary)
        }
    }

    /// 一条都不剩时整条删掉，而不是留一份空表——空表会让「读不到」和「没有」分不清。
    private func removeVaultItem() -> OSStatus {
        switch tier {
        case .dataProtection, .classic:
            return perform { protecting in
                SecItemDelete(baseQuery(account: CredentialVault.itemAccount,
                                        dataProtection: protecting) as CFDictionary)
            }
        case .automatic:
            // 自动档两层都删：条目可能只落在经典那层（`save` 降级写进去的）。
            _ = SecItemDelete(baseQuery(account: CredentialVault.itemAccount,
                                        dataProtection: true) as CFDictionary)
            return perform { protecting in
                SecItemDelete(baseQuery(account: CredentialVault.itemAccount,
                                        dataProtection: protecting) as CFDictionary)
            }
        }
    }

    // MARK: - 老式布局（一 account 一条）—— 只用于迁移来源

    private func savePerAccount(_ value: String, account: String) throws {
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

    private func readPerAccount(account: String) -> String? {
        // 自动档可能查两层（理由见 `LookupPolicy`），钉住档只问自己那层：
        // 升迁要靠「DP 侧到底有没有」来判断，替它换层就把事实藏起来了。
        let outcome: (status: OSStatus, data: Data?) = acrossTiers { protecting in
            var query = baseQuery(account: account, dataProtection: protecting)
            query[kSecReturnData as String] = true
            query[kSecMatchLimit as String] = kSecMatchLimitOne
            var result: CFTypeRef?
            let status = SecItemCopyMatching(query as CFDictionary, &result)
            return (status, result as? Data)
        }
        lastStatus.value = outcome.status
        guard outcome.status == errSecSuccess, let data = outcome.data,
              let value = String(data: data, encoding: .utf8), !value.isEmpty else { return nil }
        return value
    }

    private func deletePerAccount(account: String) -> Bool {
        switch tier {
        case .dataProtection, .classic:
            return finish(perform { protecting in
                SecItemDelete(baseQuery(account: account, dataProtection: protecting) as CFDictionary)
            })
        case .automatic:
            // 自动档**两层都删**，不是「删掉一层就收工」：
            // 条目可能只落在经典那层（`save` 降级写进去的），只删 DP 会返回
            // errSecItemNotFound、看上去成功了，而密码其实还在——
            // 用户关掉「记住这台 NAS 的密码」，本机却仍留着它。
            _ = SecItemDelete(baseQuery(account: account, dataProtection: true) as CFDictionary)
            return finish(SecItemDelete(baseQuery(account: account, dataProtection: false) as CFDictionary))
        }
    }

    private func allPerAccountAccounts() -> [String] {
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

    // MARK: - 内部

    /// 记录最近一次结果，并给出「删掉了 / 本来就没有」的统一判定。
    private func finish(_ status: OSStatus) -> Bool {
        lastStatus.value = status
        // errSecItemNotFound 也算成功：移除来源时会无条件调用。
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// 按档位执行一次查询；自动档在「这一层说没有 / 用不了」时换另一层再问一次。
    ///
    /// 查询动作由调用方注入（`operation`），因此这里**不碰 Security 框架**，
    /// 可以用假闭包做确定性测试——真钥匙串在测试里是禁止触碰的。
    func acrossTiers<T>(_ operation: (Bool) -> (status: OSStatus, data: T?)) -> (status: OSStatus, data: T?) {
        switch tier {
        case .dataProtection: return operation(true)
        case .classic: return operation(false)
        case .automatic: break
        }
        let first = dataProtection.value
        let result = operation(first)
        guard LookupPolicy.shouldTryTheOtherTier(after: result.status) else { return result }
        return operation(!first)
    }

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

    /// 合并条目的进程内副本。`nil` = 还没读过；读出空表也是一个确定结果，
    /// 所以「读过没有」与「内容是什么」必须分开记，否则每次读都会再问一次钥匙串。
    private final class VaultBox: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: CredentialVault?
        private var loaded = false
        var value: CredentialVault? {
            get { lock.lock(); defer { lock.unlock() }; return loaded ? raw : nil }
            set {
                lock.lock()
                raw = newValue
                loaded = newValue != nil
                lock.unlock()
            }
        }
    }

    private final class ProblemBox: @unchecked Sendable {
        private let lock = NSLock()
        private var raw: CredentialStoreProblem?
        var value: CredentialStoreProblem? {
            get { lock.lock(); defer { lock.unlock() }; return raw }
            set { lock.lock(); raw = newValue; lock.unlock() }
        }
    }
}
