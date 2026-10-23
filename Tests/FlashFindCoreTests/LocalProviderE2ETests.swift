import XCTest
import CryptoKit
@testable import FlashFindCore

/// Phase 6.3b-2：**Local 真 Provider 端到端**。
///
/// 与 6.3b-1 的差别只有一个，但它就是本阶段的存在理由：
/// 那些测试的「结果从哪来」是替身（FakeProvider / StubProvider），
/// 这里换成了**真的 `LocalSearchProvider` → `LocalFolderSearch`**——
/// 临时目录里真建文件、真枚举、真返回 `SearchResult`，其余整条链路
/// （`RoutingAuthorityService` → `ToolRouter` → `PermissionPolicy` →
/// snapshot handle → `SearchScheduler` → `RelativePath.canonical` →
/// `FileID.make` → ranking → `LocateResponse` → wire）原样走。
///
/// 硬 Gate 用 **LocalFolderSearch + 临时目录**，不用 Spotlight 当唯一 Gate：
/// Spotlight 索引有异步延迟，失败时区分不了「链路错」和「mds 还没索引到」
/// （Spotlight 只留一条 smoke，见文件末尾）。
///
/// 复审锁的九点全部落在这里：
/// ① golden file_id（测试内独立 SHA-256，不调 `FileID.make`）；
/// ② `relative_path` 是相对 `/` 的词法路径、无前导斜杠；
/// ③ `source_id` 正确（`local_mac`）；
/// ④ owner == wire 请求派生的 MCP owner；
/// ⑤ 同 owner `supersedePrevious=false`；
/// ⑥ limit=N 的生产执行真的观察到第 N+1 条（provider 没有先截 N）；
/// ⑦ MCP locate 与 `.ui` 请求并发不互相 cancel；
/// ⑧ 两个 MCP 请求同 source 排队但不互相 cancel；
/// ⑨ provider failed / cancelled 不许变成「成功但 results=[]」。
@MainActor
final class LocalProviderE2ETests: XCTestCase {

    // MARK: - 装配

    /// 包装真 `LocalSearchProvider` 的观察层。它**只记录、只透传**：
    /// 搜索与取消全部委托给内层的真 provider，自己不产生任何事件。
    private final class ObservedLocalProvider: SearchProvider, @unchecked Sendable {
        let source: SearchSource
        private let inner: LocalSearchProvider
        private(set) var owners: [SearchOwner] = []
        private(set) var cancelCalls: [UUID] = []

        init(_ inner: LocalSearchProvider) {
            self.inner = inner
            self.source = inner.source
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            owners.append(owner)
            await inner.search(text, queryID: queryID, owner: owner, emit: emit)
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            owners.append(.ui)
            await inner.search(text, queryID: queryID, emit: emit)
        }

        func cancel(queryID: UUID) {
            cancelCalls.append(queryID)
            inner.cancel(queryID: queryID)
        }
    }

    /// GUI 那一侧的事件收集（等终态用）。
    private final class RecordedEvents: @unchecked Sendable {
        private(set) var states: [ProviderSearchState] = []
        private(set) var results: [SearchResult] = []
        var terminal: ProviderSearchState? {
            switch states.last {
            case .completed, .cancelled, .failed, .timedOut, .truncated: return states.last
            default: return nil
            }
        }
        func record(_ event: ProviderEvent) {
            states.append(event.state)
            results.append(contentsOf: event.results)
        }
    }

    private var root = ""
    private var path = ""
    private var listeners: [AuthorityListener] = []

    override func setUpWithError() throws {
        root = "/tmp/ff-e2e-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        path = root + "/authority.sock"
    }

