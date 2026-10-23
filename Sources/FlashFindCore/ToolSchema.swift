import Foundation

/// 结果的种类。**闭集 `file` / `folder`**。
///
/// ★ 这个枚举是 `kind` 参数取值集合的**唯一来源**：`ToolCatalog` 里的
/// `allowedValues` 由 `FileKind.allCases` 派生。曾经两边各写一份
/// （schema 写死 `["file", "folder"]`、Router 再用 `FileKind(rawValue:)` 挡一遍），
/// 于是红证只改一边时用例不红——两处都在拦同一个非法值，分不清是哪一处拦的。
/// 与 `LimitRange` 是同一个教训：**同一事实写两遍，红证会假装通过。**
public enum FileKind: String, Equatable, Sendable, CaseIterable {
    case file
    case folder
}

/// 一个 Tool 参数的类型。只覆盖 1.1.2 真正用到的三种，不做通用的 JSON Schema 建模。
///
/// ★ 为什么不直接依赖 MCP SDK 的 Schema 类型：这一层是**我们自己的契约**，
/// 它要在没有 SDK、没有网络、没有工具链升级的情况下也能写、能测。
/// SDK 那边只在最后一跳做「翻译」，翻译错了是适配层的事（§8.1）。
public enum ToolValueKind: String, Equatable, Sendable {
    case string
    case integer
    case stringArray
}

/// 参数默认值。1.1.2 只有整数型参数有默认值（那几个 `limit`），
/// 先只做这一种，等真有第二种再扩——空着比瞎猜强。
public enum ToolDefault: Equatable, Sendable {
    case integer(Int)
}

/// 一个参数的定义。
///
/// 这些字段会**原样变成发给 Agent 的 JSON Schema**，所以每个取值都必须有理由：
/// 多余的限制会让 Agent 传不进来，缺了的限制会让 Agent 传进来一个我们没处理的值。
public struct ToolParameter: Equatable, Sendable {

    public let name: String
    public let kind: ToolValueKind
    public let isRequired: Bool
    /// 英文，进 Agent 上下文。写「什么时候用它」而不是「它的类型是什么」——
    /// 类型 Agent 能看出来，用途看不出来。
    public let summary: String

    /// 字符串枚举（闭集）。目前只有 `kind` 用它。
    public let allowedValues: [String]?
    /// 整数下界 / 上界（闭区间）。
    public let minimum: Int?
    public let maximum: Int?
    /// 数组长度上下界。
    public let minItems: Int?
    public let maxItems: Int?
    public let defaultValue: ToolDefault?

    public init(name: String,
                kind: ToolValueKind,
                isRequired: Bool = false,
                summary: String,
                allowedValues: [String]? = nil,
                minimum: Int? = nil,
                maximum: Int? = nil,
                minItems: Int? = nil,
                maxItems: Int? = nil,
                defaultValue: ToolDefault? = nil) {
        self.name = name
        self.kind = kind
        self.isRequired = isRequired
        self.summary = summary
        self.allowedValues = allowedValues
        self.minimum = minimum
        self.maximum = maximum
        self.minItems = minItems
        self.maxItems = maxItems
        self.defaultValue = defaultValue
    }
}

/// 一个 Tool 的完整定义。
public struct ToolSchema: Equatable, Sendable {

    public let name: String
    /// 英文，进 Agent 上下文。**必须写清「什么时候用这个、什么时候用隔壁那个」**：
    /// `locate` 与 `search` 的差别就是靠这句话告诉 Agent 的（§4.3）。
    public let summary: String
    public let parameters: [ToolParameter]

    public init(name: String, summary: String, parameters: [ToolParameter]) {
        self.name = name
        self.summary = summary
        self.parameters = parameters
    }

    /// 必填参数名，保持声明顺序（`tools/list` 的输出要稳定）。
    public var requiredNames: [String] {
        parameters.filter(\.isRequired).map(\.name)
    }

    public func parameter(named name: String) -> ToolParameter? {
        parameters.first { $0.name == name }
    }
}

/// 一次 `limit` 处理的结果。
public struct LimitApplication: Equatable, Sendable {
    /// 真正生效的条数。
    public let applied: Int

