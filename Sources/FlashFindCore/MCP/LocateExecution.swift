import Foundation

/// 来源失败码使用固定闭集，供排序与警告输出共用。
public enum LocateFailureCode: String, Equatable, Sendable, CaseIterable {

    /// 凭据失效（设备那边的登录态过期 / 需要重新认证）。
    case authRequired = "auth_required"
    /// 请求点名的来源没被授权（只在聚合阶段由 `scope.warnings` 参与）。
    case sourceDenied = "source_denied"
    /// 请求本身对**这个来源**不成立（例如设备不接受这个搜索词）。
    case invalidArgument = "invalid_argument"
    /// 来源没在预算内给出结果。
    case timeout = "timeout"
    /// 来源此刻不可用（掉线 / 没连 / provider 不存在）。
    case sourceUnavailable = "source_unavailable"
    /// 其它（含「搜索被取消」）。
    case internalError = "internal_error"

    /// 超时与不可用分别排序，避免误导用户排查正常设备。
    public var priority: Int {
        switch self {
        case .authRequired:      return 0
        case .sourceDenied:      return 1
        case .timeout:           return 2
        case .sourceUnavailable: return 3
        case .invalidArgument:   return 4
        case .internalError:     return 5
        }
    }

    /// 对外文案。**英文、固定、不含来源 id 或名字**（§4.3.1：名字本身就是信息）。
    public var message: String {
        switch self {
        case .authRequired:
            return "A source needs to be signed in again in FlashFind before it can be searched. "
                 + "Ask the user to reconnect it, then try again."
        case .sourceDenied:
            return "None of the requested sources is available for AI access."
        case .invalidArgument:
            return "No authorized source accepted this query. Try a different query."
        case .timeout:
            return "The search did not finish in time. Try again, or narrow the query."
        case .sourceUnavailable:
            return "The requested source is not reachable right now. "
                 + "Ask the user to check it, or try a different source."
        case .internalError:
            return "FlashFind could not complete this search."
        }
    }
}

/// 各搜索工具共用的已过滤、已规范化候选，避免路径规则分叉。
struct Candidate: Equatable {
    let fileID: FileID
    let name: String
    let relativePath: String
    let sourceID: String
    let kind: FileKind
    let modified: Date?
}

/// 整次请求共用单调时钟预算，避免子查询各自重复领取时限。
public struct Deadline: Sendable {

    private let start: DispatchTime
    public let budget: TimeInterval

    public init(budget: TimeInterval, start: DispatchTime = .now()) {
        self.budget = budget
        self.start = start
    }

    /// 还剩多少秒（已到期返回 0）。
    public func remaining() -> TimeInterval {
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds) / 1_000_000_000
        return max(0, budget - elapsed)
    }
}

/// 只消费授权快照；全部候选先过滤、去重和排序，再统一截取窗口。
/// 超时保留已收结果并取消未完成搜索，locate_many 共用一个截止时间。
@MainActor
public final class LocateExecutor {

    /// 执行预算与时钟。**时钟必须可注入**：`recently-modified` 要按「现在」算，
    /// 读系统时钟的用例无法确定性复现（§7.3）。
    public struct Timing: Sendable {

        /// 本次请求最多等多久。
        public var budget: TimeInterval
        public var now: @Sendable () -> Date

        public init(budget: TimeInterval = LocateExecutor.defaultBudget,
                    now: @escaping @Sendable () -> Date = { Date() }) {
            self.budget = budget
            self.now = now
        }
    }

    /// 请求共用 8 秒，留 2 秒给编码和传输。
    nonisolated public static let defaultBudget: TimeInterval = 8

    private let timing: Timing
    /// `file_id` 的反查表。**收到结果的同一刻**把要发出去的引用登记进去（§4.11.4）。
    ///
    /// ★ 它是 `nil` 时（纯搜索用例）不登记；产品装配必定带着一张。
    private let referenceStore: FileReferenceStore?

    public init(timing: Timing = Timing(), referenceStore: FileReferenceStore? = nil) {
        self.timing = timing
        self.referenceStore = referenceStore
    }

    /// 执行过程的诊断（不进返回体）。测试用它区分「被丢弃」与「被截断」。
    public struct Report: Equatable, Sendable {

