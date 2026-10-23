import XCTest
@testable import FlashFindCore

/// 源码级闸口：**除钥匙串后端这一个文件外，产品代码不许再出现任何钥匙串条目访问**。
///
/// 为什么要有这种「看源码」的测试（而不是只测行为）：
/// 钥匙串弹窗是**进程外**的副作用——由系统 SecurityAgent 弹出，
/// 单次 XCTest 里根本观察不到，本机跑一百遍都是绿的，用户一开机就中招。
/// 一次典型的漏法：为了「顺手迁移旧条目」留了一次 `SecItemCopyMatching`，
/// 还加了 `kSecUseAuthenticationUIFail` 以为能静默——
/// 本机怎么跑都看不出来，用户一开机就被 SecurityAgent 拉起。
///
/// 选了「迁移到钥匙串」之后，这条断言从「完全不许碰」收窄成「只许一个文件碰」——
/// 仍然防得住上面那种「在别的文件里顺手调一次」。
final class NoKeychainAccessTests: XCTestCase {

    /// 只要碰钥匙串条目，就必然经过这几个 API 之一。
    private static let forbidden = [
        "SecItemCopyMatching", "SecItemAdd", "SecItemUpdate", "SecItemDelete",
        "SecKeychainFindGenericPassword", "SecKeychainAddGenericPassword",
        "SecKeychainSetUserInteractionAllowed",
    ]

    /// 唯一允许直接调用钥匙串条目的文件。它不是「例外」，是**唯一实现点**：
    /// 所有钥匙串访问都必须收在这里，好让这一条扫描守住其余全部代码。
    private static let allowedFile = "KeychainSecretStore.swift"

