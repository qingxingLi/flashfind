import XCTest
import CryptoKit
@testable import FlashFindCore

/// Phase 6.3b-4：**产品装配**的跨进程端到端。
///
/// ## 它要回答的问题
///
/// 6.3b-1 证明执行层能搜，6.3b-2/3 证明真 Provider 能搜，但它们都是**测试自己**
/// 把 `AppModel` 那套装配手工拼了一遍（手工 `AuthorityListener`、手工 registry、
/// 手工 `SourceExecutionHandle`）。产品真正启动时会不会也拼对——真 App 进程里
/// 真 `MCPAuthorityController` + 真 `AppModel` + 真 provider 能不能被一个真
/// MCP 客户端叫通——只有真的启动一次才知道。
///
/// ```text
/// 真 FlashFind2App 进程（.build/debug/FlashFind2App，装在临时 .app 里）
///        ↓ 真 MCPAuthorityController / 真 AppModel / 真 LocalSearchProvider
///   Unix Socket（临时路径，FF_AUTHORITY_SOCKET）
///        ↓
/// 真 flashfind-mcp（.build/debug/FlashFindMCP）—— stdio 说 MCP
/// ```
///
/// ## 边界：harness 只做四件事
///
/// 启动 App、启动 Helper、发 MCP 报文、读结果。**不替 App 配置 provider、
/// 不替 App 决定授权、不调 `MCPHandler`**：一旦替了，要验的「产品装配」就没了。
/// 本机搜索范围是 App 自己从偏好里读出来再套到 provider 上的。
///
/// ## 为什么 App 要包一层临时 .app
///
/// 产品是 `.app`：`Bundle.main.resourceURL` 是 `Contents/Resources`，AppModel 在那儿
/// 找 `MyNAS/bin/mynas-core`；裸可执行文件的 resourceURL 是它所在的构建目录。
/// 这个包装只是给真二进制一个产品形态的外壳（+ `LSUIElement` 不进 Dock），
/// 不改任何代码路径。
///
/// ## 与红证的关系
///
/// 这条测试会真起 GUI 进程，**不进批跑变异**；它只在逐条归因里单跑，
/// 用来证明「MCP 执行路径不套用本机搜索范围」这类装配级变异能被抓住。
final class ProductAssemblyE2ETests: XCTestCase {

    private var app: AppRun?
    private var helper: HelperRun?

    override func tearDownWithError() throws {
        helper?.stop()
        helper = nil
        app?.terminate()
        app = nil
    }

    // MARK: - ① 主链路：真 App + 真 Helper + stdio locate

