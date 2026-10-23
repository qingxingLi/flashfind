import Foundation

// MARK: - 入参：MCP 的 JSON 到这里只剩三种值

/// 一个参数值的**原始形态**，只覆盖我们真正会用的三种。
///
/// ★ 保留 `.unsupported` 而不是在解析阶段就丢掉：`nil`（没传）与
/// 「传了一个我们看不懂的东西」在处理上常常**相反**——
/// `source_ids` 没传是「搜所有已授权来源」，传了 `null` 必须报错。
/// 用 `nil` 表示两者，早晚有人写反。
public enum ToolArgument: Equatable, Sendable {
    case string(String)
    case integer(Int)
    case stringArray([String])
    /// 其它一切 JSON 类型：bool、小数、null、对象、数组套数组。
    case unsupported
}

/// 一次调用的全部参数。
public struct ToolArguments: Equatable, Sendable, ExpressibleByDictionaryLiteral {

    public let values: [String: ToolArgument]

    public init(_ values: [String: ToolArgument] = [:]) {
        self.values = values
    }

    public init(dictionaryLiteral elements: (String, ToolArgument)...) {
        var values: [String: ToolArgument] = [:]
        for (name, value) in elements { values[name] = value }
        self.init(values)
    }

    public subscript(name: String) -> ToolArgument? { values[name] }

    /// 传了哪些参数（`.unsupported` 也算传了）。
    public var providedNames: Set<String> { Set(values.keys) }
}

// MARK: - 权限事实（由调用方给，Router 不自己去读）

/// 判定一次请求需要的事实。**全部由调用方给**，与 `PermissionPolicy` 的入参一一对应。
///
/// 这里刻意不叫 `PermissionContext`：本项目里 `context` 读起来像并发隔离域，
/// 而这四个值就是「事实」，没有任何行为。
public struct PermissionFacts: Equatable, Sendable {

    public let mcpEnabled: Bool
    /// 用户勾选的来源 id（可能含已删除的残留）。
    public let allowedSources: Set<String>
    /// **现在还存在**的来源 id。不是「在线」——在线与否是 provider 的事。
    public let existing: Set<String>

    public init(mcpEnabled: Bool, allowedSources: Set<String>, existing: Set<String>) {
        self.mcpEnabled = mcpEnabled
        self.allowedSources = allowedSources
        self.existing = existing
    }
}

// MARK: - 出参：纯 Core 类型，Phase 6 的 AuthorityLink 只认它

/// 一次已经过权限的访问范围。
///
/// ★ 只能从**放行**的判定里构造（`init?(granting:)`）。这是契约 8 的落地方式：
/// 「权限失败发生在创建 `AuthorityRequest` 之前」不是靠代码顺序守的，
/// 而是拒绝时**根本造不出** scope，于是也造不出请求。
public struct AuthorizationScope: Equatable, Sendable {

    /// 已与 allowlist、existing 求交的来源 id，**永不为空**。
    public let sourceIDs: [String]
    /// 部分失败：`source_denied:<id>`。不含来源名（§4.3.1）。
    public let warnings: [String]

    public init?(granting decision: PermissionDecision) {
        guard case .allow(let sources, let warnings) = decision, !sources.isEmpty else { return nil }
        self.sourceIDs = sources
        self.warnings = warnings
    }
}

/// 校验 + 授权之后的一次调用。
public enum ToolCall: Equatable, Sendable {

    case listSources
    case locate(query: String, kind: FileKind?, modifiedAfter: Date?, limit: LimitApplication)
    case locateMany(queries: [String], perQueryLimit: LimitApplication)
    case search(query: String, limit: LimitApplication)
    case getMetadata(fileID: FileID)
    case recent(withinDays: Int?, limit: LimitApplication)

    public var toolName: String {
        switch self {
        case .listSources: return "list_sources"
        case .locate:      return "locate"
        case .locateMany:  return "locate_many"
        case .search:      return "search"
        case .getMetadata: return "get_metadata"
        case .recent:      return "recent"
        }
    }

