import Foundation
import MCP

// ★ 本文件是 `FlashFindCore` 里**唯一**允许 `import MCP` 的文件（§11.1 / §11.2 结构测试守着）。
//
// 它只做三件事，多一件都不做：
//
//     SDK 的 Tool → 我们的 ToolSchema        （tools/list：翻译，不重写）
//     SDK 的参数 → 我们的 ToolArguments       （tools/call：翻译，不校验）
//     权威端结果 → SDK 的 Result              （错误码在这里落成 isError）
//
// ★ 从 6.2 起它**不再**做任何判断（v0.18 撤回 `facts`）：工具名对不对、参数合不合法、
// 来源有没有授权，全部由 App 侧的权威端回答（§5.2.2）。这里一旦出现一句
// 「未知工具」或「没权限」，参数语义就有了第二份实现，而两份迟早会漂。
//
// 这样 SDK 换版本时，要改的只有这一跳；而业务契约的测试一条都不用重写（§8.1）。

// MARK: - Handler

/// `tools/list` 与 `tools/call` 的装配层。
///
/// ★ 这里**没有**权限逻辑、**没有**参数校验、**没有** Tool 名副本：
/// `listTools()` 整个从 `ToolCatalog` 翻译，`callTool()` 整个交给 `AuthorityLink`。
/// 结构测试会断言本文件里不出现任何权限/路由类型（`MCPBoundaryTests` 第 4 组）。
public struct MCPHandler: Sendable {

    // MARK: 对外标识（serverInfo）

    /// `serverInfo.name`。**英文、稳定**：客户端会把它写进自己的配置与日志。
    ///
    /// ★ 1.1.2 新增的对外标识之一。发布到公开仓时脱敏脚本会把独立成词的
    /// `flashfind` 换成占位串——这个词必须进 `PROTECTED_SLUGS`，否则 1.1.0 的
    /// 「仓名被替换 → 发布页 404」会以另一种形式重演（见 §12 与脱敏验收三铁律）。
    public static let serverName = "flashfind"

    /// `serverInfo.version`。**机器可读**，不取界面文案——界面在裸二进制上显示
    /// 「开发构建」，把它塞进协议会让客户端看到一个中文版本号。
    public static var serverVersion: String { AppVersion.machineReadable }

    /// `initialize` 的 instructions：给模型的一句使用顺序提示。
    ///
    /// ★ 只写「先调哪个」，不写业务规则。规则写在每个 Tool 的 description 里，
    /// 两处都写就必然漂成两份说法。
    public static let instructions =
        "FlashFind searches files on this Mac and on the user's NAS shares. "
        + "Call list_sources first to learn which source_id values are authorized, "
        + "then pass those ids to the other tools."

    // MARK: 依赖

    /// 权威端。只搬运，不判断。
    private let link: any AuthorityLink
    /// Helper 进程级的身份源（`session_id` + `agent_id`）。
    ///
    /// ★ 它产出的是**不可信标签**：App 端只用于 History 关联与诊断，
    ///   不进任何判定（§7a）。
    private let history: HistoryContextSource

    public init(link: any AuthorityLink, history: HistoryContextSource = HistoryContextSource()) {
        self.link = link
        self.history = history
    }

    // MARK: 会话身份（History 用，非安全用途）

    /// 记下 MCP `initialize` 送来的客户端标识。
    ///
    /// ★ 这是**唯一**会被 `agent_id` 影响的地方，且只影响 History 标签与诊断输出。
    ///   它不进入 `PermissionPolicy` / `AuthorizationScope` / 来源选择
    ///   ——由 `HistoryContextTests` 的结构断言机器执行。
    ///
    /// ★ 助手主进程在 `Server.start(initializeHook:)` 里调用它。
    public func noteClient(name: String?, version: String?) {
        history.noteClient(name: name, version: version)
    }

    // MARK: tools/list

    /// 交给客户端的六个 Tool。**整个由 `ToolCatalog` 翻译而来**，不存在第二份 schema。
    public static var tools: [MCP.Tool] { ToolCatalog.all.map(tool(from:)) }

    public func listTools() -> ListTools.Result {
        // 六个 Tool 一次给完，不分页：`nextCursor` 保持 nil。
        ListTools.Result(tools: Self.tools)
    }

    // MARK: tools/call

    /// 一次调用。**不抛错**：权威端的失败落成 `isError: true` 的结果。
    ///
    /// ★ 为什么不让失败冒泡成 JSON-RPC error：`unknown_tool` 与
    /// `invalid_argument` 对 Agent 是「你这次调错了，改一改再试」，
    /// 而 JSON-RPC error（`-32602` / `-32601`）在多数客户端里是「服务端有问题」。
    /// 两者混用会让 Agent 放弃而不是重试（§4.2 / §8.4）。
    public func callTool(_ parameters: CallTool.Parameters) async -> CallTool.Result {

        // 名字与参数**原样**交出去：这里不查 ToolCatalog、不 trim、不钳位、不丢键。
        // 未知工具也照样送——判断它是 App 的事，App 会回 `unknown_tool`。
        //
        // ★ `context` 与参数分开走：它是「这次调用的环境标签」，不是 Agent 说的话。
        //   合进 `arguments` 会被 Router 当成未知名参数拒掉（§7a）。
        let outcome = await link.call(tool: parameters.name,
                                      arguments: Self.arguments(from: parameters.arguments),
                                      context: history.current())

        switch outcome {
        case .success(let json):
            return Self.success(json)
        case .failure(let code, let message):
            // 权威端的码原样转发：`source_unavailable` / `auth_required` /
            // `timeout` 各有各的「Agent 该做什么」，在适配层改码等于把
            // §4.2 那张表的语义销毁在这一跳。
            return Self.failure(code: code, message: message)
        }
    }