        /// 真的被提交给调度器的来源数（不含「没有 provider」的）。
        public var executedSources = 0
        /// 提交的子查询数（`locate` / `search` 恒为 1，`locate_many` 为 `queries.count`）。
        public var queries = 0
        /// 进入排序的合格候选数（= 开窗之前的总数；`locate_many` 为各组合计）。
        public var candidates = 0
        public var returned = 0
        /// 任一窗口发生了截断（`locate_many` 里只要有一组截断就是 true）。
        public var truncated = false
        /// 路径规范化不了（`..` 越界 / 空路径）→ 丢弃。**不重排、不钳根**。
        public var droppedUnsafePath = 0
        /// `kind` 不匹配。
        public var droppedKind = 0
        /// 不满足 `modified_after`（含「没有修改时间，无法证明满足」）。
        public var droppedDate = 0
        /// 同一来源给了同一个 `file_id` 两次，只留更好的一条。
        public var mergedDuplicates = 0
        /// 来源自己说结果可能不全（`.truncated` / `resultsIncomplete`）。
        public var incompleteSources: [String] = []
        /// 失败来源，`"<code>:<id>"`，按 `snapshot.ids` 顺序。
        public var failures: [String] = []
    }

    public struct Run: Sendable {
        public let outcome: ToolOutcome
        public let report: Report
    }

    // MARK: - 入口：locate

    public func run(query: String,
                    kind: FileKind?,
                    modifiedAfter: Date?,
                    application: LimitApplication,
                    snapshot: AuthorizedSourceSnapshot,
                    owner: SearchOwner,
                    history: HistorySink? = nil) async -> Run {

        var report = Report()
        let deadline = Deadline(budget: timing.budget)

        let (pending, missing) = pendingSources(snapshot, report: &report)
        var timedOutAny = false
        let outcomes = await submitAndWait([query],
                                           pending: pending,
                                           snapshot: snapshot,
                                           owner: owner,
                                           deadline: deadline,
                                           report: &report,
                                           timedOutAny: &timedOutAny)

        let now = timing.now()
        var failureByID = missing
        var sawUsableSource = false
        var collected: [(sourceID: String, results: [LocateResult])] = []

        for entry in outcomes[0].sources {
            if let code = Self.failureCode(for: entry.snapshot) {
                failureByID[entry.id] = code
            } else {
                sawUsableSource = true
            }
            if entry.snapshot.resultsIncomplete || entry.snapshot.state == .truncated {
                report.incompleteSources.append(entry.id)
            }
            let results = locateResults(from: candidates(rows: entry.snapshot.rows,
                                                        sourceID: entry.id,
                                                        kind: kind,
                                                        modifiedAfter: modifiedAfter,
                                                        report: &report),
                                        query: query,
                                        now: now,
                                        report: &report)
            if !results.isEmpty {
                // 来源报了失败却给出了可用结果时，结果照留：文件是真的。
                // 「可能有更多」这件事由 warning 说，不塞进 truncated（§4.4.1）。
                sawUsableSource = true
            }
            collected.append((entry.id, results))
        }

        let warnings = mergedWarnings(snapshot, failureByID: failureByID)
        report.failures = warnings.filter { !$0.hasPrefix("source_denied:") }

        guard sawUsableSource else {
            let code = Self.worstCode(failureByID: failureByID, scopeWarnings: snapshot.warnings)
            return Run(outcome: .failure(code: code.rawValue, message: code.message), report: report)
        }

        let ordered = Self.ordered(collected.flatMap(\.results), report: &report)
        report.candidates = ordered.count
        let response = LocateResponse(selecting: ordered,
                                      application: application,
                                      warnings: warnings)
        report.returned = response.results.count
        report.truncated = response.truncated

        // ★ 落盘**先于**成功响应：写不进去就不许把这一批 id 发出去。
        if let failure = registerSelected(response.results.map(\.reference)) {
            return Run(outcome: failure, report: report)
        }
        // ★ 只有**窗口内**那几条才算「被看到过」：被 limit 截掉的候选不记。
        if let history {
            history.located(Self.locatedEvents(response.results, context: history.context, at: now))
        }

        guard let json = try? response.json() else {
            return Run(outcome: .failure(code: LocateFailureCode.internalError.rawValue,
                                         message: LocateFailureCode.internalError.message),
                       report: report)
        }
        return Run(outcome: .success(json: json), report: report)
    }

    // MARK: - 入口：search（宽口径，无 composite 分）

