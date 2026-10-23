import Foundation

/// 权威端 socket 上的一行 JSON（方案 §1.3.5）。
///
/// ## 这一层负责什么
///
/// ```text
/// {tool, arguments}（Agent 的原话，未受信）
///     ⇄ Request / Response（一行 JSON）
/// ```
///
/// 只做序列化，不做判断：不认识 socket、不认识 MCP、不认识权限、**不知道任何参数名**。
/// `UnixSocketAuthorityLink`（调用端）与 `AuthorityListener`（权威端）都用它。
///
/// ## ★ 报文是不可信的（v0.18 / §5.2.2）
///
/// 线上这条 JSON 由**任何同 UID 进程**都能发（socket 只校验同 UID）。所以：
///
/// * 这里**没有** `AuthorizationScope`：授权范围只能在 App authority 里产生；
/// * 当然也**没有** `facts` 操作：那等于把判定点挪回 Helper；
/// * `source_ids` 作为参数是合法的，但它的含义是「Agent 想搜这些」——**请求，不是批准**。
///   App 收到后仍要走一遍 `ToolRouter` → `PermissionPolicy`。
///
/// ★ 为什么这里不定义参数键常量：按 B 方案，Helper 不解释任何参数，只是把 Agent 给的
/// 键值原样搬过去。一旦在这里列一份 `Key.query = "query"`，就多了一份「参数名叫什么」
/// 的副本——而它只被测试用得到，生产代码根本不读，迟早与 `ToolSchema` 漂开。
///
/// ## ★ `context` 为什么与 `args` 同级（Phase 7a）
///
/// History 需要 `session_id` / `agent_id`，但它们**不是 Agent 说的参数**：
/// Agent 传的是「它想搜什么」，而 `context` 是「这次调用发生在哪个助手进程、
/// 谁发起的」。把它塞进 `args` 会有两个后果：
///
/// ① 它会被当成参数送进 Router 的「未知参数 → `invalid_argument`」，
///    于是助手每次调用都失败；
/// ② Router 的入参语义里多出一个「其实不是参数」的键，
///    「Agent 的请求」与「调用环境」从此再也分不开。
public enum AuthorityWire {

    /// 线上报文版本。**不是** MCP 协议版本——MCP 的版本由 SDK 协商（§8.2），
    /// 这里只是我们自己的 App↔Helper 报文格式号，用来在两端不同步时给出明确错误。
    public static let version = 1

    /// 权威端认识的操作。
    ///
    /// 六个业务操作的值**等于 Tool 名**（`ToolCatalog.all` 就是唯一来源），
    /// 另加一个只走 socket、不作为 MCP Tool 暴露的 `ping`：
    /// 它回答的是「权威端还活着吗」，不是「帮我搜个文件」。把它做成第七个 Tool
    /// 会让 Agent 以为有个叫 ping 的搜索工具。
    public enum Operation: String, Equatable, Sendable, CaseIterable {
        case ping
        case listSources = "list_sources"
        case locate
        case locateMany = "locate_many"
        case search
        case getMetadata = "get_metadata"
        case recent
    }

