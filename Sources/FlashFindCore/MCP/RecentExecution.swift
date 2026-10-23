import Foundation

/// `recent` 成功返回里的一条结果（方案 §4.13）。
///
/// ★ **没有 `score` / `reasons`**：`recent` 是「按最近被看到的时刻倒序」的列表，
///   不是排序评分。给列表里的每一项编一个分数，会让 Agent 以为这个分数和
///   `locate` 的分数同量纲，于是拿它跟搜索结果比大小——那两个数的含义完全不同。
/// ★ **没有 `kind` / `size_bytes` / `modified`**：History 里没有记这三项（§6.1 的列是
///   冻住的，且 §4.11 定了「完整元数据只有一个出口 —— `get_metadata`」）。
///   要它们就拿 `file_id` 去调 `get_metadata`，而不是让 `recent` 编一个。
public struct RecentHit: Equatable, Sendable {

    public let fileID: FileID
    public let sourceID: String
    public let name: String
    public let relativePath: String
    /// 最近一次被 Agent 看到的时刻。
    public let lastSeen: Date

    public init(fileID: FileID,
                sourceID: String,
                name: String,
                relativePath: String,
                lastSeen: Date) {
        self.fileID = fileID
        self.sourceID = sourceID
        self.name = name
        self.relativePath = relativePath
        self.lastSeen = lastSeen
    }

    var payload: AuthorityWire.Value {
        .object([AuthorityWire.ResponseKey.fileID: .string(fileID.value),
                 AuthorityWire.ResponseKey.sourceID: .string(sourceID),
                 AuthorityWire.ResponseKey.name: .string(name),
                 AuthorityWire.ResponseKey.relativePath: .string(relativePath),
                 AuthorityWire.ResponseKey.lastSeen:
                     .string(MetadataResponse.utcFormatter.string(from: lastSeen))])
    }
}

/// `recent` 的成功返回（方案 §4.13）。
///
/// ```json
/// { "results": [ … ], "truncated": false, "limit_applied": 5, "warnings": [] }
/// ```
///
/// ★ 与 `locate` / `search` 同一副外壳（`truncated` / `limit_applied` / `warnings`），
///   见 §4.1：所有列表类返回都带这三个字段。
public struct RecentResponse: Equatable, Sendable {

    public let results: [RecentHit]
    public let truncated: Bool
    public let limitApplied: Int
    public let warnings: [String]

    public init(selecting hits: [RecentHit],
                application: LimitApplication,
                warnings: [String]) {
        self.results = Array(hits.prefix(application.applied))
        self.truncated = hits.count > application.applied
        self.limitApplied = application.applied
        self.warnings = warnings
    }

    public func payload() -> AuthorityWire.Value {
        .object([AuthorityWire.ResponseKey.results: .array(results.map(\.payload)),
                 AuthorityWire.ResponseKey.truncated: .bool(truncated),
                 AuthorityWire.ResponseKey.limitApplied: .int(limitApplied),
                 AuthorityWire.ResponseKey.warnings: .array(warnings.map { .string($0) })])
    }

    public func json() throws -> String {
        try AuthorityWire.jsonString(payload())
    }
}

/// `recent` 的执行（Phase 7d）。
///
/// ## ★ 它每调一次都要重新判权（§7d）
///
/// ```text
/// History 中曾经有这个文件  ≠  现在还能把它返回给 Agent
/// ```
///
/// 顺序刻意是「**先判权，再查历史**」：
///
/// ```text
/// Router → PermissionPolicy → AuthorizationScope   ← 本类之前（每次请求现算）
///     ↓
/// 查 History（按时间倒序取候选）
///     ↓
/// 只保留 source_id ∈ 本次 scope            ← 撤销在这里生效
///     ↓
/// FileReferenceStore.resolve              ← 解析不了 = stale
///     ↓
/// 返回
/// ```
///
/// ★ 撤销来源后下一次 `recent` 必须立即消失；总开关关着则根本走不到这里
///   （Router 直接 `mcp_disabled`）。
///
/// ## ★ 单条 stale 不许毁掉整个列表
///
/// `recent` 是列表型 Tool。一条历史失效就让它**跳过**，并把原因放进
/// `warnings`；只有「一条都拿不出来且是系统级失败」时才整个 Tool error。
/// 否则一个 90 天没清理的坏行会让 Agent 以为「历史是空的」。
public enum RecentExecutor {

    /// 执行过程的诊断。测试用它区分「被跳过」与「被截断」。
    public struct Report: Equatable, Sendable {
        /// 扫描过的**不同文件**数（已按 `file_id` 收敛、已按来源筛过）。
        ///
        /// ★ build 29 起它不再是「取到的事件条数」：那正是 BUG-112-03 的形状 ——
        ///   一个文件刷 20 次，事件数很好看，不同文件只有 1 个。
        public var candidates = 0
        public var returned = 0
        public var truncated = false
        /// 被跳过的原因，`"stale_file_id:<id>"`。
        public var skipped: [String] = []
        /// History 库没装配（不是故障：不写历史时就不该有库）。
        public var historyUnavailable = false
    }

    public struct Run: Sendable {
        public let outcome: ToolOutcome
        public let report: Report
    }

