import Foundation

/// 凭据门面。20 余处调用点只认它，换后端不动调用点。
///
/// ## 后端装配
///
/// - GUI App：`KeychainSecretStore`（**默认，也是 Release 的默认后端**）。
/// - 测试：`InMemorySecretStore`，或带临时目录的 `FileSecretStore`。
/// - 命令行工具：`FileSecretStore`。它只是迁移/开发工具，**不再充任正式 App 的默认后端**。
///
/// 两条必须守住的保护：
/// - **OSS-04** 读不出来就拒绝写入，绝不拿空表覆盖其余 NAS 的密码。
/// - **OSS-05** 落盘走原子替换，不留「凭据文件不存在」的窗口。
///
/// 身份绑定见 `CredentialIdentity`：带 `identity` 读写时，归属不匹配的凭据视同不存在。
public enum CredentialStore {

    // MARK: - 后端装配

    private static let lock = NSLock()
    private static var backend: SecretStore = InMemorySecretStore()
    /// 旧明文文件（`credentials.json`）的读取端。只在迁移期间有意义：
    /// 默认后端换成钥匙串之后，`backend` 不再是文件，迁移还需要另一个入口才能读到待迁移的明文。
    private static var plaintextArchive: FileSecretStore?

    /// 装配后端。
    ///
    /// - Parameter plaintextSource: 旧明文所在的文件后端。切到非文件后端（钥匙串）时必须传，
    ///   否则迁移读不到源头的明文。
    public static func install(_ store: SecretStore, plaintextSource: FileSecretStore? = nil) {
        lock.lock()
        backend = store
        plaintextArchive = plaintextSource
        lock.unlock()
    }

    /// 装配文件后端。`nil` = 默认目录（`~/Library/Application Support/FlashFind2`）。
    public static func useDirectory(_ url: URL?) {
        let file = FileSecretStore(directory: url)
        install(file, plaintextSource: file)
    }

    /// 当前后端名，仅供诊断显示。
    public static var backendName: String {
        lock.lock(); defer { lock.unlock() }
        switch backend {
        case is FileSecretStore: return "file"
        case is KeychainSecretStore: return "keychain"
        default: return "inMemory"
        }
    }

    /// 当前文件落点。非文件后端时给默认路径，便于界面与测试说明「会写到哪儿」。
    public static var fileURL: URL {
        lock.lock(); defer { lock.unlock() }
        if let file = backend as? FileSecretStore { return file.fileURL }
        return FileSecretStore.defaultDirectory.appendingPathComponent("credentials.json")
    }

    // MARK: - 变更审计

    /// 一次**真实落盘**的凭据变更（没写进去就不算，例如删一条本来就不存在的）。
    ///
    /// 为什么需要它： 实测到凭据文件被写成空表，而这条路径只能由「删掉最后一条
    /// 已存在记录」产生，三个删除入口留下的文件一模一样，事后无法判断是谁动的。
    /// 记录内容只有四项，**不含密码也不含账号名**。
    public struct Mutation: Sendable, Equatable {
        public enum Operation: String, Sendable { case save, delete }
        public let operation: Operation
        /// 脱敏后的键：去掉 `nas-source:` / `nas:` 前缀。
        public let sourceKey: String
        public let storedCount: Int
        public let reason: String
    }

    /// 变更观察者（诊断用）。实现方不得抛错或阻塞。
    public static var onMutation: ((Mutation) -> Void)?

    public static func sourceKey(_ account: String) -> String {
        for prefix in [CredentialAccount.sourcePrefix, CredentialAccount.profilePrefix]
        where account.hasPrefix(prefix) {
            return String(account.dropFirst(prefix.count))
        }
        return account
    }

    // MARK: - 对外接口

    /// 保存密文。`identity` 非空时连归属一起封进信封（见 `CredentialEnvelope`）。
    public static func save(_ value: String, account: String,
                            identity: CredentialIdentity? = nil,
                            reason: String = "未标注") throws {
        guard !account.isEmpty else { throw CredentialStoreError.invalidAccount }
        lock.lock(); let store = backend; lock.unlock()
        let payload = identity.map { CredentialEnvelope.wrap(value, identity: $0) } ?? value
        try store.save(payload, account: account)
        report(.init(operation: .save, sourceKey: sourceKey(account),
                     storedCount: count(after: store), reason: reason))
    }

    /// 读出密文。**身份不匹配时返回 `nil`**——旧要与新目标不符就是不存在的凭据。
    public static func read(account: String, identity: CredentialIdentity? = nil,
                            allowInteraction: Bool = false) -> String? {
        _ = allowInteraction
        lock.lock(); let store = backend; lock.unlock()
        guard let raw = store.read(account: account), !raw.isEmpty else { return nil }
        guard let identity else { return raw }
        return CredentialEnvelope.unwrap(raw, identity: identity)
    }

