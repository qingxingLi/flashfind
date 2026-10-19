import XCTest
@testable import FlashFindCore

/// 凭据生命周期的行为证据。
///
/// 这一组回答一个具体问题：**密码在什么时候必须消失、又必须还在**。
/// 三个方向：
/// - 目标换了（地址 / 端口 / 账号）→ 旧密码不再属于它，必须读不出来；
/// - 用户改主意了（关掉记住、删掉来源）→ 必须立刻清掉，不能留孤儿；
/// - 迁移途中 → 明文只能删在「新后端写入成功 + 真实登录验证成功」之后。
///
/// 全程走 `InMemorySecretStore`：**测试不碰真钥匙串**（见 NoKeychainAccessTests 的同名闸口）。
final class CredentialLifecycleTests: XCTestCase {

    private var directory: URL!
    private var backend: InMemorySecretStore!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-lifecycle-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        backend = InMemorySecretStore()
        CredentialStore.install(backend)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
        CredentialStore.install(InMemorySecretStore())
    }

    private func source(host: String = "nas-a.example", port: Int = 5000,
                        username: String = "alice") -> NASSourceConfig {
        NASSourceConfig(id: "固定的来源ID", host: host, port: port, username: username)
    }

    // MARK: - 目标变了不许复用旧凭据

    func testChangingHostDoesNotReuseTheOldCredential() throws {
        let original = source()
        try CredentialStore.save("s3cret", account: original.credentialAccount,
                                 identity: original.credentialIdentity)
        XCTAssertEqual(CredentialStore.read(account: original.credentialAccount,
                                            identity: original.credentialIdentity), "s3cret")

        let moved = source(host: "nas-b.example")
        XCTAssertNil(CredentialStore.read(account: moved.credentialAccount,
                                         identity: moved.credentialIdentity),
                     "换了目标地址还能读到旧密码 —— 那把密码属于原来那台设备，会被拿去连别人")
    }

    func testChangingPortDoesNotReuseTheOldCredential() throws {
        let original = source()
        try CredentialStore.save("s3cret", account: original.credentialAccount,
                                 identity: original.credentialIdentity)

        let moved = source(port: 5001)
        XCTAssertNil(CredentialStore.read(account: moved.credentialAccount,
                                         identity: moved.credentialIdentity),
                     "端口也是目标的一部分：同一台机换个端口可能就是另一套服务（5000/5001 常是不同的东西）")
    }

    func testChangingUsernameDoesNotReuseTheOldCredential() throws {
        let original = source()
        try CredentialStore.save("s3cret", account: original.credentialAccount,
                                 identity: original.credentialIdentity)

        let moved = source(username: "bob")
        XCTAssertNil(CredentialStore.read(account: moved.credentialAccount,
                                         identity: moved.credentialIdentity),
                     "换了账号还拿着前一个账号的密码去连，等于凭前人的身份进门")
    }

    /// 上面三条成立的前提：identity 真的由三要素派生，而不是被某处写死了。
    func testIdentityFingerprintFollowsAllThreeFields() {
        XCTAssertNotEqual(source().credentialIdentity.fingerprint,
                          source(host: "nas-b.example").credentialIdentity.fingerprint)
        XCTAssertNotEqual(source().credentialIdentity.fingerprint,
                          source(port: 5001).credentialIdentity.fingerprint)
        XCTAssertNotEqual(source().credentialIdentity.fingerprint,
                          source(username: "bob").credentialIdentity.fingerprint)
        XCTAssertEqual(source().credentialIdentity,
                       source().credentialIdentity, "同样的三要素必须得到同样的身份")
    }

    /// 大小写与首尾空白不该被当成换目标：`NAS-A.example ` 与 `nas-a.example` 是同一台。
    func testIdentityIgnoresCaseAndSurroundingWhitespace() {
        XCTAssertEqual(source(host: "  NAS-A.example  ").credentialIdentity.fingerprint,
                       source(host: "nas-a.example").credentialIdentity.fingerprint)
    }

    /// 摘要算法锁：SHA-256 的已知向量。
    ///
    /// 这一条同时挡住两种退化：
    /// - 换回 FNV-1a 之类的非密码学哈希 → 值不再是这串，立刻红；
    /// - 换成 `Hasher` → 值每次进程都变，同样立刻红（这正是「重启后凭据全丢」的成因）。
    ///
    /// 向量来源：canonical = `host \x1F port \x1F username`（已 trim + 小写），
    /// 即 `nas-a.example` + 0x1F + `5000` + 0x1F + `alice` 的 SHA-256。
    func testIdentityFingerprintIsSHA256OverTheCanonicalForm() {
        XCTAssertEqual(source().credentialIdentity.fingerprint,
                       "fb929937d43bf22d47e596e8cf73b486a3f6f82001642537cd2ce60a91fbf1af")
        XCTAssertEqual(source(host: "nas-b.example").credentialIdentity.fingerprint,
                       "7e7c6bc10d190f9335d420d4d525fae6cc725ab6e801e2bcd4f33a44d2153675")
    }

    /// 形态锁：64 位小写十六进制。少了/多了都说明摘要算法被换过或被截断。
    func testIdentityFingerprintIsA64CharacterLowercaseHexDigest() {
        let digest = source().credentialIdentity.fingerprint
        XCTAssertEqual(digest.count, 64)
        XCTAssertTrue(digest.allSatisfy { ($0 >= "0" && $0 <= "9") || ($0 >= "a" && $0 <= "f") },
                      "摘要必须是小写十六进制，实际是 \(digest)")
    }

    /// 历史裸密文（没有信封）不能冒充这条目标的凭据：它可能来自另一台设备。
    func testLegacyPlainValueNeverSatisfiesAnIdentity() throws {
        let account = source().credentialAccount
        try CredentialStore.save("老版本直接写的裸密码", account: account)
        XCTAssertNil(CredentialStore.read(account: account,
                                          identity: source().credentialIdentity),
                     "裸密文没有归属地，拿来就用等于把旧设备的密码送去新的目标")
    }

    // MARK: - 旧键规则条目的清理

    /// 1.0 的旧键（`<地址>|<账号>`）不含来源 ID，两条删除路径都点不到它。
    /// 这里给出「指名删除」这条唯一可行的清理路径，并锁住它不许误伤新键那一份。
    private func legacyAccount(for config: NASSourceConfig) -> String {
        CredentialAccount.legacy(address: "https://\(config.hostName):\(config.effectivePort)",
                                 username: config.username)
    }

    func testLegacyCopyIsRemovedOnceTheNewKeyHoldsThePassword() throws {
        let config = source()
        let legacy = legacyAccount(for: config)
        // 旧键那条是 1.0 写的裸密文（没有信封），这正是存量数据的真实形态。
        try CredentialStore.save("s3cret", account: legacy)
        try CredentialStore.save("s3cret", account: config.credentialAccount,
                                 identity: config.credentialIdentity)

        XCTAssertTrue(CredentialStore.removeLegacyItem(legacy, migratedTo: config.credentialAccount,
                                                       reason: "旧键规则的副本已由新键接管"))
        XCTAssertNil(CredentialStore.read(account: legacy),
                     "旧键那条必须消失：它成了删来源也删不掉的孤儿")
        XCTAssertEqual(CredentialStore.read(account: config.credentialAccount,
                                            identity: config.credentialIdentity), "s3cret",
                       "清旧副本绝不能顺手把新键那一份也带走")
    }

    /// 新旧是同一个键时**不许删**。此时「旧键」就是刚写进去的那份活凭据，
    /// 删它等于把唯一副本清掉，之后自动重连再也拿不到密码。
    func testLegacyCleanupRefusesToDeleteWhenBothKeysAreTheSame() throws {
        let config = source()
        try CredentialStore.save("s3cret", account: config.credentialAccount,
                                 identity: config.credentialIdentity)

        XCTAssertFalse(CredentialStore.removeLegacyItem(config.credentialAccount,
                                                        migratedTo: config.credentialAccount))
        XCTAssertEqual(CredentialStore.read(account: config.credentialAccount,
                                            identity: config.credentialIdentity), "s3cret")
    }

    /// 没有旧键（2.0 之后新建的来源都是这样）必须是彻底的 no-op：
    /// 既不删东西，也不许把「删成功」报出去污染审计。
    func testLegacyCleanupIsANoOpWithoutALegacyKey() throws {
        let config = source()
        try CredentialStore.save("s3cret", account: config.credentialAccount,
                                 identity: config.credentialIdentity)

        XCTAssertFalse(CredentialStore.removeLegacyItem(nil, migratedTo: config.credentialAccount))
        XCTAssertFalse(CredentialStore.removeLegacyItem("", migratedTo: config.credentialAccount))
        XCTAssertEqual(CredentialStore.read(account: config.credentialAccount,
                                            identity: config.credentialIdentity), "s3cret")
    }

    /// 本函数**不许读新键**。钥匙串上每一次读都是一次系统授权，
    /// 而这里唯一要做的事是删——「新的一份在不在」由调用方在登录成功后负责证明。
    func testLegacyCleanupDoesNotReadTheBackend() throws {
        let body = try coreBody("CredentialStore.swift", function: "removeLegacyItem")
        XCTAssertFalse(body.isEmpty, "没读到函数体，这条会假绿")
        // 判据写 `read(account:` 而不是 `.read(`：枚举里的方法是 `read`，
        // 真写成 `_ = read(...)` 时没有点号——只认带点的形式会漏掉这种写法，
        // 红证已经证明过一次（变异写的就是无点号版本，测试却没红）。
        XCTAssertFalse(body.contains("read(account:"),
                       "清理旧副本不该读后端：读一次就弹一次授权，而且它读也证明不了什么")
        // 只准删一条：多出来的删除说明它被当成通用清理口子用了。
        XCTAssertEqual(body.split(separator: "\n").filter({ $0.contains("delete(account:") }).count, 1,
                       "清理只针对指名的那一个旧键，实际：\(body)")
    }

    /// ★ 接线的位置比接线本身更要紧：必须在**登录成功之后**才清。
    /// 提前到登录之前，等于在还不知道新的一份能不能用时就删掉老的一份。
    func testLegacyCleanupIsWiredOnlyAfterALoginSucceeded() throws {
        let appModel = try appLayerSource("AppModel.swift")
        XCTAssertTrue(appModel.contains("CredentialStore.removeLegacyItem("),
                      "App 层必须真的接上清理，否则旧键条目永远没人删")
        guard let cleanup = appModel.range(of: "CredentialStore.removeLegacyItem("),
              let login = appModel.range(of: "connection.login(password:") else {
            XCTFail("找不到清理点或登录点，这条断言会假绿"); return
        }
        XCTAssertTrue(cleanup.lowerBound > login.upperBound,
                      "清理必须排在登录成功之后：先证明新的一份能用，才能删旧的那一份")
    }

    // MARK: - 用户改主意

    func testTurningRememberPasswordOffDeletesTheCredential() throws {
        var remember = source()
        remember.rememberPassword = true
        try CredentialStore.save("s3cret", account: remember.credentialAccount,
                                 identity: remember.credentialIdentity)

        var forget = remember
        forget.rememberPassword = false
        XCTAssertTrue(CredentialStore.applyRememberPassword(false, config: forget),
                      "关掉「记住密码」必须真的删掉已存的那条")
        XCTAssertNil(CredentialStore.read(account: forget.credentialAccount),
                     "用户以为不保存了，实际密码还在 —— 这是从界面上完全看不出来的背离")
    }

    func testTurningRememberPasswordOnDeletesNothing() throws {
        let config = source()
        try CredentialStore.save("s3cret", account: config.credentialAccount,
                                 identity: config.credentialIdentity)
        XCTAssertFalse(CredentialStore.applyRememberPassword(true, config: config))
        XCTAssertEqual(CredentialStore.read(account: config.credentialAccount,
                                            identity: config.credentialIdentity), "s3cret")
    }

    func testRemovingASourceCleansUpEvenWhenItWasNotRemembered() throws {
        var forgotten = source()
        forgotten.rememberPassword = false
        try CredentialStore.save("s3cret", account: forgotten.credentialAccount,
                                 identity: forgotten.credentialIdentity)

        CredentialStore.removeSource(forgotten)
        XCTAssertNil(CredentialStore.read(account: forgotten.credentialAccount),
                     "删除来源必须无条件清凭据：flag 为 false 不代表后端里没有历史残留")
    }

    /// 删除从 App 层搬进 Core 之后，审计原因不能跟着丢：留在 Core 里也要写全。
    func testCoreDeleteHelpersStillCarryAReason() throws {
        let lines = try coreSource("CredentialStore.swift").split(separator: "\n").map(String.init)
        func body(of name: String) throws -> String {
            guard let start = lines.firstIndex(where: { $0.contains("func " + name + "(") }) else {
                XCTFail("找不到 \(name)"); return ""
            }
            var collected: [String] = []
            for line in lines[(start + 1)...] {
                if line.trimmingCharacters(in: .whitespaces) == "}" { break }
                collected.append(line)
            }
            return collected.joined(separator: "\n")
        }
        for name in ["applyRememberPassword", "removeSource"] {
            let code = try body(of: name)
            XCTAssertFalse(code.isEmpty, "没读到 \(name)，这条会假绿")
            XCTAssertTrue(code.contains("reason:"),
                          "Core 里的删除也要带原因：审计要能分清是谁动的（\(name)）")
        }
    }

    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/" + name),
                          encoding: .utf8)
    }

    /// App 层不可测（`FlashFind2App` 是 executable），涉及它的接线只能扫源码。
    private func appLayerSource(_ name: String) throws -> String {
        // AppModel 已拆成主文件 + 分区，读它必须走整套入口，否则搬到分区里的
        // 实现会「消失」，下面的断言全部假绿。
        if name == "AppModel.swift" { return try AppModelSource.readRaw(callerFilePath: #filePath) }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFind2App/" + name),
                          encoding: .utf8)
    }

    /// 取一个函数的**函数体**（按括号配平的行级切块，不做全文 contains）。
    private func coreBody(_ name: String, function: String) throws -> String {
        let lines = try coreSource(name).split(separator: "\n").map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func " + function + "(") }) else {
            XCTFail("找不到 \(function)，这条会假绿"); return ""
        }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if line.trimmingCharacters(in: .whitespaces) == "}" { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    // MARK: - 迁移：明文删在最后

    /// 目标后端写不进去时，明文必须原样留着。
    private struct RefusingStore: SecretStore {
        func save(_ value: String, account: String) throws { throw CredentialStoreError.writeFailed }
        func read(account: String) -> String? { nil }
        @discardableResult func delete(account: String) -> Bool { false }
        func allAccounts() -> [String] { [] }
        var unreadableReason: CredentialStoreProblem? { nil }
        func auditableAccounts() -> [String]? { [] }
        func existsForAudit(_ account: String) -> Bool? { false }
    }

    private func plaintextFile(withSecrets secrets: [String: String]) throws -> FileSecretStore {
        let store = FileSecretStore(directory: directory)
        for (account, secret) in secrets { try store.save(secret, account: account) }
        return store
    }

    func testMigrationFailureKeepsThePlaintext() throws {
        let account = source().credentialAccount
        let file = try plaintextFile(withSecrets: [account: "s3cret"])
        CredentialStore.install(RefusingStore(), plaintextSource: file)

        let report = CredentialStore.migrateLegacyPlaintext()
        XCTAssertFalse(report.failures.isEmpty, "目标后端写不进去，报告里必须有失败")
        XCTAssertTrue(report.added.isEmpty)
        XCTAssertEqual(file.plaintext(account), "s3cret",
                       "迁移失败的那一刻明文是**唯一副本** —— 删掉它就再也找不回来了")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path))
    }

    func testVerifiedMigrationRemovesThePlaintext() throws {
        let account = source().credentialAccount
        let file = try plaintextFile(withSecrets: [account: "s3cret"])
        CredentialStore.install(backend, plaintextSource: file)

        let report = CredentialStore.migrateLegacyPlaintext()
        XCTAssertEqual(report.added, [account])
        XCTAssertEqual(backend.read(account: account), "s3cret")
        // 只写进目标还不够：这一步之前明文必须还在。
        XCTAssertEqual(file.plaintext(account), "s3cret",
                       "写入成功就急着删明文，等于赌目标后端读得出来")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.fileURL.path))

        // 真实登录用新后端的密码连上了（这里是同一次登录的等价物）→ 才轮到删明文。
        XCTAssertTrue(CredentialStore.confirmCredentialVerified(account))
        XCTAssertNil(file.plaintext(account))
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.fileURL.path),
                       "全部迁完之后不该留一个空的凭据文件：有没有明文密码不该靠读 JSON 才知道")
    }

    func testPlaintextSurvivesUntilItWasVerified() throws {
        let account = source().credentialAccount
        let file = try plaintextFile(withSecrets: [account: "s3cret"])
        CredentialStore.install(backend, plaintextSource: file)

        // 没迁移就去「确认验证」，等于谎报成功：这时新后端里根本没这条密码。
        XCTAssertFalse(CredentialStore.confirmCredentialVerified(account),
                       "没写过就不能确认——否则密码会从两端同时消失")
        XCTAssertEqual(file.plaintext(account), "s3cret")
    }
}