    /// 这条调用生效的条数。`list_sources` / `get_metadata` 不按条数取，返回 `nil`。
    public var limit: LimitApplication? {
        switch self {
        case .listSources, .getMetadata:      return nil
        case .locate(_, _, _, let limit):     return limit
        case .locateMany(_, let limit):       return limit
        case .search(_, let limit):           return limit
        case .recent(_, let limit):           return limit
        }
    }
}

/// 交给权威端的一条请求。**没有 MCP、没有 socket、没有 JSON**。
public struct AuthorityRequest: Equatable, Sendable {

    public let call: ToolCall
    public let scope: AuthorizationScope

    public init(call: ToolCall, scope: AuthorizationScope) {
        self.call = call
        self.scope = scope
    }

    public var tool: String { call.toolName }

    /// 真正生效的条数（`truncated == true` 时返回体要带 `truncated`）。
    public var appliedLimit: LimitApplication? { call.limit }
}

// MARK: - 失败：对外错误码在这里定，JSON-RPC 的错误号不在这里

/// Router 的三种失败。`code` 就是方案 §4.2 的**对外固定错误码**。
///
/// ★ 刻意不做成 `-32601` / `-32602` 那种 JSON-RPC 错误号：
/// 那是协议层的事，由 Phase 5.5 的 `MCPHandler` 决定怎么映射（§8.1）。
/// Router 一旦知道 JSON-RPC，`ToolRouter` 就不再是纯 Core 类型。
public enum ToolRoutingError: Equatable, Sendable {

    /// 工具名不存在（`unknown_tool`）。
    case unknownTool(name: String)
    /// 参数类型 / 必填 / 枚举 / 空串 / 未知参数（`invalid_argument`）。
    case invalidArgument(argument: String, message: String)
    /// 权限不放行（`mcp_disabled` / `source_denied`），message 来自权限层。
    case permissionDenied(code: PermissionDenial, message: String)

    public var code: String {
        switch self {
        case .unknownTool:                  return "unknown_tool"
        case .invalidArgument:              return "invalid_argument"
        case .permissionDenied(let code, _): return code.rawValue
        }
    }

    public var message: String {
        switch self {
        case .unknownTool(let name):
            return "Unknown tool '\(name)'. Call tools/list to see the available tools."
        case .invalidArgument(_, let message):
            return message
        case .permissionDenied(_, let message):
            return message
        }
    }

    /// 出问题的参数名（只有 `invalid_argument` 有）。
    /// Agent 靠它知道自己该改哪一个，不用把整段参数重猜一遍。
    public var argumentName: String? {
        if case .invalidArgument(let argument, _) = self { return argument }
        return nil
    }
}

/// 路由结果。成功就一定带着一个 `AuthorityRequest`。
public enum ToolRoutingResult: Equatable, Sendable {

    case routed(AuthorityRequest)
    case failed(ToolRoutingError)

    public var request: AuthorityRequest? {
        if case .routed(let request) = self { return request }
        return nil
    }

    public var failure: ToolRoutingError? {
        if case .failed(let error) = self { return error }
        return nil
    }
}

// MARK: - Router

/// 把一次 `tools/call` 的参数变成一条**已经过校验与授权**的 `AuthorityRequest`。
///
/// 只做四件事，多一件都不做：
///
/// ```text
/// Tool 名   → ToolCatalog.schema(named:)        未知 → unknown_tool
/// 参数      → 类型 / 必填 / 枚举 / 空串 / 未知参数
/// limit     → LimitRange.forTool(_:)            这里不出现第二个上限数字
/// source_ids→ PermissionPolicy.decision(...)    这里不出现 allowedSources.contains
/// ```
///
/// ★ 不 `import MCP`、不碰 socket、不读偏好、不搜文件。这一层因此能在
/// 工具链还解析不了 SDK 的时候写完、测完（§14.3.3）；也因此在 Phase 6
/// 换成别的传输方式时一行都不用改。
public enum ToolRouter {