    @discardableResult
    public static func delete(account: String, reason: String = "未标注") -> Bool {
        lock.lock(); let store = backend; lock.unlock()
        // 删一条本来就不存在的**不改存储**，因此不该报变更——它解释不了文件为什么变空。
        let existed = store.existsForAudit(account)
        let removed = store.delete(account: account)
        if removed && (existed ?? false) {
            report(.init(operation: .delete, sourceKey: sourceKey(account),
                         storedCount: count(after: store), reason: reason))
        }
        return removed
    }

    public static var storedAccountCount: Int {
        lock.lock(); defer { lock.unlock() }
        return backend.auditableAccounts()?.count ?? 0
    }

    /// 后端为何读不出来（`nil` = 可读）。界面据此解释「为什么勾了记住却没存上」。
    public static var currentProblem: CredentialStoreProblem? {
        lock.lock(); defer { lock.unlock() }
        return backend.unreadableReason
    }

    // MARK: - 来源生命周期

    /// 关掉「记住这台 NAS 的密码」：**立刻**删掉已存的凭据。
    ///
    /// 只看 flag 不删条目时，用户以为「不保存了」，实际密码还在后端里，
    /// 下次自动连接仍会拿去用——界面上完全看不出来。
    ///
    /// 这里按**目标状态**判定而不是「有没有变化」：要求是
    /// `rememberPassword == false ⇒ 本机不存在这条凭据`，无条件的。
    /// 返回是否真的删掉了东西（本来没存则 false）。
    @discardableResult
    public static func applyRememberPassword(_ remember: Bool, config: NASSourceConfig) -> Bool {
        guard !remember else { return false }
        return delete(account: config.credentialAccount,
                      reason: "用户关掉了「记住这台 NAS 的密码」")
    }

    /// 移除 NAS 来源：清理凭据，**不看** `rememberPassword`。
    ///
    /// 用户可能先勾了「保存密码」、后来取消勾选——那时 flag 已是 false，
    /// 但历史密码还留在后端，跟着来源 ID 一起变成无人认领的孤儿。
    @discardableResult
    public static func removeSource(_ config: NASSourceConfig) -> Bool {
        delete(account: config.credentialAccount, reason: "来源已被用户移除")
    }

    // MARK: - 旧键规则条目的清理

    /// 清掉同一目标在**旧键规则**下的那条副本。
    ///
    /// 1.0 时期凭据按 `<地址>|<账号>` 存（`CredentialAccount.legacy`），新键是 `nas-source:<id>`。
    /// 换键之后旧条目不会自己消失：它不含来源 ID，于是「删来源」「关记住密码」
    /// 两条删除路径都点不到它——用户以为密码已清干净，钥匙串里其实还留着一份。
    ///
    /// 两个前提，缺一不可：
    /// - **只能按已知键定点删**。钥匙串**不能枚举**（`allAccounts` 会触碰系统授权），
    ///   所以找不出「现在有哪些孤儿」，只能由握着旧键的一方（连接档案的
    ///   `legacyCredentialAccount`）指名删除。
    /// - **只能在新键那一份确认写进去之后调用**。本函数不读新键（读 = 一次授权），
    ///   因此它无法自证「新的一份确实在」；顺序搞反就变成删掉唯一副本。
    ///
    /// - Returns: 是否真的删掉了东西。
    @discardableResult
    public static func removeLegacyItem(_ legacyAccount: String?,
                                        migratedTo account: String,
                                        reason: String = "未标注") -> Bool {
        guard let legacyAccount, !legacyAccount.isEmpty else { return false }
        // 新旧是同一个键：新键那次删除已经处理过了。再删一次不但多报一条变更，
        // 更要紧的是——此时「旧键」就是刚写进去的那份活凭据，删它等于清掉唯一副本。
        guard legacyAccount != account else { return false }
        return delete(account: legacyAccount, reason: reason)
    }

    // MARK: - 迁移（明文 → 其它后端）

    /// 把旧明文文件里的凭据写入当前后端。
    ///
    /// 「一次性」由两手保证：写入成功的 account 会被标记待验证（存进明文文件），
    /// 下次跳过；验证成功之后明文连这条记录一起消失，可迁移的自然为 0。
    ///
    /// 报告可以丢弃：迁移本身可重入，这次没迁成的下次启动会再试一遍，
    /// 不消费返回值不会让凭据两头落空（那条保证由 `confirmCredentialVerified` 负责）。
    @discardableResult
    public static func migrateLegacyPlaintext() -> CredentialMigration.Report {
        lock.lock()
        let store = backend
        let archive = plaintextArchive ?? (store as? FileSecretStore)
        lock.unlock()
        guard let source = archive, !source.allAccounts().isEmpty else { return .init() }
        // 目标就是自己时不迁：那等于把明文拷给明文，什么也没发生。
        if let file = store as? FileSecretStore, file === source { return .init() }
        return CredentialMigration.migrate(from: source, to: store)
    }