    private var sourcesRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
            .appendingPathComponent("Sources", isDirectory: true)
    }

    private var testsRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }

    /// 去掉注释行。
    ///
    /// 教训就在本文件里：第一版直接 `text.contains("import Security")`，
    /// 结果匹配到说明文字里那句「这个文件曾经 import Security」，自己把自己判成违例。
    private func codeLines(in text: String) -> [(number: Int, text: String)] {
        var result: [(Int, String)] = []
        for (offset, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("//") || trimmed.hasPrefix("*") || trimmed.hasPrefix("/*") { continue }
            result.append((offset + 1, String(line)))
        }
        return result
    }

    private func swiftFiles(under root: URL) -> [URL] {
        var files: [URL] = []
        let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles])
        while let url = enumerator?.nextObject() as? URL {
            if url.pathExtension == "swift" { files.append(url) }
        }
        return files
    }

    private func source(named name: String) throws -> String {
        let url = swiftFiles(under: sourcesRoot).first { $0.lastPathComponent == name }
        return try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)
    }

    // MARK: - 白名单守得住吗

    /// 白名单文件要是被改名了，扫描就会跳过它，而「没扫到」不会让断言失败 —— 假绿。
    func testTheWhitelistedFileStillExists() {
        let names = swiftFiles(under: sourcesRoot).map(\.lastPathComponent)
        XCTAssertTrue(names.contains(Self.allowedFile),
                      "\(Self.allowedFile) 不见了。它若被改名，上面的扫描会悄悄跳过它而变成假绿")
    }

    func testProductCodeNeverTouchesKeychainItemsOutsideTheStore() throws {
        let files = swiftFiles(under: sourcesRoot)
        XCTAssertFalse(files.isEmpty, "没扫到任何 .swift —— 路径算错了，这条测试会假绿，必须查")

        var offenses: [String] = []
        for file in files where file.lastPathComponent != Self.allowedFile {
            let text = try String(contentsOf: file, encoding: .utf8)
            for line in codeLines(in: text) {
                for api in Self.forbidden where line.text.contains(api) {
                    offenses.append("\(file.lastPathComponent):\(line.number) \(api)")
                }
            }
        }

        XCTAssertEqual(
            offenses, [],
            """
            除 \(Self.allowedFile) 之外又有代码去碰钥匙串了。
            每碰一次，用户就可能多一个授权弹窗（ad-hoc 包每次构建 cdhash 都变，条目 ACL 必然不认）。
            钥匙串访问一律收进 \(Self.allowedFile)。违例：
            \(offenses.joined(separator: "\n"))
            """)
    }

    func testCredentialStoreDoesNotImportSecurity() throws {
        // 凭据门面只做转发与审计，不该自己碰 Security 框架。
        let imports = codeLines(in: try source(named: "CredentialStore.swift"))
            .map(\.text)
            .filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("import ") }
        XCTAssertFalse(imports.contains("import Security"),
                       "CredentialStore 又 import Security 了 —— 钥匙串只该由 \(Self.allowedFile) 碰。")
    }

    // MARK: - 秘密不进普通配置文件

    /// 凭据后端不许把值写进 UserDefaults / plist 这类普通配置文件。
    /// 它们没有权限保护，任何同账户进程都读得到——比文件（0600）还弱。
    func testSecretStoresDoNotWriteToUserDefaults() throws {
        for name in ["CredentialStore.swift", "SecretStore.swift",
                     "FileSecretStore.swift", Self.allowedFile] {
            let code = codeLines(in: try source(named: name)).map(\.text).joined(separator: "\n")
            XCTAssertFalse(code.contains("UserDefaults"),
                           "\(name) 不许把凭据写进 UserDefaults —— 它没有权限保护")
        }
    }

    /// 允许构造真实钥匙串后端的**测试文件白名单**（文件名 → 理由）。
    ///
    /// 这条闸口守的是「跑测试时不许触发系统授权」。构造一个 `KeychainSecretStore`
    /// 本身**不发起任何 `SecItem*` 调用**——会弹窗的是 `save` / `read` / `delete`。
    /// 所以这里放行的不是「允许碰钥匙串」，而是「允许构造出一个从不发生 IO 的值」，
    /// 并且逐条写明理由；白名单之外的文件照旧一律禁止。
    private static let allowedInstantiations: [String: String] = [
        "KeychainTierMigrationTests.swift":
            "只读取 `usesDataProtectionKeychain` 状态位来证明「钉住层级」生效；"
            + "全程不调用 save/read/delete，因此不会触发任何钥匙串访问",
        "KeychainLookupTests.swift":
            "只构造后调用 `acrossTiers`，查询动作由假闭包注入（永不进入 Security 框架）；"
            + "全程不调用 save/read/delete，因此不会触发任何钥匙串访问"
    ]

    /// 测试**不许实例化真实钥匙串后端**：那会在跑测试时触发系统授权。
    func testTestsNeverInstantiateTheRealKeychainStore() throws {
        var offenders: [String] = []
        // 跳过本文件：它的断言消息里就写着那个类型名，否则会扫到自己身上。
        let myself = URL(fileURLWithPath: #filePath).lastPathComponent
        for file in swiftFiles(under: testsRoot) where file.lastPathComponent != myself {
            let text = try String(contentsOf: file, encoding: .utf8)
            let name = file.lastPathComponent
            for line in codeLines(in: text) where line.text.contains("KeychainSecretStore(") {
                guard Self.allowedInstantiations[name] != nil else {
                    offenders.append("\(name):\(line.number)")
                    continue
                }
                // 白名单内也只许「构造 + 读状态位」。同一行上出现任何 IO 调用，
                // 说明这个后端真的被用起来了 —— 照旧判违例。
                for io in [".save(", ".read(", ".delete(", "allAccounts("] where line.text.contains(io) {
                    offenders.append("\(name):\(line.number) 白名单内却发起了钥匙串 IO（\(io)）")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "测试里出现了真实钥匙串后端。要测迁移就传 InMemorySecretStore 当目标：\(offenders)")
    }

    /// 白名单不能变成空白背书：每一条都必须带理由，理由也不能是空话。
    func testInstantiationWhitelistCarriesAReason() {
        for (name, reason) in Self.allowedInstantiations {
            XCTAssertGreaterThan(reason.count, 10,
                                 "白名单里的 \(name) 必须写明为什么它可以构造真实后端")
        }
    }

    // MARK: - 启动路径不许先读凭据

    /// 凭据后端必须赶在 AppModel 之前装配：存储属性按声明顺序初始化，
    /// 晚一步 AppModel 读到的就是空的内存后端，用户会看到「明明记住了却又要输」。
    func testCredentialBackendIsInstalledBeforeTheModelIsBuilt() throws {
        let root = sourcesRoot.appendingPathComponent("FlashFind2App", isDirectory: true)
        let url = swiftFiles(under: root).first { $0.lastPathComponent == "FlashFind2App.swift" }
        let text = try String(contentsOf: try XCTUnwrap(url), encoding: .utf8)

        let lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        func line(of needle: String) -> Int? { lines.firstIndex { $0.contains(needle) } }

        let install = try XCTUnwrap(line(of: "credentialBackendInstalled"),
                                    "找不到凭据后端装配点 —— 没装的话整个 App 跑在内存后端上")
        let model = try XCTUnwrap(line(of: "let model: AppModel"),
                                  "找不到 model 声明，无法判断装配顺序")
        XCTAssertLessThan(install, model,
                          "凭据后端必须在 model 之前装配，否则 AppModel 初始化时读不到已保存的凭据")
    }
}
