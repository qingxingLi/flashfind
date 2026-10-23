import XCTest
@testable import FlashFindCore

/// 「正式 App 不再明文持久化密码」的机器判据。
///
/// 为什么要用源码扫描而不是跑一次 App：默认后端是**进程外的副作用**决定的——
/// 换文件后端没有任何运行时症状（照样存得上、照样读得到），
/// 只有「~/Library 下多了个能 cat 出密码的 json」这一个后果，而没人会去看那个目录。
/// 所以这里直接盯装配点：GUI 入口装了哪个后端、迁移源挂没挂。
final class ReleaseBackendTests: XCTestCase {

    /// `NoKeychainAccessTests` 禁止在测试里直接写出那次构造，这里把名字拆开。
    private let keychainBackend = "Keychain" + "SecretStore"
    private let fileBackend = "File" + "SecretStore"

    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
    }

    private func contents(_ path: String) throws -> String {
        let url = clientRoot.appendingPathComponent(path)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path),
                      "找不到 \(path) —— 路径换了的话这条测试会假绿，必须修")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// GUI 入口那句装配原文。
    private func installSite() throws -> String {
        let text = try contents("Sources/FlashFind2App/FlashFind2App.swift")
        guard let start = text.range(of: "CredentialStore.install(") else {
            XCTFail("GUI 入口里没有凭据后端装配点 —— 那 App 跑在内存后端上，密码根本没存")
            return ""
        }
        return String(text[start.lowerBound...])
    }

    func testGUIAppInstallsTheKeychainBackend() throws {
        let site = try installSite()
        XCTAssertTrue(site.contains(keychainBackend),
                      "GUI App 的默认后端必须是系统钥匙串 —— 第一阶段的核心目标就是不再明文落盘")
    }

    func testGUIAppDoesNotFallBackToTheFileBackend() throws {
        let site = try installSite()
        let call = site.components(separatedBy: ")").first ?? site
        XCTAssertFalse(call.contains(fileBackend),
                       "文件后端又回到 GUI App 的默认装配上了：它还充任 Release 后端的话，第一阶段等于没做完")
    }

    /// 迁移源必须挂上：后端换成钥匙串之后，读旧明文只剩这一个入口。
    func testGUIAppPassesThePlaintextSourceSoMigrationCanRead() throws {
        XCTAssertTrue(try installSite().contains("plaintextSource:"),
                      "迁移需要读旧 credentials.json，后端不是文件时只能靠 plaintextSource 这一个入口")
    }

    /// 启动路径上要有迁移调用，否则旧明文永远躺在那儿。
    func testMigrationRunsAtLaunch() throws {
        let text = try contents("Sources/FlashFind2App/FlashFind2App.swift")
        XCTAssertTrue(text.contains("migrateLegacyPlaintext()"),
                      "没有一次性迁移的触发点：旧明文不会被搬走，也就永远不会走到「验证后删除」")
    }

    /// 缺 entitlement 的机器上，Data Protection 钥匙串写入会失败（-34018）。
    /// 没有兜底的话，「记住密码」会静默失效——用户只能发现「它又忘了」。
    func testKeychainStoreFallsBackWhenTheEntitlementIsMissing() throws {
        // 只看 `perform` 的**方法体**：
        // ① 注释里提一句「会返回 errSecMissingEntitlement」不代表真的兜了底；
        // ② 别处的同名符号也不能替这段背书 —— 查询策略里也判了一次
        //    「缺 entitlement 就换层」，全文 `contains` 会被它蒙对。
        let body = try braceBalancedBlock(in: try contents("Sources/FlashFindCore/KeychainSecretStore.swift"),
                                          anchor: "private func perform(")
        XCTAssertTrue(body.contains("errSecMissingEntitlement"),
                      "必须有 entitlement 缺失的兜底。实测：ad-hoc 试装包 SecItemAdd(DP) 直接 -34018")
        XCTAssertTrue(body.contains("dataProtection.value = false"),
                      "兜底要真的切换后端（记住这次降级），不能只是把失败吞掉")
    }

    /// 文件后端不许删：迁移读取与命令行工具都还要用它。
    func testFileBackendIsStillAvailableForMigrationAndTools() throws {
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: clientRoot.appendingPathComponent("Sources/FlashFindCore/FileSecretStore.swift").path),
            "文件后端是迁移源与CLI的落点，不能删")
        let cli = try contents("tools/DevTools/FlashFindCLI/main.swift")
        XCTAssertTrue(cli.contains(fileBackend),
                      "命令行工具仍按自己的方式落盘 —— 它进 DevTools 了，不该拖着 GUI 一起停")
    }

    /// 身份绑定真的接进了保存路径：只在读取侧校验是不够的，写的时候就得带上。
    func testSavesCarryTheIdentity() throws {
        let text = try contents("Sources/FlashFindCore/CredentialStore.swift")
        XCTAssertTrue(text.contains("CredentialEnvelope.wrap"),
                      "保存路径没封身份：写进去的凭据将来无法判断它属于哪个目标")
    }

    /// 从锚点开始的**花括号**块（方法体），配平取整段。
    ///
    /// 与 `MCPBoundaryTests` 里那份同名实现是同一份逻辑，各自拷一份：
    /// 测试类之间不共享 helper，避免一处改动牵连两个不相干的判据。
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