    /// `search`：**同一套收集与过滤**，但排序只按 `SearchResultRanker` 的 lexical 档位。
    ///
    /// ★ 它**不做**历史加权、也不做修改时间加权（§4.3 / §15 #29）：那是 `locate`
    /// 的产品语义。这里如果「顺手复用」`LocateRanker`，`search` 就会变成一个
    /// 宽口径的 `locate`——两个 Tool 的差别只剩条数上限，而 description 里
    /// 写着的是「宽口径、多结果」。
    public func runSearch(query: String,
                          application: LimitApplication,
                          snapshot: AuthorizedSourceSnapshot,
                          owner: SearchOwner,
                          history: HistorySink? = nil) async -> Run {

        var report = Report()
        let deadline = Deadline(budget: timing.budget)

        let (pending, missing) = pendingSources(snapshot, report: &report)
        var timedOutAny = false
        let outcomes = await submitAndWait([query],
                                           pending: pending,
                                           snapshot: snapshot,
                                           owner: owner,
                                           deadline: deadline,
                                           report: &report,
                                           timedOutAny: &timedOutAny)

        let now = timing.now()
        var failureByID = missing
        var sawUsableSource = false
        var hits: [SearchHit] = []

        for entry in outcomes[0].sources {
            if let code = Self.failureCode(for: entry.snapshot) {
                failureByID[entry.id] = code
            } else {
                sawUsableSource = true
            }
            if entry.snapshot.resultsIncomplete || entry.snapshot.state == .truncated {
                report.incompleteSources.append(entry.id)
            }
            // ★ `search` 没有 `kind` / `modified_after` 参数（§4.3 的 schema），
            //   过滤条件一律 `nil`——不是忘了传。
            let rows = candidates(rows: entry.snapshot.rows,
                                  sourceID: entry.id,
                                  kind: nil,
                                  modifiedAfter: nil,
                                  report: &report)
            let hitsForSource = searchHits(from: rows, report: &report)
            if !hitsForSource.isEmpty { sawUsableSource = true }
            hits.append(contentsOf: hitsForSource)
        }

        let warnings = mergedWarnings(snapshot, failureByID: failureByID)
        report.failures = warnings.filter { !$0.hasPrefix("source_denied:") }

        guard sawUsableSource else {
            let code = Self.worstCode(failureByID: failureByID, scopeWarnings: snapshot.warnings)
            return Run(outcome: .failure(code: code.rawValue, message: code.message), report: report)
        }

        let ordered = Self.orderedHits(hits, query: query, report: &report)
        report.candidates = ordered.count
        let response = SearchResponse(selecting: ordered,
                                      application: application,
                                      warnings: warnings)
        report.returned = response.results.count
        report.truncated = response.truncated

        // ★ 与 `locate` 同一条纪律：写不进去就不许把这一批 id 发出去。
        if let failure = registerSelected(response.results.map(\.reference)) {
            return Run(outcome: failure, report: report)
        }
        // ★ 与 `locate` 同一条纪律：只有窗口内那几条算「被看到过」。
        if let history {
            history.located(Self.locatedEvents(response.results, context: history.context, at: now))
        }

        guard let json = try? response.json() else {
            return Run(outcome: .failure(code: LocateFailureCode.internalError.rawValue,
                                         message: LocateFailureCode.internalError.message),
                       report: report)
        }
        return Run(outcome: .success(json: json), report: report)
    }

    // MARK: - 入口：locate_many（N 条子查询，一张预算券）

