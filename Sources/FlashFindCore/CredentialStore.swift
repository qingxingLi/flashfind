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

    /// 一次**允许与系统交互**的读刚刚结束（`allowInteraction: true`）。
    ///
    /// 为什么 Core 要报这件事：钥匙串 ACL 不认这个包时，系统会弹框要密码。
    /// **框一关，系统把激活还给先前活跃的另一个 App**，我们的窗口就被压到它后面。
    /// 现场（2026-10-26，1.1.17 build 54）：点「登录」→ 输密码点「始终允许」→
    /// 整块界面在 125ms 内消失。查统一日志才发现**进程活着**
    /// （`running-active-NotVisible`）、窗口也没关（没有 AppKit 的 `finishing close`），
    /// 只是被前台那个 App 的窗口盖住了 —— 用户只会说「闪退了」。
    ///
    /// 救窗口是 AppKit 的事，Core 不引入 AppKit，所以只把「刚发生过」报出去，
    /// 由 App 层 `bringPreferencesForwardAfterSystemPrompt()` 决定怎么办。
    ///
    /// 与 `onMutation` 一样：实现方不得抛错或阻塞；成功、用户点拒绝、读不到，
    /// 三种情况都要报 —— 因为三种情况下那个框都弹过、都可能把窗口甩到后面。
    public static var onInteractiveRead: (() -> Void)?

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
        guard !account.isEmpty else { return nil }
        // ★ 用 defer 报，不写在成功分支后面：用户点「拒绝」、密码读不出来时
        //   那个授权框一样弹过，窗口一样被甩到后面 —— 那两种情况更需要救。
        defer { if allowInteraction { onInteractiveRead?() } }
        lock.lock(); let store = backend; lock.unlock()
        var value = store.read(account: account, allowInteraction: allowInteraction)
        if value == nil, allowInteraction, store is KeychainSecretStore,
           store.unreadableReason == nil {
            // 旧凭据按当前登录的账号迁移；启动、设置渲染和自动重连均不会进入这里。
            migrateLegacyPlaintext()
            guard store.unreadableReason == nil else { return nil }
            consolidateIntoVault(accounts: [account])
            migrateKeychainTier(accounts: [account])
            value = store.read(account: account, allowInteraction: true)
        }
        guard let raw = value, !raw.isEmpty else { return nil }
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

    /// 把老布局（一台 NAS 一条条目）搬进合并条目。**升级后第一次启动调用一次**。
    ///
    /// 不搬的代价不是「多几条记录」：系统钥匙串的授权是按条目、按 App 的 cdhash 记的，
    /// 所以每装一个新版本，每一条老条目都要再问一次用户。合并之后问几次与 NAS 台数无关。
    ///
    /// 后端不是钥匙串、或已经是合并布局时，返回空报告（什么都不做）。
    ///
    /// - Parameter accounts: 要搬的 account。**钥匙串不能枚举**，由调用方指名。
    @discardableResult
    public static func consolidateIntoVault(accounts: [String]) -> VaultConsolidation.Report {
        lock.lock(); let store = backend; lock.unlock()
        guard let keychain = store as? KeychainSecretStore,
              keychain.entryLayout == .vault, !accounts.isEmpty else { return .init() }
        return VaultConsolidation.run(
            from: KeychainSecretStore(tier: .automatic, layout: .perAccount),
            to: keychain,
            accounts: accounts)
    }

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
        guard let keychain = store as? KeychainSecretStore, !accounts.isEmpty else { return .init() }
        // ★ 先确认 DP 写得进去，再去读经典。
        //
        // 顺序反了就是每次启动白读一遍经典钥匙串——而读 = 一次系统授权弹窗，
        // 每台 NAS 一次。今天所有构建都缺 entitlement，探针必然失败，
        // 于是这一步直接返回，用户一次弹窗都不用为「注定搬不走」的迁移付账。
        guard keychain.dataProtectionIsWritable() else { return .init() }
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