    /// **返回体**里的字段名。与上面的「操作」不同，这些不是 Agent 传进来的参数名，
    /// 而是我们自己定义的结果形状（§14.3.5）。
    ///
    /// ★ 这里是**结果字段名的唯一出处**：`list_sources` 的 `sources` 与 `locate` 的
    /// `results` / `file_id` / `relative_path` / … 都从这里取。各处自己写字符串，
    /// 就会出现「生成侧写 `path`、测试断言 `relative_path`」这种只能靠人眼发现的漂移。
    ///
    /// ★ 这里**没有**参数名（`query` / `source_ids` / `limit`）：按 B 方案，
    /// Helper 不解释任何参数，报文只做原样搬运。
    public enum ResponseKey {
        public static let sources = "sources"
        public static let sourceID = "source_id"
        public static let name = "name"
        public static let results = "results"
        public static let fileID = "file_id"
        public static let relativePath = "relative_path"
        public static let kind = "kind"
        public static let score = "score"
        public static let reasons = "reasons"
        public static let truncated = "truncated"
        public static let limitApplied = "limit_applied"
        public static let warnings = "warnings"
        /// `locate_many` 的分组数组：与输入 `queries[]` 同序（§4.4.3）。
        ///
        /// ★ 顶层键叫 `queries` 而不是又一个 `results`：`results` 嵌在 `results` 里
        /// 读起来分不清哪一层是哪一层，而这层数组的每一项**就是一条入参的回执**。
        public static let queries = "queries"
        /// 分组里回显的那条子查询。
        public static let query = "query"
        /// `get_metadata` 的字节数。**可空**（§4.11.3）。
        public static let sizeBytes = "size_bytes"
        /// `get_metadata` 的最后修改时间。**可空**（§4.11.3）。
        ///
        /// ★ 名字刻意不带 `_at` 后缀：`locate` 的入参叫 `modified_after`，
        /// 出参叫 `modified_at` 会让「同一个事实两个名字」变成常态。
        public static let modified = "modified"
        /// `recent` 的「最近一次被看到的时刻」（§4.13）。UTC ISO 8601，秒精度。
        ///
        /// ★ 不用 Unix 时间戳：响应里已经有一个 `modified` 用字符串表达时间，
        ///   再引入第二种时间写法会让「时间怎么读」变成两处口径。
        public static let lastSeen = "last_seen"
    }

    /// **请求**里那层非安全上下文的键名（Phase 7a）。
    ///
    /// ★ 为什么单独给一组键常量、而不是复用 `ResponseKey`：
    /// 请求与响应是两种形状，共用一个枚举会让「加一个返回字段」看起来
    /// 像是同时也加了一个入参。它们唯一真正的共同点只是「都在这一行 JSON 上」。
    ///
    /// ★ `context` 里**只放** History 标签，不放任何与安全有关的值——
    /// 同 UID 进程可以伪造它（§5.2.2），所以里面任何字段都不许进判定。
    public enum ContextKey {
        public static let context = "context"
        public static let sessionID = "session_id"
        public static let agentID = "agent_id"
    }

    // MARK: - 值

    /// 线上 JSON 值。用枚举而不是 `Any`：`Any` 不是 `Sendable`，也没法断言相等。
    public enum Value: Equatable, Sendable {
        case string(String)
        case int(Int)
        case double(Double)
        case bool(Bool)
        case null
        case array([Value])
        case object([String: Value])

        /// 便捷取字符串（`kind` / `file_id` 这类）。
        public var stringValue: String? {
            if case .string(let text) = self { return text }
            return nil
        }

        public var intValue: Int? {
            if case .int(let number) = self { return number }
            return nil
        }

        public var arrayValue: [Value]? {
            if case .array(let items) = self { return items }
            return nil
        }
    }

    // MARK: - 请求

    public struct Request: Equatable, Sendable {
        public var v: Int
        public var id: String
        public var op: String
        public var args: [String: Value]
        /// History 用的非安全标签（§7a）。**可选**：老客户端 / 直接写 socket 的
        /// 进程不会带它，缺了不是错误——History 只是拿不到 session / agent 维度。
        ///
        /// ★ 与 `args` 同级：它不是「Agent 给的参数」，而是「这次调用的环境」。
        public var context: HistoryContext?

        public init(v: Int = AuthorityWire.version,
                    id: String,
                    op: String,
                    args: [String: Value] = [:],
                    context: HistoryContext? = nil) {
            self.v = v
            self.id = id
            self.op = op
            self.args = args
            self.context = context
        }

        public var operation: Operation? { Operation(rawValue: op) }
    }

    /// 一次失败。`code` 取 §4.2 的固定闭集，`message` 直接进 Agent 上下文。
    public struct Failure: Error, Equatable, Sendable {
        public var code: String
        public var message: String

