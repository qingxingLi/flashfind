import XCTest
import MCP
@testable import FlashFindCore

/// Phase 5.5 验收：协议层真的能跑通（方案 §8.1 / §11.3）。
///
/// `MCPHandlerTests` 测的是「翻译对不对」，这里测的是「装上 SDK 的 `Server`
/// 之后，一条 JSON-RPC 报文进、一条报文出」——`initialize` 能完成、
/// `tools/list` 与 `tools/call` 在**线路上**是同一个答案。
///
/// ★ 装配这几行在这里**又写了一遍**（建 `Server`、挂两个 handler），
/// 和 `Sources/FlashFindMCP/main.swift` 重复。这是有意的取舍：
/// `main.swift` 在 executableTarget 里，测试依赖不了它（§11.2），
/// 而把装配抽进 Core 就等于让 Core 暴露「怎么建 server」——那是可执行文件的事。
/// 重复的代价由 `MCPStdioTests` 兜住：那两条用例跑的是**真实二进制**，
/// `main.swift` 装配错了它们会红。两份覆盖的不是同一件事，谁也替不了谁。
final class MCPServerTests: XCTestCase {

    /// 假执行端：记录「工具名 + 原始参数」，回可配置的结果。
    private final class RecordingLink: AuthorityLink, @unchecked Sendable {

        struct Call: Equatable {
            let tool: String
            let arguments: ToolArguments
            let context: HistoryContext?
        }

