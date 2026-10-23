import XCTest
@testable import FlashFindCore

/// Phase 6.4a：`locate_many` 的聚合契约。
///
/// ## 这一组守的四件事（v0.27 拍板，逐条有用例）
///
/// ```text
/// ① 一个 owner        —— N 条子查询挂在同一个 wire 请求的 owner 上
/// ② supersedePrevious —— 必须 false，否则第 5 条把前 4 条取消
/// ③ 一张预算券        —— 全部子查询共用 deadline，不是每条各领一份
/// ④ 输入顺序          —— 分组按 queries[] 排，不按谁先搜完
/// ```
///
/// ★ 只替换 provider，**调度器是真的**：同来源排队、跨来源并行、终态恰好一次
/// 这些不变量都得真的跑一遍。用假调度器测「共用预算」等于测替身自己。
///
/// ★ 所有来源 id、文件名、查询词都是编造的。
@MainActor
final class LocateManyExecutionTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let archive = "src_nas_archive"

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timing(budget: TimeInterval = 3) -> LocateExecutor.Timing {
        LocateExecutor.Timing(budget: budget, now: { self.now })
    }

    // MARK: - 替身 Provider

    /// 按「查询词」产出行与终态的 provider。
    ///
    /// * `rows`：这个词返回哪些行；
    /// * `states`：这个词的终态（默认 `.completed`）；
    /// * `delays`：这个词先睡多久再回（用来制造「第一条最慢」）；
    /// * `hangs`：这个词**占住槽位但不发终态**（一台不回包的慢设备）。
    final class ScriptedProvider: SearchProvider, @unchecked Sendable {

        let source: SearchSource

        private let rows: [String: [SearchResult]]
        private let states: [String: ProviderSearchState]
        private let delays: [String: Duration]
        private let hangs: Set<String>

        private(set) var owners: [SearchOwner] = []
        private(set) var texts: [String] = []
        private(set) var queryIDs: [UUID] = []
        private(set) var cancelled: [UUID] = []

        init(id: String,
             rows: [String: [SearchResult]] = [:],
             states: [String: ProviderSearchState] = [:],
             delays: [String: Duration] = [:],
             hangs: Set<String> = []) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.rows = rows
            self.states = states
            self.delays = delays
            self.hangs = hangs
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            owners.append(owner)
            texts.append(text)
            queryIDs.append(queryID)

            if let delay = delays[text] { try? await Task.sleep(for: delay) }
            if hangs.contains(text) {
                // 占住槽位（调度器眼里就是「running 一直不结束」），什么都不发。
                for _ in 0..<100 where !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(20))
                }
                return
            }

            await Task.yield()
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
            emit(ProviderEvent(queryID: queryID,
                               sourceID: source.id,
                               results: rows[text] ?? [],
                               state: states[text] ?? .completed))
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            await search(text, queryID: queryID, owner: .ui, emit: emit)
        }

        func cancel(queryID: UUID) { cancelled.append(queryID) }
    }

    // MARK: - 脚手架

    private func row(_ path: String, kind: String = "file", modified: Date? = nil) -> SearchResult {
        var result = SearchResult(id: path,
                                  name: (path as NSString).lastPathComponent,
                                  relativePath: path,
                                  sourceID: nil,
                                  sourceName: "",
                                  kind: kind,
                                  size: 1,
                                  localURL: nil)
        result.modifiedDate = modified
        return result
    }

    private func snapshot(_ providers: [ScriptedProvider]) -> AuthorizedSourceSnapshot {
        let shared = SearchScheduler(providers: providers)
        let registry = providers.map {
            AuthoritySource(id: $0.source.id,
                            name: "Source \($0.source.id)",
                            execution: SourceExecutionHandle(provider: $0, scheduler: shared))
        }
        let scope = AuthorizationScope(granting: .allow(sources: providers.map(\.source.id),
                                                        warnings: []))!
        return AuthorizedSourceSnapshot(scope: scope, registry: registry)
    }

    private func run(_ executor: LocateExecutor,
                     _ snapshot: AuthorizedSourceSnapshot,
                     queries: [String],
                     limit: Int = 3,
                     owner: SearchOwner = .mcp(sessionID: "many")) async -> LocateExecutor.Run {
        await executor.runMany(queries: queries,
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

    private func groups(_ body: [String: Any]) throws -> [[String: Any]] {
        try XCTUnwrap(body["queries"] as? [[String: Any]], "没有 queries 分组：\(body)")
    }

    /// 第 N 组，**越界时失败而不是崩**。
    ///
    /// ★ `list[1]` 这种写法在「分组被丢掉」那类变异下会 index out of range，
    /// 而 Swift 的越界是**进程级 trap**：整个 `swift test` 当场终止，
    /// 批跑里后面的用例全部变成 MISS（2026-10-21 实测过一次，144/303 假 MISS）。
    /// 断言失败只红一条，trap 红掉一整轮。
    private func group(_ list: [[String: Any]], _ index: Int) throws -> [String: Any] {
        guard index < list.count else {
            XCTFail("分组数不足：要第 \(index + 1) 组，实际只有 \(list.count) 组")
            throw Failure()
        }
        return list[index]
    }

    private func names(_ group: [String: Any]) -> [String] {
        (group["results"] as? [[String: Any]])?.compactMap { $0["name"] as? String } ?? []
    }

    private struct Failure: Error {}

    // MARK: - ④ 顺序 = 输入顺序

    /// 三条子查询**故意不按字典序**传（丙 / 甲 / 乙），并且第一条最慢。
    ///
    /// ★ 只断言「都回来了」是不够的：把分组按查询词排序、或按「谁先搜完」排序，
    /// 这类实现都能让「三条都在」成立，却会让 Agent 把 A 文件的答案说成 B 文件的。
    func testGroupsFollowTheInputOrderNotTheCompletionOrder() async throws {
        let provider = ScriptedProvider(
            id: work,
            rows: ["丙": [row("归档/丙.pdf")],
                   "甲": [row("归档/甲.pdf")],
                   "乙": [row("归档/乙.pdf")]],
            delays: ["丙": .milliseconds(120)])

        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]),
                            queries: ["丙", "甲", "乙"])
        let body = try payload(run.outcome)
        let list = try groups(body)

        XCTAssertEqual(list.compactMap { $0["query"] as? String }, ["丙", "甲", "乙"])
        XCTAssertEqual(list.map { names($0) }, [["丙.pdf"], ["甲.pdf"], ["乙.pdf"]],
                       "分组的顺序或内容串位了：\(list)")
        XCTAssertEqual(body["limit_applied"] as? Int, 3)
        for group in list {
            XCTAssertNil(group["limit_applied"],
                         "每组的 limit 是同一个 per_query_limit，别在组里再抄一份")
        }
    }

    // MARK: - 每组独立的 truncated

    /// 甲 4 条 / limit 3 → 这一组 `truncated: true` 且只回 3 条；
    /// 乙 2 条 / limit 3 → `false`。
    ///
    /// ★ 两组必须**结论不同**：如果实现把「整个 call 的候选总数」当成截断判据，
    /// 两组会一起变 true。
    func testEveryGroupHasItsOwnTruncatedWindow() async throws {
        let four = (1...4).map { row("归档/甲-\($0).pdf") }
        let two = (1...2).map { row("归档/乙-\($0).pdf") }
        let provider = ScriptedProvider(id: work, rows: ["甲": four, "乙": two])

        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]),
                            queries: ["甲", "乙"], limit: 3)
        let list = try groups(try payload(run.outcome))

        XCTAssertEqual(names(try group(list, 0)).count, 3)
        XCTAssertEqual(try group(list, 0)["truncated"] as? Bool, true,
                       "甲有 4 条候选，limit 3，确实还有更多")
        XCTAssertEqual(names(try group(list, 1)).count, 2)
        XCTAssertEqual(try group(list, 1)["truncated"] as? Bool, false, "乙只有 2 条，没有第 4 条")
        XCTAssertEqual(run.report.candidates, 6, "诊断里的候选数是各组合计")
        XCTAssertEqual(run.report.returned, 5)
    }

    // MARK: - ① 一个 owner

    /// 三条子查询 × 两个来源 = 6 次 provider 调用，**全部同一个 owner**。
    ///
    /// ★ owner 一旦按子查询各生成一个，「取消这次 locate_many」就没有落点：
    /// 用户按 Esc 只会取消掉其中一条。
    func testAllSubQueriesShareTheSameOwner() async throws {
        let a = ScriptedProvider(id: work, rows: ["甲": [row("a/甲.pdf")]])
        let b = ScriptedProvider(id: archive, rows: ["乙": [row("b/乙.pdf")]])
        let owner = SearchOwner.mcp(sessionID: "wire-42")

        _ = await run(LocateExecutor(timing: timing()), snapshot([a, b]),
                      queries: ["甲", "乙", "丙"], owner: owner)

        XCTAssertEqual(a.owners.count, 3)
        XCTAssertEqual(b.owners.count, 3)
        XCTAssertTrue(a.owners.allSatisfy { $0 == owner }, "子查询换了 owner：\(a.owners)")
        XCTAssertTrue(b.owners.allSatisfy { $0 == owner })
        XCTAssertEqual(Set(a.queryIDs).count, 3, "三条子查询必须各有自己的 queryID")
    }

    /// 同一条子查询在**不同来源**上共用一个 queryID（一次查询打多来源）。
    func testOneSubQueryUsesOneQueryIDAcrossSources() async throws {
        let a = ScriptedProvider(id: work, rows: ["甲": [row("a/甲.pdf")]])
        let b = ScriptedProvider(id: archive, rows: ["甲": [row("b/甲.pdf")]])

        _ = await run(LocateExecutor(timing: timing()), snapshot([a, b]), queries: ["甲"])

        XCTAssertEqual(a.queryIDs.count, 1)
        XCTAssertEqual(a.queryIDs, b.queryIDs, "同一条子查询在两个来源上必须是同一个 queryID")
    }

    // MARK: - ② 五条子查询不许互相取代

    /// 5 条子查询打在**同一个来源**上：5 条都要有结果。
    ///
    /// ★ 这是 v0.6 那个真实故障的回归：同 owner 自动取代会让第 5 条取消前 4 条，
    /// 结果只剩最后一条。`supersedePrevious: false` 必须显式传，不能靠推断。
    func testFiveSubQueriesOnOneSourceAllComeBack() async throws {
        let queries = ["一", "二", "三", "四", "五"]
        let rows = Dictionary(uniqueKeysWithValues: queries.map { ($0, [row("归档/\($0).pdf")]) })
        let provider = ScriptedProvider(id: work, rows: rows)

        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), queries: queries)
        let list = try groups(try payload(run.outcome))

        XCTAssertEqual(list.count, 5)
        XCTAssertEqual(list.map { names($0) }, queries.map { ["\($0).pdf"] },
                       "有子查询被同 owner 的后续请求取代掉了：\(list)")
        XCTAssertTrue(provider.cancelled.isEmpty, "不该有任何取消：\(provider.cancelled)")
    }

    // MARK: - ③ 一张预算券（不是每条一张）

    /// 5 条子查询共用**一张**预算券。
    ///
    /// ## 这条为什么必须存在
    ///
    /// 对外的契约是「整个 `tools/call` ≤ 10 s」（`AuthorityLimits.requestTimeout`）。
    /// 如果实现给每条子查询各发一张 budget，最坏就是 5 × budget——
    /// 10 s 的契约当场变成 50 s，而这种实现**单看结果是对的**（每条都会按自己的
    /// 预算超时，warning 也齐），只有量时间才看得出来。
    ///
    /// 做法：让 provider 对第一条查询占住槽位不回包（同来源串行，后面 4 条排队），
    /// budget 0.35 s，然后**量整次调用的墙钟**。
    ///
    /// ★ 为什么红证的变异写成「`remaining()` 乘份数」而不是「换成 `deadline.budget`」：
    ///   所有 wait 任务是同一瞬间起步的，那一刻 `remaining()` 本来就 ≈ `budget`，
    ///   后者是**等价变异**，红不了（2026-10-21 实测：0 条变红）。真正能被观察到的
    ///   缺陷形态是「总时长 = 份数 × budget」——那正是给每条子查询各发一张券的后果，
    ///   也是这条用例唯一量得到的东西（`tools/red_proof.py` ㉘）。
    ///   券本身「会随时间消耗」由下一条用例单独守。
    func testTheSubQueriesShareOneBudgetInsteadOfOneEach() async throws {
        let queries = ["一", "二", "三", "四", "五"]
        let provider = ScriptedProvider(id: work, hangs: ["一"])

        let started = Date()
        let run = await run(LocateExecutor(timing: timing(budget: 0.35)),
                            snapshot([provider]),
                            queries: queries)
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 0.9,
                          "5 条子查询各领了一份预算（总耗时 \(elapsed) s）：对外 10 s 契约会被突破")
        guard case .failure(let code, _) = run.outcome else {
            return XCTFail("全部来源超时应当返回错误：\(run.outcome)")
        }
        XCTAssertEqual(code, LocateFailureCode.timeout.rawValue)

        // 失败按**来源**聚合：5 条子查询各报一次 timeout 只是噪声。
        XCTAssertEqual(run.report.failures, ["timeout:\(work)"])
    }

    /// 预算券必须**随时间消耗**，不能永远报「还剩一整张」。
    ///
    /// 这条守的是 `Deadline` 自己的算术。上一条用例抓不到它：所有 wait 任务同一瞬间
    /// 起步，那一刻 `remaining()` 与 `budget` 数值相同——`remaining()` 写成
    /// `return budget` 时上一条照样绿（2026-10-21 实测）。所以「会消耗」必须单独证。
    func testTheBudgetCouponShrinksWithTheClockInsteadOfStayingFull() {
        let fresh = Deadline(budget: 1.0)
        XCTAssertGreaterThan(fresh.remaining(), 0.9, "刚建好的券应当还剩几乎一整张")
        XCTAssertLessThanOrEqual(fresh.remaining(), 1.0)

        let half = Deadline(budget: 1.0, start: .now() - .milliseconds(400))
        XCTAssertLessThan(half.remaining(), 0.95,
                          "过了 0.4 s 还报「剩一整张」：预算永远用不完")
        XCTAssertGreaterThan(half.remaining(), 0.05)

        let expired = Deadline(budget: 0.1, start: .now() - .milliseconds(600))
        XCTAssertEqual(expired.remaining(), 0, accuracy: 0.0001,
                       "过期后必须报 0，不能是负数")
    }

    /// 只有一条慢、其余正常：结果照常返回，慢的那条以 `timeout:<id>` 出现，
    /// 且**整次调用**仍然在预算内结束。
    func testOneHangingSourceDoesNotHoldTheWholeCall() async throws {
        let fast = ScriptedProvider(id: work, rows: ["甲": [row("a/甲.pdf")], "乙": [row("a/乙.pdf")]])
        let slow = ScriptedProvider(id: archive, hangs: ["甲", "乙"])

        let started = Date()
        let run = await run(LocateExecutor(timing: timing(budget: 0.4)),
                            snapshot([fast, slow]),
                            queries: ["甲", "乙"])
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertLessThan(elapsed, 1.0, "一次 locate_many 必须整体受预算约束")
        let body = try payload(run.outcome)
        XCTAssertEqual(try groups(body).map { names($0) }, [["甲.pdf"], ["乙.pdf"]])
        XCTAssertEqual(body["warnings"] as? [String], ["timeout:\(archive)"])
    }

    // MARK: - 空组 / 重复词 / 全失败

    /// 0 命中的那条也必须有一个 `results: []` 的组。
    ///
    /// 少了它，Agent 分不清「这条搜过了没有」与「这条压根没搜」。
    func testAQueryWithoutHitsStillGetsAnEmptyGroup() async throws {
        let provider = ScriptedProvider(id: work, rows: ["甲": [row("归档/甲.pdf")]])
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), queries: ["甲", "乙"])

        let list = try groups(try payload(run.outcome))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(names(try group(list, 0)), ["甲.pdf"])
        XCTAssertEqual(names(try group(list, 1)), [], "乙没有命中，但这一组必须在，且为空")
        XCTAssertEqual(try group(list, 1)["truncated"] as? Bool, false)
    }

    /// 用户把同一个词说了两遍：两条子查询各算各的。
    ///
    /// ★ 这条守的是聚合键必须是 `queryID` 而不是查询文本——按文本归并会让
    /// 两条子查询的结果互相串到一起（每组都变成两倍）。
    func testDuplicateQueryTextsKeepTheirOwnGroups() async throws {
        let provider = ScriptedProvider(id: work, rows: ["报告": [row("归档/报告.pdf")]])
        let run = await run(LocateExecutor(timing: timing()), snapshot([provider]), queries: ["报告", "报告"])

        let list = try groups(try payload(run.outcome))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list.map { names($0) }, [["报告.pdf"], ["报告.pdf"]],
                       "同一个词的两条子查询把结果混到一起了：\(list)")
    }

    /// 所有来源都失败 → **错误**，不是五个空组。
    ///
    /// 空组的语义是「搜过了，没有」；真实原因是设备连不上。
    ///
    /// ★ 两条子查询都必须标成失败：`completed` + 0 条是「搜过了，没有」——
    /// 那是**成功**，`sawUsableSource` 在这里不区分「有结果」与「真的跑完了」。
    func testEverySourceFailingReturnsAnErrorInsteadOfEmptyGroups() async throws {
        let a = ScriptedProvider(id: work, states: ["甲": .failed, "乙": .failed])
        let b = ScriptedProvider(id: archive, states: ["甲": .failed, "乙": .failed])

        let run = await run(LocateExecutor(timing: timing()), snapshot([a, b]), queries: ["甲", "乙"])
        guard case .failure(let code, let message) = run.outcome else {
            return XCTFail("全部来源失败时必须返回错误：\(run.outcome)")
        }
        XCTAssertEqual(code, LocateFailureCode.sourceUnavailable.rawValue)
        XCTAssertFalse(message.isEmpty)
    }

    /// 一个来源好、一个来源坏 → 成功 + 一条（按来源去重后的）warning。
    func testPartialFailureIsReportedOncePerSource() async throws {
        let ok = ScriptedProvider(id: mac, rows: ["甲": [row("Users/x/甲.pdf")]])
        let dead = ScriptedProvider(id: work, states: ["甲": .failed, "乙": .failed])

        let run = await run(LocateExecutor(timing: timing()), snapshot([ok, dead]), queries: ["甲", "乙"])
        let body = try payload(run.outcome)

        XCTAssertEqual(body["warnings"] as? [String], ["source_unavailable:\(work)"],
                       "两条子查询各报一次就是同一句话说了两遍")
    }

    /// 没有 provider 的来源（已授权但没连上）仍然要出现在结果里：
    /// 它是 `source_unavailable`，不是「不存在」。
    func testASourceWithoutAProviderIsReportedNotDropped() async throws {
        let ok = ScriptedProvider(id: mac, rows: ["甲": [row("Users/x/甲.pdf")]])
        let shared = SearchScheduler(providers: [ok])
        let registry = [
            AuthoritySource(id: mac, name: "mac",
                            execution: SourceExecutionHandle(provider: ok, scheduler: shared)),
            AuthoritySource(id: work, name: "work", execution: nil),
        ]
        let scope = AuthorizationScope(granting: .allow(sources: [mac, work], warnings: []))!
        let snapshot = AuthorizedSourceSnapshot(scope: scope, registry: registry)

        let run = await run(LocateExecutor(timing: timing()), snapshot, queries: ["甲"])
        let body = try payload(run.outcome)

        XCTAssertEqual(try groups(body).map { names($0) }, [["甲.pdf"]])
        XCTAssertEqual(body["warnings"] as? [String], ["source_unavailable:\(work)"])
        XCTAssertEqual(run.report.executedSources, 1)
    }
}
