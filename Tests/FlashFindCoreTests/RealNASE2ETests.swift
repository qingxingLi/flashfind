import XCTest
import CryptoKit
@testable import FlashFindCore

/// Phase 6.3b-3 的**最后一条 Gate**：真机 NAS 端到端。
///
/// ## 为什么必须有这一条
///
/// `NASProviderContractTests` 证明的是「产品代码里没有埋着『剥共享名』的假设」，
/// 但它喂给 Provider 的是**手写批次**。真机上还有三件事只有真机说了算：
///
/// 1. `NASSearchProvider` 与真 `mynas-core`（Dart AOT）之间的协议能不能走通
///    （`discover → login → selectScope → search`，缺一步核心就回 `needsAuth`）；
/// 2. DSM 真实返回的路径**是什么形态**（设备根 `/共享/…`，不是相对路径）——
///    这一点 6.3b-0 是实测出来的，本用例把它钉在真机链路上；
/// 3. 共享名在**真实返回**里确实保留在 `relative_path` 第一段，且 `file_id`
///    与独立计算的 golden 一致。
///
/// ## 凭据处理（硬约束）
///
/// 主机、账号、密码、共享、查询词、期望相对路径**全部只经环境变量**传入，
/// 源码里不留任何真机地址、账号、共享名或文件名。缺任何一个 → `XCTSkip`。
/// 这样 `swift test` 在没有真机环境的机器上仍然是绿的，而**在有环境时不会假装验过**。
///
/// ```sh
/// FLASHFIND_E2E_NAS_HOST=… FLASHFIND_E2E_NAS_USER=… FLASHFIND_E2E_NAS_PASSWORD=… \
/// FLASHFIND_E2E_NAS_SCOPE=/某共享 FLASHFIND_E2E_NAS_QUERY=某关键词 \
/// FLASHFIND_E2E_NAS_EXPECT_RELATIVE=某共享/某目录/某文件.pdf \
/// swift test --filter RealNASE2ETests
/// ```
///
/// ## 与 6.3b-4 的边界
///
/// 本用例起的是**真核心子进程 + 真 NAS**，但 authority 端用的是测试内起的
/// `AuthorityListener`（与产品同一份实现）。**它不替代 6.3b-4**——6.3b-4 要求的是
/// 真 App 进程 + 真 `flashfind-mcp` + stdio `initialize` + `tools/call locate`，
/// 验的是产品装配，不是这一条。
///
/// ## 6.4b-1：这里再补一条 `get_metadata` 的硬 Gate
///
/// `testGetMetadataAgainstRealNASReadsTheFileThroughTheFrozenHandle` 走的是
/// `locate → file_id → get_metadata`，并且在**同一次会话**里同时给出两条：
/// 一个真实存在的文件必须返回七字段元数据；同目录一个**编造的**名字必须得到
/// `file_not_found`。缺任何一条都不算证据——
/// 「存在文件能读」只证明协议通了，不证明「没有了」这件事能被如实报出来。
@MainActor
final class RealNASE2ETests: XCTestCase {

    // MARK: - 环境

    private struct Environment {
        let host: String
        let port: Int
        let user: String
        let password: String
        let scope: String
        let query: String
        let expectedRelative: String

        /// 缺任何必需项就返回 nil（→ 调用方 XCTSkip）。
        static func fromProcess() -> Environment? {
            let env = ProcessInfo.processInfo.environment
            func value(_ key: String) -> String? {
                guard let raw = env[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !raw.isEmpty else { return nil }
                return raw
            }
            guard let host = value("FLASHFIND_E2E_NAS_HOST"),
                  let user = value("FLASHFIND_E2E_NAS_USER"),
                  let password = value("FLASHFIND_E2E_NAS_PASSWORD"),
                  let scope = value("FLASHFIND_E2E_NAS_SCOPE"),
                  let query = value("FLASHFIND_E2E_NAS_QUERY"),
                  let expected = value("FLASHFIND_E2E_NAS_EXPECT_RELATIVE") else { return nil }
            let port = Int(value("FLASHFIND_E2E_NAS_PORT") ?? "5001") ?? 5001
            return Environment(host: host, port: port, user: user, password: password,
                               scope: scope.hasPrefix("/") ? scope : "/" + scope,
                               query: query, expectedRelative: expected)
        }

        /// 共享名（scope 去掉前导斜杠后的第一段）。
        var shareName: String {
            String(scope.dropFirst()).split(separator: "/").first.map(String.init) ?? ""
        }
    }