    /// 一次 `recent`。
    ///
    /// - Parameters:
    ///   - withinDays: 只看最近这么多天内被看到过的；`nil` 不限。
    ///   - application: 最终返回几条（`LimitRange.recent`：默认 5 / 上限 20）。
    ///   - snapshot: 本次授权快照。**它已经是收紧过的**——`source_ids`
    ///     在 `PermissionPolicy` 里就与授权集合求过交（§5.2.2）。
    ///
    /// ## ★★ 筛来源只此一处（§5.2.2「判定点只有一处」）
    ///
    /// 曾经这里同时用 SQL 的 `source_id IN (…)` 和循环里的 `where allowed.contains(…)`
    /// 过滤**同一个**集合。那是两处口径：删掉任意一处，另一处仍然兜住，
    /// 于是「撤销来源后 recent 立即消失」这条规则**没有任何变异能证红**——
    /// 红证上它永远绿着，看起来像被守住了，其实只是被守了两遍。
    ///
    /// 现在收敛到一处：交给 SQL（`history.recent(sourceIDs: snapshot.ids)`），
    /// 循环里不再重复判断。选 SQL 而不是循环，是因为它能让开窗落在
    /// **已授权**的那批候选上——循环里再筛一次，遇到「最近 20 条全是已撤销来源」
    /// 就会返回空列表，而那不是事实。
    ///   - history: History 读取 + `lastSeen` 的来源。
    ///   - references: `file_id` 的反查表；解析不了就是 stale。
    public static func run(withinDays: Int?,
                           application: LimitApplication,
                           snapshot: AuthorizedSourceSnapshot,
                           history: HistoryStore?,
                           references: FileReferenceStore?,
                           now: Date = Date()) -> Run {

        var report = Report()

        // ① 权限：本函数被调到的那一刻，Router → PermissionPolicy 已经判过。
        //    这里**不**重新读设置、不重新读注册表，只用传进来的快照。
        //    （「每一次请求都判权」由 `handle` 每请求读一次闭包保证。）
        guard let history else {
            report.historyUnavailable = true
            // ★ 没有 History 库时返回**空列表**而不是报错，只在 warnings 里说明：
            //   这不是故障，是「这个功能没开」。报错会让 Agent 去让用户修一个没坏的东西。
            let response = RecentResponse(selecting: [], application: application,
                                          warnings: ["recent_unavailable"])
            guard let json = try? response.json() else {
                return Run(outcome: Self.failure, report: report)
            }
            return Run(outcome: .success(json: json), report: report)
        }

        // ② + ③ 取候选并折叠。
        //
        // ★★ 顺序是「**先按文件去重，再限量**」，不是「先限量、再去重」。
        //    `metadata` 事件按设计每次访问都记一条，所以一个文件被看 20 次就能
        //    占满预采样窗口，把「昨天看过的另一个文件」整个挤掉 —— 而返回里
        //    还写着 truncated=false，Agent 根本不知道少了东西。
        //
        // ★ 来源筛只在 SQL 一处（`snapshot.ids` 已经收紧过），循环里不再筛。
        var hits: [RecentHit] = []
        var seen = Set<String>()
        var offset = 0
        var scanned = 0
        // 多要一条：`RecentResponse` 靠 `hits.count > applied` 判 truncated。
        let target = application.applied + 1
        // 扫描上限：历史里全是 stale 时，不该把这次调用拖成整库遍历。
        let scanBudget = max(application.applied * 8, 64)

        while hits.count < target && scanned < scanBudget {
            // 一页至少 8 条：够填满 limit 还留余量，又不必为一条结果来回跑。
            let need = max(target - hits.count, 8)
            let events: [AccessEvent]
            do {
                events = try history.recentDistinct(limit: need,
                                                    sourceIDs: snapshot.ids,
                                                    withinDays: withinDays,
                                                    now: now,
                                                    offset: offset)
            } catch {
                // 历史库坏了：整次失败，因为「最近看过什么」本身就是这次请求要的答案。
                return Run(outcome: Self.failure, report: report)
            }
            // 取到空页 = 真的到底了，不是「这一页里没有」。
            if events.isEmpty { break }
            offset += events.count
            scanned += events.count
            report.candidates = scanned

            // 同一页里不会出现重复的 file_id（SQL 已按文件收敛），`seen` 只作跨页兜底。
            for event in events {
                guard seen.insert(event.fileID.value).inserted else { continue }

                // ④ 解析身份。解析不到 = 这条历史已经失效（stale）→ 跳过，不毁掉整个列表。
                let resolved = references.flatMap { try? $0.lookup(event.fileID) }
                guard let resolved, resolved.sourceID == event.sourceID else {
                    report.skipped.append("stale_file_id:\(event.fileID.value)")
                    continue
                }

                hits.append(RecentHit(fileID: event.fileID,
                                      sourceID: resolved.sourceID,
                                      name: (resolved.canonicalRelativePath as NSString).lastPathComponent,
                                      relativePath: resolved.canonicalRelativePath,
                                      lastSeen: event.timestamp))
                // 多一条就够判 truncated 了，不必把这一页剩下的都解析一遍。
                if hits.count >= target { break }
            }
        }

        let response = RecentResponse(selecting: hits,
                                      application: application,
                                      warnings: report.skipped)
        report.returned = response.results.count
        report.truncated = response.truncated
        guard let json = try? response.json() else {
            return Run(outcome: Self.failure, report: report)
        }
        return Run(outcome: .success(json: json), report: report)
    }

    private static var failure: ToolOutcome {
        .failure(code: "internal_error",
                 message: "FlashFind could not read its file history.")
    }
}