    public static func route(tool: String,
                             arguments: ToolArguments,
                             permission: PermissionFacts) -> ToolRoutingResult {

        guard let schema = ToolCatalog.schema(named: tool) else {
            return .failed(.unknownTool(name: tool))
        }

        // 只认 schema 里声明过的参数名。Agent 自己发明一个 `path` 必须当场拒掉：
        // 「忽略它然后照常搜」等于允许 Agent 用参数名暗示路径（§4.3.1）。
        let declared = Set(schema.parameters.map(\.name))
        if let unexpected = arguments.providedNames.subtracting(declared).sorted().first {
            return .failed(.invalidArgument(
                argument: unexpected,
                message: "Unknown argument '\(unexpected)'. Call tools/list to see the accepted arguments."))
        }

        // ★ 必填**只在一个地方执行**：各自的解析器（`query` / `queries` / `file_id`）。
        // 这里曾经还有一层「按 schema 的 isRequired 扫一遍、且顺手判空白」的循环，
        // 结果同一个空 query 在两处各拦一次，红证只改一处时不红——分不清是谁拦住的。
        // schema 的 `isRequired` 仍然有用：它决定 `tools/list` 里哪些参数是必填的。
        // 而「每个必填参数真的会被执行」由 `testEveryRequiredParameterIsActuallyEnforced` 守着。

        do {
            let call = try toolCall(for: schema, arguments: arguments)

            // ★ 权限在**造请求之前**：`AuthorizationScope` 只能从 allow 构造，
            //   所以拒绝时连一条请求都拼不出来（契约 8）。
            let decision = PermissionPolicy.decision(mcpEnabled: permission.mcpEnabled,
                                                     allowedSources: permission.allowedSources,
                                                     requested: try sourceIDs(arguments),
                                                     existing: permission.existing)
            guard let scope = AuthorizationScope(granting: decision) else {
                if case .deny(let code, let message) = decision {
                    return .failed(.permissionDenied(code: code, message: message))
                }
                // `allow` 但来源为空：判定层已保证不会发生，这里收口成拒绝，
                // 绝不把一个空权限放出去。
                return .failed(.permissionDenied(code: .sourceDenied,
                                                 message: PermissionPolicy.nothingUsableMessage))
            }
            return .routed(AuthorityRequest(call: call, scope: scope))
        } catch let error as InvalidArgument {
            return .failed(.invalidArgument(argument: error.argument, message: error.message))
        } catch {
            return .failed(.invalidArgument(argument: tool, message: "The arguments are not usable."))
        }
    }

    // MARK: 逐工具解析

    private static func toolCall(for schema: ToolSchema,
                                 arguments: ToolArguments) throws -> ToolCall {
        switch schema.name {
        case "list_sources":
            return .listSources

        case "locate":
            return .locate(query: try query(arguments),
                           kind: try fileKind(arguments),
                           modifiedAfter: try date(arguments, "modified_after", schema: schema),
                           limit: try limit(arguments, schema: schema))

        case "locate_many":
            return .locateMany(queries: try queries(arguments, schema: schema),
                               perQueryLimit: try limit(arguments, schema: schema))

        case "search":
            return .search(query: try query(arguments),
                           limit: try limit(arguments, schema: schema))

        case "get_metadata":
            return .getMetadata(fileID: try fileID(arguments))

        case "recent":
            return .recent(withinDays: try optionalInteger(arguments, "within_days", schema: schema),
                           limit: try limit(arguments, schema: schema))

        default:
            // 不可达：`schema` 来自 `ToolCatalog`，它的名字就是上面六个。
            throw InvalidArgument(argument: schema.name, message: "Unknown tool '\(schema.name)'.")
        }
    }

    // MARK: 参数校验

    private struct InvalidArgument: Error {
        let argument: String
        let message: String
    }