    /// 用户要的条数**超过了本 Tool 的上限**，已按下限执行（`applied == maximum`）。
    ///
    /// ★ 名字是 `wasClamped` 而不是 `truncated`（Phase 6.3b-0 复审纠正）：
    /// 它说的是「**参数被钳位**」，而返回体里的 `truncated` 说的是
    /// 「**确实还有更多合格结果没返回**」。两者完全不同：
    ///
    /// ```text
    /// 请求 limit=100，上限 20，实际只有 3 条
    ///   参数被钳位  wasClamped = true
    ///   结果被截断  truncated  = false     ← 没有第 21 条，不能说「还有更多」
    /// ```
    ///
    /// 以前两个词共用一个字段，`locate` 只要 Agent 传大一点的 `limit`
    /// 就会回 `truncated: true`，Agent 会一直以为「还有更多」，反复加参数。
    public let wasClamped: Bool

    public init(applied: Int, wasClamped: Bool) {
        self.applied = applied
        self.wasClamped = wasClamped
    }
}

/// `limit` 的三种去向：按请求 / 按上限 / 参数错误。
///
/// 用枚举而不是 `Int?`：`nil` 会被读成「没传」，而「传了 0」与「没传」在这里
/// 的处理**相反**（前者是参数错误，后者用默认值）。用 Optional 表示两者必然有人写反。
public enum LimitOutcome: Equatable, Sendable {
    case applied(LimitApplication)
    case invalid
}

/// 某个 Tool 的 `limit` 默认值与上限。
///
/// ★ **每个 Tool 的上限各是各的**（§4.3）。统一成一个数的写法看起来整齐，
/// 但会把宽口径的 `search` 压成和 `locate` 一样窄，或者让 `locate_many`
/// 一次返回 5×5 条把上下文塞满。
public struct LimitRange: Equatable, Sendable {

    public let defaultValue: Int
    public let maximum: Int

    public init(defaultValue: Int, maximum: Int) {
        self.defaultValue = defaultValue
        self.maximum = maximum
    }

    public func apply(_ requested: Int?) -> LimitOutcome {
        guard let requested else {
            return .applied(LimitApplication(applied: defaultValue, wasClamped: false))
        }
        // `<= 0` 是参数错误，**不静默改成默认值**：改了之后 Agent 永远不知道
        // 自己传错了，benchmark 里「传错参数」也会被掩盖成「顺利返回 N 条」。
        guard requested > 0 else { return .invalid }
        if requested > maximum {
            return .applied(LimitApplication(applied: maximum, wasClamped: true))
        }
        return .applied(LimitApplication(applied: requested, wasClamped: false))
    }

    /// 按 Tool 名取上限。没有 `limit` 参数的 Tool 返回 `nil`
    /// （不「顺手给一个默认值」：那会让调用方以为它接受 limit）。
    ///
    /// ★ 四个上限是**唯一来源**：`ToolCatalog` 里 Schema 上的 `maximum` 也从这里取。
    /// 曾经两边各写一份（Schema 写 50、`forTool` 写 50），第一次变异就暴露了：
    /// 只改一边时 `testSearchIsWiderThanLocate` 不红——因为读的是另一份数据。
    public static func forTool(_ name: String) -> LimitRange? {
        switch name {
        case "locate":      return locate
        case "locate_many": return locateMany
        case "search":      return search
        case "recent":      return recent
        default:            return nil
        }
    }

    public static let locate = LimitRange(defaultValue: 5, maximum: 20)
    public static let locateMany = LimitRange(defaultValue: 3, maximum: 5)
    public static let search = LimitRange(defaultValue: 10, maximum: 50)
    public static let recent = LimitRange(defaultValue: 5, maximum: 20)
}

/// 六个 Tool 的定义（唯一来源）。
///
/// ★ 这里**只有定义，没有实现**：真正的查询在 Phase 6 才接。
/// 这一层能先写，是因为它不 `import MCP`——工具链/SDK 的问题挡不住它（§14.3.3）。
public enum ToolCatalog {