        private let lock = NSLock()
        private var recorded: [Call] = []
        var outcome: ToolOutcome = .success(json: #"{"ok":true,"results":[]}"#)

        init(outcome: ToolOutcome? = nil) {
            if let outcome { self.outcome = outcome }
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

    /// 与 `main.swift` 相同的 `Server` 构造（handler 由调用方给）。
    private func makeServer() -> Server {
        Server(name: MCPHandler.serverName,
               version: MCPHandler.serverVersion,
               instructions: MCPHandler.instructions,
               capabilities: .init(tools: .init(listChanged: false)))
    }

    /// 建好一对内存传输并完成握手。`initialize` 由官方 `Client` 发起——
    /// 用客户端库里那一份实现，而不是我们手写一份「像 initialize 的」报文。
    private func connect(link: any AuthorityLink) async throws
        -> (server: Server, client: Client, initialized: Initialize.Result) {

        let handler = MCPHandler(link: link)
        let server = makeServer()
        await server.withMethodHandler(ListTools.self) { _ in handler.listTools() }
        await server.withMethodHandler(CallTool.self) { parameters in
            await handler.callTool(parameters)
        }

        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        try await server.start(transport: serverTransport)

        let client = Client(name: "flashfind-tests", version: "0.0.0")
        let initialized = try await client.connect(transport: clientTransport)
        return (server, client, initialized)
    }

    // MARK: - initialize

    func testInitializeCompletesAndAdvertisesTools() async throws {
        let wired = try await connect(link: RecordingLink())

        // ★ 协议版本只能来自 SDK：`Version.supported` 是 SDK 自己协商用的那个集合。
        // 断言里写死一个 `2025-11-25` 就等于把版本钉在测试里——SDK 升级时
        // 我们要改测试，而不是发现「Server 回的其实是别的版本」。
        XCTAssertTrue(Version.supported.contains(wired.initialized.protocolVersion),
                      "握手回来的版本不在 SDK 的支持集合里：\(wired.initialized.protocolVersion)")
        XCTAssertEqual(wired.initialized.serverInfo.name, MCPHandler.serverName)
        XCTAssertEqual(wired.initialized.serverInfo.version, MCPHandler.serverVersion)
        XCTAssertEqual(wired.initialized.instructions, MCPHandler.instructions)
        XCTAssertNotNil(wired.initialized.capabilities.tools,
                        "没声明 tools 能力，客户端不会显示任何 Tool")
        XCTAssertEqual(wired.initialized.capabilities.tools?.listChanged, false,
                       "声明了 listChanged 却不发通知，客户端会一直等")

        await wired.client.disconnect()
        await wired.server.stop()
    }

    /// 未知版本必须**回落到 SDK 的最新版本**，而不是报错、也不是回一个空串。
    ///
    /// 这一段必须发原始报文：官方 `Client` 只会发 `Version.latest`，
    /// 走它永远测不到「对方报了个我们不认识的版本」。
    func testUnknownProtocolVersionFallsBackToTheSDKsLatest() async throws {
        let (clientTransport, serverTransport) = await InMemoryTransport.createConnectedPair()
        let server = makeServer()
        try await server.start(transport: serverTransport)
        try await clientTransport.connect()

        // ★ receive() 每次调用都会**换掉**内部 continuation，只能取一次。
        let incoming = await clientTransport.receive()
        let request = #"""
        {"jsonrpc":"2.0","id":7,"method":"initialize","params":{"protocolVersion":"1999-01-01","capabilities":{},"clientInfo":{"name":"raw","version":"0"}}}
        """#
        try await clientTransport.send(Data(request.utf8))

        let data = try await firstMessage(of: incoming)
        let message = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(message["jsonrpc"] as? String, "2.0", "线路上每一行都必须是 JSON-RPC 2.0")
        XCTAssertEqual(message["id"] as? Int, 7, "响应必须带回同一个 id")
        let result = try XCTUnwrap(message["result"] as? [String: Any])
        XCTAssertEqual(result["protocolVersion"] as? String, Version.latest,
                       "不认识的版本要回落到 SDK 的最新版本")

        await server.stop()
    }

    // MARK: - tools/list / tools/call

    func testToolsListOverTheWireMatchesTheCatalog() async throws {
        let wired = try await connect(link: RecordingLink())
        let listed = try await wired.client.listTools()

        XCTAssertEqual(listed.tools.map(\.name), ToolCatalog.all.map(\.name))
        XCTAssertNil(listed.nextCursor)

        await wired.client.disconnect()
        await wired.server.stop()
    }

    func testToolCallOverTheWireReachesTheLink() async throws {
        let link = RecordingLink()
        let wired = try await connect(link: link)

        let called = try await wired.client.callTool(
            name: "search",
            arguments: ["query": .string("年度报告"), "limit": .int(7)])

        XCTAssertEqual(called.isError, false)
        XCTAssertEqual(called.content.count, 1)
        guard case .text(let body, _, _) = try XCTUnwrap(called.content.first) else {
            return XCTFail("结果不是文本内容")
        }
        XCTAssertEqual(body, #"{"ok":true,"results":[]}"#, "适配层不许改写执行端给的结果")

        // ★ 线上走完一圈之后，App 收到的是**原话**：没 trim、没钳位、没补 source_ids。
        let call = try XCTUnwrap(link.calls.first)
        XCTAssertEqual(call.tool, "search")
        XCTAssertEqual(call.arguments, ["query": .string("年度报告"), "limit": .integer(7)])

        await wired.client.disconnect()
        await wired.server.stop()
    }

    /// 线上也不许出现「Tool 错误变协议错误」：客户端拿到的是 `isError: true` 的结果，
    /// 不是一次抛出来的 error（抛了就是 `-3260x`）。
    func testRejectedCallComesBackAsAToolErrorOverTheWire() async throws {
        let wired = try await connect(link: RecordingLink(
            outcome: .failure(code: "unknown_tool",
                              message: "Unknown tool 'no_such_tool'. Call tools/list to see the available tools.")))

        let called = try await wired.client.callTool(name: "no_such_tool")
        XCTAssertEqual(called.isError, true)
        guard case .text(let body, _, _) = try XCTUnwrap(called.content.first) else {
            return XCTFail("结果不是文本内容")
        }
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["code"] as? String, "unknown_tool")

        await wired.client.disconnect()
        await wired.server.stop()
    }

    // MARK: - 小工具

    private struct WireTimeout: Error {}

    /// 取第一条报文，带 10 s 上限——传输层真卡住时用例要失败，不能挂住整条回归。
    private func firstMessage(of stream: AsyncThrowingStream<Data, Error>) async throws -> Data {
        try await withThrowingTaskGroup(of: Data.self) { group in
            group.addTask {
                for try await message in stream { return message }
                throw WireTimeout()
            }
            group.addTask {
                try await Task.sleep(nanoseconds: 10 * 1_000_000_000)
                throw WireTimeout()
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw WireTimeout() }
            return first
        }
    }
}