        public init(code: String, message: String) {
            self.code = code
            self.message = message
        }
    }

    // MARK: - 响应

    public struct Response: Equatable, Sendable {
        public var v: Int
        public var id: String
        public var ok: Bool
        public var result: Value?
        public var error: Failure?
        public var warnings: [String]?

        public init(v: Int = AuthorityWire.version,
                    id: String,
                    ok: Bool,
                    result: Value? = nil,
                    error: Failure? = nil,
                    warnings: [String]? = nil) {
            self.v = v
            self.id = id
            self.ok = ok
            self.result = result
            self.error = error
            self.warnings = warnings
        }
    }
}

// MARK: - Codable

extension AuthorityWire.Value: Codable {

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null; return }
        // 顺序有意义：`true` 不能被解成 1，`5` 不能被解成 true，
        // 而 `5` 既可能是 Int 也可能是 Double —— 先 Int 才能保住整数。
        if let value = try? container.decode(Bool.self) { self = .bool(value); return }
        if let value = try? container.decode(Int.self) { self = .int(value); return }
        if let value = try? container.decode(Double.self) { self = .double(value); return }
        if let value = try? container.decode(String.self) { self = .string(value); return }
        if let value = try? container.decode([AuthorityWire.Value].self) { self = .array(value); return }
        if let value = try? container.decode([String: AuthorityWire.Value].self) { self = .object(value); return }
        throw DecodingError.dataCorruptedError(in: container,
                                               debugDescription: "Unsupported JSON value")
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let text): try container.encode(text)
        case .int(let number): try container.encode(number)
        case .double(let number): try container.encode(number)
        case .bool(let flag): try container.encode(flag)
        case .null: try container.encodeNil()
        case .array(let items): try container.encode(items)
        case .object(let fields): try container.encode(fields)
        }
    }
}

extension AuthorityWire.Request: Codable {

    private enum CodingKeys: String, CodingKey {
        case v, id, op, args, context
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.v = try container.decode(Int.self, forKey: .v)
        self.id = try container.decode(String.self, forKey: .id)
        self.op = try container.decode(String.self, forKey: .op)
        self.args = try container.decodeIfPresent([String: AuthorityWire.Value].self, forKey: .args) ?? [:]
        // ★ 解码即降级（不抛错）：标签来自不可信进程，畸形是常态。
        //   在这里抛错会让任何同 UID 进程有能力用一条畸形标签把 MCP 搜索打挂（§5.2.2）。
        self.context = try container.decodeIfPresent(HistoryContext.self, forKey: .context)?.clamped
    }
}

extension AuthorityWire.Failure: Codable {}

extension AuthorityWire.Response: Codable {

    private enum CodingKeys: String, CodingKey {
        case v, id, ok, result, error, warnings
    }
}

// MARK: - 编码 / 解码

extension AuthorityWire {

    /// 一条报文 = 一行 JSON + `\n`。**不写多行**：权威端按 `\n` 切帧（§1.3.3）。
    public static func line<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        // 键序固定：同一输入两次必须产出同一串，否则断言只能写成「解析后相等」。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(value)
        data.append(0x0A)
        return data
    }

    public static func decodeRequest(_ data: Data) throws -> Request {
        try JSONDecoder().decode(Request.self, from: data)
    }

    public static func decodeResponse(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }

    /// 把一段结果 JSON 变回 `Value`：执行端返回的是字符串，线上要的是 JSON 值。
    /// 解析不了说明执行端违约——**不能把它当成功发出去**（那会让 Agent 拿到一段坏 JSON）。
    public static func value(fromJSON text: String) throws -> Value {
        try JSONDecoder().decode(Value.self, from: Data(text.utf8))
    }

    public static func jsonString(_ value: Value) throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(value), as: UTF8.self)
    }
}

// MARK: - 参数：`ToolArguments` ⇄ 线上 JSON