    /// 一次性地跳过（没有真机环境时不发任何网络请求）。
    private func environment() throws -> Environment {
        guard let env = Environment.fromProcess() else {
            throw XCTSkip("未配置真机 NAS 环境变量（FLASHFIND_E2E_NAS_*），跳过真机端到端")
        }
        return env
    }

    // MARK: - 核心可执行文件 / 装配

    /// 已编译核心的资源根：与 `NASSearchPipelineTests.coreResourceRoot` 同一约定
    /// （`FF_MYNAS_RESOURCE_ROOT` 优先，否则源码树里的 `Resources/MyNAS`）。
    ///
    /// 单独复制一份而不是共用：那个 helper 是 `private`，而「跨文件拷同一份 helper」
    /// 是本项目明令禁止的做法——所以这里只依赖**公开约定**（环境变量 + 目录布局），
    /// 不依赖对方的私有符号。
    private func coreResourceRoot() -> URL? {
        if let path = ProcessInfo.processInfo.environment["FF_MYNAS_RESOURCE_ROOT"] {
            return URL(fileURLWithPath: path)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Resources/MyNAS")
        guard FileManager.default.fileExists(atPath: root.appendingPathComponent("bin/mynas-core").path) else {
            return nil
        }
        return root
    }

    /// 独立的 golden 计算：不调 `FileID.make`（让公式写错时两边一起错就白测了）。
    /// 前像：`utf8(source_id) + 0x1F + "path:" + utf8(NFC(相对路径))`，取前 128 位。
    private func goldenFileID(sourceID: String, relativePath: String) -> String {
        let rel = relativePath.precomposedStringWithCanonicalMapping
        var preimage = Data(sourceID.utf8)
        preimage.append(0x1F)
        preimage.append(contentsOf: Data("path:".utf8))
        preimage.append(contentsOf: Data(rel.utf8))
        let digest = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
        return "ff1_" + String(digest.prefix(32))
    }

    private func located(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw NotSuccess()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private struct NotSuccess: Error {}

    // MARK: - 真机装配（两个用例共用同一份）

    /// 一次已就绪的真机会话。
    private struct Session {
        let provider: NASSearchProvider
        let scheduler: SearchScheduler
        let registry: [AuthoritySource]
        /// `file_id` 反查表。★ 与三个搜索 Tool 共用**这一张**——
        /// 这正是 `get_metadata` 能凭 id 找到文件的前提。
        let store: FileReferenceStore
        let sourceID: String
        let socketPath: String
        let bridge: MyNASProcessBridge
        /// 核心上报的协议事件。失败时能说清「卡在哪一步」。
        let events: () -> [[String: Any]]
    }

    /// 监听器的持有者：helper 负责收尾，body 只管用。
    private final class ListenerBox {
        var listener: AuthorityListener?
        func stop() { listener?.stop(); listener = nil }
    }

    /// 起真核心子进程 → 连真 DSM → 握手 / 登录 / 绑定 → 把装配交给 `body`。
    ///
    /// ★ 装配**只有这一份**：分开写两份就会出现「其中一份忘了接映射表、
/// 另一份仍然绿」的情况。6.4b-1 在单测侧已经踩过一次——三处落盘代码合成
    /// 一条变异，`replace(...,1)` 只删第一处，另外两处的用例在逐条里
    /// **根本没被打到**却被记成已证红。
    private func withRealNAS(_ body: (Environment, Session, ListenerBox) async throws -> Void) async throws {
        let env = try environment()
        guard let root = coreResourceRoot() else {
            throw XCTSkip("缺少已编译的 MyNAS 核心，先跑 scripts/build.sh core")
        }

        let sourceID = "src_e2e_nas"
        // ★ 必须用 `/private/tmp`，不能用 `NSTemporaryDirectory()`（它给的是
        // `/var/folders/…`）：`/var` 与 `/tmp` 都是符号链接，而信任库落盘前会
        // 逐级检查祖先目录**不是链接**（`UnsafeTrustDirectory`）。
        // 用带链接的路径会在确权时失败，而核心把任何 StateError 都收成
        // `ExplicitCertificateConfirmationRequired`——表现像「没确认过」，
        // 真因是落盘被拒。本机 2026-10-21 实测踩过。
        let scratch = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ff2-e2e-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let socketRoot = URL(fileURLWithPath: "/private/tmp")
            .appendingPathComponent("ff2-e2e-sock-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: socketRoot, withIntermediateDirectories: true)
        let socketPath = socketRoot.appendingPathComponent("authority.sock").path

        let bridge = MyNASProcessBridge(executable: root.appendingPathComponent("bin/mynas-core"),
                                        stateDirectory: scratch)
        // 诊断：把核心上报的协议事件收集起来，失败时能说清「卡在哪一步」。
        var protocolEvents: [[String: Any]] = []
        bridge.observeProtocol = { protocolEvents.append($0) }

        var store: FileReferenceStore?
        let box = ListenerBox()
        defer {
            box.stop()
            bridge.shutdown()
            store?.close()
            try? FileManager.default.removeItem(at: scratch)
            try? FileManager.default.removeItem(at: socketRoot)
        }

        let config = NASSourceConfig(id: sourceID, name: "E2E NAS", vendor: .synology,
                                     host: env.host, port: env.port, username: env.user,
                                     scopes: [env.scope])
        let provider = NASSearchProvider(bridge: bridge, config: config, port: env.port)
        // 真机 E2E 为避免 provider 内部过早超时，给足内部 budget；
        // 产品对外总超时仍由 `AuthorityLimits` 控制（`requestTimeout`，默认 10 s）。
        // 两处**不是同一个钟**，所以别把这里的数字当成「产品默认值」。
        provider.queryBudgetMs = 60_000
        provider.requestBudgetMs = 30_000

        // ── 握手（群晖走 sourcePin：首次连接会要求确认证书指纹）
        //
        // ★ 事件形状与产品向导一致：证书候选**嵌在 `candidate` 里**，不是顶层字段
        //   （`event == "certificateTrustRequired"`，payload 是 `{"candidate": {...}}`）。
        //   按顶层读会读不到 → 不确认 → 紧接着的 login 撞 `UnknownSource`
        //   （核心在 trustRequired 分支直接 return，没建 source）。这一条本轮踩过。
        let discovered = try await provider.discover()
        if let candidate = discovered["candidate"] as? [String: Any] {
            let candidateID = try XCTUnwrap(candidate["candidateID"] as? String,
                                            "要求确认证书但没有 candidateID：\(candidate)")
            let sha256 = try XCTUnwrap(candidate["sha256"] as? String,
                                       "要求确认证书但没有 sha256：\(candidate)")
            let expired = (candidate["expired"] as? Bool) ?? false
            // 设备证书**可以**是过期的：群晖出厂自签证书常年不续，产品向导的做法是
            // 明确告知并让用户确认（`allowExpired`），不是直接拒绝。这里与产品一致：
            // 如实把 `expired` 传下去，由信任库记成 `allowExpired: true` 的 pin。
            if expired {
                XCTAssertNotNil(candidate["validUntil"] as? String,
                                "过期证书必须能报出有效期：\(candidate)")
            }
            let trusted = try await provider.confirmTrust(
                candidateID: candidateID, sha256: sha256, allowExpired: expired)
            XCTAssertEqual(trusted["state"] as? String, "confirmed",
                           "确权后核心应回 trustState/confirmed：\(trusted)")
        }

        // ── 登录 + 绑定范围（就绪判据只能由 selectScopes 给出）
        try await provider.login(account: env.user, password: env.password)
        let shares = try await provider.loadShares()
        // 核心给的是**带前导斜杠的 scope 根**（`/docker`、`/某共享`），与
        // `selectScopes` 接受的形态一致；因此这里拿 `env.scope` 比，
        // 而不是去掉斜杠的裸共享名（真机实测：`["/docker", "/home", "/某共享"]`）。
        XCTAssertTrue(shares.contains(env.scope),
                      "账号看不到共享「\(env.scope)」（可见：\(shares)）")
        let bound = try await provider.selectScopes([env.scope])
        XCTAssertTrue(bound, "selectScope 未成功：\(env.scope)")
        XCTAssertTrue(provider.ready, "绑定范围后必须就绪，否则搜索会走 source_unavailable")

        let scheduler = SearchScheduler(providers: [provider])
        let registry = [AuthoritySource(id: provider.source.id, name: provider.source.name,
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))]
        let referenceStore = try FileReferenceStore(
            url: scratch.appendingPathComponent("ai-file-reference.sqlite"))
        store = referenceStore

        let session = Session(provider: provider, scheduler: scheduler, registry: registry,
                              store: referenceStore, sourceID: sourceID, socketPath: socketPath,
                              bridge: bridge, events: { protocolEvents })
        try await body(env, session, box)

        // 收尾：断开，让核心把会话释放掉（不留悬挂搜索）。
        _ = try? await bridge.command("disconnect", sourceID: sourceID)
    }

    /// 产品同款装配：每次请求现读设置 + 现读来源；映射表只在这一处接进执行器。
    private func service(for session: Session) -> RoutingAuthorityService {
        RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [session.sourceID]) },
            sources: { session.registry },
            referenceStore: session.store)
    }

