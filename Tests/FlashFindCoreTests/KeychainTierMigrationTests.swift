import XCTest
@testable import FlashFindCore

/// 经典钥匙串 → Data Protection 钥匙串升迁的行为证据。
///
/// 今天所有构建都缺 `keychain-access-groups` entitlement，这条路**不会真的发生**。
/// 测试的目的因此不是「跑通一次升迁」，而是把三条规矩钉死，
/// 等 entitlement 到位那天它才不会变成一场数据丢失：
/// 1. 先写 DP、再删经典（顺序反了就是删掉唯一副本）；
/// 2. 只能按指名的 account 搬（钥匙串不能枚举）；
/// 3. 缺 entitlement 时整批中止，且**一条都不许动**。
///
/// 全程走 `InMemorySecretStore`：**测试不碰真钥匙串**。
final class KeychainTierMigrationTests: XCTestCase {

    private func classic(_ secrets: [String: String]) -> InMemorySecretStore {
        let store = InMemorySecretStore()
        for (account, secret) in secrets { try? store.save(secret, account: account) }
        return store
    }

    /// 钉住层级的两个真钥匙串后端：**不发起任何钥匙串操作**，只读它自己的状态位。
    func testKeychainStoreCanBePinnedToATier() {
        XCTAssertFalse(KeychainSecretStore(tier: .classic).usesDataProtectionKeychain,
                       "钉在经典层的实例不该自称走 DP")
        XCTAssertTrue(KeychainSecretStore(tier: .dataProtection).usesDataProtectionKeychain,
                      "钉在 DP 层的实例不许自动降级：失败要如实报出来，否则永远看不出 entitlement 到位")
    }

    func testTierMigrationMovesTheValueAndDropsTheClassicCopy() {
        let source = classic(["nas-source:a": "s3cret"])
        let target = InMemorySecretStore()

        let report = KeychainTierMigration.migrate(from: source, to: target,
                                                   accounts: ["nas-source:a"])
        XCTAssertEqual(report.moved, ["nas-source:a"])
        XCTAssertEqual(target.read(account: "nas-source:a"), "s3cret")
        XCTAssertNil(source.read(account: "nas-source:a"),
                     "搬走之后经典侧那一份必须消失：留着就是两份密码，删来源只删得掉一份")
    }

    /// ★ 顺序是这条流程的全部：**DP 侧写成功之后**才允许删经典侧。
    /// 反过来等于在还不知道新的一份存不存在时就删掉旧的一份。
    func testTierMigrationKeepsTheClassicCopyWhenTheDPCopyFailed() {
        let source = classic(["nas-source:a": "s3cret"])
        let refusing = RefusingStore(status: errSecIO)

        let report = KeychainTierMigration.migrate(from: source, to: refusing,
                                                   accounts: ["nas-source:a"])
        XCTAssertEqual(report.moved, [])
        XCTAssertEqual(report.failures.count, 1)
        XCTAssertEqual(source.read(account: "nas-source:a"), "s3cret",
                       "DP 侧没写进去就把经典侧删了 —— 密码两头落空，用户只能一台一台重输")
    }

    /// 经典侧本来就没有的 account：记一笔就跳过，不许去删（那边删的是 DP 侧那一份）。
    func testTierMigrationSkipsAccountsThatAreNotOnClassic() {
        let source = classic([:])
        let target = InMemorySecretStore()
        let report = KeychainTierMigration.migrate(from: source, to: target,
                                                   accounts: ["nas-source:a"])
        XCTAssertEqual(report.absentOnClassic, ["nas-source:a"])
        XCTAssertEqual(report.moved, [])
        XCTAssertTrue(report.failures.isEmpty,
                      "没存过不是失败：每次启动都报一批失败会把真故障淹没掉")
    }

    /// entitlement 不到位：整批中止，且**一条都不许动**。
    ///
    /// 这里最要紧的是「不重试到底」——-34018 是整包的属性，不是某一条的属性，
    /// 试完全部只会得到 N 条同样的失败；更要紧的是它绝不能顺手删掉经典侧。
    func testTierMigrationAbortsWhenTheEntitlementIsMissing() {
        let source = classic(["nas-source:a": "s3cret", "nas-source:b": "s3cret"])
        let refusing = RefusingStore(status: errSecMissingEntitlement)

        let report = KeychainTierMigration.migrate(from: source, to: refusing,
                                                   accounts: ["nas-source:a", "nas-source:b"])
        XCTAssertTrue(report.abortedForMissingEntitlement)
        XCTAssertEqual(report.attempted, ["nas-source:a"], "第一条就中止，不该把剩下的再试一遍")
        XCTAssertEqual(source.read(account: "nas-source:a"), "s3cret")
        XCTAssertEqual(source.read(account: "nas-source:b"), "s3cret")
    }

    /// 后端不是钥匙串时（测试用内存后端、CLI 用文件后端）整件事不适用。
    /// 这条同时挡住「把读经典侧那套语义套到别的存储上」。
    func testTierMigrationIsASkipWhenTheBackendIsNotKeychain() {
        CredentialStore.install(InMemorySecretStore())
        let report = CredentialStore.migrateKeychainTier(accounts: ["nas-source:a"])
        XCTAssertTrue(report.isEmpty, "非钥匙串后端没有「层级」这回事，应当整体跳过")
    }

    /// 升迁的调用点在启动路径上，且 account 由调用方指名（不枚举）。
    func testTierMigrationIsRegisteredOnTheLaunchPath() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let text = try String(contentsOf: root.appendingPathComponent("Sources/FlashFind2App/FlashFind2App.swift"),
                              encoding: .utf8)
        XCTAssertTrue(text.contains("CredentialStore.migrateKeychainTier(accounts:"),
                      "升迁必须登记在启动路径上，否则 entitlement 到位那天也不会发生")
        XCTAssertFalse(text.contains("allAccounts()"),
                       "启动路径上不许枚举钥匙串：枚举会触碰系统授权")
    }

    /// 只按给定状态码拒绝写入，用来模拟「DP 侧写不进去」。
    private struct RefusingStore: SecretStore {
        let status: OSStatus
        init(status: OSStatus) { self.status = status }
        func save(_ value: String, account: String) throws {
            throw CredentialStoreError.keychainStatus(status)
        }
        func read(account: String) -> String? { nil }
        @discardableResult func delete(account: String) -> Bool { false }
        func allAccounts() -> [String] { [] }
        var unreadableReason: CredentialStoreProblem? { nil }
        func auditableAccounts() -> [String]? { [] }
        func existsForAudit(_ account: String) -> Bool? { false }
    }
}