    /// 顺序即 `tools/list` 的顺序，别随手调整：它会进客户端缓存与 benchmark 记录。
    public static let all: [ToolSchema] = [
        ToolSchema(
            name: "list_sources",
            summary: "List the file sources (this Mac and NAS shares) that the user has authorized for AI access. "
                   + "Call this first to learn which source_id values you may pass to the other tools.",
            parameters: []),

        ToolSchema(
            name: "locate",
            summary: "Find the one file the user most likely means. Strong ranking, few results, each with a "
                   + "ranking score and reasons. Use it when the user describes a specific file. "
                   + "Never pass a file path: identity is a natural-language query or a file_id.",
            parameters: [
                ToolParameter(name: "query", kind: .string, isRequired: true,
                              summary: "What the user is looking for, in their own words. Must not be empty."),
                ToolParameter(name: "source_ids", kind: .stringArray,
                              summary: "Restrict the search to these source_id values from list_sources. "
                                     + "Omit to search every authorized source."),
                ToolParameter(name: "kind", kind: .string,
                              summary: "Restrict results to 'file' or 'folder'. Omit to match both.",
                              allowedValues: FileKind.allCases.map(\.rawValue)),
                ToolParameter(name: "modified_after", kind: .string,
                              summary: "Only return items modified at or after this instant, as an ISO 8601 "
                                     + "timestamp such as 2026-10-01T00:00:00+08:00."),
                limitParameter(.locate, summary: "How many results to return. Defaults to 5.")
            ]),

        ToolSchema(
            name: "locate_many",
            summary: "Find several distinct files in one call, one query per file the user asked for. "
                   + "Use it when a single turn names a list of documents; use locate when only one file is meant.",
            parameters: [
                ToolParameter(name: "queries", kind: .stringArray, isRequired: true,
                              summary: "One query per requested file, in the user's own words. Between 1 and 5.",
                              minItems: 1, maxItems: 5),
                limitParameter(.locateMany, name: "per_query_limit",
                               summary: "How many results to keep per query. Defaults to 3."),
                ToolParameter(name: "source_ids", kind: .stringArray,
                              summary: "Restrict every query to these source_id values. "
                                     + "Omit to search every authorized source.")
            ]),

        ToolSchema(
            name: "search",
            summary: "Search broadly by file name and path. Wider matching and more results than locate, "
                   + "without history ranking. Use it to discover which files of a kind exist, "
                   + "then narrow down with locate or get_metadata.",
            parameters: [
                ToolParameter(name: "query", kind: .string, isRequired: true,
                              summary: "Words to match against file names and paths. Must not be empty."),
                ToolParameter(name: "source_ids", kind: .stringArray,
                              summary: "Restrict the search to these source_id values. "
                                     + "Omit to search every authorized source."),
                limitParameter(.search, summary: "How many results to return. Defaults to 10.")
            ]),

        ToolSchema(
            name: "get_metadata",
            // ★ 不说「absolute path」（v0.29）：1.1.2 的 MCP 面**不输出**
            // synthetic `absolute_path`，NAS 也没有可信的本机绝对路径。
            // 写进 description 会让 Agent 以为拿得到，然后去拼一个打不开的路径。
            summary: "Return the current metadata for one file: size, kind and modification time. "
                   + "Use it only after a file_id came back from locate, locate_many or search. "
                   + "size_bytes and modified are omitted (null) when the device does not report them.",
            parameters: [
                ToolParameter(name: "file_id", kind: .string, isRequired: true,
                              summary: "An id returned by another FlashFind tool. Do not invent or edit it.")
            ]),

        ToolSchema(
            name: "recent",
            summary: "List files that AI tools have recently seen through FlashFind. "
                   + "Use it for references such as 'the report from yesterday' or 'the file we just looked at'.",
            parameters: [
                limitParameter(.recent, summary: "How many results to return. Defaults to 5."),
                ToolParameter(name: "source_ids", kind: .stringArray,
                              summary: "Restrict the results to these source_id values. "
                                     + "Omit to keep every authorized source."),
                ToolParameter(name: "within_days", kind: .integer,
                              summary: "Only return files seen within this many days. Omit for no time limit.",
                              minimum: 1)
            ])
    ]

    /// `limit` 参数的**唯一构造入口**：默认值与上限都从 `LimitRange` 取，
    /// 不在 Schema 里再抄一遍数字（抄了就会漂，第一次变异就踩到过）。
    private static func limitParameter(_ range: LimitRange,
                                       name: String = "limit",
                                       summary: String) -> ToolParameter {
        ToolParameter(name: name, kind: .integer, summary: summary, minimum: 1,
                      maximum: range.maximum, defaultValue: .integer(range.defaultValue))
    }

    /// 名字 → 定义。由 `all` 派生，**不另写一份**（两处各写一份必然漂移）。
    private static let byName: [String: ToolSchema] =
        Dictionary(uniqueKeysWithValues: all.map { ($0.name, $0) })

    /// 未知 Tool 返回 `nil`。调用方负责把它变成 `unknown_tool`
    /// （不是 JSON-RPC 的 `-32601`——那是「未知方法」，两者不能混，§4.2）。
    public static func schema(named name: String) -> ToolSchema? {
        byName[name]
    }
}
