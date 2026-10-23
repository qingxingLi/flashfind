import Foundation

/// `locate_many` 里**一条子查询**的结果（方案 §4.4.3，v0.27 冻结）。
///
/// ```json
/// { "query": "第一季度报告", "results": [ … ], "truncated": false }
/// ```
///
/// ## 为什么把 `LocateResponse` 整个装进来
///
/// 每组的窗口与 `truncated` 由**同一个** `LocateResponse(selecting:)` 算出来。
/// 如果这里另写一次 `prefix(limit)` + `count > limit`，`truncated` 就有了第二处
/// 赋值——而 §4.4.1 明确要求它在代码里只有一处（那是 6.3b-0/6.3b-1 两次复审
/// 才锁死的东西，两处一旦不一致，Agent 看到的就是「说还有更多，可怎么加参数都没有」）。
///
/// ## 为什么要回显 `query`
///
/// 分组顺序**永远是输入 `queries[]` 的顺序**（§4.4.3），所以回显不是用来对位的，
/// 而是让 Agent 在拼装「第 3 个问题对应哪个用户需求」时不必自己数下标——
/// 一次 5 条子查询，数错一格就是把 A 文件的答案说成 B 文件的。
public struct LocateManyGroup: Equatable, Sendable {

    public let query: String
    /// 这一组的窗口。`results` / `truncated` 都从它取，不再二次计算。
    public let response: LocateResponse

    public init(query: String, response: LocateResponse) {
        self.query = query
        self.response = response
    }

    var payload: AuthorityWire.Value {
        .object([
            AuthorityWire.ResponseKey.query: .string(query),
            AuthorityWire.ResponseKey.results: .array(response.results.map(\.payload)),
            AuthorityWire.ResponseKey.truncated: .bool(response.truncated)
        ])
    }
}

/// `locate_many` 的成功返回（方案 §4.4.3）。
///
/// ```json
/// {
///   "queries": [
///     { "query": "第一季度报告", "results": [ … ], "truncated": false },
///     { "query": "供应商名单",   "results": [],       "truncated": false }
///   ],
///   "limit_applied": 3,
///   "warnings": []
/// }
/// ```
///
/// ## 三个冻结点
///
/// 1. **顺序 = 输入顺序**：不按「谁先搜完」排。并发完成的次序是运行时噪声，
///    让它决定顺序，同一次调用两次跑就会给出两种排列。
/// 2. **空组也必须在**：某条子查询 0 命中，仍然要有一个 `results: []` 的组。
///    否则 Agent 无法区分「这条搜过了没有」与「这条压根没搜」。
/// 3. **`limit_applied` 只有一份，在顶层**：五条子查询用的是同一个
///    `per_query_limit`（Router 只解析一次），每组再抄一遍等于五个可能不一致的副本。
///    每组只有自己的 `truncated`——因为「还有更多」本来就是每组各自的结论。
///
/// ★ 没有任何一个 `truncated` 表示「整个 call 被截断」：总预算是时间预算，
///   它到期时表现是来源 `timeout` warning，不是「还有更多结果」。
public struct LocateManyResponse: Equatable, Sendable {

    /// 与输入 `queries[]` **一一对应且同序**，长度可为零（Router 已保证至少 1 条）。
    public let groups: [LocateManyGroup]
    /// 每组的条数上限（`per_query_limit` 生效后的值）。
    public let limitApplied: Int
    public let warnings: [String]

    public init(groups: [LocateManyGroup],
                application: LimitApplication,
                warnings: [String]) {
        self.groups = groups
        self.limitApplied = application.applied
        self.warnings = warnings
    }

    public func payload() -> AuthorityWire.Value {
        .object([
            AuthorityWire.ResponseKey.queries: .array(groups.map(\.payload)),
            AuthorityWire.ResponseKey.limitApplied: .int(limitApplied),
            AuthorityWire.ResponseKey.warnings: .array(warnings.map { .string($0) })
        ])
    }

    public func json() throws -> String {
        try AuthorityWire.jsonString(payload())
    }
}