    /// 8 个验收点里的 1–6 + 7–8（退出/恢复）。
    func testTheRealAppServesLocateOverStdioAndRecoversAfterRestart() throws {
        let stage = try makeStage(aiEnabled: true)
        defer { try? FileManager.default.removeItem(at: stage.root) }

        // ── ① 启动真 App（不是测试里手工 new 的 AuthorityListener）
        let appRun = try AppRun(launching: stage)
        app = appRun
        XCTAssertTrue(appRun.waitUntilListening(timeout: 30),
                      "真 App 没在临时 socket 上监听。stderr：\n\(appRun.stderrText)")
        XCTAssertTrue(appRun.isRunning, "App 进程已经退出，后面的断言没有意义")

        // ── ② 启动真 Helper，并通过 stdin/stdout 说 MCP
        let helperRun = try HelperRun(binary: try builtProduct("FlashFindMCP"),
                                      socketPath: stage.socketPath)
        helper = helperRun
        let helperPID = helperRun.pid

        // ── ③ initialize
        let initialized = try helperRun.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "product-e2e", "version": "0"],
        ])
        let initResult = try XCTUnwrap(initialized["result"] as? [String: Any],
                                       "initialize 没有 result：\(initialized)")
        XCTAssertEqual(initResult["protocolVersion"] as? String, "2025-06-18")
        let serverInfo = try XCTUnwrap(initResult["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, MCPHandler.serverName)
        let capabilities = try XCTUnwrap(initResult["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"], "没声明 tools 能力")
        try helperRun.notify("notifications/initialized")

        // ── ④ tools/list：六个，名字与顺序来自 ToolCatalog
        let listed = try helperRun.request("tools/list")
        let listResult = try XCTUnwrap(listed["result"] as? [String: Any])
        let tools = try XCTUnwrap(listResult["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ToolCatalog.all.map(\.name),
                       "tools/list 必须恰好是 ToolCatalog 那六个（顺序一致）")
        XCTAssertEqual(ToolCatalog.all.count, 6)

        // ── ⑤ list_sources：只列 App 当前实际授权的来源
        //
        // 偏好里只授权了 `local_mac`。名字取自 App 的 `aiAccessCandidates`
        // （`SearchSource.local.displayName`）——这条同时说明清单**来自 App 的
        // 来源宇宙**，不是助手或测试编的。
        let sources = try helperRun.toolCall("list_sources", [:])
        XCTAssertFalse(sources.isError, "list_sources 不该失败：\(sources.rawText)")
        let sourceList = try XCTUnwrap(sources.payload["sources"] as? [[String: Any]])
        XCTAssertEqual(sourceList.count, 1, "只授权了 local_mac，不该列出别的：\(sourceList)")
        XCTAssertEqual(sourceList.first?["source_id"] as? String, SearchSource.local.id)
        XCTAssertEqual(sourceList.first?["name"] as? String, SearchSource.local.displayName)

        // ── ⑥ tools/call locate：命中已知目标，且**只在授权的本机范围里**搜
        let located = try helperRun.toolCall("locate", ["query": stage.token,
                                                       "limit": 10])
        XCTAssertFalse(located.isError, "locate 不该失败：\(located.rawText)")
        let hits = try XCTUnwrap(located.payload["results"] as? [[String: Any]],
                                 "locate 没有 results：\(located.payload)")
        XCTAssertEqual(hits.count, 1,
                       "同名文件在授权目录里只有一个；多出来的是越界搜了别处："
                       + "\(hits.map { $0["relative_path"] ?? "?" })")
        XCTAssertEqual(located.payload["truncated"] as? Bool, false)

        let hit = try XCTUnwrap(hits.first)
        XCTAssertEqual(hit["source_id"] as? String, SearchSource.local.id)
        XCTAssertEqual(hit["kind"] as? String, "file")
        let relative = try XCTUnwrap(hit["relative_path"] as? String)
        XCTAssertEqual(relative, stage.expectedRelative,
                       "relative_path 是相对 `/` 的词法路径（local_mac 的口径）")
        XCTAssertFalse(relative.hasPrefix("/"))
        XCTAssertEqual(hit["file_id"] as? String,
                       goldenFileID(sourceID: SearchSource.local.id, relativePath: relative),
                       "file_id 必须等于独立计算的 golden")

        // 摘要：证据目录里看到这一行，才能把「跑过」与「据说跑过」分开。
        print("PRODUCT-E2E ok · app=real · helper=real · hits=\(hits.count) "
              + "· relative=\(relative) · file_id=\(hit["file_id"] as? String ?? "?")")

        // ── ⑦ App 退出后，**同一个 Helper** 下一次 call → flashfind_app_unavailable
        appRun.terminate()
        app = nil
        XCTAssertFalse(appRun.isRunning, "App 没退出")

        let afterQuit = try helperRun.toolCall("locate", ["query": stage.token])
        XCTAssertTrue(afterQuit.isError, "App 不在了就不许假装搜过：\(afterQuit.rawText)")
        XCTAssertEqual(afterQuit.errorCode, UnixSocketAuthorityLink.appUnavailableCode,
                       "App 退出后的错误码必须是 flashfind_app_unavailable，实际：\(afterQuit.rawText)")

        // ── ⑧ App 再启动，**不重启 Helper**，下一次 call 自动恢复
        //
        // 这一条验的是「每请求重新 connect」在**产品装配**里也成立，而不只是
        // Core 的单元测试里成立。Helper 的 pid 必须没变——变了就说明测试偷偷
        // 重启了助手，恢复了也不算数。
        let relaunched = try AppRun(launching: stage)
        app = relaunched
        XCTAssertTrue(relaunched.waitUntilListening(timeout: 30),
                      "App 重启后没重新监听。stderr：\n\(relaunched.stderrText)")
        XCTAssertEqual(helperRun.pid, helperPID, "Helper 不许被重启")

        let recovered = try helperRun.toolCall("locate", ["query": stage.token])
        XCTAssertFalse(recovered.isError, "App 回来后同一个 Helper 必须能恢复：\(recovered.rawText)")
        let recoveredHits = try XCTUnwrap(recovered.payload["results"] as? [[String: Any]])
        XCTAssertEqual(recoveredHits.count, 1, "恢复后应当仍能命中那一个文件：\(recoveredHits)")

        // ── stdout 归协议独占：一路下来每一行都必须是 JSON-RPC
        for line in helperRun.stdoutLines {
            guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                return XCTFail("stdout 出现非 JSON 的一行：\(line)")
            }
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0", "不是 JSON-RPC 报文：\(line)")
        }
    }

    // MARK: - ② AI 关着时由 App 判，不是助手猜

    /// 助手没有任何依据说「用户关了 AI」（v0.18 撤回 `facts`）。所以这一条验的是
    /// **App 按实时设置判出来**的 `mcp_disabled`：同样的 Helper、同样的 socket，
    /// 只要偏好里 `ff2.aiAccess.enabled.v1=false`，App 就回这个码。
    func testTheAppItselfReportsDisabledAIAccess() throws {
        let stage = try makeStage(aiEnabled: false)
        defer { try? FileManager.default.removeItem(at: stage.root) }

        let appRun = try AppRun(launching: stage)
        app = appRun
        XCTAssertTrue(appRun.waitUntilListening(timeout: 30),
                      "真 App 没起来。stderr：\n\(appRun.stderrText)")

        let helperRun = try HelperRun(binary: try builtProduct("FlashFindMCP"),
                                      socketPath: stage.socketPath)
        helper = helperRun
        _ = try helperRun.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "product-e2e", "version": "0"],
        ])
        try helperRun.notify("notifications/initialized")

        let call = try helperRun.toolCall("list_sources", [:])
        XCTAssertTrue(call.isError, "AI 关着时不许成功：\(call.rawText)")
        XCTAssertEqual(call.errorCode, PermissionDenial.mcpDisabled.rawValue,
                       "关闭状态必须由 App 判成 mcp_disabled，实际：\(call.rawText)")
    }

    // MARK: - ③ 本机开关压过 AI 授权，但不删授权（§15 #26）

    /// `ff2.localEnabled=false` + AI 授权里勾着 `local_mac`：
    ///
    /// ```text
    /// list_sources       → mcp_disabled（唯一授权来源被全局关掉 = 没有可用来源）
    /// tools/call locate  → mcp_disabled（不执行本机 provider）
    /// 只把开关打开（授权一个字没改）→ local_mac 立刻回来
    /// ```
    ///
    /// ★ 最后一步是本条的重点：授权是 **latent** 的，本机关着只是「当前不可执行」。
    /// 如果实现拿「当前可执行集合」去 `pruned` 授权，恢复时就会要求用户重新勾一次
    /// ——而 UI 上他只是关了个开关。
    ///
    /// ★ 这条也是**装配级**的：`aiAccessUsableCandidates` 到底有没有接到
    /// `MCPAuthority` 的 `sources` 闭包上，只有真 App 跑起来才知道。
    func testTurningOffLocalSearchHidesTheMacWithoutForgettingItsAuthorization() throws {
        let off = try makeStage(aiEnabled: true, localEnabled: false)
        defer { try? FileManager.default.removeItem(at: off.root) }

        let appRun = try AppRun(launching: off)
        app = appRun
        XCTAssertTrue(appRun.waitUntilListening(timeout: 30),
                      "真 App 没起来。stderr：\n\(appRun.stderrText)")

        let helperRun = try HelperRun(binary: try builtProduct("FlashFindMCP"),
                                      socketPath: off.socketPath)
        helper = helperRun
        _ = try helperRun.request("initialize", params: [
            "protocolVersion": "2025-06-18",
            "capabilities": [:] as [String: Any],
            "clientInfo": ["name": "product-e2e", "version": "0"],
        ])
        try helperRun.notify("notifications/initialized")

        let listed = try helperRun.toolCall("list_sources", [:])
        XCTAssertTrue(listed.isError,
                      "本机关着时不该还列出一个搜不了的来源：\(listed.rawText)")
        XCTAssertEqual(listed.errorCode, PermissionDenial.mcpDisabled.rawValue)

        let located = try helperRun.toolCall("locate", ["query": off.token])
        XCTAssertTrue(located.isError, "关掉的来源不许照常搜：\(located.rawText)")
        XCTAssertEqual(located.errorCode, PermissionDenial.mcpDisabled.rawValue,
                       "全局关闭必须压过 AI 授权，实际：\(located.rawText)")

        appRun.terminate()
        app = nil

        let on = try restaged(off, localEnabled: true)
        let relaunched = try AppRun(launching: on)
        app = relaunched
        XCTAssertTrue(relaunched.waitUntilListening(timeout: 30),
                      "App 重启后没重新监听。stderr：\n\(relaunched.stderrText)")

        let back = try helperRun.toolCall("list_sources", [:])
        XCTAssertFalse(back.isError, "开关一打开就该恢复，不该要求重新授权：\(back.rawText)")
        let sources = try XCTUnwrap(back.payload["sources"] as? [[String: Any]])
        XCTAssertEqual(sources.compactMap { $0["source_id"] as? String }, [SearchSource.local.id],
                       "同一份授权下打开开关，本机应当原样回来：\(sources)")
    }

    // MARK: - 舞台

    /// 一次测试的全部外部输入。
    struct Stage {
        let root: URL
        let socketPath: String
        let cacheDirectory: URL
        let preferencesJSON: String
        /// 文件名里的唯一词：查询用它，避免撞上机器上别的文件。
        let token: String
        /// 期望的 `relative_path`（相对 `/` 的词法路径，无前导斜杠）。
        let expectedRelative: String
    }

    /// 同一舞台、**同一份 AI 授权**，只换本机开关。
    ///
    /// 刻意不重建 `.app` 外壳、不换 socket、不换 cache：这一条要验的是
    /// 「只翻一个开关」的效果，别把 App 的其它输入一起改了。
    private func restaged(_ stage: Stage, localEnabled: Bool) throws -> Stage {
        let scope = stage.root.appendingPathComponent("授权目录", isDirectory: true)
        let preferences: [String: Any] = [
            AIAccessStore.enabledKey: true,
            AIAccessStore.sourcesKey: [SearchSource.local.id],
            "ff2.localEnabled": localEnabled,
            "ff2.localSearchMode": LocalSearchMode.selectedFolders.rawValue,
            "ff2.localFolders": [scope.path],
        ]
        let data = try JSONSerialization.data(withJSONObject: preferences)
        return Stage(root: stage.root,
                     socketPath: stage.socketPath,
                     cacheDirectory: stage.cacheDirectory,
                     preferencesJSON: try XCTUnwrap(String(data: data, encoding: .utf8)),
                     token: stage.token,
                     expectedRelative: stage.expectedRelative)
    }

    /// 建临时舞台：授权目录（有目标文件）+ 诱饵目录（同名文件，不许被搜到）
    /// + 真 App 的临时 .app 外壳 + 偏好 JSON。
    private func makeStage(aiEnabled: Bool, localEnabled: Bool = true) throws -> Stage {
        // `/private/tmp` 而不是 `NSTemporaryDirectory()`：后者给 `/var/folders/…`。
        // 本地搜索不受信任库影响，但两个 Phase 用同一种舞台路径少一类变量。
        let root = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ff2-product-e2e-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let scope = root.appendingPathComponent("授权目录", isDirectory: true)
        let decoy = root.appendingPathComponent("诱饵目录", isDirectory: true)
        for directory in [scope, decoy] {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        }

        let token = "e2e" + UUID().uuidString.prefix(6).lowercased()
        let name = "交付验证-\(token).pdf"
        try Data("scope".utf8).write(to: scope.appendingPathComponent(name))
        try Data("decoy".utf8).write(to: decoy.appendingPathComponent(name))

        // 独立枚举拿到 fixture 文件的词法路径（不拿我们拼的字符串当基准）。
        let expectedAbsolute = try lexicalPath(ofFileNamed: name, under: scope)

        try makeAppBundle(in: root, from: try builtProduct("FlashFind2App"))

        let cache = root.appendingPathComponent("cache", isDirectory: true)
        try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)

        let preferences: [String: Any] = [
            AIAccessStore.enabledKey: aiEnabled,
            AIAccessStore.sourcesKey: [SearchSource.local.id],
            "ff2.localEnabled": localEnabled,
            "ff2.localSearchMode": LocalSearchMode.selectedFolders.rawValue,
            "ff2.localFolders": [scope.path],
        ]
        let data = try JSONSerialization.data(withJSONObject: preferences)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        return Stage(root: root,
                     socketPath: root.appendingPathComponent("ipc/mcp.sock").path,
                     cacheDirectory: cache,
                     preferencesJSON: json,
                     token: token,
                     expectedRelative: expectedAbsolute)
    }

    /// 词法路径（相对 `/`、无前导斜杠、NFC）——与 `LocalProviderE2ETests` 同一口径。
    private func lexicalPath(ofFileNamed name: String, under directory: URL) throws -> String {
        let finder = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: nil)
        while let url = finder?.nextObject() as? URL {
            guard url.lastPathComponent == name else { continue }
            return url.path.split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/").precomposedStringWithCanonicalMapping
        }
        throw StageError.fixtureMissing(name)
    }

    private enum StageError: Error, CustomStringConvertible {
        case fixtureMissing(String)
        case productMissing([String])
        var description: String {
            switch self {
            case .fixtureMissing(let name): return "临时目录里没有 fixture 文件：\(name)"
            case .productMissing(let paths):
                return "找不到已构建的产品可执行文件（找过：\(paths.joined(separator: "、"))）。"
                    + "先跑 `swift build`，或用 FLASHFIND_MCP_BINARY / FLASHFIND_APP_BINARY 指过去。"
            }
        }
    }

    // MARK: - 真 App 的 .app 外壳

    /// 把真可执行文件包成最小 .app：`Contents/MacOS/<exe>` + `Contents/Resources/MyNAS`。
    ///
    /// 只补产品形态需要的东西（resourceURL 指向 Resources、`LSUIElement` 不进 Dock），
    /// 不复制任何代码路径。`MyNAS` 必须真的在，否则 `AppModel.ensureProviderCoordinator`
    /// 会停在「应用缺少搜索资源」，本地来源拿不到执行句柄——那会表现成
    /// `source_unavailable`，而不是这条用例要验的东西。
    private func makeAppBundle(in root: URL, from executable: URL) throws {
        let contents = root.appendingPathComponent("FlashFind2E2E.app/Contents", isDirectory: true)
        let macos = contents.appendingPathComponent("MacOS", isDirectory: true)
        let resources = contents.appendingPathComponent("Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: macos, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: executable,
                                         to: macos.appendingPathComponent("FlashFind2App"))

        let coreSource = clientRoot.appendingPathComponent("Resources/MyNAS")
        guard FileManager.default.fileExists(atPath: coreSource.appendingPathComponent("bin/mynas-core").path) else {
            // `Resources/MyNAS` 是 `scripts/build_mynas_resources.py` 的**产物**，
            // 不是源码：它由 Dart AOT 核心 + 原生 HTTPS 助手组成，公开仓按设计
            // 不含（体积、可复现性、以及「别把二进制塞进源码仓」三条）。
            //
            // 所以「源码仓里没有它」是正常状态，不是缺陷——skip 而不是红。
            // ★ 必须 skip 得看得见：测试报告里会明确列出 skipped，不是静默通过。
            //   client 里这个目录恒在（构建流程保证），真丢了会是另一条断言先炸。
            throw XCTSkip("""
                没有预编译的 MyNAS 核心：\(coreSource.path)
                它是 build_mynas_resources.py 的产物，源码仓（公开仓）按设计不含。
                要跑这组产品 E2E：先 `python3 scripts/build_mynas_resources.py --output Resources/MyNAS`。
                """)
        }
        try FileManager.default.copyItem(at: coreSource,
                                         to: resources.appendingPathComponent("MyNAS"))

        let plist: [String: Any] = [
            "CFBundleExecutable": "FlashFind2App",
            "CFBundleIdentifier": "com.flashfind.e2e.harness",
            "CFBundleName": "FlashFind2E2E",
            "CFBundlePackageType": "APPL",
            "CFBundleShortVersionString": "0.0",
            "CFBundleVersion": "0",
            "LSMinimumSystemVersion": "13.0",
            "LSUIElement": true,
            "NSPrincipalClass": "NSApplication",
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist,
                                                      format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
    }

    // MARK: - 已构建的产品

    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
    }

    /// 找已构建的可执行文件。找不到就**失败**而不是跳过——跳过等于这条最重要的
    /// 用例从来没跑过（与 `MCPStdioTests` 同一个理由）。
    private func builtProduct(_ name: String) throws -> URL {
        let overrideKey = name == "FlashFindMCP" ? "FLASHFIND_MCP_BINARY" : "FLASHFIND_APP_BINARY"
        if let override = ProcessInfo.processInfo.environment[overrideKey], !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            throw StageError.productMissing([url.path])
        }

        let build = clientRoot.appendingPathComponent(".build")
        var candidates = [build.appendingPathComponent("debug/\(name)")]
        if let entries = try? FileManager.default.contentsOfDirectory(at: build,
                                                                     includingPropertiesForKeys: nil) {
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.pathExtension.isEmpty {
                candidates.append(entry.appendingPathComponent("debug/\(name)"))
            }
        }
        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw StageError.productMissing(candidates.map(\.path))
    }

    // MARK: - golden（独立实现，不调 FileID.make）

    /// 前像：`utf8(source_id) + 0x1F + "path:" + utf8(NFC(相对路径))`，取前 128 位。
    private func goldenFileID(sourceID: String, relativePath: String) -> String {
        var preimage = Data(sourceID.utf8)
        preimage.append(0x1F)
        preimage.append(contentsOf: Data("path:".utf8))
        preimage.append(contentsOf: Data(relativePath.precomposedStringWithCanonicalMapping.utf8))
        let digest = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
        return "ff1_" + String(digest.prefix(32))
    }
}