    /// 必填字符串（`query`）。空串与全空白都算没给——空白 query 送进搜索引擎
    /// 等于全量返回，结果看起来成功、拿到一堆无关文件，比报错难查得多。
    private static func query(_ arguments: ToolArguments) throws -> String {
        guard let raw = arguments["query"] else {
            throw InvalidArgument(argument: "query", message: "Missing required argument 'query'.")
        }
        guard case .string(let value) = raw else {
            throw InvalidArgument(argument: "query", message: "query must be a string.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw InvalidArgument(argument: "query", message: "query must not be empty.")
        }
        return trimmed
    }

    /// `kind`：**只认 `FileKind`**——它同时是 schema 里那个枚举的来源
    /// （`ToolCatalog` 用 `FileKind.allCases` 生成 `allowedValues`），
    /// 所以「Agent 看到的取值」与「我们接受的取值」只可能一起变。
    private static func fileKind(_ arguments: ToolArguments) throws -> FileKind? {
        guard let raw = arguments["kind"] else { return nil }
        guard case .string(let value) = raw else {
            throw InvalidArgument(argument: "kind", message: "kind must be a string.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let kind = FileKind(rawValue: trimmed) else {
            throw InvalidArgument(argument: "kind",
                                  message: "kind must be one of: "
                                         + FileKind.allCases.map(\.rawValue).joined(separator: ", ") + ".")
        }
        return kind
    }

    /// `limit`（`locate_many` 里叫 `per_query_limit`）：识别方式**从 schema 派生**，
    /// 不写死名字，也不抄上限。`limit <= 0` 与超上限都由 `LimitRange.apply` 判。
    private static func limit(_ arguments: ToolArguments, schema: ToolSchema) throws -> LimitApplication {
        guard let name = limitParameterName(in: schema),
              let range = LimitRange.forTool(schema.name) else {
            // 不可达：只有带 limit 参数的 Tool 才会走到这里。
            throw InvalidArgument(argument: schema.name, message: "\(schema.name) takes no limit.")
        }
        var requested: Int?
        if let raw = arguments[name] {
            guard case .integer(let value) = raw else {
                throw InvalidArgument(argument: name, message: "\(name) must be an integer.")
            }
            requested = value
        }
        switch range.apply(requested) {
        case .applied(let application):
            return application
        case .invalid:
            throw InvalidArgument(argument: name, message: "\(name) must be greater than 0.")
        }
    }

    /// schema 里「唯一一个有默认值的整数参数」就是 limit 类参数。
    /// 不写死名字：`locate_many` 叫 `per_query_limit`，写死就会有一份
    /// schema 之外的参数名副本，schema 改名时 Router 静默失效。
    private static func limitParameterName(in schema: ToolSchema) -> String? {
        schema.parameters.first { $0.kind == .integer && $0.defaultValue != nil }?.name
    }

    private static func optionalInteger(_ arguments: ToolArguments,
                                        _ name: String,
                                        schema: ToolSchema) throws -> Int? {
        guard let raw = arguments[name] else { return nil }
        guard case .integer(let value) = raw else {
            throw InvalidArgument(argument: name, message: "\(name) must be an integer.")
        }
        if let minimum = schema.parameter(named: name)?.minimum, value < minimum {
            throw InvalidArgument(argument: name, message: "\(name) must be at least \(minimum).")
        }
        if let maximum = schema.parameter(named: name)?.maximum, value > maximum {
            throw InvalidArgument(argument: name, message: "\(name) must be at most \(maximum).")
        }
        return value
    }

    /// `queries`：长度按 schema 的 `minItems` / `maxItems` 判。
    ///
    /// ★ 超上限**拒绝**而不是截断：截断等于替用户丢掉他点名的文件，
    /// 而 `limit` 超上限只是少返回几条候选。两者不是一类事。
    private static func queries(_ arguments: ToolArguments, schema: ToolSchema) throws -> [String] {
        guard let parameter = schema.parameter(named: "queries") else {
            throw InvalidArgument(argument: "queries", message: "queries is not accepted by \(schema.name).")
        }
        guard let raw = arguments["queries"] else {
            throw InvalidArgument(argument: "queries", message: "Missing required argument 'queries'.")
        }
        guard case .stringArray(let values) = raw else {
            throw InvalidArgument(argument: "queries", message: "queries must be an array of strings.")
        }
        if let minimum = parameter.minItems, values.count < minimum {
            throw InvalidArgument(argument: "queries",
                                  message: "queries must contain at least \(minimum) item(s).")
        }
        if let maximum = parameter.maxItems, values.count > maximum {
            throw InvalidArgument(argument: "queries",
                                  message: "queries must contain at most \(maximum) items.")
        }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else {
            throw InvalidArgument(argument: "queries", message: "queries must not contain empty strings.")
        }
        return trimmed
    }

    /// `source_ids` 的三种形态**严格分开**：
    ///
    /// ```text
    /// 没传          → nil   → PermissionPolicy 搜 allowlist
    /// 空数组        → []    → PermissionPolicy 判 source_denied
    /// null / 类型错 → 报错  → 绝不降级成 nil
    /// ```
    ///
    /// 最后一条是权限参数上唯一可接受的方向：**只许收紧，不许放宽**。
    /// 把 `null` 当「没传」，一次参数错误就变成一次范围更大的搜索。
    private static func sourceIDs(_ arguments: ToolArguments) throws -> [String]? {
        guard let raw = arguments["source_ids"] else { return nil }
        guard case .stringArray(let values) = raw else {
            throw InvalidArgument(argument: "source_ids",
                                  message: "source_ids must be an array of source_id strings. "
                                         + "Omit it to search every authorized source.")
        }
        let trimmed = values.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard trimmed.allSatisfy({ !$0.isEmpty }) else {
            throw InvalidArgument(argument: "source_ids",
                                  message: "source_ids must not contain empty ids.")
        }
        // 空数组原样交给权限层：它按「点了名但一个都没给」拒绝。
        return trimmed
    }

    /// `file_id` 必须是别的 Tool 返回过的那种形状：`ff1_` + 32 位小写 hex。
    ///
    /// 在 Router 拦下的意义：Agent 编一个 id、或直接把路径塞进来，
    /// 会在参数阶段就得到 `invalid_argument`，而不是变成一次 `file_not_found`
    /// 让它以为「文件没了」。
    ///
    /// ★ 形状判定**只由 `FileID.parse` 做**（v0.20 / §4.6）：这里曾经自带一套
    /// `count == 36` + `isHexDigit` 的判据，而生成侧将来也要拼同一个格式——
    /// 两份实现必然漂开，表现是「刚拿到的 id 被拒」。现在 Router 只负责
    /// 「有没有传、是不是字符串」，`FileID` 负责「长什么样」。
    private static func fileID(_ arguments: ToolArguments) throws -> FileID {
        guard let raw = arguments["file_id"] else {
            throw InvalidArgument(argument: "file_id", message: "Missing required argument 'file_id'.")
        }
        guard case .string(let value) = raw else {
            throw InvalidArgument(argument: "file_id", message: "file_id must be a string.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let id = FileID.parse(trimmed) else {
            throw InvalidArgument(argument: "file_id",
                                  message: "file_id must be an id returned by another FlashFind tool. "
                                         + "Do not invent or edit it.")
        }
        return id
    }

    /// `modified_after`：必须带时区的时间戳。
    ///
    /// 解析不了就报错，**不静默丢掉这个过滤条件**——丢掉之后「按时间过滤」
    /// 变成「没过滤」，Agent 以为筛过了，实际拿回一堆老文件。
    /// 只给日期（`2026-10-01`）也拒：那要替用户猜时区。
    private static func date(_ arguments: ToolArguments,
                             _ name: String,
                             schema: ToolSchema) throws -> Date? {
        guard let raw = arguments[name] else { return nil }
        guard case .string(let value) = raw else {
            throw InvalidArgument(argument: name, message: "\(name) must be an ISO 8601 timestamp string.")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let parsed = iso8601WithZone.date(from: trimmed) ?? iso8601WithZoneAndFraction.date(from: trimmed)
        guard let parsed else {
            throw InvalidArgument(argument: name,
                                  message: "\(name) must be an ISO 8601 timestamp with a time zone, "
                                         + "such as 2026-10-01T00:00:00+08:00.")
        }
        return parsed
    }

    private static let iso8601WithZone: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let iso8601WithZoneAndFraction: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