    /// 登录成功后调用：证明新后端的密码能用，于是删掉这条明文副本。
    ///
    /// 这是「明文删在最后」的另一半——没有真实登录作证，旧明文绝不先删。
    /// 全部迁完之后，`credentials.json` 会被整个删掉，而不是留一个空文件。
    @discardableResult
    public static func confirmCredentialVerified(_ account: String) -> Bool {
        lock.lock()
        let store = backend
        let archive = plaintextArchive ?? (store as? FileSecretStore)
        lock.unlock()
        guard let file = archive else { return false }
        // 没被标记过待验证 = 还没成功写进新后端。此时删明文等于让密码两头落空。
        guard file.pendingVerification.contains(account) else { return false }
        let dropped = file.dropPlaintextAfterVerification(account)
        guard dropped, file.allAccounts().isEmpty, file.pendingVerification.isEmpty else { return dropped }
        // 后端不是它自己，说明它只是「待迁移的旧明文」，腾空之后整个删除。
        if let fileBackend = store as? FileSecretStore, fileBackend === file { return dropped }
        return (try? file.removeStorageFile()) != nil
    }

    public static var pendingVerification: Set<String> {
        lock.lock()
        let store = backend
        let archive = plaintextArchive ?? (store as? FileSecretStore)
        lock.unlock()
        return archive?.pendingVerification ?? []
    }

    // MARK: - 层级升迁（经典钥匙串 → Data Protection 钥匙串）

    /// 把指名的凭据从经典钥匙串升到 Data Protection 钥匙串。
    ///
    /// **这一条登记在这里，是为了不让它被忘掉**：今天所有构建都缺
    /// `keychain-access-groups` entitlement，于是它每次都会因为 -34018 整批中止、
    /// 什么也不做；等签上 Developer ID 的那一天，同一份代码就会真的把老密码搬过去，
    /// 用户不用重输。规则与顺序见 `KeychainTierMigration`。
    ///
    /// - Parameter accounts: 要搬的 account。**钥匙串不能枚举**，
    ///   调用方（它握着 NAS 来源列表）必须自己指名。
    /// - Returns: 空报告 = 没有可升迁的东西（后端不是钥匙串 / 没有 account）。
    @discardableResult
    public static func migrateKeychainTier(accounts: [String]) -> KeychainTierMigration.Report {
        lock.lock(); let store = backend; lock.unlock()
        // 只有钥匙串后端才有「层级」这回事。文件后端与内存后端直接跳过，
        // 免得把「读经典侧」这套语义套到别的存储上。
        guard store is KeychainSecretStore, !accounts.isEmpty else { return .init() }
        return KeychainTierMigration.migrate(
            from: KeychainSecretStore(tier: .classic),
            to: KeychainSecretStore(tier: .dataProtection),
            accounts: accounts)
    }

    /// 已写入目标后端、但还没被真实登录验证过的 account。
    public static func migratePlaintextTo(_ destination: SecretStore) -> CredentialMigration.Report {
        lock.lock()
        let store = backend
        let archive = plaintextArchive ?? (store as? FileSecretStore)
        lock.unlock()
        guard let source = archive else { return .init() }
        return CredentialMigration.migrate(from: source, to: destination)
    }

    // MARK: - 内部

    private static func count(after store: SecretStore) -> Int {
        store.auditableAccounts()?.count ?? 0
    }

    /// 在锁外调用：观察者是外部代码，不能握着锁回调。
    private static func report(_ mutation: Mutation) {
        guard let onMutation else { return }
        onMutation(mutation)
    }
}

public enum CredentialStoreError: LocalizedError {
    case invalidAccount
    case writeFailed
    /// 存储读不出来，因此**没有写入**（OSS-04）。
    case storeUnreadable(CredentialStoreProblem)
    /// 钥匙串操作失败。带状态码好定位是权限还是 entitlement。
    case keychainStatus(OSStatus)

    public var errorDescription: String? {
        switch self {
        case .invalidAccount: return "凭据账号名不能为空"
        case .writeFailed: return "无法写入本机凭据存储"
        case let .storeUnreadable(problem):
            // 结尾半句是关键：必须说清「没写入」是**保护**而不是故障，
            // 否则用户会以为是磁盘坏了，转手把文件删掉——那才是真丢。
            return problem.summary + "。为避免覆盖已保存的密码，这次没有写入。"
        case let .keychainStatus(status):
            return "系统钥匙串操作失败（状态码 \(status)）"
        }
    }
}