// MARK: - 真 App 进程

/// 真 `FlashFind2App` 的一次运行。
private final class AppRun {

    private let process = Process()
    private let errors = TextBox()
    private let socketPath: String

    init(launching stage: ProductAssemblyE2ETests.Stage) throws {
        let executable = stage.root
            .appendingPathComponent("FlashFind2E2E.app/Contents/MacOS/FlashFind2App")
        socketPath = stage.socketPath

        var environment = ProcessInfo.processInfo.environment
        // 只换「偏好从哪儿来、socket 绑哪儿、要不要开窗」（见 E2ELaunchMode）。
        environment["FF_E2E_LAUNCH"] = "1"
        environment["FF_E2E_PREFERENCES"] = stage.preferencesJSON
        environment["FF_E2E_CACHE_DIR"] = stage.cacheDirectory.path
        environment["FF_AUTHORITY_SOCKET"] = stage.socketPath
        process.environment = environment
        process.executableURL = executable

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        // GUI 进程的两个管道都要有人读：写满 64 KB 会把子进程堵死。
        drain(stdoutPipe.fileHandleForReading, into: errors)
        drain(stderrPipe.fileHandleForReading, into: errors)
        try process.run()
    }

    var pid: Int32 { process.processIdentifier }
    var isRunning: Bool { process.isRunning }
    var stderrText: String { errors.text }

