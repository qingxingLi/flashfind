import XCTest
@testable import FlashFindCore

/// Phase 6.3b-1：`locate` 真实执行的聚合契约。
///
/// ## 这一组用例守什么
///
/// ```text
/// AuthorizedSourceSnapshot（判权那一刻冻结的 provider）
///   → LocateExecutor（被测对象）
///     → SearchScheduler（真家伙，不是替身）
///       → FakeProvider（唯一被替换的只有「结果从哪来」）
/// ```
///
/// ★ 只替换 provider，**调度器是真的**：owner 隔离、同来源排队、终态恰好一次
/// 这些不变量都真的跑了一遍。用假调度器测「隔离」等于测替身自己。
///
/// ★ 所有来源 id 与文件名都是编造的。
@MainActor
final class LocateExecutionTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let archive = "src_nas_private"

    /// 固定「现在」，让 `recently-modified` 可复现（§7.3）。
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timing(budget: TimeInterval = 3) -> LocateExecutor.Timing {
        LocateExecutor.Timing(budget: budget, now: { self.now })
    }

    // MARK: - 替身 Provider

    /// 按脚本产出事件的 provider。
    ///
    /// `hang(_:)` 让前 N 次 `search` **占用槽位但不发终态**——那正是「一台不回包的
    /// 慢设备」在调度器眼里的样子（槽位被 running 占着，直到 search 返回）。
    final class FakeProvider: SearchProvider, @unchecked Sendable {

        let source: SearchSource
        private let script: ([ProviderEvent]) -> [ProviderEvent]
        private var remainingHangs = 0

        private(set) var searchCount = 0
        private(set) var owners: [SearchOwner] = []
        private(set) var cancelled: [UUID] = []
        /// 同一来源上观测到的最大并发搜索数——设备约束的断言点。
        private(set) var maxConcurrent = 0
        private var concurrent = 0

        init(id: String, events: @escaping ([ProviderEvent]) -> [ProviderEvent] = { _ in [] }) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.script = events
        }

        @discardableResult
        func hang(_ times: Int = 1) -> FakeProvider {
            remainingHangs = times
            return self
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            searchCount += 1
            owners.append(owner)
            concurrent += 1
            maxConcurrent = max(maxConcurrent, concurrent)
            defer { concurrent -= 1 }

            if remainingHangs > 0 {
                remainingHangs -= 1
                // 占住槽位约 1 秒，然后**什么都不发**（真实慢设备的形态）。
                for _ in 0..<50 {
                    if Task.isCancelled { break }
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return
            }
            // 让出一次，让并发进来的第二个请求真的排到队里（否则串行得太快，测不到排队）。
            await Task.yield()
            for event in script([ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching)]) {
                emit(event)
            }
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            await search(text, queryID: queryID, owner: .ui, emit: emit)
        }

        func cancel(queryID: UUID) { cancelled.append(queryID) }
    }

    // MARK: - 组装

    private func result(_ path: String, name: String? = nil, kind: String = "file",
                        modified: Date? = nil) -> SearchResult {
        var row = SearchResult(id: path, name: name ?? (path as NSString).lastPathComponent,
                              relativePath: path, sourceID: nil, sourceName: "",
                              kind: kind, size: 1, localURL: nil)
        row.modifiedDate = modified
        return row
    }

    private func events(_ rows: [SearchResult],
                        state: ProviderSearchState = .completed,
                        incomplete: Bool = false) -> ([ProviderEvent]) -> [ProviderEvent] {
        { prefix in
            var out = prefix
            out.append(ProviderEvent(queryID: prefix[0].queryID,
                                     sourceID: prefix[0].sourceID,
                                     results: rows,
                                     state: state,
                                     resultsIncomplete: incomplete))
            return out
        }
    }

    private func snapshot(_ providers: [FakeProvider],
                          allowed: [String]? = nil,
                          denied: [String] = [],
                          scheduler: SearchScheduler? = nil) -> AuthorizedSourceSnapshot {
        let ids = allowed ?? providers.map(\.source.id)
        let shared = scheduler ?? SearchScheduler(providers: providers)
        let registry = providers.map {
            AuthoritySource(id: $0.source.id,
                            name: "Source \($0.source.id)",
                            execution: SourceExecutionHandle(provider: $0, scheduler: shared))
        }
        let scope = AuthorizationScope(granting: .allow(sources: ids,
                                                        warnings: denied.map { "source_denied:\($0)" }))!
        return AuthorizedSourceSnapshot(scope: scope, registry: registry)
    }

    private func run(_ executor: LocateExecutor,
                     _ snapshot: AuthorizedSourceSnapshot,
                     query: String = "报告",
                     kind: FileKind? = nil,
                     modifiedAfter: Date? = nil,
                     limit: Int = 5,
                     owner: SearchOwner = .mcp(sessionID: "s1")) async -> LocateExecutor.Run {
        await executor.run(query: query,
                           kind: kind,
                           modifiedAfter: modifiedAfter,
                           application: LimitApplication(applied: limit, wasClamped: false),
                           snapshot: snapshot,
                           owner: owner)
    }

    private func payload(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw Failure()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func names(_ body: [String: Any]) -> [String]? {
        (body["results"] as? [[String: Any]])?.compactMap { $0["name"] as? String }
    }

    private func paths(_ body: [String: Any]) -> [String]? {
        (body["results"] as? [[String: Any]])?.compactMap { $0["relative_path"] as? String }
    }

    private struct Failure: Error {}

    // MARK: - ① limit + 1：truncated 必须真的观察到第 N+1 条

    /// 21 条候选 / limit 20 → `truncated: true`，只回 20 条。
    ///
    /// ★ 这条**必须走生产路径**：`LocateResponse` 自己的单测证明不了「执行层没提前
    /// 砍到 20 条」——一旦执行层先 `prefix(limit)` 再交给 `LocateResponse`，
    /// `truncated` 就永远 false，而那两个单测照样绿。
    func testOneMoreCandidateThanTheLimitIsTruncatedOnTheProductionPath() async throws {
        let rows = (1...21).map { result("归档/报告-\($0).pdf", name: "报告-\($0)") }
        let provider = FakeProvider(id: work, events: events(rows))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), limit: 20)

        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [Any])?.count, 20)
        XCTAssertEqual(body["truncated"] as? Bool, true)
        XCTAssertEqual(body["limit_applied"] as? Int, 20)
        XCTAssertEqual(run.report.candidates, 21, "执行层提前砍了候选：truncated 永远算不出来")
        XCTAssertEqual(run.report.returned, 20)
    }

    /// 正好 20 条 / limit 20 → `truncated: false`：用满上限不是「还有更多」（§4.4.1）。
    func testExactlyTheLimitIsNotTruncatedOnTheProductionPath() async throws {
        let rows = (1...20).map { result("归档/报告-\($0).pdf", name: "报告-\($0)") }
        let provider = FakeProvider(id: work, events: events(rows))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), limit: 20)

        XCTAssertEqual(try payload(run.outcome)["truncated"] as? Bool, false)
        XCTAssertEqual(run.report.candidates, 20)
    }

    /// 3 条 / limit 20 → `truncated: false`；`limit_applied` 用的是 Router 给的数。
    func testFewerCandidatesThanTheLimitIsNotTruncated() async throws {
        let rows = (1...3).map { result("归档/报告-\($0).pdf", name: "报告-\($0)") }
        let provider = FakeProvider(id: work, events: events(rows))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), limit: 20)

        let body = try payload(run.outcome)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(body["limit_applied"] as? Int, 20)
    }

    /// 来源自己说「结果不全」**不许**变成 `truncated`（§4.4.1 第三条）。
    func testProviderSideIncompletenessIsNotTruncated() async throws {
        let rows = (1...3).map { result("归档/报告-\($0).pdf", name: "报告-\($0)") }
        let provider = FakeProvider(id: work,
                                    events: events(rows, state: .truncated, incomplete: true))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), limit: 20)

        XCTAssertEqual(try payload(run.outcome)["truncated"] as? Bool, false,
                       "来源侧不完整被写成了 truncated")
        XCTAssertEqual(run.report.incompleteSources, [work])
    }

    // MARK: - ② 部分失败：results + typed warning

    /// 一个成功 + 一个掉线 → **成功结果 + `source_unavailable:<id>`**。
    func testOneSourceFailingYieldsResultsAndAWarning() async throws {
        let ok = FakeProvider(id: mac, events: events([result("Users/x/报告.pdf")]))
        let dead = FakeProvider(id: work, events: events([], state: .failed))
        let run = await run(LocateExecutor(timing: timing()), snapshot([ok, dead]))

        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [Any])?.count, 1)
        XCTAssertEqual(body["warnings"] as? [String], ["source_unavailable:\(work)"])
    }

    /// 一个来源被取消、另一个正常：取消的那台要出 `internal_error:<id>` warning，
    /// **不许**被悄悄丢掉（typed 语义对部分失败同样成立）。
    ///
    /// ★ 这条在**批跑**里也能红：「取消当成空结果」那条变异在单来源场景会被
    /// 「空结果被当成失败」遮住（两条都命中后，`sawUsableSource = false`
    /// 仍然把请求折回 `internal_error`，老用例 `testACancelledSearchIsNever…`
    /// 反而绿了）。这里有成功结果在场，`sawUsableSource` 走的是「有结果」分支，
    /// 遮蔽不成立；单来源那条留给 `mutate_each_mapped.py` 单独证红。
    func testACancelledSourceIsReportedEvenWhenAnotherSourceSucceeded() async throws {
        let ok = FakeProvider(id: mac, events: events([result("Users/x/报告.pdf")]))
        let cancelled = FakeProvider(id: work, events: events([], state: .cancelled))
        let run = await run(LocateExecutor(timing: timing()), snapshot([ok, cancelled]))

        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [Any])?.count, 1, "成功来源的结果不许丢")
        XCTAssertEqual(body["warnings"] as? [String], ["internal_error:\(work)"])
    }

    /// 一个成功 + 一个**超时** → `timeout:<id>`，**不许**伪装成 `source_unavailable`。
    ///
    /// ★ 这是复审点名的那条：三项优先级表里没有 `timeout`，但超时不能被折进
    /// 「来源连不上」——Agent 会去让用户排查一台其实好好的设备。
    func testATimedOutSourceIsReportedAsTimeoutNotUnavailable() async throws {
        let ok = FakeProvider(id: mac, events: events([result("Users/x/报告.pdf")]))
        let slow = FakeProvider(id: work).hang()
        let run = await run(LocateExecutor(timing: timing(budget: 0.3)), snapshot([ok, slow]))

        let body = try payload(run.outcome)
        XCTAssertEqual(body["warnings"] as? [String], ["timeout:\(work)"])
        XCTAssertEqual((body["results"] as? [Any])?.count, 1, "已完成的来源不许被慢来源拖死")
    }

    /// 超预算的来源要被真的取消：否则它会在设备上继续跑、占着那一台唯一的槽位。
    func testAnOverBudgetSourceIsCancelled() async throws {
        let slow = FakeProvider(id: work).hang()
        let ok = FakeProvider(id: mac, events: events([]))
        _ = await run(LocateExecutor(timing: timing(budget: 0.2)), snapshot([ok, slow]))
        XCTAssertEqual(slow.cancelled.count, 1, "超预算的搜索没有停掉")
    }

    /// 拒绝授权的来源在 warnings 里原样带出（`source_denied:<id>`），且不会被搜。
    func testDeniedSourcesComeFromTheScopeVerbatim() async throws {
        let provider = FakeProvider(id: mac, events: events([result("Users/x/报告.pdf")]))
        let run = await run(LocateExecutor(timing: timing()),
                            snapshot([provider], allowed: [mac], denied: [archive]))

        let body = try payload(run.outcome)
        XCTAssertEqual(body["warnings"] as? [String], ["source_denied:\(archive)"])
        XCTAssertEqual(provider.searchCount, 1, "已授权来源应当真的搜一次")
    }

    // MARK: - ③ 全部失败：typed error 不降级

    /// **公开错误模型冻结**（复审 6.3b-2 确认项）：wire 上能出现的失败码
    /// **就是这六个**，一个都不许多。内部 provider 状态里的 `.cancelled`
    /// 只是内部诊断态，它必须映射到既有语义（`internal_error`），不许
    /// 以 `{"code":"cancelled"}` 的形态漏进 1.1.2 的公开契约——
    /// 那是 Helper（第三方 Agent 的代码）要 switch 的集合，加码是破坏性变更。
    func testThePublicErrorCodesAreExactlyTheFrozenSix() {
        XCTAssertEqual(Set(LocateFailureCode.allCases.map(\.rawValue)),
                       ["auth_required", "source_denied", "timeout",
                        "source_unavailable", "invalid_argument", "internal_error"])
        // 取消从来不是公开失败码：`.cancelled` 落进 internal_error（永不空成功）。
        XCTAssertEqual(LocateExecutor.failureCode(for: SourceCollector.Snapshot(
                           rows: [], state: .cancelled, resultsIncomplete: false, timedOut: false)),
                       .internalError)
    }

    /// 单一来源超时 → 最终码就是 `timeout`。
    func testASingleTimedOutSourceKeepsItsOwnCode() async {
        let slow = FakeProvider(id: work).hang()
        let run = await run(LocateExecutor(timing: timing(budget: 0.2)), snapshot([slow]))
        XCTAssertEqual(run.outcome,
                       .failure(code: "timeout", message: LocateFailureCode.timeout.message))
    }

    /// 凭据失效压过「连不上」：`auth_required` 最优先（§4.2.1）。
    func testAuthRequiredWinsOverUnavailable() async {
        let auth = FakeProvider(id: work, events: events([], state: .needsAuth))
        let dead = FakeProvider(id: archive, events: events([], state: .failed))
        let run = await run(LocateExecutor(timing: timing()), snapshot([auth, dead]))
        XCTAssertEqual(run.outcome,
                       .failure(code: "auth_required",
                                message: LocateFailureCode.authRequired.message))
    }

    /// 超时压过「连不上」：超时是「重试可能就好」，折成不可用会把人引去查设备。
    func testTimeoutOutranksUnavailableWhenEverythingFails() async {
        let slow = FakeProvider(id: work).hang()
        let dead = FakeProvider(id: archive, events: events([], state: .failed))
        let run = await run(LocateExecutor(timing: timing(budget: 0.2)), snapshot([slow, dead]))
        XCTAssertEqual(run.outcome,
                       .failure(code: "timeout", message: LocateFailureCode.timeout.message))
    }

    /// 设备不接受这个搜索词（`.blocked`）是**参数**问题，不是设备问题。
    func testABlockedSourceIsAnArgumentProblemNotAnOutage() async {
        let blocked = FakeProvider(id: work, events: events([], state: .blocked))
        let run = await run(LocateExecutor(timing: timing()), snapshot([blocked]))
        XCTAssertEqual(run.outcome,
                       .failure(code: "invalid_argument",
                                message: LocateFailureCode.invalidArgument.message))
    }

    /// 被取消不是「没找到」：宁可说内部错误，也不要回空结果。
    func testACancelledSearchIsNeverAnEmptySuccess() async {
        let cancelled = FakeProvider(id: work, events: events([], state: .cancelled))
        let run = await run(LocateExecutor(timing: timing()), snapshot([cancelled]))
        XCTAssertEqual(run.outcome,
                       .failure(code: "internal_error",
                                message: LocateFailureCode.internalError.message))
    }

    /// 「搜过了，没有」是**成功**：`results: []` + 无 warnings。
    func testAnEmptyButCompletedSearchIsASuccess() async throws {
        let provider = FakeProvider(id: work, events: events([]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))
        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [Any])?.count, 0)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(body["warnings"] as? [String], [])
    }

    // MARK: - ④ 快照：不重读注册表

    /// 快照里没有 provider 的来源（判权后被删 / 尚未构建）→ `source_unavailable`，
    /// **不许**去别处找一个新的 provider 顶上。
    func testASourceWithoutAProviderFailsInsteadOfSubstitutingAnother() async {
        let inScope = "src_nas_gone"
        let scope = AuthorizationScope(granting: .allow(sources: [inScope], warnings: []))!
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope,
            registry: [AuthoritySource(id: inScope, name: "Gone", execution: nil)])
        let run = await run(LocateExecutor(timing: timing()), snapshot)

        XCTAssertEqual(run.outcome,
                       .failure(code: "source_unavailable",
                                message: LocateFailureCode.sourceUnavailable.message))
    }

    /// 只有快照里的 provider 会被搜：注册表里多出来的那个一条事件都收不到。
    func testTheExecutorUsesOnlyTheProvidersInTheSnapshot() async throws {
        let authorized = FakeProvider(id: mac, events: events([result("Users/x/报告.pdf")]))
        let unlisted = FakeProvider(id: work, events: events([result("共享/报告.pdf")]))
        let run = await run(LocateExecutor(timing: timing()),
                            snapshot([authorized, unlisted], allowed: [mac]))

        XCTAssertEqual(unlisted.searchCount, 0, "未授权的 provider 被搜了")
        XCTAssertEqual(authorized.searchCount, 1)
        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [Any])?.count, 1)
        XCTAssertEqual((body["results"] as? [[String: Any]])?.first?["source_id"] as? String, mac)
    }

    // MARK: - ⑤ owner 隔离

    /// 一次 wire 请求一个 owner：两次请求（两个 session）在**同一来源**上排队，
    /// 不是互相取消。
    func testTwoMCPRequestsOnTheSameSourceQueueRatherThanCancel() async throws {
        let provider = FakeProvider(id: work, events: events([result("共享/报告.pdf")]))
        let scheduler = SearchScheduler(providers: [provider])
        let snapshot = self.snapshot([provider], scheduler: scheduler)
        let executor = LocateExecutor(timing: timing())

        async let first = executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                       application: LimitApplication(applied: 5, wasClamped: false),
                                       snapshot: snapshot, owner: .mcp(sessionID: "a"))
        async let second = executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                        application: LimitApplication(applied: 5, wasClamped: false),
                                        snapshot: snapshot, owner: .mcp(sessionID: "b"))
        let (one, two) = await (first, second)

        guard case .success = one.outcome, case .success = two.outcome else {
            return XCTFail("两个会话的请求应当都成功：\(one.outcome) / \(two.outcome)")
        }
        XCTAssertEqual(scheduler.rejectedCancelCount, 0, "发生了跨 owner 的取消")
        XCTAssertEqual(provider.maxConcurrent, 1, "同一来源同时跑了两个查询")
        XCTAssertEqual(Set(provider.owners), [.mcp(sessionID: "a"), .mcp(sessionID: "b")],
                       "两次请求必须是两个不同的 owner")
    }

    /// 同一个会话的两次请求**也不互相取代**：`supersedePrevious` 显式传 `false`。
    func testTwoSequentialRequestsFromOneSessionBothSurvive() async throws {
        let provider = FakeProvider(id: work, events: events([result("共享/报告.pdf")]))
        let scheduler = SearchScheduler(providers: [provider])
        let snapshot = self.snapshot([provider], scheduler: scheduler)
        let executor = LocateExecutor(timing: timing())

        let one = await executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                     application: LimitApplication(applied: 5, wasClamped: false),
                                     snapshot: snapshot, owner: .mcp(sessionID: "a"))
        let two = await executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                     application: LimitApplication(applied: 5, wasClamped: false),
                                     snapshot: snapshot, owner: .mcp(sessionID: "a"))
        guard case .success = one.outcome, case .success = two.outcome else {
            return XCTFail("同会话的两次请求都被取代了")
        }
        XCTAssertEqual(provider.cancelled.count, 0)
    }

    /// **同一个会话的两个并发请求**不许互相取消。
    ///
    /// ★ 这条比上面那条狠：串行时「取代」没有对象可取消，改坏了也看不出来；
    /// 并发时 `supersedePrevious: true` 会立刻把第一条取消掉。
    /// `locate_many` 将来一次展开 5 条子查询，靠的就是这条不变量。
    func testTwoConcurrentRequestsFromOneSessionDoNotCancelEachOther() async throws {
        let provider = FakeProvider(id: work, events: events([result("共享/报告.pdf")]))
        let scheduler = SearchScheduler(providers: [provider])
        let snapshot = self.snapshot([provider], scheduler: scheduler)
        let executor = LocateExecutor(timing: timing())
        let owner = SearchOwner.mcp(sessionID: "a")

        async let first = executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                       application: LimitApplication(applied: 5, wasClamped: false),
                                       snapshot: snapshot, owner: owner)
        async let second = executor.run(query: "报告", kind: nil, modifiedAfter: nil,
                                        application: LimitApplication(applied: 5, wasClamped: false),
                                        snapshot: snapshot, owner: owner)
        let (one, two) = await (first, second)

        guard case .success = one.outcome, case .success = two.outcome else {
            return XCTFail("同会话的并发请求互相取代了：\(one.outcome) / \(two.outcome)")
        }
        XCTAssertEqual(provider.cancelled.count, 0, "同会话的两个请求互相取消了")
    }

    /// MCP 的执行不许碰 GUI 那条正在跑的查询：owner 不同 → 不取消、只排队。
    func testMCPExecutionNeverCancelsTheGUIsRunningQuery() async {
        // 第一次（GUI 那条）占住槽位，MCP 那条排到它后面。
        let provider = FakeProvider(id: work, events: events([result("共享/报告.pdf")])).hang()
        let scheduler = SearchScheduler(providers: [provider])
        let snapshot = self.snapshot([provider], scheduler: scheduler)

        scheduler.submit(text: "gui", queryID: UUID(), owner: .ui, supersedePrevious: true) { _ in }
        XCTAssertEqual(scheduler.runningQuery(sourceID: work) != nil, true, "GUI 那条应当占着槽位")

        _ = await run(LocateExecutor(timing: timing()), snapshot, owner: .mcp(sessionID: "x"))

        XCTAssertEqual(provider.cancelled.count, 0, "MCP 把 GUI 的查询取消了")
        XCTAssertEqual(scheduler.rejectedCancelCount, 0)
    }

    // MARK: - ⑥ 参数与身份

    /// `kind` 过滤在开窗之前生效：21 条里 1 条是文件夹 → 候选 20 条，不是截断。
    func testKindFilteringHappensBeforeTheWindow() async throws {
        var rows = (1...20).map { result("归档/报告-\($0).pdf", name: "报告-\($0)") }
        rows.append(result("归档/报告文件夹", kind: "directory"))
        let provider = FakeProvider(id: work, events: events(rows))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]),
                            kind: .file, limit: 20)

        XCTAssertEqual(run.report.droppedKind, 1)
        XCTAssertEqual(run.report.candidates, 20)
        XCTAssertEqual(try payload(run.outcome)["truncated"] as? Bool, false)
    }

    /// `modified_after`：没有修改时间的结果**无法证明**满足条件 → 丢弃并计数。
    func testModifiedAfterDropsUndatedRows() async throws {
        let provider = FakeProvider(id: work, events: events([
            result("a/报告-新.pdf", modified: now.addingTimeInterval(-3600)),
            result("a/报告-老.pdf", modified: now.addingTimeInterval(-86_400 * 400)),
            result("a/报告-无时间.pdf", modified: nil),
        ]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]),
                            modifiedAfter: now.addingTimeInterval(-86_400))

        XCTAssertEqual(names(try payload(run.outcome)), ["报告-新.pdf"])
        XCTAssertEqual(run.report.droppedDate, 2)
    }

    /// 越界路径（`..`）被丢弃，**不钳根、不重排**。
    func testEscapingPathsAreDroppedNotRepaired() async throws {
        let provider = FakeProvider(id: work, events: events([
            result("../../etc/passwd", name: "报告-越界"),
            result("/共享/报告.pdf", name: "报告-正常"),
        ]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))

        XCTAssertEqual(paths(try payload(run.outcome)), ["共享/报告.pdf"], "越界路径被钳到了根上")
        XCTAssertEqual(run.report.droppedUnsafePath, 1)
        XCTAssertEqual(run.report.candidates, 1)
    }

    /// 本机来源的绝对路径按「根 = /」收敛：`/Users/x/报告.pdf` → `Users/x/报告.pdf`。
    ///
    /// ★ 复审拍板：`local_mac` 的逻辑根固定为 `/`，否则 `/Applications` 这类
    /// 本来属于「此 Mac」的结果无法表达。
    func testTheLocalSourceRootIsTheWholeMac() async throws {
        let provider = FakeProvider(id: mac, events: events([result("/Applications/预览.app")]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))
        XCTAssertEqual(paths(try payload(run.outcome)), ["Applications/预览.app"])
    }

    /// `source_id` 只来自快照，不来自 provider 塞进结果里的字段。
    func testTheSourceIDComesFromTheSnapshotNotFromTheRow() async throws {
        var row = result("共享/报告.pdf")
        row.sourceID = "src_forged"      // provider 说了不算
        let provider = FakeProvider(id: work, events: events([row]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))

        let body = try payload(run.outcome)
        XCTAssertEqual((body["results"] as? [[String: Any]])?.first?["source_id"] as? String, work)
    }

    /// 同一来源重复给同一个路径 → 合并成一条（`file_id` 相同就是同一个文件）。
    func testDuplicateRowsForOnePathAreMerged() async throws {
        let provider = FakeProvider(id: work, events: events([
            result("共享/报告.pdf"), result("共享/报告.pdf"),
        ]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))
        XCTAssertEqual(run.report.candidates, 1)
        XCTAssertEqual(run.report.mergedDuplicates, 1)
    }

    // MARK: - ⑦ 排序与理由

    /// 名字更像的排前面，哪怕它更旧：§7.1 那条硬约束。
    func testASharperNameMatchOutranksAFresherFile() async throws {
        let provider = FakeProvider(id: work, events: events([
            result("共享/报告草稿.pdf", name: "报告草稿", modified: now.addingTimeInterval(-86_400 * 300)),
            result("共享/季度报告.pdf", name: "季度报告", modified: now.addingTimeInterval(-60)),
        ]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), query: "报告")
        XCTAssertEqual(names(try payload(run.outcome)), ["报告草稿", "季度报告"])
    }

    /// 没有历史数据时**不许**出现 `metadata-access` / `located-recently`。
    func testNoHistoryReasonsAreInvented() async throws {
        let provider = FakeProvider(id: work,
                                    events: events([result("共享/报告.pdf", modified: now)]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))
        let body = try payload(run.outcome)
        let reasons = (body["results"] as? [[String: Any]])?.first?["reasons"] as? [String]
        XCTAssertEqual(reasons, ["name-match", "recently-modified"])
    }

    /// 三年前改过的文件：分数里仍有极小的一点，但**不许**声称「近期修改过」。
    func testAnOldFileDoesNotClaimToBeRecentlyModified() async throws {
        let provider = FakeProvider(id: work,
                                    events: events([result("共享/报告.pdf",
                                                           modified: now.addingTimeInterval(-86_400 * 900))]))
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]))
        let body = try payload(run.outcome)
        let hit = (body["results"] as? [[String: Any]])?.first
        XCTAssertEqual(hit?["reasons"] as? [String], ["name-match"])
    }

    /// 同分时按 `relative_path` 升序，结果与到达顺序无关（§7.3 确定性）。
    func testTiesAreBrokenByPathSoTheOrderIsReproducible() async throws {
        let rows = ["共享/报告-b.pdf", "共享/报告-a.pdf", "共享/报告-c.pdf"]
        let forward = FakeProvider(id: work, events: events(rows.map { result($0) }))
        let backward = FakeProvider(id: work, events: events(rows.reversed().map { result($0) }))

        let one = try payload(await run(LocateExecutor(timing: timing()),
                                        snapshot([forward])).outcome)
        let two = try payload(await run(LocateExecutor(timing: timing()),
                                        snapshot([backward])).outcome)
        XCTAssertEqual(paths(one), ["共享/报告-a.pdf", "共享/报告-b.pdf", "共享/报告-c.pdf"])
        XCTAssertEqual(paths(one), paths(two), "同一批结果换个到达顺序就变了")
    }

    /// 分数落在 `0…1`，且**同一输入两次逐字节相同**。
    func testScoresStayInRangeAndThePayloadIsStable() async throws {
        let rows = [result("共享/报告.pdf", modified: now),
                    result("共享/其它.pdf", modified: now.addingTimeInterval(-86_400 * 40))]
        let provider = FakeProvider(id: work, events: events(rows))
        let executor = LocateExecutor(timing: timing())
        let snapshot = self.snapshot([provider])

        let one = await run(executor, snapshot)
        let two = await run(executor, snapshot)
        guard case .success(let first) = one.outcome, case .success(let second) = two.outcome else {
            return XCTFail("应当成功")
        }
        XCTAssertEqual(first, second, "同一输入两次产出不同串")

        let body = try payload(one.outcome)
        let scores = (body["results"] as? [[String: Any]])?.compactMap { $0["score"] as? Double }
        XCTAssertEqual(scores?.count, 2)
        for score in scores ?? [] {
            XCTAssertTrue((0...1).contains(score), "分数越界：\(score)")
        }
    }
}
