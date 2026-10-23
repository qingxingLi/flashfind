import XCTest
@testable import FlashFindCore

/// 合并条目（一条钥匙串装下所有 NAS 密码）的编解码与搬迁顺序。
///
/// 这里**一个钥匙串都不碰**：`CredentialVault` 是纯结构，搬迁用内存后端跑。
/// 真钥匙串在测试里是禁止触碰的（见 `NoKeychainAccessTests`）——那类副作用
/// 发生在进程外，本机跑一百遍都是绿的，用户一开机就中招。
final class CredentialVaultTests: XCTestCase {

    // MARK: - 编解码

    func testRoundTripKeepsEveryEntry() {
        var vault = CredentialVault()
        vault.set("p1", for: "nas-source:a")
        vault.set("p2", for: "nas-source:b")
        let decoded = CredentialVault.decode(vault.encoded())
        guard case let .ok(copy) = decoded else { return XCTFail("自己编码出来的东西读不回来：\(decoded)") }
        XCTAssertEqual(copy, vault)
        XCTAssertEqual(copy.value(for: "nas-source:a"), "p1")
        XCTAssertEqual(copy.value(for: "nas-source:b"), "p2")
    }

    /// 编码结果必须**稳定**：同内容两次编码字节一致，且键按升序。
    ///
    /// 不稳定的话 `SecItemUpdate` 会白写一次（一次磁盘+一次钥匙串往返），
    /// 更糟的是红证锚不住——每次跑出来的原文都不一样。
    /// 这里钉的是**确定的字节串**：顺序一变（升序→降序、或退回无序）立刻红。
    func testEncodingIsStableRegardlessOfInsertionOrder() {
        var one = CredentialVault()
        one.set("p1", for: "nas-source:a")
        one.set("p2", for: "nas-source:b")
        var two = CredentialVault()
        two.set("p2", for: "nas-source:b")
        two.set("p1", for: "nas-source:a")
        XCTAssertEqual(one.encoded(), two.encoded())
        XCTAssertEqual(one.encoded(), one.encoded())
        XCTAssertEqual(one.encoded(),
                       "{\"v\":1,\"entries\":{\"nas-source:a\":\"p1\",\"nas-source:b\":\"p2\"}}",
                       "编码形态变了：键序、信封版本或分隔符动了")
    }

    func testMissingItemAndEmptyStringBothDecodeAsEmpty() {
        XCTAssertEqual(CredentialVault.decode(nil), .empty)
        XCTAssertEqual(CredentialVault.decode(""), .empty)
        XCTAssertEqual(CredentialVault.decode("   \n "), .empty)
    }

    /// ★ 读不懂**绝不能**当成空表。
    ///
    /// 当成空表的话，下一次保存会拿一份新表把全部密码覆盖掉（OSS-04）。
    /// 这是整个合并方案里唯一会造成「密码全丢」的分支，所以单独守着。
    func testDamagedPayloadIsRefusedRatherThanTreatedAsEmpty() {
        for payload in ["{", "不是 JSON", "[]", "{\"v\":1}", "{\"entries\":[]}", "{\"entries\":{\"a\":1}}"] {
            XCTAssertEqual(CredentialVault.decode(payload), .damaged(.undecodable),
                           "这个应当被判成损坏：\(payload)")
        }
    }

    /// 版本比本机新：它能读，本机不能写——写回去等于把人家的新结构抹平。
    func testNewerVersionIsRefused() {
        let payload = "{\"v\":\(CredentialVault.currentVersion + 1),\"entries\":{}}"
        XCTAssertEqual(CredentialVault.decode(payload), .damaged(.newerVersion(CredentialVault.currentVersion + 1)))
    }

    /// 账号名里带引号、反斜杠、换行都要能原样回来（否则就是「密码读出来了但对不上」）。
    func testSpecialCharactersInAccountSurviveRoundTrip() {
        let account = "nas-source:他说\"走\" \\ 换行\n制表\t"
        var vault = CredentialVault()
        vault.set("secret", for: account)
        guard case let .ok(copy) = CredentialVault.decode(vault.encoded()) else {
            return XCTFail("含特殊字符的账号名把自己编码坏了")
        }
        XCTAssertEqual(copy.value(for: account), "secret")
    }

