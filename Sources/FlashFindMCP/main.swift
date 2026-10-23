import Foundation
import FlashFindCore
import MCP

// `flashfind-mcp`：MCP 客户端（Claude Code / Codex / Cursor…）用 stdio 拉起的助手。
//
// ★ 本文件**只做装配**：建 server、挂两个 handler、跑 stdio。所有判断都在
//   `FlashFindCore`（§11.1）——这里出现一个 `if` 就说明有逻辑漏到不可测的位置了。
//
// ★ stdout 归 SDK 独占：`StdioTransport` 只往 stdout 写 JSON-RPC 报文。
//   本文件的所有诊断走 stderr，且不超过 3 行（§8.3）。**不许出现 `print(`**——
//   一句调试输出就能让客户端连不上，而报错信息不会指向我们（结构测试守着）。

/// 启动诊断。只写 stderr，不缓冲到退出——用户贴日志时就在眼前。
func note(_ line: String) {
    FileHandle.standardError.write(Data(("flashfind-mcp: " + line + "\n").utf8))
}

// 权威端 socket 的位置。
//
// ★ 开发构建允许用 `FF_AUTHORITY_SOCKET` 指到临时路径：`MCPStdioTests` 要跑真实
//   二进制，而「App 没在跑 → flashfind_app_unavailable」这条断言在开发机上会
//   随手边那份闪寻是开是关而变红变绿。**发布构建里这段被编译掉**（`#if DEBUG`），
//   产品二进制只会连标准路径，不读环境变量。
let socketPath: String = {
    #if DEBUG
    if let override = ProcessInfo.processInfo.environment["FF_AUTHORITY_SOCKET"],
       !override.isEmpty {
        return override
    }
    #endif
    return AuthoritySocketPath.standard()
}()

// 执行端是**真实的 socket 客户端**：每次请求新建一条连接，不缓存 fd——
// App 重启后同一个助手进程的下一次请求自动恢复（§1.5）。
//
// ★ 权限判定不在这里（v0.18 撤回 `facts`）：助手不读设置、不读来源清单、
//   不产生授权范围，只把 Agent 的原话搬过去（§5.2.2）。所以：
//
//     App 没在跑      → flashfind_app_unavailable（唯一诚实的说法：权威端不可达）
//     App 在跑、AI 关  → mcp_disabled（由 App 按实时设置判出来）
//
//   6.1 这里曾经硬写 `PermissionFacts(mcpEnabled: false, …)`，让每个
//   `tools/call` 都回 `mcp_disabled`。那不是「fail closed 的事实」，是 Helper
//   在替 App 宣布「用户关了 AI」——它没有任何依据，只是猜了个最安全的值。
// ★ History 的 session 标识 = **本进程**的生命周期（§6.4 / §7a）。
//   它在进程启动时定下一次，之后只读——所以「重启 Helper 就是换一个 session」。
//   ★ 绝不能拿 `AuthorityWire.Request.id` 顶替：那是「每次调用」的 owner（§4.7），
//     两者混了，`located` 的「同 session 同文件只记一次」立刻失真。
let history = HistoryContextSource()

let handler = MCPHandler(link: UnixSocketAuthorityLink(path: socketPath), history: history)

let server = Server(name: MCPHandler.serverName,
                    version: MCPHandler.serverVersion,
                    instructions: MCPHandler.instructions,
                    // 六个 Tool 是静态的，不会中途变化：`listChanged: false` 是承诺，
                    // 不是默认值——声明 true 却从不发通知，客户端会一直等。
                    capabilities: .init(tools: .init(listChanged: false)))

await server.withMethodHandler(ListTools.self) { _ in handler.listTools() }
await server.withMethodHandler(CallTool.self) { parameters in
    await handler.callTool(parameters)
}

// 传输层外包一层兼容清洗（Phase 11-lite）。
//
// ★ 起因：swift-sdk 0.12.1 把 `capabilities.experimental` 建模成 `[String: String]?`，
//   而 MCP 规范允许它的值是任意 JSON。Codex 发 `{"codex/auth-change": {}}`，
//   于是整个 `initialize` 解码失败、握手回 -32603，客户端连 Tools 都列不出来。
//   实测上游 `main` 声明未变，升级解决不了 → 在我们这边兜。
// ★ 只洗入站、只洗这一个字段，规则与证据见 `ClientCapabilitySanitizer`。
let transport = SanitizingTransport(wrapping: StdioTransport())

note("starting \(MCPHandler.serverName) \(MCPHandler.serverVersion) over stdio")

do {
    // ★ `agent_id` 只在握手时记一次，来自客户端自报的 clientInfo。
    //   它可以被伪造，但伪造的后果只落在 History 的标签上（§7a）。
    try await server.start(transport: transport, initializeHook: { info, _ in
        handler.noteClient(name: info.name, version: info.version)
    })
    await server.waitUntilCompleted()
} catch {
    // 传输层起不来（stdin 被关掉、fd 不是管道…）是致命错误：不能退出码 0，
    // 否则客户端只会看到「连上了但没响应」，而把这件事记成我们的 bug。
    note("stdio transport failed: \(error)")
    exit(1)
}
