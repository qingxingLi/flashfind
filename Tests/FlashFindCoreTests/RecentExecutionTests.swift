import XCTest
@testable import FlashFindCore
import CSQLite

/// Phase 7c / 7d 的 Gate：写者接上了、`recent` 真执行、撤销来源立即生效。
///
/// ## 这一组守的几件事（对应用户给的 Gate 清单）
///
/// ```text
/// ① 只有进窗口的才记 located   —— 被 limit 截掉的候选不算「被看到过」
/// ② 同 session 同文件只记一次   —— 不因次数放大
/// ③ get_metadata 每次都记       —— Phase 8 要按次数算
/// ④ History 写失败不影响搜索    —— 它是旁路，与映射表那条规则正相反
/// ⑤ recent 真返回历史           —— 不是空的假实现
/// ⑥ 撤销来源后 recent 立即消失  —— 历史 ≠ 现在还授权
/// ⑦ 总开关关闭 → mcp_disabled  —— 不绕过 PermissionPolicy
/// ⑧ source_ids 只能收紧         —— 不能靠它扩大授权
/// ⑨ 清空历史后 recent 为空      —— 但已发出的 file_id 仍可 get_metadata
/// ```
///
/// ★ 这里的装配尽量走**真的** `RoutingAuthorityService`：只替换 provider
/// 与两张库的落盘位置。走真链路才能证明「接线」本身，而不是证明替身自洽。
///
/// ★ 所有来源 id、文件名、查询词都是编造的。
@MainActor
final class RecentExecutionTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let archive = "src_nas_archive"

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ff2-recent-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - 替身 Provider

    /// 既能搜、又能按路径直查的 provider。
    final class Fake: SearchProvider, PathMetadataProviding, @unchecked Sendable {

        let source: SearchSource
        private let rows: [String: [SearchResult]]
        private let fallback: MetadataOutcome

        private(set) var asked: [String] = []

        init(id: String,
             rows: [String: [SearchResult]] = [:],
             fallback: MetadataOutcome = .notFound) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.rows = rows
            self.fallback = fallback
        }

        func metadata(canonicalRelativePath: String) async -> MetadataOutcome {
            asked.append(canonicalRelativePath)
            return fallback
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
            emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                               results: rows[text] ?? [], state: .completed))
        }

        func cancel(queryID: UUID) {}
    }

    // MARK: - 脚手架

    private func row(_ path: String, kind: String = "file") -> SearchResult {
        SearchResult(id: path,
                     name: (path as NSString).lastPathComponent,
                     relativePath: path,
                     sourceID: nil,
                     sourceName: "",
                     kind: kind,
                     size: 1,
                     localURL: nil)
    }

    private func snapshot(ids: [String], providers: [any SearchProvider]) -> AuthorizedSourceSnapshot {
        let shared = SearchScheduler(providers: providers)
        var byID: [String: any SearchProvider] = [:]
        for provider in providers { byID[provider.source.id] = provider }
        let registry = ids.map { id -> AuthoritySource in
            var handle: SourceExecutionHandle?
            if let provider = byID[id] {
                handle = SourceExecutionHandle(provider: provider, scheduler: shared)
            }
            return AuthoritySource(id: id, name: "Source \(id)", execution: handle)
        }
        let scope = AuthorizationScope(granting: .allow(sources: ids, warnings: []))!
        return AuthorizedSourceSnapshot(scope: scope, registry: registry)
    }

    private func application(_ applied: Int) -> LimitApplication {
        LimitApplication(applied: applied, wasClamped: false)
    }

    private func makeHistory() throws -> HistoryStore {
        try HistoryStore(url: scratch.appendingPathComponent("ai-history.sqlite"))
    }

    private func makeReferences() throws -> FileReferenceStore {
        try FileReferenceStore(url: scratch.appendingPathComponent("ai-file-reference.sqlite"))
    }

    /// 一次带 History 的 `locate`。
    private func locate(_ query: String,
                        in providers: [any SearchProvider],
                        ids: [String],
                        limit: Int,
                        history: HistorySink?,
                        references: FileReferenceStore?) async -> ToolOutcome {
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: references)
        let run = await executor.run(query: query,
                                     kind: nil,
                                     modifiedAfter: nil,
                                     application: application(limit),
                                     snapshot: snapshot(ids: ids, providers: providers),
                                     owner: .mcp(sessionID: "recent-tests"),
                                     history: history)
        return run.outcome
    }

    private func ids(in outcome: ToolOutcome) throws -> [String] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw Failure()
        }
        let payload = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        return try results.map { try XCTUnwrap($0["file_id"] as? String) }
    }

    private func code(of outcome: ToolOutcome) -> String? {
        guard case .failure(let code, _) = outcome else { return nil }
        return code
    }

    private struct Failure: Error {}

    /// 可变的「当前事实」。与 `AuthorityServiceTests` 里那份同一个形状——
    /// 这里再写一份是因为私有的替身不该跨文件共享（共享了就会被別的用例改坏）。
    private final class Holder: @unchecked Sendable {
        var settings: AIAccessSettings
        var sources: [AuthoritySource]
        init(settings: AIAccessSettings, sources: [AuthoritySource]) {
            self.settings = settings
            self.sources = sources
        }
    }

    private func sources(_ ids: [String]) -> [AuthoritySource] {
        ids.map { AuthoritySource(id: $0, name: "Source \($0)") }
    }

    private func job(_ op: AuthorityWire.Operation,
                     _ arguments: [String: AuthorityWire.Value] = [:]) -> AuthorityJob {
        AuthorityJob(id: UUID().uuidString, op: op, arguments: arguments)
    }

    /// 成功结果的字段表。`recent` 的断言要按键取值，不比整串 JSON。
    private static func dictionary(of outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw Failure()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    // MARK: - ① 只有进窗口的才算 located

    /// 来源给了 6 条，`limit=3` → 只有回到 Agent 的那 3 条进 History。
    ///
    /// ★ 这是 7c 最关键的一条：被 `limit` 截掉的候选**不是**「Agent 看到过」。
    /// 记它就是把「我们搜到过」说成「助理看到过」，那正是 §6.2.1 挡掉的那件事。
    ///
    /// ★ 它同时也是「写入点接在开窗之后」那个变异的直接抓手：若写入点挪到
    ///   开窗之前，这条会红，而「能返回 3 条」那类断言依然全绿。
    func testLocatedCoversOnlyTheReturnedWindow() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let paths = (0..<6).map { "共享/文件\($0).pdf" }
        let provider = Fake(id: work, rows: ["预算": paths.map { row("/" + $0) }])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))

        let outcome = await locate("预算", in: [provider], ids: [work], limit: 3,
                                   history: sink, references: references)
        let returned = try ids(in: outcome)
        XCTAssertEqual(returned.count, 3, "只该返回 3 条：\(outcome)")

        let events = try history.recent(limit: 100)
        XCTAssertEqual(events.count, 3, "窗口外的候选不该记 located：\(events.count)")
        XCTAssertEqual(Set(events.map(\.lastKnownRelativePath)), Set(returned.compactMap {
            try? references.lookup(FileID.parse($0)!)?.canonicalRelativePath
        }))
    }

    /// 同一个 session 里重复 locate 同一个文件，`located` 只留一条。
    ///
    /// ★ 与 7b 的库级去重互为补充：那边证明「写两遍只有一行」，
    ///   这边证明「接线的位置只会写一遍」。
    func testRepeatedLocateInOneSessionRecordsLocatedOnce() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))

        _ = await locate("预算", in: [provider], ids: [work], limit: 5,
                         history: sink, references: references)
        _ = await locate("预算", in: [provider], ids: [work], limit: 5,
                         history: sink, references: references)

        XCTAssertEqual(try history.count(), 1, "同 session 同文件只该记一次")
        XCTAssertNil(sink.lastFailure, "幂等写入不该被当成失败：\(sink.lastFailure ?? "")")
    }

    // MARK: - ③ get_metadata 每次都记

    /// 同一个文件连查两次 → 两条 `metadata`（`located` 仍然只有一条）。
    func testGetMetadataRecordsEverySuccessfulCall() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let path = "/共享/预算.xlsx"
        let provider = Fake(id: work, rows: ["预算": [row(path)]],
                            fallback: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                           sizeBytes: 4096, modified: nil)))
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))

        let first = await locate("预算", in: [provider], ids: [work], limit: 5,
                                 history: sink, references: references)
        let fileID = try XCTUnwrap(try ids(in: first).first.flatMap { FileID.parse($0) })

        for _ in 0..<2 {
            let outcome = await MetadataExecutor(store: references)
                .run(fileID: fileID, snapshot: snapshot(ids: [work], providers: [provider]),
                     history: sink).outcome
            XCTAssertNil(code(of: outcome), "get_metadata 不该失败：\(outcome)")
        }

        let events = try history.recent(limit: 100)
        XCTAssertEqual(events.filter { $0.action == .metadata }.count, 2)
        XCTAssertEqual(events.filter { $0.action == .located }.count, 1)
    }

    // MARK: - ④ History 写库故障 = 旁路

    /// 库关掉之后（等价于「磁盘写不进去」）`locate` 依然成功。
    ///
    /// ★ 这是 §6.6 那条规则的机器执行版本，方向**与 `FileReferenceStore` 相反**：
    ///   那边写失败必须让 Tool Call 失败，这边**必须不让**。
    ///   两者写成同一副样子的话，一个与本次搜索无关的磁盘问题会毁掉整次搜索。
    func testLocateStillSucceedsWhenHistoryCannotBeWritten() async throws {
        let history = try makeHistory()
        let references = try makeReferences()
        defer { references.close() }

        history.close()  // 让它之后所有写入都抛

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let outcome = await locate("预算", in: [provider], ids: [work], limit: 5,
                                   history: sink, references: references)

        XCTAssertNil(code(of: outcome), "历史写不进去不该让搜索失败：\(outcome)")
        XCTAssertEqual(try ids(in: outcome).count, 1, "结果照常返回：\(outcome)")
        XCTAssertNotNil(sink.lastFailure, "故障必须记进诊断，不能静默吞掉")
    }

    /// `get_metadata` 同样：历史写失败不影响它返回元数据。
    func testGetMetadataStillSucceedsWhenHistoryCannotBeWritten() async throws {
        let history = try makeHistory()
        let references = try makeReferences()
        defer { references.close() }

        let path = "共享/预算.xlsx"
        // ★ provider 必须**真的给出**这一行：映射表是在 `locate` 返回窗口时登记的，
        //   没有候选就没有登记，后面的 get_metadata 当然只能 file_not_found。
        let provider = Fake(id: work,
                            rows: ["预算": [row("/" + path)]],
                            fallback: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                          sizeBytes: 4096, modified: nil)))
        _ = await locate("预算", in: [provider], ids: [work], limit: 5,
                         history: HistorySink(store: history,
                                               context: HistoryContext(sessionID: "sess-A",
                                                                       agentID: "tests/1")),
                         references: references)
        let fileID = try FileID.make(sourceID: work, canonicalRelativePath: path)

        history.close()  // 让它之后所有写入都抛

        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let outcome = await MetadataExecutor(store: references)
            .run(fileID: fileID, snapshot: snapshot(ids: [work], providers: [provider]),
                 history: sink).outcome

        let payload = try Self.dictionary(of: outcome)
        XCTAssertEqual(payload["size_bytes"] as? Int, 4096, "元数据照常返回：\(outcome)")
        XCTAssertNotNil(sink.lastFailure, "故障必须记进诊断")
    }

    // MARK: - ⑤ recent 真执行

    /// 空历史 → 空列表 + 成功（不是 error，也不是「功能没实现」）。
    func testRecentReturnsAnEmptyListWhenNothingHasBeenSeen() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [Fake(id: work)]),
                                     history: history,
                                     references: references,
                                     now: now)

        XCTAssertNil(code(of: run.outcome))
        XCTAssertTrue(try ids(in: run.outcome).isEmpty)
        XCTAssertFalse(run.report.historyUnavailable, "库是装上的，只是没数据")
    }

    /// `locate` 之后 `recent` 能取出同一个 `file_id`、来源与相对路径。
    ///
    /// ★ 这是「recent 不是假实现」的正向抓手：它必须真的从 History 里读出东西。
    func testRecentReturnsWhatLocateJustReturned() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let located = try ids(in: await locate("预算", in: [provider], ids: [work], limit: 5,
                                               history: sink, references: references))

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now)
        XCTAssertEqual(try ids(in: run.outcome), located, "recent 该返回刚才 locate 的同一条")
        XCTAssertEqual(run.report.returned, 1)
    }

    // MARK: - ⑥ 撤销来源立即生效

    /// 历史里有 A、B 两个来源的记录，本次只授权 A → `recent` 只出 A。
    ///
    /// ★ 这是 7d 那条权限原则的机器执行版本：
    ///   「History 里曾经有这个文件 ≠ 现在还能把它返回给 Agent」。
    func testRecentDropsSourcesThatAreNoLongerAuthorized() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        _ = await locate("预算", in: [provider], ids: [work], limit: 5,
                         history: sink, references: references)
        // 手工补一条「另一个来源」的历史，模拟用户撤销了它。
        let archivePath = "归档/旧预算.xlsx"
        let archiveID = try FileID.make(sourceID: archive, canonicalRelativePath: archivePath)
        try references.register(FileReference(fileID: archiveID, sourceID: archive,
                                               canonicalRelativePath: archivePath))
        try history.recordLocated(AccessEvent(sessionID: "sess-A", agentID: "tests/1",
                                              fileID: archiveID, sourceID: archive,
                                              action: .located, timestamp: now,
                                              lastKnownRelativePath: archivePath))

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now)
        let returned = try ids(in: run.outcome)
        XCTAssertEqual(returned.count, 1, "撤销的来源必须立刻消失：\(returned)")
        XCTAssertTrue(try references.lookup(archiveID) != nil, "映射表还在（撤销 ≠ 清库）")
    }

    // MARK: - ⑦ 总开关

    /// AI 关着 → `recent` 得到 `mcp_disabled`，**不因 History 有没有数据而变**。
    func testRecentIsDisabledWhenTheMasterSwitchIsOff() async throws {
        let holder = Holder(settings: AIAccessSettings(isEnabled: false, allowedSources: []),
                            sources: sources([work]))
        let service = RoutingAuthorityService(settings: { holder.settings },
                                              sources: { holder.sources })
        let outcome = await service.handle(job(.recent, [:]))
        XCTAssertEqual(code(of: outcome), "mcp_disabled")
    }

    // MARK: - ⑧ source_ids 只能收紧

    /// 两个来源都授权时，`source_ids=[archive]` 只出 archive 那一条。
    func testSourceIDsTightenRecentAndNeverWiden() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let workPath = "共享/预算.xlsx"
        let archivePath = "归档/旧预算.xlsx"
        let workID = try FileID.make(sourceID: work, canonicalRelativePath: workPath)
        let archiveID = try FileID.make(sourceID: archive, canonicalRelativePath: archivePath)
        try references.registerAll([
            FileReference(fileID: workID, sourceID: work, canonicalRelativePath: workPath),
            FileReference(fileID: archiveID, sourceID: archive, canonicalRelativePath: archivePath)
        ])
        try history.recordLocatedAll([
            AccessEvent(sessionID: "sess-A", agentID: "tests/1", fileID: workID,
                        sourceID: work, action: .located, timestamp: now,
                        lastKnownRelativePath: workPath),
            AccessEvent(sessionID: "sess-A", agentID: "tests/1", fileID: archiveID,
                        sourceID: archive, action: .located, timestamp: now,
                        lastKnownRelativePath: archivePath)
        ])

        let both = RecentExecutor.run(withinDays: nil,
                                      application: application(5),
                                      snapshot: snapshot(ids: [work, archive],
                                                               providers: [Fake(id: work), Fake(id: archive)]),
                                      history: history,
                                      references: references,
                                      now: now)
        XCTAssertEqual(try ids(in: both.outcome).count, 2, "不点名时两个来源都在：\(both.outcome)")

        let tightened = RecentExecutor.run(withinDays: nil,
                                           application: application(5),
                                           snapshot: snapshot(ids: [archive],
                                                                    providers: [Fake(id: archive)]),
                                           history: history,
                                           references: references,
                                           now: now)
        XCTAssertEqual(try ids(in: tightened.outcome).count, 1, "点名后只该出那一个：\(tightened.outcome)")
    }

    // MARK: - ⑨ 清空历史

    /// `clear()` 之后 `recent` 立即为空；但已经发出去的 `file_id` 仍然能查元数据。
    ///
    /// ★ 这条守的是两件事的**分离**：历史可以清，映射表不能跟着清。
    ///   混在一个库里的话，「清空 AI 历史」会顺手废掉 Agent 手里所有 id。
    func testClearingHistoryEmptiesRecentButKeepsFileIdsResolvable() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let path = "共享/预算.xlsx"
        let provider = Fake(id: work,
                            rows: ["预算": [row("/" + path)]],
                            fallback: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                          sizeBytes: 4096, modified: nil)))
        _ = await locate("预算", in: [provider], ids: [work], limit: 5,
                         history: HistorySink(store: history,
                                               context: HistoryContext(sessionID: "sess-A",
                                                                       agentID: "tests/1")),
                         references: references)
        let fileID = try FileID.make(sourceID: work, canonicalRelativePath: path)

        try history.clear()

        let afterClear = RecentExecutor.run(withinDays: nil,
                                            application: application(5),
                                            snapshot: snapshot(ids: [work], providers: [provider]),
                                    history: history,
                                    references: references,
                                    now: now)
        XCTAssertTrue(try ids(in: afterClear.outcome).isEmpty, "清空后 recent 必须为空")

        let metadata = await MetadataExecutor(store: references)
            .run(fileID: fileID, snapshot: snapshot(ids: [work], providers: [provider])).outcome
        XCTAssertNil(code(of: metadata), "清空历史不该让已有 file_id 失效：\(metadata)")
    }

    /// History 里**不存**查询词 / 路径根。
    ///
    /// ★ 这是 §6.3 的机器执行版本：列名闭集里出现了 `query`、`prompt`、
    ///   `absolute_path` 之类的键，这条就红。
    func testTheSchemaCarriesNoQueryPromptOrAbsolutePath() {
        let banned = ["query", "query_hash", "prompt", "content", "absolute_path",
                      "password", "secret", "token", "path_root", "volume"]
        let schema = HistoryStore.schemaSQL.lowercased()
        for word in banned {
            XCTAssertFalse(schema.contains(word),
                           "History 库不该有 `\(word)`：\(HistoryStore.schemaSQL)")
        }
    }

    /// `recent` 每条结果的键闭集：**只有这五个**。
    ///
    /// ★ 没有 `score` / `reasons`：`recent` 是「最近被看到的时刻倒序」的列表，
    ///   不是评分排序。给每一项编一个分数，Agent 会拿它跟 `locate` 的
    ///   `ranking_score` 比大小，而那两个数的含义完全不同（§4.13）。
    /// ★ 没有 `kind` / `size_bytes` / `modified`：History 里没记这三项（§6.3），
    ///   且 §4.11 定了「完整元数据只有 `get_metadata` 一个出口」。
    ///   要它们就拿 `file_id` 去调 `get_metadata`，不许 `recent` 编一个。
    func testTheRecentHitCarriesExactlyFiveFields() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        _ = try ids(in: await locate("预算", in: [provider], ids: [work], limit: 5,
                                     history: HistorySink(store: history,
                                                           context: HistoryContext(sessionID: "sess-A",
                                                                                   agentID: "tests/1")),
                                     references: references))

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now)
        let payload = try Self.dictionary(of: run.outcome)
        let results = try XCTUnwrap(payload["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1, "先要能取出一条，否则这条断言会假绿：\(run.outcome)")
        XCTAssertEqual(Set(results[0].keys),
                       ["file_id", "source_id", "name", "relative_path", "last_seen"],
                       "recent 的字段闭集变了：\(results[0].keys.sorted())")
    }

    /// 同一个文件被看三次（一次 located + 两次 metadata）→ `recent` 仍然只出一条。
    ///
    /// ★ 库里**不是**一条：`metadata` 刻意不去重（Phase 8 的 `metadata-access`
    ///   按 `1-exp(-n/5)` 用次数）。折叠只发生在返回列表这一层。
    ///   不折叠的话，Agent 会看到同一个文件连着出现三次。
    func testRecentCollapsesRepeatedSightingsOfOneFile() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let path = "共享/预算.xlsx"
        let provider = Fake(id: work, rows: ["预算": [row("/" + path)]],
                            fallback: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                          sizeBytes: 4096, modified: nil)))
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let returned = try ids(in: await locate("预算", in: [provider], ids: [work],
                                                limit: 5, history: sink,
                                                references: references))
        let fileID = try XCTUnwrap(returned.first.flatMap { FileID.parse($0) })
        for _ in 0..<2 {
            _ = await MetadataExecutor(store: references)
                .run(fileID: fileID, snapshot: snapshot(ids: [work], providers: [provider]),
                     history: sink).outcome
        }
        XCTAssertEqual(try history.count(), 3,
                       "库里该有三条事件（一次 located + 两次 metadata 不去重）")

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now)
        XCTAssertEqual(try ids(in: run.outcome).count, 1, "列表要折叠成一条：\(run.outcome)")
    }

    /// ★ 一个文件刷满近期访问，不能把另一个「也看过、只是更早」的文件挤掉。
    ///
    /// 这是代码审核 BUG-112-03 的原始反例：先按事件取候选、再按 `file_id` 折叠，
    /// 而 `metadata` 事件按设计每次访问都记一条 —— 一个文件被看 20 次就能占满
    /// 整个预采样窗口。固定倍数（`limit*4` / `limit+16`）挡不住它，因为
    /// 「一个文件能刷多少次」本身没有上界。
    ///
    /// 用户看到的是「明明昨天还看过另一个文件，它说没有」，而且返回里
    /// `truncated=false` —— Agent 连「少了一条」都不知道。
    func testOneFileFloodingHistoryDoesNotEvictAnother() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work,
                            rows: ["报告": [row("/共享/A-报告.docx"), row("/共享/B-预算.xlsx")]],
                            fallback: .found(PathMetadata(name: "x", kind: .file,
                                                          sizeBytes: 1, modified: nil)))
        let sink = HistorySink(store: history,
                               context: HistoryContext(sessionID: "sess-A", agentID: "tests/1"))
        let returned = try ids(in: await locate("报告", in: [provider], ids: [work],
                                                limit: 5, history: sink,
                                                references: references))
        XCTAssertEqual(returned.count, 2)
        let flooded = try XCTUnwrap(FileID.parse(returned[0]))
        let quiet = try XCTUnwrap(FileID.parse(returned[1]))

        // 第一个文件被反复「看」20 次，时间都晚于那次 locate。
        for offset in 1...20 {
            _ = await MetadataExecutor(store: references)
                .run(fileID: flooded,
                     snapshot: snapshot(ids: [work], providers: [provider]),
                     history: sink,
                     now: now.addingTimeInterval(Double(offset))).outcome
        }
        XCTAssertEqual(try history.count(), 22, "2 条 located + 20 条 metadata（metadata 不去重）")

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(2),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now.addingTimeInterval(30))

        let got = try ids(in: run.outcome)
        XCTAssertEqual(got.count, 2, "另一个文件不能被 20 次重复访问挤掉：\(run.outcome)")
        XCTAssertTrue(got.contains(quiet.value), "较早看过的那个文件必须还在")
        XCTAssertEqual(run.report.truncated, false)
    }

    /// 没有 History 库 → 空列表 + 成功，并在 `warnings` 里说明。
    ///
    /// ★ 不许报错：这不是故障，是「这个功能没开」。报错会让 Agent 去让用户
    ///   修一个没坏的东西（§7d）。
    func testRecentIsEmptyNotAnErrorWhenHistoryIsNotAttached() async throws {
        let references = try makeReferences()
        defer { references.close() }

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [Fake(id: work)]),
                                     history: nil,
                                     references: references,
                                     now: now)

        XCTAssertNil(code(of: run.outcome), "没装 History 不是故障：\(run.outcome)")
        XCTAssertTrue(try ids(in: run.outcome).isEmpty)
        XCTAssertTrue(run.report.historyUnavailable)
        let payload = try Self.dictionary(of: run.outcome)
        XCTAssertEqual(payload["warnings"] as? [String], ["recent_unavailable"])
    }

    /// History 库**坏了**（句柄已关）→ 整次 `recent` 失败。
    ///
    /// ★ 为什么这里不许退化成空列表：「最近看过什么」就是这次请求要的答案，
    ///   读不出来必须如实说。返回空列表会让 Agent 得出「用户最近没看过任何文件」
    ///   这个我们并不知道的错误结论（§7d）。
    func testRecentFailsWhenTheHistoryStoreIsBroken() async throws {
        let history = try makeHistory()
        history.close()  // 让它之后的读取一律抛
        let references = try makeReferences()
        defer { references.close() }

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [Fake(id: work)]),
                                     history: history,
                                     references: references,
                                     now: now)

        XCTAssertEqual(code(of: run.outcome), "internal_error")
    }

    // MARK: - ⑩ 另外两个写者：search / locate_many

    /// `search` 也要写 located——它是 `file_id` 的第二个出口。
    ///
    /// ★ 三个写者是**三份代码**。合成一个函数后，删掉 `search` 那一份
    ///   不会让 `locate` / `locate_many` 的用例变红（6.4b-1 踩过的正是这个）。
    func testSearchRecordsLocatedForTheHitsItReturns() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work, rows: ["预算": [row("/共享/预算.xlsx")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: references)
        let outcome = await executor.runSearch(
            query: "预算",
            application: application(5),
            snapshot: snapshot(ids: [work], providers: [provider]),
            owner: .mcp(sessionID: "recent-tests"),
            history: sink).outcome

        XCTAssertNil(code(of: outcome), "search 不该失败：\(outcome)")
        XCTAssertEqual(try history.recent(limit: 100).map(\.lastKnownRelativePath),
                       ["共享/预算.xlsx"])
    }

    /// `locate_many` 的每个分组都要写，而且是**一笔事务**。
    func testLocateManyRecordsLocatedForEveryGroup() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        let provider = Fake(id: work,
                            rows: ["预算": [row("/共享/预算.xlsx")],
                                   "合同": [row("/共享/合同.pdf")]])
        let sink = HistorySink(store: history, context: HistoryContext(sessionID: "sess-A",
                                                                        agentID: "tests/1"))
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: references)
        let outcome = await executor.runMany(
            queries: ["预算", "合同"],
            application: application(1),
            snapshot: snapshot(ids: [work], providers: [provider]),
            owner: .mcp(sessionID: "recent-tests"),
            history: sink).outcome

        XCTAssertNil(code(of: outcome), "locate_many 不该失败：\(outcome)")
        XCTAssertEqual(Set(try history.recent(limit: 100).map(\.lastKnownRelativePath)),
                       ["共享/预算.xlsx", "共享/合同.pdf"])
    }

    // MARK: - ⑪ stale 行：跳过 + 说清

    /// 历史里有一条 `file_id` 已经解析不出来了 → 跳过它，其余照常返回，
    /// 并把原因放进 `warnings`。
    ///
    /// ★ 列表型 Tool 不许因为一条坏行变成「历史是空的」——那会让 Agent
    /// 得出「用户最近没看过任何文件」这个错误结论（§7d）。
    func testRecentSkipsStaleReferencesAndWarns() async throws {
        let history = try makeHistory()
        defer { history.close() }
        let references = try makeReferences()
        defer { references.close() }

        // `recent` 不去问设备，但它读历史时仍要一次授权快照；这里给一个同 id 的空 provider。
        let provider = Fake(id: work)
        let freshPath = "共享/新预算.xlsx"
        let freshID = try FileID.make(sourceID: work, canonicalRelativePath: freshPath)
        try references.register(FileReference(fileID: freshID, sourceID: work,
                                              canonicalRelativePath: freshPath))
        try history.recordLocated(AccessEvent(sessionID: "sess-A", agentID: "tests/1",
                                              fileID: freshID, sourceID: work,
                                              action: .located, timestamp: now,
                                              lastKnownRelativePath: freshPath))

        // 一条「历史里有、但映射表里已经没有」的引用。
        let stalePath = "共享/被清掉的.pdf"
        let staleID = try FileID.make(sourceID: work, canonicalRelativePath: stalePath)
        try history.recordLocated(AccessEvent(sessionID: "sess-A", agentID: "tests/1",
                                              fileID: staleID, sourceID: work,
                                              action: .located,
                                              timestamp: now.addingTimeInterval(60),
                                              lastKnownRelativePath: stalePath))

        let run = RecentExecutor.run(withinDays: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     history: history,
                                     references: references,
                                     now: now)
        let returned = try ids(in: run.outcome)
        XCTAssertEqual(returned, [freshID.value], "stale 行要跳过，但不许毁掉整列表")
        XCTAssertTrue(run.report.skipped.contains("stale_file_id:\(staleID.value)"),
                      "跳过必须说清原因：\(run.report.skipped)")
        XCTAssertTrue(try Self.dictionary(of: run.outcome)["warnings"] as? [String]
                      == run.report.skipped, "warnings 要能带回给 Agent")
    }
}
