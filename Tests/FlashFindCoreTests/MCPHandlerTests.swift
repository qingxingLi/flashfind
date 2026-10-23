import XCTest
import MCP
@testable import FlashFindCore

/// Phase 5.5 / 6.2 验收：`MCPHandler`（方案 §8.1 / §11.1 / §14.3.5）。
///
/// 6.2 起 handler 只做**两件**事，用例就按这两件事分组：
///
/// ```text
/// tools/list   ToolCatalog → SDK Tool                  （翻译，不重写 schema）
/// tools/call   {工具名, 原始参数} → AuthorityLink       （搬运，不判断）
/// ```
///
/// ★ 这里曾经有一组「Router 拒收 → Tool Error」的用例。它们随 `facts` 一起搬走了：
/// 参数语义与权限判定现在只在 App authority 里（`AuthorityServiceTests`）。
/// handler 这一侧唯一该断言的是**它什么都没改**。
///
/// ★ 这一层**不测**协议本身（initialize / framing / stdout）——那是
/// `MCPServerTests` 与 `MCPStdioTests` 的事。
final class MCPHandlerTests: XCTestCase {

    /// 假执行端：记录收到的「工具名 + 原始参数」，回一个可配置的结果。
    ///
    /// `AuthorityLink` 要求 `Sendable`，而记录是可变状态，所以用锁而不是 actor：
    /// 用例要在 `await` 之后同步读回记录，actor 会让每条断言都变成 await。
    private final class RecordingLink: AuthorityLink, @unchecked Sendable {

        struct Call: Equatable {
            let tool: String
            let arguments: ToolArguments
            /// History 标签。`MCPHandler` 每次调用都现盖一次（§7a）。
            let context: HistoryContext?
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        private var outcome: ToolOutcome

        init(outcome: ToolOutcome = .success(json: #"{"ok":true,"results":[]}"#)) {
            self.outcome = outcome
        }

        func call(tool: String, arguments: ToolArguments, context: HistoryContext?) async -> ToolOutcome {
            // `NSLock.lock()` 在异步上下文里是「Swift 6 会报错」的写法，
            // 用 `withLock` 把临界区收成一个同步闭包。
            lock.withLock { recorded.append(Call(tool: tool, arguments: arguments, context: context)) }
            return lock.withLock { outcome }
        }

        var calls: [Call] {
            lock.lock()
            defer { lock.unlock() }
            return recorded
        }
    }

    /// 全是编造的 id：测试不许出现真实设备名或来源名。
    private let mac = "local_mac"
    private let nas = "src_nas_work"

    private func handler(link: AuthorityLink) -> MCPHandler {
        MCPHandler(link: link)
    }

    // MARK: - tools/list：只能来自 ToolCatalog

    func testToolsListIsExactlyTheCatalog() {
        let handler = handler(link: RecordingLink())
        let result = handler.listTools()

        XCTAssertEqual(ToolCatalog.all.count, 6, "六个 Tool 是 §4.3 的契约，数量变了就要改方案")
        XCTAssertEqual(result.tools.map(\.name), ToolCatalog.all.map(\.name),
                       "tools/list 的顺序就是 ToolCatalog 的顺序（客户端会缓存它）")
        XCTAssertNil(result.nextCursor, "六个 Tool 一次给完，不分页")
    }

    /// ★ 逐个参数 deep check：type / enum / minimum / maximum / default /
    /// minItems / maxItems / description 任何一项漏翻译，这里都要红。
    ///
    /// 写成「按 ToolCatalog 遍历、按字段比对」而不是「挑几个字面量断言」，是为了
    /// 让以后新增参数时**不需要改这条用例**——它自动覆盖新参数。
    func testEveryCatalogParameterIsCarriedIntoTheSchema() throws {
        let tools = MCPHandler.tools
        XCTAssertEqual(tools.count, ToolCatalog.all.count)

        for (tool, schema) in zip(tools, ToolCatalog.all) {
            XCTAssertEqual(tool.name, schema.name)

            let input = try XCTUnwrap(tool.inputSchema.objectValue, "\(schema.name) 的 inputSchema 不是对象")
            XCTAssertEqual(input["type"]?.stringValue, "object")
            XCTAssertEqual(input["additionalProperties"]?.boolValue, false,
                           "权威端拒收未声明参数，schema 要如实写出来")
            XCTAssertEqual(input["required"]?.arrayValue?.compactMap(\.stringValue),
                           schema.requiredNames,
                           "\(schema.name) 的必填集合与声明不一致")

            let properties = try XCTUnwrap(input["properties"]?.objectValue)
            XCTAssertEqual(Set(properties.keys), Set(schema.parameters.map(\.name)),
                           "\(schema.name) 的参数集合与声明不一致")

            for parameter in schema.parameters {
                let json = try XCTUnwrap(properties[parameter.name]?.objectValue,
                                         "\(schema.name).\(parameter.name) 没有 properties 片段")
                XCTAssertEqual(json["description"]?.stringValue, parameter.summary,
                               "\(schema.name).\(parameter.name) 的说明与声明不一致")

                switch parameter.kind {
                case .string:
                    XCTAssertEqual(json["type"]?.stringValue, "string")
                    XCTAssertEqual(json["enum"]?.arrayValue?.compactMap(\.stringValue),
                                   parameter.allowedValues,
                                   "\(schema.name).\(parameter.name) 的闭集没有翻译")
                case .integer:
                    XCTAssertEqual(json["type"]?.stringValue, "integer")
                    XCTAssertEqual(json["minimum"]?.intValue, parameter.minimum)
                    XCTAssertEqual(json["maximum"]?.intValue, parameter.maximum,
                                   "\(schema.name).\(parameter.name) 的上限没有翻译")
                    XCTAssertEqual(json["default"]?.intValue, integer(parameter.defaultValue))
                case .stringArray:
                    XCTAssertEqual(json["type"]?.stringValue, "array")
                    XCTAssertEqual(json["items"]?.objectValue?["type"]?.stringValue, "string")
                    XCTAssertEqual(json["minItems"]?.intValue, parameter.minItems)
                    XCTAssertEqual(json["maxItems"]?.intValue, parameter.maxItems)
                }
            }
        }
    }