    /// `locate_many`：把 1…5 条 `queries` 各自当成一次 `locate`，**共用一张预算券**。
    ///
    /// ## 四个冻结点（v0.27 决策，都有具名用例）
    ///
    /// 1. **一个 owner**：N 条子查询都挂在同一个 wire 请求算出来的 `SearchOwner` 上
    ///    （§4.7）。owner 一旦按 query 各自生成，`locate_many` 就退化成 5 个互不
    ///    相干的请求，用户按 Esc 也取消不掉。
    /// 2. **`supersedePrevious: false`**：同 owner + 取代会让第 5 条把前 4 条取消
    ///    （v0.6 实测过「5 条只剩 1 条」）。这里**显式传 false**，不依赖 nil 推断。
    /// 3. **一个 deadline**：全部子查询共用一个 `Deadline`，不是每条各领一份
    ///    `budget`——否则最坏 5 × budget，直接突破对外的 10 s 契约。
    /// 4. **顺序 = 输入顺序**：分组按 `queries` 排，不按谁先搜完。
    ///
    /// ★ 同一来源仍然串行（`SearchScheduler` 每个来源一条队列），不同来源并行——
    /// 这是现有调度模型本来就保证的，本类不为 `locate_many` 另开一条并发路。
    public func runMany(queries: [String],
                        application: LimitApplication,
                        snapshot: AuthorizedSourceSnapshot,
                        owner: SearchOwner,
                        history: HistorySink? = nil) async -> Run {

        var report = Report()
        let deadline = Deadline(budget: timing.budget)

        let (pending, missing) = pendingSources(snapshot, report: &report)
        var timedOutAny = false
        let outcomes = await submitAndWait(queries,
                                           pending: pending,
                                           snapshot: snapshot,
                                           owner: owner,
                                           deadline: deadline,
                                           report: &report,
                                           timedOutAny: &timedOutAny)

        let now = timing.now()
        // 失败按**来源**聚合，取最严重的那一条：五条子查询各自报一次
        // `source_unavailable:src` 只是噪声，Agent 需要知道的是「这个来源这次不行」。
        var failureByID = missing
        var sawUsableSource = false
        var groups: [LocateManyGroup] = []

        for outcome in outcomes {
            var collected: [(sourceID: String, results: [LocateResult])] = []
            for entry in outcome.sources {
                if let code = Self.failureCode(for: entry.snapshot) {
                    failureByID[entry.id] = Self.worse(failureByID[entry.id], code)
                } else {
                    sawUsableSource = true
                }
                if entry.snapshot.resultsIncomplete || entry.snapshot.state == .truncated,
                   !report.incompleteSources.contains(entry.id) {
                    report.incompleteSources.append(entry.id)
                }
                let results = locateResults(from: candidates(rows: entry.snapshot.rows,
                                                            sourceID: entry.id,
                                                            kind: nil,
                                                            modifiedAfter: nil,
                                                            report: &report),
                                            query: outcome.text,
                                            now: now,
                                            report: &report)
                if !results.isEmpty { sawUsableSource = true }
                collected.append((entry.id, results))
            }

            let ordered = Self.ordered(collected.flatMap(\.results), report: &report)
            report.candidates += ordered.count
            // ★ 每组的窗口走同一个 `LocateResponse(selecting:)`：`truncated` 只有一处赋值。
            let response = LocateResponse(selecting: ordered, application: application, warnings: [])
            report.returned += response.results.count
            if response.truncated { report.truncated = true }
            groups.append(LocateManyGroup(query: outcome.text, response: response))
        }

        let warnings = mergedWarnings(snapshot, failureByID: failureByID)
        report.failures = warnings.filter { !$0.hasPrefix("source_denied:") }

        guard sawUsableSource else {
            let code = Self.worstCode(failureByID: failureByID, scopeWarnings: snapshot.warnings)
            return Run(outcome: .failure(code: code.rawValue, message: code.message), report: report)
        }

        // ★ 所有分组**合成一笔事务**：一条写失败就得整次 `locate_many` 失败。
        // 分批提交会得到「前三组的 id 能查、后两组的不能」，而 Agent 拿到的是
        // 一个看起来完整的响应。
        // ★ 所有分组合成一批：一组写失败就整次调用丢这一批事件（历史可丢，但
        //   不许「有的分组记了、有的没记」——那会让 `recent` 的顺序不可解释）。
        if let failure = registerSelected(groups.flatMap { $0.response.results.map(\.reference) }) {
            return Run(outcome: failure, report: report)
        }
        if let history {
            history.located(groups.flatMap {
                Self.locatedEvents($0.response.results, context: history.context, at: now)
            })
        }

        let response = LocateManyResponse(groups: groups,
                                          application: application,
                                          warnings: warnings)
        guard let json = try? response.json() else {
            return Run(outcome: .failure(code: LocateFailureCode.internalError.rawValue,
                                         message: LocateFailureCode.internalError.message),
                       report: report)
        }
        return Run(outcome: .success(json: json), report: report)
    }

    // MARK: - 提交 / 等待