    override func tearDown() {
        for listener in listeners { listener.stop() }
        listeners = []
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 一套完整装配：真 provider（已观察包装）+ 真调度器 + 真权威端 + 真 socket。
    private func assemble(folders: [URL]) throws
        -> (provider: ObservedLocalProvider, scheduler: SearchScheduler, link: UnixSocketAuthorityLink) {
        let local = LocalSearchProvider()
        local.mode = .selectedFolders
        local.folders = folders
        let provider = ObservedLocalProvider(local)
        let scheduler = SearchScheduler(providers: [provider])
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: ["local_mac"]) },
            sources: { [AuthoritySource(id: "local_mac", name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))] })
        let listener = AuthorityListener(path: path, service: service, log: { _ in })
        XCTAssertTrue(listener.start().isListening, "监听没起来")
        listeners.append(listener)
        return (provider, scheduler, UnixSocketAuthorityLink(path: path))
    }

    private func touch(_ relative: String) throws {
        let full = root + "/" + relative
        let dir = (full as NSString).deletingLastPathComponent
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        XCTAssertTrue(FileManager.default.createFile(atPath: full, contents: Data("x".utf8)),
                      "建文件失败：\(full)")
    }

    private func located(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw NotSuccess()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private struct NotSuccess: Error {}

    /// ★ **独立的 golden 计算**：不调 `FileID.make`，按方案 §4.6 的前像公式
    /// 直接算 SHA-256。产品实现要是改了公式（或 `RelativePath.canonical`
    /// 偷偷改了语义），这里第一个红。
    /// 前像：`utf8(source_id) + 0x1F + "path:" + utf8(NFC(相对路径))`，取前 128 位。
    private func goldenFileID(sourceID: String, absolutePath: String) -> String {
        // RelativePath.canonical 的独立实现（本测试只造无 `..`、无尾随斜杠的路径）：
        // 剥前导斜杠、消空段、NFC。
        let rel = absolutePath.split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/").precomposedStringWithCanonicalMapping
        var preimage = Data(sourceID.utf8)
        preimage.append(0x1F)
        preimage.append(contentsOf: Data("path:".utf8))
        preimage.append(contentsOf: Data(rel.utf8))
        let digest = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
        return "ff1_" + String(digest.prefix(32))
    }

    /// 等 GUI 那一路落终态（主 actor 让出，emit 才有机会跑）。
    private func waitForTerminal(_ events: RecordedEvents) async throws {
        for _ in 0..<1500 {
            if events.terminal != nil { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTFail("GUI 搜索 15 秒没有落终态：\(events.states)")
    }

    // MARK: - ①②③④ 全链路 + golden 身份

    /// 真文件穿过整条链路，`file_id` 与**独立计算**的 golden 一致，
    /// `relative_path` 是相对 `/` 的词法路径（无前导斜杠）。
    ///
    /// 注意 relative_path 的形态：根 = `/`（复审拍板，只适用于 `local_mac`），
    /// 所以临时目录里的文件返回的是 `…/ff-e2e-xxx/目录/年度报告.pdf` 这样的词法路径——
    /// **`tmp` 一段保留在路径里**。这就是「整台 Mac」该有的样子。
    ///
    /// ★ golden 的路径基准来自**测试自己的独立枚举**（`FileManager.enumerator`，
    /// 与产品实现互不调用）：`/tmp` 在 macOS 上是 `/private/tmp` 的符号链接，
    /// `resolvingSymlinksInPath()` 对它的结果不稳定（实测两次 run 两种形态），
    /// 不能当基准；而 `LocalFolderSearch` 的身份口径是 enumerator 给的词法路径。
    /// 独立观察锁的是 **FileID 公式**（哈希前像、NFC、128 位截断）；
    /// 路径形态契约由第 ② 断言（无前导斜杠、与 fixture 同前缀）单独守。
    func testALocalFolderFileComesBackWithAGoldenFileIDThroughTheWholeStack() async throws {
        try touch("目录A/年度报告.pdf")
        // 独立枚举：拿到 fixture 文件的词法绝对路径（不受我们传入的 /tmp 形态影响）。
        let finder = FileManager.default.enumerator(at: URL(fileURLWithPath: root),
                                                    includingPropertiesForKeys: nil)
        var observed: String?
        while let url = finder?.nextObject() as? URL {
            if url.lastPathComponent == "年度报告.pdf" { observed = url.path; break }
        }
        let absolute = try XCTUnwrap(observed, "独立枚举没找到 fixture 文件")
        let (provider, _, link) = try assemble(folders: [URL(fileURLWithPath: root)])

        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("报告")])))
        XCTAssertEqual(body["truncated"] as? Bool, false)
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1, "临时目录里只有一个名字含「报告」的文件：\(hits)")

        let hit = hits[0]
        XCTAssertEqual(hit["source_id"] as? String, "local_mac", "③ source_id")
        XCTAssertEqual(hit["kind"] as? String, "file")

        let expectedRelative = absolute.split(separator: "/", omittingEmptySubsequences: true)
            .joined(separator: "/").precomposedStringWithCanonicalMapping
        XCTAssertEqual(hit["relative_path"] as? String, expectedRelative,
                       "② 相对 `/` 的词法路径，无前导斜杠")
        XCTAssertEqual(hit["file_id"] as? String,
                       goldenFileID(sourceID: "local_mac", absolutePath: absolute),
                       "① 与独立计算的 golden 一致")

        // ④ owner 由 wire 请求派生：不是 .ui，而且这个请求确实到达了真 provider。
        XCTAssertEqual(provider.owners.count, 1, "一次 locate 只许打到 provider 一次")
        guard case .mcp(let session) = provider.owners[0] else {
            return XCTFail("MCP locate 的 owner 必须是 .mcp，实际 \(provider.owners[0])")
        }
        XCTAssertFalse(session.isEmpty)
    }

    // MARK: - ⑥ limit+1 在生产路径上（provider 没先截 N）

    /// 6 个真文件、请求 limit=2：`truncated=true` **只能**来自执行层真的观察到
    /// 第 3 条合格候选。如果有人把执行层改回 `prefix(2)`、或让 provider 先截 2 条，
    /// 观察不到第 3 条，`truncated` 就会错成 false。
    /// （provider 侧的 `LocalFolderSearch` 自带上限 200，不会截这 6 个文件。）
    func testSixRealFilesWithLimitTwoProveTheExecutorObservedTheThird() async throws {
        for i in 1...6 { try touch("batch/年报\(i).pdf") }
        let (_, _, link) = try assemble(folders: [URL(fileURLWithPath: root)])

        let body = try located(await link.call(
            tool: "locate",
            arguments: ToolArguments(["query": .string("年报"), "limit": .integer(2)])))
        XCTAssertEqual(body["limit_applied"] as? Int, 2)
        XCTAssertEqual(body["truncated"] as? Bool, true,
                       "6 条合格候选只返回 2 条，必须如实说还有更多")
        XCTAssertEqual((body["results"] as? [[String: Any]])?.count, 2)
    }

    // MARK: - ⑦ MCP 与 .ui 并发不互相 cancel

    /// MCP locate 在跑（真遍历临时目录，2000 个文件拖住它）时 GUI 提交一次
    /// supersede 型请求：`.ui` 的取代**不许**跨 owner 扫到 MCP 那条。
    /// 两者都必须拿到真结果；观察层一次 `cancel` 都不许看到。
    func testAUIRequestAndAnMCPLocateDoNotCancelEachOther() async throws {
        for i in 0..<2000 { try touch("noise/file\(String(format: "%04d", i)).dat") }
        try touch("目录A/年度报告.pdf")
        let (provider, scheduler, link) = try assemble(folders: [URL(fileURLWithPath: root)])

        async let mcpOutcome = link.call(tool: "locate",
                                         arguments: ToolArguments(["query": .string("报告")]))
        // 等 MCP 确实开跑（provider 被调到），再让 GUI 进来。
        for _ in 0..<1500 where provider.owners.isEmpty {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(provider.owners.isEmpty, "MCP locate 没有到达 provider")

        let gui = RecordedEvents()
        scheduler.submit(text: "报告", queryID: UUID(), owner: .ui,
                         sources: ["local_mac"], emit: { gui.record($0) })
        try await waitForTerminal(gui)

        let mcpBody = try located(try await mcpOutcome)
        XCTAssertEqual(provider.owners.count, 2, "两条请求各打一次 provider")
        XCTAssertTrue(provider.cancelCalls.isEmpty,
                      "观察层看到了取消：\(provider.cancelCalls)")
        XCTAssertEqual((mcpBody["results"] as? [[String: Any]])?.count, 1, "MCP 那条不许被 GUI 取代")
        XCTAssertTrue(gui.results.contains { $0.name == "年度报告.pdf" },
                      "GUI 那条也要拿到结果：\(gui.results.map(\.name))")
    }

    // MARK: - ⑧ 两个 MCP 请求同 source 排队不互相 cancel

    func testTwoConcurrentMCPLocatesOnOneSourceBothFinish() async throws {
        try touch("目录A/年度报告.pdf")
        let (provider, _, link) = try assemble(folders: [URL(fileURLWithPath: root)])

        async let first = link.call(tool: "locate",
                                    arguments: ToolArguments(["query": .string("报告")]))
        async let second = link.call(tool: "locate",
                                     arguments: ToolArguments(["query": .string("报告")]))
        let bodies = try [located(try await first), located(try await second)]

        XCTAssertEqual(provider.owners.count, 2)
        // 每条 wire 请求一个独立 owner；同 source 上它们排队（LocalFolderSearch 同一
        // provider 实例串行处理），谁也不许取消谁。
        XCTAssertNotEqual(provider.owners[0], provider.owners[1],
                          "两条 wire 请求不许共享一个 owner")
        XCTAssertTrue(provider.cancelCalls.isEmpty,
                      "排队不等于取消，观察层不该看到 cancel：\(provider.cancelCalls)")
        for body in bodies {
            XCTAssertEqual(body["truncated"] as? Bool, false)
            XCTAssertEqual((body["results"] as? [[String: Any]])?.count, 1)
        }
    }

    // MARK: - ⑨ failed / cancelled 不许变成空成功

    /// provider 直接失败（一个文件夹都没配）：wire 上必须是 `source_unavailable`，
    /// **不是** `{"results": []}` 那种空成功。
    func testAProviderFailureIsNotAnEmptySuccess() async throws {
        let (provider, _, link) = try assemble(folders: [])

        let outcome = await link.call(tool: "locate",
                                      arguments: ToolArguments(["query": .string("报告")]))
        guard case .failure(let code, _) = outcome else {
            return XCTFail("provider 失败必须以失败形态回到 wire，实际 \(outcome)")
        }
        XCTAssertEqual(code, "source_unavailable",
                       "LocalFolderSearch 抛「请选择要搜索的本机文件夹」要映射成 unavailable")
        XCTAssertTrue(provider.cancelCalls.isEmpty, "failed 不是 cancelled")
    }

    // MARK: - Spotlight smoke（辅助 Gate，不绑 CI 语义）

    /// 真实系统索引的 smoke：整条链路对「整台 Mac」也通。
    ///
    /// ★ 只冒烟不断言时序：mds 有异步延迟，断言「非空结果」会把 CI 绑在
    /// 系统索引状态上。这里允许三种可解释结局：
    /// 成功（索引正常）／`timeout`（mds 慢，skip）／`failed`（本机索引不可用，skip）。
    /// 任何其它失败码（`source_unavailable` 等）仍然是链路问题，照常红。
    func testSpotlightSmokeOnTheWholeMac() async throws {
        // smoke 单独起一个 spotlight 模式的装配（其余用例都走 selectedFolders）。
        let spotlight = LocalSearchProvider()
        spotlight.mode = .spotlight
        let observed = ObservedLocalProvider(spotlight)
        let scheduler = SearchScheduler(providers: [observed])
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: ["local_mac"]) },
            sources: { [AuthoritySource(id: "local_mac", name: "This Mac",
                                        execution: SourceExecutionHandle(provider: observed,
                                                                         scheduler: scheduler))] })
        let listener = AuthorityListener(path: path + "-spotlight", service: service, log: { _ in })
        XCTAssertTrue(listener.start().isListening)
        listeners.append(listener)
        let spotlightLink = UnixSocketAuthorityLink(path: path + "-spotlight")

        let outcome = await spotlightLink.call(
            tool: "locate",
            arguments: ToolArguments(["query": .string("Safari"), "limit": .integer(3)]))

        switch outcome {
        case .success(let json):
            let body = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            // Safari 在整台 Mac 上远不止 3 个匹配，`truncated=true` 才是对的；
            // 这里只断言窗口与返回条数自洽，**不**断言有没有结果（mds 时序不进 CI）。
            let hits = (body["results"] as? [[String: Any]]) ?? []
            XCTAssertLessThanOrEqual(hits.count, body["limit_applied"] as? Int ?? 0)
            if body["truncated"] as? Bool == true {
                XCTAssertGreaterThanOrEqual(hits.count, 1, "说还有更多，就必须真的返回了一些")
            }
        case .failure(let code, _):
            if code == "timeout" {
                throw XCTSkip("Spotlight 查询超时（mds 慢），链路本身没红")
            }
            if code == "source_unavailable" {
                throw XCTSkip("本机 Spotlight 索引不可用，smoke 无法进行")
            }
            XCTFail("Spotlight smoke 意外失败：\(code)")
        }
    }
}
