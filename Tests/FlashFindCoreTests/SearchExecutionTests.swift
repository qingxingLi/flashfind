import XCTest
@testable import FlashFindCore

/// Phase 6.4a：`search` 的契约。
///
/// ## 它和 `locate` 的分工（§15 #29，v0.27 拍板）
///
/// ```text
///              SearchResultRanker        ← lexical（名字/路径）唯一事实来源
///                     ↑
///                LocateRanker            ← 在基础分上组合 locate 独有信号
/// ```
///
/// **共用 lexical，不共用最终 composite 分**：`search` 宽口径、多结果、
/// 不做修改时间与历史加权；`locate` 强排序、少量结果、要 `score` 与 `reasons`。
///
/// ★ 所以本文件里最要紧的一条是 `testTheTwoToolsOrderTheSameInputDifferently`：
/// 同一批输入，`search` 按名字/路径排，`locate` 把刚改过的提到前面。
/// 两边顺序**必须不同**——如果哪天有人「顺手复用」了 `LocateRanker`，
/// 这条会红。
@MainActor
final class SearchExecutionTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func timing(budget: TimeInterval = 3) -> LocateExecutor.Timing {
        LocateExecutor.Timing(budget: budget, now: { self.now })
    }

    // MARK: - 替身 Provider

    final class ScriptedProvider: SearchProvider, @unchecked Sendable {

        let source: SearchSource
        private let rows: [SearchResult]
        private let state: ProviderSearchState
        private let delay: Duration?

        private(set) var searchCount = 0
        private(set) var owners: [SearchOwner] = []

        init(id: String,
             rows: [SearchResult] = [],
             state: ProviderSearchState = .completed,
             delay: Duration? = nil) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.rows = rows
            self.state = state
            self.delay = delay
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            searchCount += 1
            owners.append(owner)
            if let delay { try? await Task.sleep(for: delay) }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, results: rows, state: state))
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            await search(text, queryID: queryID, owner: .ui, emit: emit)
        }

        func cancel(queryID: UUID) {}
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

    private func search(_ executor: LocateExecutor,
                        _ snapshot: AuthorizedSourceSnapshot,
                        query: String = "报告",
                        limit: Int = 10) async -> LocateExecutor.Run {
        await executor.runSearch(query: query,
                                 application: LimitApplication(applied: limit, wasClamped: false),
                                 snapshot: snapshot,
                                 owner: .mcp(sessionID: "search"))
    }

    private func payload(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw Failure()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func payload(_ run: LocateExecutor.Run) throws -> [String: Any] {
        try payload(run.outcome)
    }

    private func hits(_ body: [String: Any]) -> [[String: Any]] {
        (body["results"] as? [[String: Any]]) ?? []
    }

    private func names(_ body: [String: Any]) -> [String] {
        hits(body).compactMap { $0["name"] as? String }
    }

    private struct Failure: Error {}

    // MARK: - 五个字段，没有 score

    /// 单条结果**只有五个字段**：没有 `score`，也没有 `reasons`。
    ///
    /// ★ 这不是漏了：`search` 的产品语义里没有 composite 分。给它一个分，
    /// Agent 会拿它去和 `locate` 的 `score` 比大小，而两者不是同一把尺子。
    func testEachHitHasExactlyFiveFields() async throws {
        let provider = ScriptedProvider(id: work, rows: [row("归档/报告.pdf")])
        let body = try payload(await search(LocateExecutor(timing: timing()), snapshot([provider])))

        let hit = try XCTUnwrap(hits(body).first)
        XCTAssertEqual(Set(hit.keys),
                       ["file_id", "name", "relative_path", "source_id", "kind"],
                       "search 的字段集合变了：\(hit.keys.sorted())")
        XCTAssertEqual(body["limit_applied"] as? Int, 10)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(body["warnings"] as? [String], [])
    }

    /// `file_id` 必须与 `locate` 算出来的**同一个**（同一份 `FileID` 实现）。
    func testTheFileIDAgreesWithLocate() async throws {
        let rows = [row("归档/报告.pdf")]
        let provider = ScriptedProvider(id: work, rows: rows)
        let executor = LocateExecutor(timing: timing())
        let snap = snapshot([provider])

        let searchBody = try payload(await search(executor, snap))
        let locate = await executor.run(query: "报告",
                                        kind: nil,
                                        modifiedAfter: nil,
                                        application: LimitApplication(applied: 5, wasClamped: false),
                                        snapshot: snap,
                                        owner: .mcp(sessionID: "locate"))
        let locateBody = try payload(locate.outcome)

        XCTAssertEqual(hits(searchBody).first?["file_id"] as? String,
                       (locateBody["results"] as? [[String: Any]])?.first?["file_id"] as? String)
        XCTAssertEqual(hits(searchBody).first?["relative_path"] as? String, "归档/报告.pdf")
    }

    // MARK: - 排序：只按 lexical

    /// 整名 → 前缀 → 文件名全词 → 仅路径命中。
    ///
    /// 四个样本刻意选成四档（`SearchResultRanker` 的 0…3）：
    /// 名字与查询逐字相同、名字以查询开头、名字含查询词但不在开头、
    /// 名字里没有但路径里有。
    func testHitsAreOrderedByLexicalRankThenPath() async throws {
        let provider = ScriptedProvider(id: work, rows: [
            row("报告归档/年报.pdf"),        // 名字不含「报告」，路径含 → 仅路径命中
            row("归档/季度报告清单.pdf"),     // 名字含「报告」但不在开头
            row("归档/报告-2026.pdf"),        // 名字以「报告」开头
            row("报告", kind: "directory"),   // 名字与查询逐字相同
        ])
        let body = try payload(await search(LocateExecutor(timing: timing()), snapshot([provider])))

        XCTAssertEqual(names(body), ["报告", "报告-2026.pdf", "季度报告清单.pdf", "年报.pdf"])
    }

    /// **同一批输入、两个 Tool、两种顺序**：`search` 不把「刚改过的」提前。
    ///
    /// ```text
    /// 两个文件的 lexical 档位相同（都是「文件名前缀」），差别只有修改时间：
    ///   报告A-旧.pdf  2015 年改过
    ///   报告B-新.pdf  刚刚改过
    ///
    /// search → A 在前（同档按路径升序，完全不看时间）
    /// locate → B 在前（recently-modified 加 0.15）
    /// ```
    ///
    /// ★ 这条是「共用 lexical、不共用最终 composite」的**唯一直接证据**：
    /// 如果有人让 `search` 复用 `LocateRanker`，两个顺序会变成一样，它就红了。
    func testTheTwoToolsOrderTheSameInputDifferently() async throws {
        let old = row("归档/报告A-旧.pdf",
                      modified: Date(timeIntervalSince1970: 1_420_000_000))   // 2015
        let fresh = row("归档/报告B-新.pdf", modified: now)
        let executor = LocateExecutor(timing: timing())
        let snap = snapshot([ScriptedProvider(id: work, rows: [old, fresh])])

        let searchNames = names(try payload(await search(executor, snap)))
        XCTAssertEqual(searchNames, ["报告A-旧.pdf", "报告B-新.pdf"],
                       "search 必须是纯 lexical 顺序（同档按路径），不看修改时间")

        let locateRun = await executor.run(query: "报告",
                                           kind: nil,
                                           modifiedAfter: nil,
                                           application: LimitApplication(applied: 5, wasClamped: false),
                                           snapshot: snap,
                                           owner: .mcp(sessionID: "locate"))
        let locateNames = (try payload(locateRun.outcome)["results"] as? [[String: Any]])?
            .compactMap { $0["name"] as? String }
        XCTAssertEqual(locateNames, ["报告B-新.pdf", "报告A-旧.pdf"],
                       "locate 应当把刚改过的提前；两个 Tool 的顺序不该一样")
    }

    // MARK: - 截断：与 locate 同一条边界

    /// 11 条候选 / limit 10 → `truncated: true`，只回 10 条（必须真的看到第 11 条）。
    func testOneMoreCandidateThanTheLimitIsTruncated() async throws {
        let rows = (1...11).map { row("归档/报告-\($0).pdf") }
        let provider = ScriptedProvider(id: work, rows: rows)
        let run = await search(LocateExecutor(timing: timing()), snapshot([provider]), limit: 10)
        let body = try payload(run.outcome)

        XCTAssertEqual(hits(body).count, 10)
        XCTAssertEqual(body["truncated"] as? Bool, true)
        XCTAssertEqual(run.report.candidates, 11, "执行层提前砍了候选：truncated 永远算不出来")
    }

    /// 正好 10 条 / limit 10 → `false`（用满上限不是「还有更多」）。
    func testExactlyTheLimitIsNotTruncated() async throws {
        let rows = (1...10).map { row("归档/报告-\($0).pdf") }
        let provider = ScriptedProvider(id: work, rows: rows)
        let body = try payload(await search(LocateExecutor(timing: timing()),
                                            snapshot([provider]), limit: 10))
        XCTAssertEqual(body["truncated"] as? Bool, false)
    }

    // MARK: - 去重 / 空结果 / 目录

    /// 同一个 `file_id` 两条只留一条（DSM 实测会重复给同一路径）。
    func testDuplicateFileIDsCollapseIntoOneHit() async throws {
        let provider = ScriptedProvider(id: work,
                                        rows: [row("归档/报告.pdf"), row("归档/报告.pdf")])
        let run = await search(LocateExecutor(timing: timing()), snapshot([provider]))

        XCTAssertEqual(names(try payload(run.outcome)), ["报告.pdf"])
        XCTAssertEqual(run.report.mergedDuplicates, 1)
    }

    /// 0 命中**是成功**：`results: []` 的语义是「搜过了，没有」。
    func testNoHitsIsSuccessNotFailure() async throws {
        let provider = ScriptedProvider(id: work, rows: [])
        let run = await search(LocateExecutor(timing: timing()), snapshot([provider]))
        let body = try payload(run.outcome)

        XCTAssertEqual(hits(body).count, 0)
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(body["warnings"] as? [String], [])
    }

    /// 目录照样返回（`search` 没有 `kind` 参数，不该偷偷把它过滤掉）。
    func testFoldersAreReturnedWithKindFolder() async throws {
        let provider = ScriptedProvider(id: work,
                                        rows: [row("归档/报告归档", kind: "directory")])
        let body = try payload(await search(LocateExecutor(timing: timing()), snapshot([provider])))

        XCTAssertEqual(hits(body).first?["kind"] as? String, "folder")
    }

    // MARK: - 部分失败

    /// 一个来源好、一个坏 → 结果 + `source_unavailable:<id>` warning。
    func testAPartiallyFailingSearchStillReturnsHits() async throws {
        let ok = ScriptedProvider(id: mac, rows: [row("Users/x/报告.pdf")])
        let dead = ScriptedProvider(id: work, state: .failed)
        let body = try payload(await search(LocateExecutor(timing: timing()), snapshot([ok, dead])))

        XCTAssertEqual(names(body), ["报告.pdf"])
        XCTAssertEqual(body["warnings"] as? [String], ["source_unavailable:\(work)"])
    }

    /// 全部来源失败 → 错误，不是空结果。
    func testEverySourceFailingReturnsAnError() async throws {
        let dead = ScriptedProvider(id: work, state: .failed)
        let run = await search(LocateExecutor(timing: timing()), snapshot([dead]))

        guard case .failure(let code, _) = run.outcome else {
            return XCTFail("全部来源失败时必须返回错误：\(run.outcome)")
        }
        XCTAssertEqual(code, LocateFailureCode.sourceUnavailable.rawValue)
    }

    /// 搜索用了调用方给的 owner（不是自己造的）。
    func testSearchUsesTheOwnerItWasGiven() async throws {
        let provider = ScriptedProvider(id: work, rows: [row("归档/报告.pdf")])
        let owner = SearchOwner.mcp(sessionID: "wire-7")

        _ = await LocateExecutor(timing: timing())
            .runSearch(query: "报告",
                       application: LimitApplication(applied: 10, wasClamped: false),
                       snapshot: snapshot([provider]),
                       owner: owner)

        XCTAssertEqual(provider.owners, [owner])
    }
}