    // MARK: - SDK → Core：参数

    /// SDK 的参数表 → `ToolArguments`。
    ///
    /// ★ 认不出的类型**保留成 `.unsupported`**，不丢键、不降级：`source_ids: null`
    /// 必须一路走到 App 的「类型错」，而不是被这里吞成「没传」——那是一次权限放宽。
    static func arguments(from raw: [String: Value]?) -> ToolArguments {
        guard let raw else { return ToolArguments() }
        var values: [String: ToolArgument] = [:]
        for (name, value) in raw { values[name] = argument(from: value) }
        return ToolArguments(values)
    }

    private static func argument(from value: Value) -> ToolArgument {
        switch value {
        case .string(let text):
            return .string(text)
        case .int(let number):
            return .integer(number)
        case .array(let items):
            // 只接受「全是字符串」的数组。混进一个数字就是 `.unsupported`，
            // 由权威端报 `must be an array of strings`——不在这里挑出字符串、
            // 悄悄把数字丢掉（那等于替 Agent 改参数）。
            var strings: [String] = []
            for item in items {
                guard case .string(let text) = item else { return .unsupported }
                strings.append(text)
            }
            return .stringArray(strings)
        case .bool, .double, .null, .object, .data:
            // `.data` 是 SDK 把「长得像 data URL 的字符串」解出来的形态。
            // 它不可能是来源 id 或 file_id，按类型错处理是唯一安全的方向。
            return .unsupported
        }
    }

    // MARK: - Core → SDK：结果

    private static func success(_ json: String) -> CallTool.Result {
        // `isError` 显式写 false，不留给客户端猜 `nil` 的意思。
        CallTool.Result(content: [text(json)], isError: false)
    }

    private static func failure(code: String, message: String) -> CallTool.Result {
        CallTool.Result(content: [text(failureBody(code: code, message: message))], isError: true)
    }

    private static func text(_ value: String) -> MCP.Tool.Content {
        .text(text: value, annotations: nil, _meta: nil)
    }

    /// 失败正文：`{"code":"...","message":"...","ok":false}`。
    ///
    /// 固定成 JSON 而不是「一句话」，是因为 Agent 要按键取码决定下一步
    /// （§4.2 那张表的第三列）；一串自由文本只能靠肉眼读。
    static func failureBody(code: String, message: String) -> String {
        struct Body: Encodable {
            let code: String
            let message: String
            let ok: Bool
        }
        let encoder = JSONEncoder()
        // 键序、斜杠转义都固定下来：同一输入两次必须产出同一串，
        // 否则断言只能写成「解析后相等」，而错位的括号永远解析不过。
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let body = Body(code: code, message: message, ok: false)
        // 三个字段都是字符串/常量，编码不会失败；万一失败也不能吐空串——
        // Agent 拿到空正文就彻底不知道发生了什么。
        guard let data = try? encoder.encode(body) else {
            return #"{"code":"internal_error","message":"FlashFind could not describe this failure.","ok":false}"#
        }
        return String(decoding: data, as: UTF8.self)
    }

    // MARK: - Core → SDK：schema

    /// 一个 `ToolSchema` → 一个 SDK Tool。
    ///
    /// ★ 这里**不写任何名字、上限、枚举**：全部从 `ToolParameter` 读。
    /// 一旦在这里抄一个 `maximum: 50`，schema 与 `LimitRange` 就分叉了——
    /// 那正是 §4.3 反复踩到的「同一事实写两遍，红证会假装通过」。
    static func tool(from schema: ToolSchema) -> MCP.Tool {
        var properties: [String: Value] = [:]
        for parameter in schema.parameters {
            properties[parameter.name] = schemaValue(for: parameter)
        }
        let input: [String: Value] = [
            "type": .string("object"),
            "properties": .object(properties),
            // `additionalProperties: false` 是权威端的真实行为（未知参数 → `invalid_argument`）。
            // 写进 schema，Agent 在调用前就能看到，而不是靠被拒一次才知道。
            "additionalProperties": .bool(false),
            // 空也照写：`required: []` 与缺省在语义上等价，但前者让
            // 「这个 Tool 一个必填参数都没有」变成可断言的事实。
            "required": .array(schema.requiredNames.map { .string($0) })
        ]
        return MCP.Tool(name: schema.name,
                        description: schema.summary,
                        inputSchema: .object(input))
    }

    /// 一个参数的 JSON Schema 片段。
    static func schemaValue(for parameter: ToolParameter) -> Value {
        var object: [String: Value] = ["description": .string(parameter.summary)]
        switch parameter.kind {
        case .string:
            object["type"] = .string("string")
            if let allowed = parameter.allowedValues {
                object["enum"] = .array(allowed.map { .string($0) })
            }
        case .integer:
            object["type"] = .string("integer")
            if let minimum = parameter.minimum { object["minimum"] = .int(minimum) }
            if let maximum = parameter.maximum { object["maximum"] = .int(maximum) }
            if case .integer(let fallback)? = parameter.defaultValue {
                object["default"] = .int(fallback)
            }
        case .stringArray:
            object["type"] = .string("array")
            object["items"] = .object(["type": .string("string")])
            if let minimum = parameter.minItems { object["minItems"] = .int(minimum) }
            if let maximum = parameter.maxItems { object["maxItems"] = .int(maximum) }
        }
        return .object(object)
    }
}