    /// socket 真的能往返一次 ping 才算「起来了」：文件存在只说明 bind 过。
    func waitUntilListening(timeout: TimeInterval) -> Bool {
        let limits = AuthorityLimits()
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if !process.isRunning { return false }
            if UnixSocketAuthorityLink.ping(path: socketPath, limits: limits) { return true }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return false
    }

    func terminate() {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.05)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

// MARK: - 真 Helper 进程

/// 真 `flashfind-mcp`：一条长连接（进程）跨 App 重启存活，报文走 stdin/stdout。
private final class HelperRun {

    struct ToolReply {
        let isError: Bool
        let payload: [String: Any]
        let rawText: String
        var errorCode: String? { payload["code"] as? String }
    }

    private let process = Process()
    private let stdinPipe = Pipe()
    private let stdout = TextBox()
    private let stderr = TextBox()
    private var nextID = 1
    private var readIndex = 0

    init(binary: URL, socketPath: String) throws {
        var environment = ProcessInfo.processInfo.environment
        // 与 App 同一个变量：助手在 DEBUG 构建里读它（main.swift 的 `#if DEBUG`）。
        environment["FF_AUTHORITY_SOCKET"] = socketPath
        process.environment = environment
        process.executableURL = binary

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe
        try process.run()

        drain(stdoutPipe.fileHandleForReading, into: stdout)
        drain(stderrPipe.fileHandleForReading, into: stderr)
    }