    // MARK: - 真机端到端

    /// 真机一次完整 `locate`：真核心子进程 + 真 DSM + 真 authority socket。
    ///
    /// 断言顺序刻意从「最可能是环境问题」走到「最小粒度语义」：
    /// 就绪 → 共享可见 → 命中 → 共享名保留 → 身份与 golden 一致。
    func testLocateAgainstRealNASReturnsShareQualifiedRelativePath() async throws {
        try await withRealNAS { env, session, box in
            // 产品同款装配：真 Scheduler + 真权威端 + 真 socket。
            let authority = AuthorityListener(path: session.socketPath,
                                              service: service(for: session),
                                              log: { _ in })
            XCTAssertTrue(authority.start().isListening, "监听没起来")
            box.listener = authority

            let link = UnixSocketAuthorityLink(path: session.socketPath)
            let outcome = await link.call(tool: "locate",
                                          arguments: ToolArguments(["query": .string(env.query),
                                                                    "limit": .integer(10)]))
            let body = try located(outcome)
            let hits = try XCTUnwrap(body["results"] as? [[String: Any]],
                                     "locate 没有 results 字段：\(body)")

            guard let hit = hits.first(where: { ($0["relative_path"] as? String) == env.expectedRelative }) else {
                XCTFail("真机 locate「\(env.query)」没命中期望路径「\(env.expectedRelative)」；"
                        + "实际 \(hits.count) 条：\(hits.map { $0["relative_path"] ?? "?" })"
                        + "\n协议事件尾部：\(session.events().suffix(5))")
                return
            }

            let relative = try XCTUnwrap(hit["relative_path"] as? String)
            XCTAssertEqual(relative, env.expectedRelative)
            XCTAssertFalse(relative.hasPrefix("/"), "relative_path 不许带前导斜杠：\(relative)")
            XCTAssertEqual(relative.split(separator: "/").first.map(String.init), env.shareName,
                           "① 共享名必须保留在相对路径第一段（这是 6.3b-3 的拍板语义）")
            XCTAssertEqual(hit["source_id"] as? String, session.sourceID)
            XCTAssertEqual(hit["file_id"] as? String,
                           goldenFileID(sourceID: session.sourceID, relativePath: env.expectedRelative),
                           "真机 file_id 必须等于独立计算的 golden（source_id = 整台来源 + share 保留）")
            XCTAssertEqual(body["truncated"] as? Bool, false, "单个命中不该被截断")

            // 真机验收要留一条**可核查**的摘要（不含任何凭据）：证据目录里看到这一行，
            // 才能把「跑过」与「据说跑过」分开。
            print("REAL-NAS-E2E ok · scope=\(env.shareName) · hits=\(hits.count) "
                  + "· relative=\(relative) · file_id=\(hit["file_id"] as? String ?? "?") "
                  + "· truncated=\(body["truncated"] as? Bool ?? false)")
        }
    }