    func testToolDescriptionIsTheCatalogSummary() {
        for (tool, schema) in zip(MCPHandler.tools, ToolCatalog.all) {
            XCTAssertEqual(tool.description, schema.summary,
                           "\(schema.name) 的 description 必须就是 schema 里那句，不许另写一份")
        }
    }

    // MARK: - tools/call：只搬运，不判断

    /// ★ 6.2 的核心：handler 把**Agent 的原话**交出去。
    ///
    /// query 带着空格不 trim、limit 不钳位、`source_ids` 不解释——这些都归 App 的
    /// `ToolRouter`。在这一层做一遍就是第二份参数语义（§5.2.2）。
    func testCallToolForwardsTheToolNameAndRawArguments() async throws {
        let link = RecordingLink()
        let result = await handler(link: link).callTool(
            .init(name: "locate",
                  arguments: ["query": .string("  年度报告  "),
                              "source_ids": .array([.string(nas)]),
                              "kind": .string("folder"),
                              "limit": .int(9)]))

        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(link.calls.count, 1)
        let call = try XCTUnwrap(link.calls.first)
        XCTAssertEqual(call.tool, "locate")
        XCTAssertEqual(call.arguments, ["query": .string("  年度报告  "),
                                        "source_ids": .stringArray([nas]),
                                        "kind": .string("folder"),
                                        "limit": .integer(9)],
                       "参数必须原样：trim / 钳位 / 补默认值都是 App 的事")
    }

    /// 未知工具也照样送出去：查 `ToolCatalog` 是 App 的判断，不是助手的。
    ///
    /// ★ 这条同时守住「`unknown_tool` 只有一个产生点」：如果 handler 自己先拦一道，
    /// 那么两处各有一份「什么是合法工具名」，而客户端看到的码可能不一样。
    func testUnknownToolIsForwardedInsteadOfJudgedHere() async throws {
        let link = RecordingLink(outcome: .failure(code: "unknown_tool",
                                                   message: "Unknown tool 'delete_everything'."))
        let result = await handler(link: link).callTool(.init(name: "delete_everything"))

        XCTAssertEqual(try XCTUnwrap(link.calls.first).tool, "delete_everything",
                       "handler 不该在这里拦未知工具")
        XCTAssertEqual(result.isError, true)
        XCTAssertEqual(try failureBody(of: result)["code"] as? String, "unknown_tool")
    }

    /// ★ 认不出的 JSON 类型不能在这里被丢掉：丢了 `source_ids: null` 会变成
    /// 「没传」，即一次范围更大的搜索。全部原样交出去，由 App 报类型错。
    func testUnsupportedJSONTypesSurviveAsUnsupported() async throws {
        let cases: [(title: String, arguments: [String: Value])] = [
            ("bool 当 string", ["kind": .bool(true)]),
            ("小数当整数", ["limit": .double(1.5)]),
            ("数组里混了数字", ["source_ids": .array([.string("a"), .int(1)])]),
            ("对象当 query", ["query": .object([:])]),
            ("null 当时间戳", ["modified_after": .null]),
        ]

        for item in cases {
            let link = RecordingLink()
            _ = await handler(link: link).callTool(.init(name: "locate", arguments: item.arguments))

            let call = try XCTUnwrap(link.calls.first, "\(item.title)：请求根本没送出去")
            XCTAssertEqual(Set(call.arguments.values.keys), Set(item.arguments.keys),
                           "\(item.title)：键被丢了，权限会因此放宽")
            XCTAssertTrue(call.arguments.values.values.allSatisfy { $0 == .unsupported },
                          "\(item.title)：认不出的类型必须保留成 .unsupported，"
                          + "实际是 \(call.arguments.values)")
        }
    }