    var pid: Int32 { process.processIdentifier }
    var stdoutLines: [String] { stdout.lines }
    var stderrText: String { stderr.text }

    // MARK: 报文

    @discardableResult
    func request(_ method: String, params: [String: Any]? = nil) throws -> [String: Any] {
        let id = nextID
        nextID += 1
        var message: [String: Any] = ["jsonrpc": "2.0", "id": id, "method": method]
        if let params { message["params"] = params }
        try send(message)
        return try waitForResponse(id: id)
    }

    func notify(_ method: String) throws {
        try send(["jsonrpc": "2.0", "method": method])
    }

    func toolCall(_ name: String, _ arguments: [String: Any]) throws -> ToolReply {
        let response = try request("tools/call",
                                   params: ["name": name, "arguments": arguments])
        let result = try XCTUnwrap(response["result"] as? [String: Any],
                                   "tools/call 没有 result：\(response)")
        let content = try XCTUnwrap((result["content"] as? [[String: Any]])?.first)
        let text = try XCTUnwrap(content["text"] as? String)
        let payload = (try? JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]) ?? [:]
        return ToolReply(isError: result["isError"] as? Bool ?? false,
                         payload: payload,
                         rawText: text)
    }

    private func send(_ message: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: message)
        var line = data
        line.append(0x0A)
        stdinPipe.fileHandleForWriting.write(line)
    }

    /// 按 id 等响应。中间出现的其他行（通知等）也算在 stdout 里，最后统一校验。
    private func waitForResponse(id: Int) throws -> [String: Any] {
        let deadline = Date().addingTimeInterval(30)
        while Date() < deadline {
            let lines = stdout.lines
            while readIndex < lines.count {
                let line = lines[readIndex]
                readIndex += 1
                guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else {
                    throw HelperError.nonJSONLine(line)
                }
                if object["id"] as? Int == id { return object }
            }
            Thread.sleep(forTimeInterval: 0.02)
        }
        throw HelperError.timeout(id: id, stdout: stdout.text, stderr: stderr.text)
    }

    /// 关掉 stdin 让助手自己退出（`print` 的块缓冲只有在正常退出时才 flush）。
    func stop() {
        try? stdinPipe.fileHandleForWriting.close()
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
    }
}

private enum HelperError: Error, CustomStringConvertible {
    case nonJSONLine(String)
    case timeout(id: Int, stdout: String, stderr: String)

    var description: String {
        switch self {
        case .nonJSONLine(let line):
            return "助手 stdout 出现非 JSON 的一行：\(line)"
        case .timeout(let id, let stdout, let stderr):
            return "等 id=\(id) 的响应超时。\nstdout：\n\(stdout)\nstderr：\n\(stderr)"
        }
    }
}

// MARK: - 管道

/// 后台把管道读空并按行切好。锁而不是 actor：读端在 GCD 队列、用例在测试线程。
private final class TextBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func append(_ chunk: Data) {
        lock.lock()
        buffer.append(chunk)
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return String(decoding: buffer, as: UTF8.self)
    }

    var lines: [String] {
        text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
    }
}

private func drain(_ handle: FileHandle, into box: TextBox) {
    DispatchQueue.global().async {
        while true {
            let chunk = handle.availableData
            if chunk.isEmpty { break }
            box.append(chunk)
        }
    }
}