    /// 一次子查询的收集器：**每个（子查询 × 来源）一个**。
    private struct QueryRun {
        let text: String
        let queryID: UUID
        /// 按 `snapshot.ids` 顺序（诊断与聚合都靠这个顺序）。
        var collectors: [(id: String, collector: SourceCollector)]
    }

    /// 一条子查询在一个来源上的结果。
    private struct SourceOutcome {
        let id: String
        let snapshot: SourceCollector.Snapshot
    }

    private struct QueryOutcome {
        let text: String
        let sources: [SourceOutcome]
    }

    /// 拆成「能跑的」与「没有 provider 的」。
    ///
    /// ★ 后者仍然在 `ids` 里（它确实被授权了），所以它必须出现在结果里——
    /// 以 `source_unavailable:<id>` 的形式，而不是悄悄消失。
    private func pendingSources(_ snapshot: AuthorizedSourceSnapshot,
                                report: inout Report) -> ([(id: String, handle: SourceExecutionHandle)],
                                                          [String: LocateFailureCode]) {
        var pending: [(id: String, handle: SourceExecutionHandle)] = []
        var missing: [String: LocateFailureCode] = [:]
        for id in snapshot.ids {
            guard let handle = snapshot.execution(for: id) else {
                missing[id] = .sourceUnavailable
                continue
            }
            pending.append((id, handle))
        }
        report.executedSources = pending.count
        return (pending, missing)
    }

    /// 提交 N 条子查询，然后一起等，**全部受同一张 deadline 约束**。
    ///
    /// 提交必须**先全部发出去**再开始等：`SearchScheduler` 每个来源一条队列，
    /// 先发 A 再发 B，来源上就是 A → B 串行、来源之间并行。如果「等完 A 再发 B」，
    /// 5 条子查询就变成纯串行，预算还没用完就先超时了。
    private func submitAndWait(_ queries: [String],
                               pending: [(id: String, handle: SourceExecutionHandle)],
                               snapshot: AuthorizedSourceSnapshot,
                               owner: SearchOwner,
                               deadline: Deadline,
                               report: inout Report,
                               timedOutAny: inout Bool) async -> [QueryOutcome] {

        var runs: [QueryRun] = []
        for text in queries {
            // ★ 一次 wire 请求 = 一个 owner；子查询之间用 queryID 区分，
            //   不用新 owner——否则「取消这次 locate_many」就无处可取消。
            let queryID = UUID()
            var collectors: [(id: String, collector: SourceCollector)] = []
            for item in pending {
                let collector = SourceCollector()
                collectors.append((item.id, collector))
                item.handle.scheduler.submit(text: text,
                                             queryID: queryID,
                                             owner: owner,
                                             provider: item.handle.provider,
                                             supersedePrevious: false) { event in
                    collector.record(event)
                }
            }
            runs.append(QueryRun(text: text, queryID: queryID, collectors: collectors))
        }
        report.queries = runs.count

        // 全部 wait 任务先建起来（它们同时跑），每条拿的是「此刻还剩多少」。
        var waits: [(queryID: UUID, id: String, task: Task<SourceCollector.Snapshot, Never>)] = []
        for run in runs {
            for entry in run.collectors {
                let remaining = deadline.remaining()
                let collector = entry.collector
                waits.append((run.queryID, entry.id,
                              Task { await collector.wait(budget: remaining) }))
            }
        }
        // ★ 键必须是 `queryID`，不能是查询文本：`locate_many` 允许两条子查询是**同一个词**
        //   （用户把「报告」说了两遍），按文本归并会让 5 条子查询的结果互相串到一起。
        var byQueryID: [UUID: [SourceOutcome]] = [:]
        for wait in waits {
            let snapshot = await wait.task.value
            if snapshot.timedOut { timedOutAny = true }
            byQueryID[wait.queryID, default: []].append(SourceOutcome(id: wait.id, snapshot: snapshot))
        }

        // 超预算的来源必须停掉：否则它会在设备上继续跑，占用那一台唯一的槽位，
        // 让用户接下来的搜索排在一个没人要的查询后面。
        if timedOutAny {
            for run in runs {
                for item in pending {
                    item.handle.scheduler.cancel(queryID: run.queryID, requester: owner)
                }
            }
        }

        // 按 `snapshot.ids` 的顺序还原每个来源，与单查询版本的顺序保持一致
        // （`warnings` 的排列顺序与诊断都依赖它）。
        let order = Dictionary(uniqueKeysWithValues: snapshot.ids.enumerated().map { ($1, $0) })
        return runs.map { run in
            let sources = (byQueryID[run.queryID] ?? []).sorted {
                (order[$0.id] ?? .max) < (order[$1.id] ?? .max)
            }
            return QueryOutcome(text: run.text, sources: sources)
        }
    }