    func testEmptyValueIsNotAnEntry() {
        var vault = CredentialVault()
        vault.set("", for: "nas-source:a")
        XCTAssertNil(vault.value(for: "nas-source:a"), "空串等于没存：读出来是空串会让人以为密码是空的")
        XCTAssertTrue(vault.isEmpty)
    }

    func testRemovingTheLastEntryLeavesAnEmptyVault() {
        var vault = CredentialVault()
        vault.set("p", for: "a")
        vault.remove("a")
        XCTAssertTrue(vault.isEmpty)
        guard case let .ok(copy) = CredentialVault.decode(vault.encoded()) else {
            return XCTFail("空 vault 应该能读回来")
        }
        XCTAssertTrue(copy.isEmpty)
    }

    // MARK: - 默认布局

    /// 默认必须是合并布局。退回「一条一个」的话，用户的弹窗次数又跟 NAS 台数绑上了。
    ///
    /// 只看源码不看行为：测试里**不许**实例化真实钥匙串后端
    /// （`NoKeychainAccessTests` 会当场抓住）。这里要守的是「两个便捷 init 都落到 `.vault`」，
    /// 源码扫描已经够用，而且改动时一下子就红。
    func testStoreDefaultsToTheConsolidatedLayout() throws {
        let source = try keychainStoreSource()
        XCTAssertEqual(source.components(separatedBy: "tier: .automatic, layout: .vault").count - 1, 1,
                       "两参 init 必须落到合并布局")
        XCTAssertEqual(source.components(separatedBy: "tier: tier, layout: .vault").count - 1, 1,
                       "钉住层级的 init 也必须落到合并布局")
        XCTAssertEqual(source.components(separatedBy: "layout: .perAccount").count - 1, 0,
                       "老布局不该在这里被实例化；它只作为迁移来源，由 CredentialStore 指名构造")
    }

    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
    }

    private func keychainStoreSource() throws -> String {
        let url = clientRoot.appendingPathComponent("Sources/FlashFindCore/KeychainSecretStore.swift")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "找不到 KeychainSecretStore.swift —— 路径换了的话这条测试会假绿，必须修")
        return try String(contentsOf: url, encoding: .utf8)
    }

    // MARK: - 搬迁（顺序与失败分支）

    func testConsolidationMovesEveryStoredAccountAndDropsTheOldOnes() throws {
        let legacy = InMemorySecretStore()
        try legacy.save("p1", account: "nas-source:a")
        try legacy.save("p2", account: "nas-source:b")
        let vault = InMemorySecretStore()

        let report = VaultConsolidation.run(from: legacy, to: vault,
                                            accounts: ["nas-source:a", "nas-source:b", "nas-source:c"])

        XCTAssertEqual(report.moved, ["nas-source:a", "nas-source:b"])
        XCTAssertEqual(report.absent, ["nas-source:c"], "从没存过的要报「本来就没有」，不能算失败")
        XCTAssertTrue(report.failures.isEmpty)
        XCTAssertTrue(report.leftBehind.isEmpty)
        XCTAssertEqual(vault.read(account: "nas-source:a"), "p1")
        XCTAssertEqual(vault.read(account: "nas-source:b"), "p2")
        XCTAssertNil(legacy.read(account: "nas-source:a"), "搬完必须把老条目删掉，否则它还会继续要授权")
        XCTAssertNil(legacy.read(account: "nas-source:b"))
    }

    /// ★ 新的一份写不进去时，**绝不能删旧的**——那等于把唯一副本删了。
    func testConsolidationKeepsTheOldEntryWhenTheNewOneCannotBeWritten() throws {
        let legacy = InMemorySecretStore()
        try legacy.save("p1", account: "nas-source:a")

        let report = VaultConsolidation.run(from: legacy, to: RefusingStore(),
                                            accounts: ["nas-source:a"])

        XCTAssertEqual(report.failures, ["nas-source:a"])
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertEqual(legacy.read(account: "nas-source:a"), "p1", "写失败还删了旧的：密码就此消失")
    }

    /// ★ 写完必须**读回来确认**，才允许删旧的。
    ///
    /// `save` 不报错不等于存住了：后端可能悄悄丢（写进一个只读副本、配额满、
    /// 后端换了实现忘了落盘）。少了这一步确认，「写失败」就变成「两份都没了」。
    func testConsolidationDoesNotDropTheOldEntryWhenTheNewOneSilentlyVanishes() throws {
        let legacy = InMemorySecretStore()
        try legacy.save("p1", account: "nas-source:a")

        let report = VaultConsolidation.run(from: legacy, to: SilentlyDroppingStore(),
                                            accounts: ["nas-source:a"])

        XCTAssertEqual(report.failures, ["nas-source:a"], "写成功但读不回来，必须当成失败")
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertEqual(legacy.read(account: "nas-source:a"), "p1", "没确认新的一份就删了旧的：密码消失")
    }

    func testConsolidationIsIdempotent() throws {        let legacy = InMemorySecretStore()
        try legacy.save("p1", account: "nas-source:a")
        let vault = InMemorySecretStore()
        XCTAssertEqual(VaultConsolidation.run(from: legacy, to: vault, accounts: ["nas-source:a"]).moved.count, 1)

        let again = VaultConsolidation.run(from: legacy, to: vault, accounts: ["nas-source:a"])
        XCTAssertTrue(again.moved.isEmpty, "第二次不该再搬一遍")
        XCTAssertEqual(again.absent, ["nas-source:a"])
        XCTAssertEqual(vault.read(account: "nas-source:a"), "p1", "第二次跑不能把已经搬过去的那份弄丢")
    }

    func testConsolidationIgnoresDuplicateAccounts() throws {
        let legacy = InMemorySecretStore()
        try legacy.save("p1", account: "nas-source:a")
        let report = VaultConsolidation.run(from: legacy, to: InMemorySecretStore(),
                                            accounts: ["nas-source:a", "nas-source:a"])
        XCTAssertEqual(report.attempted, ["nas-source:a"])
        XCTAssertEqual(report.moved, ["nas-source:a"])
    }

    /// 后端不是钥匙串（文件 / 内存）时，合并无从谈起：直接空报告，不做任何读写。
    func testConsolidationDoesNothingForNonKeychainBackends() {
        CredentialStore.install(InMemorySecretStore())
        XCTAssertTrue(CredentialStore.consolidateIntoVault(accounts: ["nas-source:a"]).isEmpty)
        CredentialStore.install(InMemorySecretStore())
    }
}

/// 写入必定失败的后端：用来验证「写不进去就别删旧的」。
private final class RefusingStore: SecretStore, @unchecked Sendable {
    func save(_ value: String, account: String) throws { throw CredentialStoreError.writeFailed }
    func read(account: String) -> String? { nil }
    func delete(account: String) -> Bool { false }
    func allAccounts() -> [String] { [] }
    var unreadableReason: CredentialStoreProblem? { .unreadable }
    func auditableAccounts() -> [String]? { nil }
    func existsForAudit(_ account: String) -> Bool? { nil }
}

/// 不报错、但什么也没存住的后端：验证「读回来确认」这一步真的存在。
private final class SilentlyDroppingStore: SecretStore, @unchecked Sendable {
    func save(_ value: String, account: String) throws {}
    func read(account: String) -> String? { nil }
    func delete(account: String) -> Bool { true }
    func allAccounts() -> [String] { [] }
    var unreadableReason: CredentialStoreProblem? { nil }
    func auditableAccounts() -> [String]? { nil }
    func existsForAudit(_ account: String) -> Bool? { nil }
}
