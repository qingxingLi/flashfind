import XCTest
import Security
@testable import FlashFindCore

/// 「重启后不必重新登录」的机器判据。
///
/// ## 这条 bug 的现场
///
/// 用户报障：**彻底退出闪寻再打开，两台 NAS 全变成「需要重新登录」**，
/// 而在同一次运行里怎么重连都正常。
///
/// 真机实测（2026-10-23，ad-hoc 试装包，无 entitlement）：
///
///   SecItemCopyMatching(DataProtection) → -25300 errSecItemNotFound
///   SecItemCopyMatching(经典钥匙串)     → 0（101 字节，密码就在里面）
///   SecItemAdd(DataProtection)          → -34018 errSecMissingEntitlement
///
/// **写**的时候 DP 报 -34018，`perform` 降级到经典、并把档位记进
/// `dataProtection.value`，所以那一次运行里后续读写都对。
/// **读**是新进程的第一件事：先问 DP，拿回的是「找不到」——不是「没权限」。
/// 旧实现只认 -34018，不换层，于是「存着密码」被读成 `nil`，
/// `autoConnectSavedSources` 走进「本机没有保存密码」分支，界面全变「需要重新登录」。
///
/// ## 为什么测的是策略与结构，而不是真钥匙串
///
/// `NoKeychainAccessTests` 明令禁止测试碰真钥匙串（一碰就弹系统授权框）。
/// 所以把「要不要换一层再问」抽成纯策略（`LookupPolicy`）与注入式查询
/// （`acrossTiers`），两者都不发起任何 `SecItem*`；真调用点由源码扫描钉住。
final class KeychainLookupTests: XCTestCase {

    // MARK: - 纯策略

    /// 「找不到」与「这层用不了」都要换一层再问：前者正是本 bug 的状态码。
    func testMissingItemAndMissingEntitlementBothJustifyAnotherLookup() {
        XCTAssertTrue(KeychainSecretStore.LookupPolicy.shouldTryTheOtherTier(after: errSecItemNotFound),
                      "经典钥匙串里的条目，在 DP 侧就是 -25300；不换层就等于「忘了密码」")
        XCTAssertTrue(KeychainSecretStore.LookupPolicy.shouldTryTheOtherTier(after: errSecMissingEntitlement),
                      "缺 entitlement 说明这层用不了，换一层是唯一的出路")
    }

    /// 其余状态不换层：授权被拒再问一次只是多弹一个窗。
    func testOtherStatusesDoNotTriggerAnotherLookup() {
        XCTAssertFalse(KeychainSecretStore.LookupPolicy.shouldTryTheOtherTier(after: errSecSuccess))
        XCTAssertFalse(KeychainSecretStore.LookupPolicy.shouldTryTheOtherTier(after: errSecAuthFailed))
        XCTAssertFalse(KeychainSecretStore.LookupPolicy.shouldTryTheOtherTier(after: errSecUserCanceled))
    }

    // MARK: - 跨层查询（注入假查询，不碰真钥匙串）

    /// 自动档：第一层说没有，就去第二层拿。这条就是修复本身。
    func testAutomaticTierReadsTheOtherTierAfterAMiss() {
        // 构造本身不发起任何 SecItem*（见 NoKeychainAccessTests 的说明）。
        let store = KeychainSecretStore()
        var asked: [Bool] = []
        let result = store.acrossTiers { protecting in
            asked.append(protecting)
            return protecting
                ? (status: errSecItemNotFound, data: nil as String?)
                : (status: errSecSuccess, data: "s3cret")
        }
        XCTAssertEqual(asked, [true, false], "必须问过两层：先 DP，再经典")
        XCTAssertEqual(result.status, errSecSuccess)
        XCTAssertEqual(result.data, "s3cret", "密码在经典层，必须能读回来")
    }

    /// 第一层命中就不再问第二层：多查一次既慢又可能多弹授权。
    func testAutomaticTierStopsAtTheFirstHit() {
        let store = KeychainSecretStore()
        var asked: [Bool] = []
        let result = store.acrossTiers { protecting in
            asked.append(protecting)
            return (status: errSecSuccess, data: "dp-value")
        }
        XCTAssertEqual(asked, [true], "DP 侧有就不用再问经典层")
        XCTAssertEqual(result.data, "dp-value")
    }

    /// 钉住的层级**不许**跨库：升迁正是靠「DP 侧到底有没有」来判断，
    /// 替它去经典层兜一次，就永远看不出 entitlement 已经到位。
    func testPinnedTiersNeverCrossOver() {
        var asked: [Bool] = []
        let result = KeychainSecretStore(tier: .classic).acrossTiers { protecting in
            asked.append(protecting)
            return (status: errSecItemNotFound, data: nil as String?)
        }
        XCTAssertEqual(asked, [false], "钉在经典层的实例只能问经典层")
        XCTAssertEqual(result.status, errSecItemNotFound)
    }