extension AuthorityWire {

    /// 一次调用 → 线上请求。**op 就是工具名，args 就是 Agent 给的键值**，一个不改。
    ///
    /// ★ 这里不做任何「归一化」：不 trim、不钳位、不补默认值、不丢键。
    /// 那些都是 App 侧 `ToolRouter` 的职责；在这里做一遍就是第二份参数语义。
    public static func request(tool: String,
                               arguments: ToolArguments,
                               id: String = UUID().uuidString,
                               context: HistoryContext? = nil) -> Request {
        Request(id: id, op: tool, args: self.arguments(from: arguments), context: context)
    }

    /// `ToolArguments` → 线上参数表。
    public static func arguments(from arguments: ToolArguments) -> [String: Value] {
        var args: [String: Value] = [:]
        for (name, argument) in arguments.values {
            args[name] = value(from: argument)
        }
        return args
    }

    /// 线上参数表 → `ToolArguments`。**权威端一侧的唯一入口**。
    ///
    /// ★ 认不出的类型一律落成 `.unsupported`，不丢键：`source_ids: null` 必须走到
    /// Router 的「类型错」，而不是被解成「没传」——那是一次权限放宽（§4.3.1）。
    public static func toolArguments(from args: [String: Value]) -> ToolArguments {
        var values: [String: ToolArgument] = [:]
        for (name, value) in args {
            values[name] = toolArgument(from: value)
        }
        return ToolArguments(values)
    }

    /// 单个参数到线上的映射。
    ///
    /// ★ `.unsupported` 上线成 `null` 是**有意的有损**：线上不保留「那个坏值原本长什么样」，
    /// 只保留「这个键有值，但不可用」。App 解回来仍是 `.unsupported` → `invalid_argument`。
    /// 保留原形状需要把整个 `Value` 塞进 `ToolArgument`，那会让 Router 认识传输层类型，
    /// 代价大于收益：Router 的报错文案本来就只说参数名、不回声参数值。
    static func value(from argument: ToolArgument) -> Value {
        switch argument {
        case .string(let text):        return .string(text)
        case .integer(let number):     return .int(number)
        case .stringArray(let values): return .array(values.map { .string($0) })
        case .unsupported:             return .null
        }
    }

    /// 单个参数从线上解回来。与 `MCPHandler.argument(from:)` 的规则**必须一致**——
    /// 一致性由 `testArgumentMappingSurvivesTheWireRoundTrip` 守着（两处各自写一份，
    /// 各自的单测都能绿，只有往返属性测试抓得住）。
    static func toolArgument(from value: Value) -> ToolArgument {
        switch value {
        case .string(let text):
            return .string(text)
        case .int(let number):
            return .integer(number)
        case .array(let items):
            var strings: [String] = []
            for item in items {
                guard case .string(let text) = item else { return .unsupported }
                strings.append(text)
            }
            return .stringArray(strings)
        case .double, .bool, .null, .object:
            return .unsupported
        }
    }

    // MARK: ping

    /// 探活请求。`ping` 只走 socket，不作为 MCP Tool 暴露（见 `Operation`）。
    public static func pingRequest(id: String = UUID().uuidString) -> Request {
        Request(id: id, op: Operation.ping.rawValue)
    }

    /// 探活应答。**只回答「活着」**：不带版本、不带路径、不带来源数量——
    /// 这是一条任何同 UID 进程都能发的报文，多一个字段就是多一次泄露机会。
    public static func pong(id: String) -> Response {
        Response(id: id, ok: true, result: .object(["pong": .bool(true)]))
    }

    public static func isPong(_ response: Response) -> Bool {
        guard response.ok, case .object(let fields)? = response.result else { return false }
        if case .bool(true)? = fields["pong"] { return true }
        return false
    }

    public static func failure(id: String, code: String, message: String) -> Response {
        Response(id: id, ok: false, error: Failure(code: code, message: message))
    }
}
