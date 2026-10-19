import XCTest
@testable import FlashFindCore

/// 凭据后端抽象与迁移的行为契约。
///
/// 迁移那几条的重点不是「搬过去了」，而是**搬的姿势**：只写不读、明文删在最后。
/// 这两条是用真机弹窗换来的，所以必须由测试钉住，不能只靠注释记着。
final class SecretStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-secret-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        CredentialStore.install(FileSecretStore(directory: directory))
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - InMemory 后端

    func testInMemoryStoreRoundTrip() throws {
        let store = InMemorySecretStore()
        try store.save("s3cret", account: "nas-source:a")
        XCTAssertEqual(store.read(account: "nas-source:a"), "s3cret")
    }

    func testInMemoryStoreTreatsEmptyAsMissing() throws {
        let store = InMemorySecretStore()
        try store.save("", account: "nas-source:a")
        XCTAssertNil(store.read(account: "nas-source:a"),
                     "空串等于没有密码，读出来必须是 nil")
    }

    func testDeletingAMissingEntryStillSucceeds() {
        // 移除来源时会无条件调用 delete，删不到不能算失败。
        XCTAssertTrue(InMemorySecretStore().delete(account: "nas-source:不存在"))
    }

    // MARK: - 装配

    /// 未装配任何后端时必须是内存后端：不落盘，也就不会因为钥匙串方案未定而阻塞。
    func testDefaultBackendIsInMemoryBeforeAnythingIsInstalled() throws {
        let code = try sourceCode("CredentialStore.swift")
        XCTAssertTrue(code.contains("private static var backend: SecretStore = InMemorySecretStore()"),
                      "默认后端必须是 InMemory —— 装配之前不写任何东西到磁盘")
    }

    func testInstallingAStoreSwitchesTheBackend() throws {
        CredentialStore.install(InMemorySecretStore())
        XCTAssertEqual(CredentialStore.backendName, "inMemory")
        CredentialStore.install(FileSecretStore(directory: directory))
        XCTAssertEqual(CredentialStore.backendName, "file")
        XCTAssertEqual(CredentialStore.fileURL.deletingLastPathComponent().path, directory.path)
    }

    // MARK: - 迁移：只写不读

    /// ★ 核心一条：迁移过程**一次都不许读目标后端**。
    ///
    /// 钥匙串的读就是弹窗源（：为了「顺手校验」留的一次 `SecItemCopyMatching`
    /// 照样弹）。写入成功与否看返回，正确性交给下一次真实登录去证明。
    func testMigrationWritesWithoutEverReadingTheDestination() throws {
        let source = FileSecretStore(directory: directory)
        try source.save("p1", account: "nas-source:aaa")
        try source.save("p2", account: "nas-source:bbb")
        let destination = RecordingStore()

        let report = CredentialMigration.migrate(from: source, to: destination)

        XCTAssertEqual(report.added.count, 2)
        XCTAssertTrue(destination.reads.isEmpty,
                      "迁移不许读目标后端，实际读了：\(destination.reads)")
    }

    /// ★ 明文必须留到验证成功之后才删。提前删 = 两头落空。
    func testPlaintextSurvivesUntilItHasBeenVerified() throws {
        let source = FileSecretStore(directory: directory)
        try source.save("p1", account: "nas-source:aaa")
        CredentialStore.install(source)

        _ = CredentialStore.migratePlaintextTo(InMemorySecretStore())

        XCTAssertEqual(source.plaintext("nas-source:aaa"), "p1",
                       "还没验证过，明文不许先删")
        XCTAssertTrue(CredentialStore.pendingVerification.contains("nas-source:aaa"))
    }

    /// ★ 验证成功（真的连上了）之后，明文副本才删掉。
    func testVerificationDropsThePlaintextCopy() throws {
        let source = FileSecretStore(directory: directory)
        try source.save("p1", account: "nas-source:aaa")
        try source.save("p2", account: "nas-source:bbb")
        CredentialStore.install(source)
        _ = CredentialStore.migratePlaintextTo(InMemorySecretStore())

        XCTAssertTrue(CredentialStore.confirmCredentialVerified("nas-source:aaa"))

        XCTAssertNil(source.plaintext("nas-source:aaa"), "验证过的这条明文该删了")
        XCTAssertEqual(source.plaintext("nas-source:bbb"), "p2", "没验证过的那条必须还在")
    }

    /// 迁移过一次的不再重复写，避免每次启动都往钥匙串里刷一遍。
    func testSecondMigrationSkipsWhatIsAlreadyMigrated() throws {
        let source = FileSecretStore(directory: directory)
        try source.save("p1", account: "nas-source:aaa")
        let destination = RecordingStore()

        _ = CredentialMigration.migrate(from: source, to: destination)
        let second = CredentialMigration.migrate(from: source, to: destination)

        XCTAssertEqual(second.added, [])
        XCTAssertEqual(second.skippedAlreadyMigrated, ["nas-source:aaa"])
        XCTAssertEqual(destination.saves.count, 1, "第二次不该再写一遍")
    }

    /// 目标后端写不进去时，明文必须原样留下 —— 留着还有救，删了就真没了。
    func testPlaintextIsKeptWhenTheDestinationRefusesToWrite() throws {
        let source = FileSecretStore(directory: directory)
        try source.save("p1", account: "nas-source:aaa")

        let report = CredentialMigration.migrate(from: source, to: RefusingStore())

        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(source.plaintext("nas-source:aaa"), "p1", "目标写不进去，明文必须保留")
    }

    // MARK: - 辅助

    private func sourceCode(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/\(name)"),
                          encoding: .utf8)
    }

    /// 记录每一次访问，用来证明「只写不读」。
    private final class RecordingStore: SecretStore, @unchecked Sendable {
        private let lock = NSLock()
        private var records: [String: String] = [:]
        private(set) var saves: [String] = []
        private(set) var reads: [String] = []

        func save(_ value: String, account: String) throws {
            lock.lock(); defer { lock.unlock() }
            records[account] = value
            saves.append(account)
        }
        func read(account: String) -> String? {
            lock.lock(); defer { lock.unlock() }
            reads.append(account)
            return records[account]
        }
        @discardableResult
        func delete(account: String) -> Bool {
            lock.lock(); defer { lock.unlock() }
            records.removeValue(forKey: account)
            return true
        }
        func allAccounts() -> [String] {
            lock.lock(); defer { lock.unlock() }
            return Array(records.keys).sorted()
        }
        var unreadableReason: CredentialStoreProblem? { nil }
        func auditableAccounts() -> [String]? { allAccounts() }
        func existsForAudit(_ account: String) -> Bool? {
            lock.lock(); defer { lock.unlock() }
            return records[account] != nil
        }
    }

    /// 一律写不进的后端，用来验证「目标失败时明文必须保留」。
    private struct RefusingStore: SecretStore {
        func save(_ value: String, account: String) throws { throw CredentialStoreError.writeFailed }
        func read(account: String) -> String? { nil }
        @discardableResult func delete(account: String) -> Bool { false }
        func allAccounts() -> [String] { [] }
        var unreadableReason: CredentialStoreProblem? { .keychain("测试用：一律拒绝") }
        func auditableAccounts() -> [String]? { [] }
        func existsForAudit(_ account: String) -> Bool? { nil }
    }
}