    /// 两层都没有时如实施报「找不到」，不能编出一个成功。
    func testBothTiersMissingReportsNotFound() {
        let store = KeychainSecretStore()
        let result = store.acrossTiers { _ in (status: errSecItemNotFound, data: nil as String?) }
        XCTAssertEqual(result.status, errSecItemNotFound)
        XCTAssertNil(result.data)
    }

    // MARK: - 真调用点（源码扫描）

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

    private func coreSource(_ name: String) throws -> String {
        let url = clientRoot.appendingPathComponent("Sources/FlashFindCore/\(name)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "找不到 \(name) —— 路径换了的话这条测试会假绿，必须修")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// ★ 层级升迁必须**先探测 DP 写得进去**，再去读经典钥匙串。
    ///
    /// 顺序反了的代价是用户实打实的一轮弹窗：读经典 = 一次系统授权，每台 NAS 一次，
    /// 而这一轮注定什么也搬不走（今天所有构建都缺 entitlement）。
    /// 这种缺陷在测试里完全看不出来（摸不到真钥匙串），只能拿源码顺序守。
    func testTierMigrationProbesDataProtectionBeforeReadingTheClassicTier() throws {
        let body = try braceBalancedBlock(in: try coreSource("CredentialStore.swift"),
                                          anchor: "public static func migrateKeychainTier(accounts: [String])")
        XCTAssertTrue(body.contains("guard keychain.dataProtectionIsWritable() else { return .init() }"),
                      "升迁前没有探测 DP 可用性：会先白读一轮经典钥匙串，用户为此多点几次授权")
        let probe = try XCTUnwrap(body.range(of: "dataProtectionIsWritable()"))
        let migrate = try XCTUnwrap(body.range(of: "KeychainTierMigration.migrate"),
                                    "升迁调用不见了？先确认它是不是被改名了")
        XCTAssertLessThan(probe.lowerBound, migrate.lowerBound,
                          "探测必须排在读经典之前，否则探测就失去意义")
    }

    /// **每一条**读路径都必须走跨层查询，不能退回「只问一层」。
    ///
    /// 1.1.5 起 `read` 只是个分发器（合并条目 / 老式一条一条），真正的读在下面两个
    /// 私有方法里，而且两者都要经过 `decodedVault` / `acrossTiers`。所以断言分开打，
    /// 不给「其中一个偷偷换了实现」留缝。
    func testReadGoesThroughTheCrossTierLookup() throws {
        let source = try keychainStoreSource()
        for anchor in ["private func readPerAccount(account: String)",
                       "private func decodedVault("] {
            let body = try braceBalancedBlock(in: source, anchor: anchor)
            XCTAssertTrue(body.contains("acrossTiers"),
                          "\(anchor) 又变回单层查询了：密码存在经典钥匙串、进程又从 DP 起步时，会读成 nil")
            XCTAssertFalse(body.contains("perform("),
                           "\(anchor) 不能走 perform：它只在 -34018 时降级，而「找不到」是 -25300")
        }
    }

    /// 自动档的删除**每条数据通路**都必须两层都删。
    ///
    /// 只删一层的后果很具体：用户在设置里关掉「记住这台 NAS 的密码」，
    /// 界面显示已关闭，经典钥匙串里那条密码却还在。
    /// 合并布局（`removeVaultItem`）与老布局（`deletePerAccount`）各有一次自动档分支，
    /// 少了任何一处都会留下「删一层」的尾巴。
    func testDeleteCoversBothTiersInAutomaticMode() throws {
        let source = try keychainStoreSource()
        for anchor in ["private func removeVaultItem()",
                       "private func deletePerAccount(account: String)"] {
            let body = try braceBalancedBlock(in: source, anchor: anchor)
            // 只数 `case .automatic:` 那一支：钉住档那一支删一次就够，
            // 把它算进来会让「该删两层」这件事被一个凑巧的总数蒙对。
            let start = try XCTUnwrap(body.range(of: "case .automatic:"),
                                      "\(anchor) 里没有 switch 的 automatic 分支 —— 结构改了，这条断言要跟着改")
            let automaticBranch = String(body[start.upperBound...])
            let deletions = automaticBranch.components(separatedBy: "SecItemDelete").count - 1
            XCTAssertEqual(deletions, 2,
                           "\(anchor) 的自动档必须删两层（DP + 经典），实际出现 \(deletions) 次 SecItemDelete")
        }
    }

    /// 从锚点开始的**花括号**块，配平取整段。
    ///
    /// 不用全文 `contains`：那会把「同名符号的定义行」或相邻函数也算进来，
    /// 一条断言看着通过了、实际守的是别人的代码。
    private func braceBalancedBlock(in text: String, anchor: String) throws -> String {
        guard let hit = text.range(of: anchor) else { throw BlockNotFound(anchor: anchor) }
        guard let open = text[hit.upperBound...].firstIndex(of: "{") else {
            throw BlockNotFound(anchor: anchor)
        }
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        throw BlockNotFound(anchor: anchor)
    }

    private struct BlockNotFound: Error, CustomStringConvertible {
        let anchor: String
        var description: String { "找不到配平的块：\(anchor)" }
    }
}