    // MARK: - 一条 provider 事件 → 候选 → 结果

    /// 过滤 + 映射 + 算 `file_id`。**这里不做条数裁剪**（见类型注释）。
    private func candidates(rows: [SearchResult],
                            sourceID: String,
                            kind: FileKind?,
                            modifiedAfter: Date?,
                            report: inout Report) -> [Candidate] {

        var candidates: [Candidate] = []
        for row in rows {
            let fileKind: FileKind = row.kind == "directory" ? .folder : .file
            if let kind, kind != fileKind {
                report.droppedKind += 1
                continue
            }
            if let modifiedAfter {
                // 没有修改时间就**无法证明**它满足过滤条件。放进来等于对 Agent 说谎；
                // 这个取舍写在 `Report.droppedDate` 的注释里，一起计数。
                guard let modified = row.modifiedDate, modified > modifiedAfter else {
                    report.droppedDate += 1
                    continue
                }
            }

            // ★ 路径规范化在**映射层**：`FileID` 本身拒绝非规范路径（§4.6.3）。
            // 拒绝就是丢弃——不修、不钳根（钳根会让根外文件与根内文件撞同一个 id）。
            guard let path = try? RelativePath.canonical(row.relativePath) else {
                report.droppedUnsafePath += 1
                continue
            }
            guard let fileID = try? FileID.make(sourceID: sourceID, canonicalRelativePath: path) else {
                report.droppedUnsafePath += 1
                continue
            }

            candidates.append(Candidate(fileID: fileID,
                                        name: row.name,
                                        relativePath: path,
                                        sourceID: sourceID,
                                        kind: fileKind,
                                        modified: row.modifiedDate))
        }
        return candidates
    }

    /// 候选 → `locate` 的七字段结果（打分在这里，**排序不在这里**）。
    private func locateResults(from candidates: [Candidate],
                               query: String,
                               now: Date,
                               report: inout Report) -> [LocateResult] {
        candidates.compactMap { candidate in
            let scored = LocateRanker.score(name: candidate.name,
                                            path: candidate.relativePath,
                                            modified: candidate.modified,
                                            query: query,
                                            now: now)
            do {
                return try LocateResult(fileID: candidate.fileID,
                                        name: candidate.name,
                                        relativePath: candidate.relativePath,
                                        sourceID: candidate.sourceID,
                                        kind: candidate.kind,
                                        score: scored.score,
                                        reasons: scored.reasons)
            } catch {
                // `score` 由纯函数产出并已 clamp；走到这里说明不变量坏了。
                report.droppedUnsafePath += 1
                return nil
            }
        }
    }

    /// 候选 → `search` 的五字段结果。**不打分**：`search` 没有 composite 分（§4.4.2）。
    private func searchHits(from candidates: [Candidate], report: inout Report) -> [SearchHit] {
        candidates.compactMap { candidate in
            do {
                return try SearchHit(fileID: candidate.fileID,
                                     name: candidate.name,
                                     relativePath: candidate.relativePath,
                                     sourceID: candidate.sourceID,
                                     kind: candidate.kind)
            } catch {
                report.droppedUnsafePath += 1
                return nil
            }
        }
    }

    // MARK: - 去重与排序