    /// ★ **6.4b-1 的硬 Gate**：真机上按路径直查元数据。
    ///
    /// 一次会话里同时给出两条，缺任一条都不算证据：
    ///
    /// 1. 真实存在的文件 → 七字段元数据（`file_id` / `source_id` / `name` /
    ///    `kind` / `relative_path` / `size_bytes` / `modified`）；
    /// 2. 同目录一个**编造的**名字 → `file_not_found`。
    ///
    /// 为什么②不能省：「存在文件能读」只证明协议通了，不证明「没有了」这件事能被
    /// 如实报出来。而 `file_not_found` 与 `source_unavailable` 的分野正是
    /// §4.11.2 的全部要害——只有真的走到了第 ④ 步（`reached == .lookedUp`），
    /// 才有资格说「这个文件不在了」。
    func testGetMetadataAgainstRealNASReadsTheFileThroughTheFrozenHandle() async throws {
        try await withRealNAS { env, session, box in
            let authority = AuthorityListener(path: session.socketPath,
                                              service: service(for: session),
                                              log: { _ in })
            XCTAssertTrue(authority.start().isListening, "监听没起来")
            box.listener = authority

            let link = UnixSocketAuthorityLink(path: session.socketPath)

            // ── 1. locate：拿一个真实存在的文件，并让它把 id 落进映射表
            let locatedOutcome = await link.call(
                tool: "locate",
                arguments: ToolArguments(["query": .string(env.query),
                                          "limit": .integer(10)]))
            let locatedBody = try located(locatedOutcome)
            let hits = try XCTUnwrap(locatedBody["results"] as? [[String: Any]],
                                     "locate 没有 results 字段：\(locatedBody)")
            guard let hit = hits.first(where: { ($0["relative_path"] as? String) == env.expectedRelative }) else {
                XCTFail("真机 locate 没命中「\(env.expectedRelative)」；实际 \(hits.count) 条："
                        + "\(hits.map { $0["relative_path"] ?? "?" })"
                        + "\n协议事件尾部：\(session.events().suffix(5))")
                return
            }
            let presentID = try XCTUnwrap(hit["file_id"] as? String)

            // ── 2. get_metadata：七字段齐全
            let metadataOutcome = await link.call(
                tool: "get_metadata",
                arguments: ToolArguments(["file_id": .string(presentID)]))
            guard case .success(let json) = metadataOutcome else {
                XCTFail("真机 get_metadata 失败了：\(metadataOutcome)"
                        + "\n协议事件尾部：\(session.events().suffix(5))")
                return
            }
            let payload = try XCTUnwrap(
                JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])

            let expectedKeys: Set<String> = ["file_id", "source_id", "name", "kind",
                                             "relative_path", "size_bytes", "modified"]
            XCTAssertEqual(Set(payload.keys), expectedKeys,
                           "get_metadata 出参必须是七字段闭集：\(payload.keys.sorted())")
            XCTAssertNil(payload["absolute_path"],
                         "★ §4.12：1.1.2 MCP 不输出 synthetic absolute_path")
            XCTAssertEqual(payload["file_id"] as? String, presentID)
            XCTAssertEqual(payload["source_id"] as? String, session.sourceID)
            XCTAssertEqual(payload["relative_path"] as? String, env.expectedRelative)
            let kind = try XCTUnwrap(payload["kind"] as? String, "kind 必须是字符串：\(payload)")
            XCTAssertFalse(kind.isEmpty, "kind 不许为空：\(payload)")
            let name = try XCTUnwrap(payload["name"] as? String, "name 必须是字符串：\(payload)")
            XCTAssertEqual(name, (env.expectedRelative as NSString).lastPathComponent,
                           "name 必须是路径的最后一段：\(payload)")

            // size_bytes / modified **必须存在**，但可以是 null —— 设备没给就是没给，
            // 不许用 0 冒充未知、也不许用 1970 冒充没给时间（§4.11.3）。
            XCTAssertNotNil(payload["size_bytes"],
                            "size_bytes 键必须存在（未知时是 null，不是不出现）：\(payload)")
            XCTAssertNotNil(payload["modified"],
                            "modified 键必须存在（未知时是 null，不是不出现）：\(payload)")

            // ── 3. 同目录一个不存在的文件 → file_not_found
            //
            // ★ 编造的那一段**不落在环境变量里**：它是测试自己造的随机名，
            // 不是真机事实，因此不需要也不应该由环境提供。
            let directory = (env.expectedRelative as NSString).deletingLastPathComponent
            let missingName = "ff2-missing-\(UUID().uuidString.prefix(8)).bin"
            let missingRelative = directory.isEmpty ? missingName : directory + "/" + missingName
            let missingID = try FileID.make(sourceID: session.sourceID,
                                            canonicalRelativePath: missingRelative)
            try session.store.register(FileReference(fileID: missingID,
                                                     sourceID: session.sourceID,
                                                     canonicalRelativePath: missingRelative))

            let missingOutcome = await link.call(
                tool: "get_metadata",
                arguments: ToolArguments(["file_id": .string(missingID.value)]))
            guard case .failure(let code, let message) = missingOutcome else {
                XCTFail("不存在的名字必须失败，却成功了：\(missingOutcome)")
                return
            }
            XCTAssertEqual(code, "file_not_found",
                           "来源可用、文件不在 → file_not_found（不是 source_unavailable）：\(message)")

            // 真机摘要：把「设备实际给了什么」打出来，证据里能一眼看出
            // 群晖的 `additional` 到底回没回 size / time。
            print("REAL-NAS-E2E metadata ok · present=\(env.expectedRelative) "
                  + "· kind=\(kind) · size_bytes=\(payload["size_bytes"].map { "\($0)" } ?? "nil") "
                  + "· modified=\(payload["modified"].map { "\($0)" } ?? "nil") "
                  + "· absent=\(missingRelative) → \(code)")
        }
    }
}