    func testSuccessPayloadIsReturnedVerbatim() async throws {
        let link = RecordingLink(outcome: .success(json: #"{"ok":true,"results":["a"]}"#))
        let result = await handler(link: link).callTool(
            .init(name: "search", arguments: ["query": .string("报告")]))

        XCTAssertEqual(result.isError, false)
        XCTAssertEqual(try text(of: result), #"{"ok":true,"results":["a"]}"#,
                       "适配层不许改写结果正文")
        XCTAssertEqual(result.content.count, 1)
    }

    func testLinkFailureCodeIsForwardedUnchanged() async throws {
        let link = RecordingLink(outcome: .failure(code: "source_unavailable",
                                                   message: "The source is offline right now."))
        let result = await handler(link: link).callTool(
            .init(name: "search", arguments: ["query": .string("报告")]))

        XCTAssertEqual(result.isError, true)
        let body = try failureBody(of: result)
        XCTAssertEqual(body["code"] as? String, "source_unavailable",
                       "执行端的码必须原样转发：改码等于把 §4.2 的语义销毁在适配层")
        XCTAssertEqual(body["message"] as? String, "The source is offline right now.")
        XCTAssertEqual(body["ok"] as? Bool, false)
    }

    /// `-32601` / `-32602` 是 JSON-RPC 的事。业务错误一旦变成协议错误，
    /// 客户端会判定「服务端有问题」并放弃，而不是「你调错了，改一改」（§4.2 / §8.4）。
    func testFailureIsNotAProtocolError() async throws {
        let link = RecordingLink(outcome: .failure(code: "invalid_argument", message: "query must be a string."))
        let result = await handler(link: link).callTool(.init(name: "locate"))

        let body = try text(of: result)
        XCTAssertEqual(try failureBody(of: result)["code"] as? String, "invalid_argument")
        for protocolCode in ["-32601", "-32602", "-32603"] {
            XCTAssertFalse(body.contains(protocolCode), "Tool Error 正文里不许出现 JSON-RPC 错误号")
        }
    }

    // MARK: - 边界

    /// serverInfo 会进客户端配置与日志，必须是 ASCII 的机器可读串。
    /// 用 `AppVersion.current`（界面文案，「开发构建」）就会把中文塞进协议。
    func testServerIdentityIsMachineReadable() {
        XCTAssertEqual(MCPHandler.serverName, "flashfind")
        XCTAssertFalse(MCPHandler.serverName.isEmpty)
        XCTAssertTrue(MCPHandler.serverName.allSatisfy(\.isASCII))

        XCTAssertEqual(MCPHandler.serverVersion, AppVersion.machineReadable,
                       "版本号的唯一出处是 AppVersion，别处不许再读一次 Info.plist")
        XCTAssertFalse(MCPHandler.serverVersion.isEmpty)
        XCTAssertTrue(MCPHandler.serverVersion.allSatisfy(\.isASCII),
                      "serverInfo.version 出现非 ASCII，说明有人换成了界面文案")

        XCTAssertTrue(MCPHandler.instructions.contains("list_sources"),
                      "instructions 的唯一作用是告诉模型先调 list_sources")
    }

    /// 连不上权威端时**必须失败**，不许假装搜过。
    ///
    /// 它返回成功（哪怕是空结果）会让 Agent 以为「闪寻搜过了，没有这个文件」，
    /// 而事实是根本没连上——空结果是撒谎，失败才是诚实的。
    ///
    /// ★ 6.2 起这里是 `flashfind_app_unavailable`，不再是 `mcp_disabled`：
    /// 助手没有依据说「用户关了 AI」，它只知道「权威端不可达」。
    func testUnreachableLinkNeverPretendsToSucceed() async {
        let path = "/tmp/flashfind-no-such-app-\(UUID().uuidString.prefix(8))/mcp.sock"
        let outcome = await UnixSocketAuthorityLink(path: path)
            .call(tool: "list_sources", arguments: ToolArguments())

        guard case .failure(let code, let message) = outcome else {
            return XCTFail("连不上执行端却返回了成功：\(outcome)")
        }
        XCTAssertEqual(code, "flashfind_app_unavailable")
        XCTAssertFalse(message.isEmpty)
        XCTAssertFalse(message.contains("/"), "文案里不许带路径")
    }

    // MARK: - 小工具

    private func integer(_ value: ToolDefault?) -> Int? {
        if case .integer(let number)? = value { return number }
        return nil
    }

    /// 取 `content` 里那段文本。SDK 的 `Tool.Content` 是枚举，只能模式匹配。
    private func text(of result: CallTool.Result) throws -> String {
        let first = try XCTUnwrap(result.content.first)
        guard case .text(let text, _, _) = first else {
            // 不是文本内容 ⇒ 这条用例的前提不成立，必须**失败**而不是跳过：
            // 跳过会让「结果形状变了」这件事永远没人发现。
            XCTFail("结果不是文本内容：\(first)")
            throw NotText()
        }
        return text
    }

    private struct NotText: Error {}

    private func failureBody(of result: CallTool.Result) throws -> [String: Any] {
        let raw = try text(of: result)
        let parsed = try JSONSerialization.jsonObject(with: Data(raw.utf8))
        return try XCTUnwrap(parsed as? [String: Any], "失败正文不是 JSON 对象：\(raw)")
    }
}