    /// 先按 `file_id` 去重，再排序（`locate` / `locate_many`）。
    ///
    /// * **去重键是 `file_id`**：身份层说过「同一个来源 + 同一条路径 = 同一个文件」，
    ///   两条同 id 的结果就是同一个文件（DSM 的 `Search.list` 实测会重复给同一路径）。
    /// * 保留规则是「分高者胜；同分取 (path, source_id) 更小者」——**与到达顺序无关**，
    ///   否则同一份输入两次跑出不同结果（§7.3）。
    /// * 排序：`score` 降序 → `relative_path` 升序 → `source_id` 升序。
    ///   三级键缺一不可：只比分数与路径时，两个来源里的同名路径仍然是平局。
    static func ordered(_ results: [LocateResult], report: inout Report) -> [LocateResult] {
        var best: [String: LocateResult] = [:]
        var duplicates = 0
        for result in results {
            let key = result.fileID.value
            guard let existing = best[key] else {
                best[key] = result
                continue
            }
            duplicates += 1
            if isBetter(result, than: existing) { best[key] = result }
        }
        report.mergedDuplicates += duplicates

        return best.values.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }
            return lhs.sourceID < rhs.sourceID
        }
    }

    private static func isBetter(_ candidate: LocateResult, than current: LocateResult) -> Bool {
        if candidate.score != current.score { return candidate.score > current.score }
        if candidate.relativePath != current.relativePath {
            return candidate.relativePath < current.relativePath
        }
        return candidate.sourceID < current.sourceID
    }

    /// 先按 `file_id` 去重，再按 **lexical 档位**排序（`search`）。
    ///
    /// ★ 档位来自 `SearchResultRanker.rank`——与 GUI 搜索、`locate` 的 `name-match`
    /// **同一个**实现（§15 #29）。这里绝不自己写一套 `contains` / `hasPrefix`：
    /// 那就是第二份 lexical 语义，两边一定会漂，「同一条 query 在 search 里排在
    /// 第 3、在 locate 里排第 1」这种问题没人查得出来。
    static func orderedHits(_ hits: [SearchHit],
                            query: String,
                            report: inout Report) -> [SearchHit] {
        var best: [String: (hit: SearchHit, rank: Int)] = [:]
        var duplicates = 0
        for hit in hits {
            let rank = SearchResultRanker.rank(name: hit.name, path: hit.relativePath, query: query)
            let key = hit.fileID.value
            guard let existing = best[key] else {
                best[key] = (hit, rank)
                continue
            }
            duplicates += 1
            if rank < existing.rank
                || (rank == existing.rank && (hit.relativePath, hit.sourceID) < (existing.hit.relativePath, existing.hit.sourceID)) {
                best[key] = (hit, rank)
            }
        }
        report.mergedDuplicates += duplicates

        return best.values.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.hit.relativePath != rhs.hit.relativePath {
                return lhs.hit.relativePath < rhs.hit.relativePath
            }
            return lhs.hit.sourceID < rhs.hit.sourceID
        }.map(\.hit)
    }

    // MARK: - 状态 → 失败码

    /// 一个来源的终态要不要算失败。`nil` = 这次搜索拿到了可用结果。
    ///
    /// ```text
    /// completed / truncated / limitedTraversal → 成功（后两者「不全」，但不是失败）
    /// needsAuth                              → auth_required
    /// timedOut / deviceBusy                  → timeout
    /// failed / degraded / blocked            → 见各自的分支
    /// cancelled                              → internal_error
    /// ```
    ///
    /// ★ 这张表是**全量**的：新增一个 `ProviderSearchState` 时这里会编译不过
    /// （开关穷举），不会静默落到 `internal_error`。
    static func failureCode(for snapshot: SourceCollector.Snapshot) -> LocateFailureCode? {
        if snapshot.timedOut { return .timeout }
        switch snapshot.state {
        case .completed, .truncated, .limitedTraversal:
            return nil
        case .needsAuth:
            return .authRequired
        case .timedOut:
            return .timeout
        case .deviceBusy:
            // 设备没把结果算出来，重试是唯一动作。**不许**折成 source_unavailable：
            // 设备是好的，让用户去检查 NAS 等于把人引到错误的地方。
            return .timeout
        case .failed, .degraded:
            return .sourceUnavailable
        case .blocked:
            // 设备不接受这个搜索词（`NASQueryPolicy`）。这是**参数**问题，
            // 不是设备问题——同一个词在别的来源上可能完全正常。
            return .invalidArgument
        case .cancelled:
            return .internalError
        case .searching:
            // 非终态被当成终态（provider 违约或预算到期）。按内部错误处理。
            return .internalError
        }
    }

    /// 同一来源在多条子查询上失败时取**更严重**的那个（`priority` 小者更严重）。
    static func worse(_ lhs: LocateFailureCode?, _ rhs: LocateFailureCode) -> LocateFailureCode {
        guard let lhs else { return rhs }
        return lhs.priority <= rhs.priority ? lhs : rhs
    }

    /// 全部失败时的最终码。
    ///
    /// `source_denied` 不在 `failureByID` 里（它没被执行到），从 scope 的 warnings 补。
    static func worstCode(failureByID: [String: LocateFailureCode],
                          scopeWarnings: [String]) -> LocateFailureCode {
        var codes = Array(failureByID.values)
        if scopeWarnings.contains(where: { $0.hasPrefix("source_denied:") }) {
            codes.append(.sourceDenied)
        }
        guard let worst = codes.min(by: { $0.priority < $1.priority }) else {
            return .internalError
        }
        return worst
    }

    /// 把「这次真的要返回给 Agent」的那批引用记进映射表。
    ///
    /// ## 顺序（§4.11.4，Phase 6.4b-1 冻结）
    ///
    /// ```text
    /// 全部候选 → 过滤 / 去重 / 排序 → limit 窗口 → registerAll（一个事务）→ 才回成功
    /// ```
    ///
    /// ★ **只登记窗口内的**，不登记所有候选：被 `limit` 砍掉的那部分没有发给 Agent，
    /// 把它们也写进库只是让表变大，并且让「哪些 id 被 Agent 拿走过」这件事说不清。
    ///
    /// ★ 写失败 → 这次 Tool Call 整个 `internal_error`。
    /// 「先回结果、落盘失败就算了」会发出一个**不能兑现的引用**：
    ///
    /// ```text
    /// locate 返回 ff1_x  →  App 重启  →  get_metadata(ff1_x) → file_not_found
    /// ```
    ///
    /// 而 Agent 在收到的当下完全看不出那个 id 是坏的。
    ///
    /// ★ 与 History 相反：**History 写失败 → 搜索照样成功**（它是增强功能）；
    ///   这里写失败 → 当前请求失败，因为 `file_id` 契约本身就包含「能反查」。
    private func registerSelected(_ references: [FileReference]) -> ToolOutcome? {
        guard let store = referenceStore else { return nil }
        do {
            try store.registerAll(references)
            return nil
        } catch {
            return .failure(code: LocateFailureCode.internalError.rawValue,
                            message: LocateFailureCode.internalError.message)
        }
    }

    // MARK: - located 事件（Phase 7c）

    /// 窗口内的 `locate` / `locate_many` 结果 → `located` 事件。
    ///
    /// ★ `results` 必须是**开窗之后**的那批：被 `limit` 截掉的候选没有交给 Agent，
    ///   记它就是把「我们搜到过」说成「Agent 看到过」——那正是 §6.2.1 挡掉的那件事。
    ///
    /// ★ 会话与客户端标签来自 `context`（不可信），**只**写进 History，
    ///   不参与判定（§7a）。
    static func locatedEvents(_ results: [LocateResult],
                              context: HistoryContext,
                              at: Date) -> [AccessEvent] {
        results.map { result in
            AccessEvent(sessionID: context.sessionID,
                        agentID: context.agentID,
                        fileID: result.fileID,
                        sourceID: result.sourceID,
                        action: .located,
                        timestamp: at,
                        lastKnownRelativePath: result.relativePath)
        }
    }

    /// 窗口内的 `search` 结果 → `located` 事件。
    ///
    /// ★ 与上面那个重载是**两份代码**，不是一个 `if` 的两个分支：
    ///   三个 Tool 各自有一个写入点，合成一个函数后，删掉其中一处调用
    ///   不会让另外两处的用例变红（6.4b-1 在 `registerAll` 上踩过的正是这个）。
    static func locatedEvents(_ results: [SearchHit],
                              context: HistoryContext,
                              at: Date) -> [AccessEvent] {
        results.map { result in
            AccessEvent(sessionID: context.sessionID,
                        agentID: context.agentID,
                        fileID: result.fileID,
                        sourceID: result.sourceID,
                        action: .located,
                        timestamp: at,
                        lastKnownRelativePath: result.relativePath)
        }
    }

    /// 部分失败的说明：`snapshot.warnings` + 逐来源失败码，按 `snapshot.ids` 顺序。
    ///
    /// ★ 只描述**这次真的点名/被默认纳入**的来源。未授权来源的名字与 id
    /// 都不会出现在这里（§4.2.1）。
    private func mergedWarnings(_ snapshot: AuthorizedSourceSnapshot,
                                failureByID: [String: LocateFailureCode]) -> [String] {
        snapshot.warnings
            + snapshot.ids.compactMap { id in failureByID[id].map { "\($0.rawValue):\(id)" } }
    }
}

