import XCTest
@testable import FlashFindCore

/// Phase 5.5 的端到端验收：跑**真实二进制**，用管道喂报文（方案 §8.3 / §11.3）。
///
/// 前面两个文件测的是「我们的代码对不对」，这里测的是「装出来的那个东西对不对」：
///
/// ```text
/// stdout  ← 每一行都必须是 JSON-RPC（一条都不能是日志、banner、调试输出）
/// stderr  ← 启动诊断，最多 3 行
/// tools/call → App 没在跑时必须 fail closed（flashfind_app_unavailable），不许假装搜过
/// ```
///
/// ★ 为什么非要起进程：`print` 混进 stdout 这件事，只有在真实管道里才看得见。
/// 在进程内测（`InMemoryTransport`）时 SDK 根本不碰 fd 1，那句 `print` 照样绿。
final class MCPStdioTests: XCTestCase {

    // MARK: - 用例

    /// stdout 的每一行都必须能被解析成 JSON-RPC 2.0 报文，且三条请求都有回音。
    func testStdoutCarriesOnlyProtocolFrames() throws {
        let run = try runHelper(with: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
            #"{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"locate","arguments":{"query":"年度报告"}}}"#,
        ], expectingResponses: 3)

        XCTAssertFalse(run.lines.isEmpty, "一条 stdout 都没收到（进程起不来？）")

        var byID: [Int: [String: Any]] = [:]
        for line in run.lines {
            let data = Data(line.utf8)
            guard let parsed = try? JSONSerialization.jsonObject(with: data),
                  let object = parsed as? [String: Any] else {
                return XCTFail("stdout 出现非 JSON 的一行：\(line)")
            }
            XCTAssertEqual(object["jsonrpc"] as? String, "2.0", "不是 JSON-RPC 报文：\(line)")
            if let id = object["id"] as? Int { byID[id] = object }
        }

        // ① initialize：能力与身份都要真的在线上。
        let initialized = try XCTUnwrap(byID[1]?["result"] as? [String: Any], "initialize 没有回音")
        XCTAssertEqual(initialized["protocolVersion"] as? String, "2025-06-18",
                       "客户端报的是 SDK 支持的版本，应当原样协商回去")
        let serverInfo = try XCTUnwrap(initialized["serverInfo"] as? [String: Any])
        XCTAssertEqual(serverInfo["name"] as? String, MCPHandler.serverName)
        let capabilities = try XCTUnwrap(initialized["capabilities"] as? [String: Any])
        XCTAssertNotNil(capabilities["tools"], "没声明 tools 能力，客户端不会显示任何 Tool")

        // ② tools/list：六个，名字与顺序来自 ToolCatalog。
        let listed = try XCTUnwrap(byID[2]?["result"] as? [String: Any], "tools/list 没有回音")
        let tools = try XCTUnwrap(listed["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.compactMap { $0["name"] as? String }, ToolCatalog.all.map(\.name))

        // ③ tools/call：这条用例把权威端指到一个不存在的 socket，必须 fail closed。
        //
        // ★ 6.2 起这里**不再**是 `mcp_disabled`：助手没有任何依据说「用户关了 AI」，
        //   它只知道权威端不可达。`mcp_disabled` 只能由 App 按实时设置判出来。
        let called = try XCTUnwrap(byID[3]?["result"] as? [String: Any], "tools/call 没有回音")
        XCTAssertEqual(called["isError"] as? Bool, true, "空执行端不可能成功")
        let content = try XCTUnwrap((called["content"] as? [[String: Any]])?.first)
        let body = try XCTUnwrap(content["text"] as? String)
        let parsed = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(body.utf8)) as? [String: Any])
        XCTAssertEqual(parsed["code"] as? String, "flashfind_app_unavailable",
                       "权威端不可达时必须如实说「闪寻没在跑」，不是空结果，也不是 mcp_disabled")

        // ④ stderr 允许有启动诊断，但**不许刷屏**（§8.3：不超过 3 行）。
        let stderrLines = run.stderr.split(separator: "\n").filter { !$0.isEmpty }
        XCTAssertLessThanOrEqual(stderrLines.count, 3,
                                 "stderr 超过 3 行了：\(run.stderr)")
        XCTAssertFalse(run.stderr.contains("jsonrpc"),
                       "协议报文跑到 stderr 去了")
    }

    /// 同一个二进制，一次只发 `initialize`：不能在 stdout 上多吐任何东西。
    ///
    /// 这条测的是「启动阶段」——启动日志是最容易顺手 `print` 的地方。
    func testStartupWritesNothingButTheResponse() throws {
        let run = try runHelper(with: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"tests","version":"0"}}}"#,
        ], expectingResponses: 1)

        XCTAssertEqual(run.lines.count, 1, "一次请求只许一行响应，多出来的是日志：\(run.lines)")
    }

    /// 真实客户端形态的握手：**Codex 的 `initialize` 必须被接住**（Phase 11-lite）。
    ///
    /// Codex（`codex-mcp-client`）会发 `capabilities.experimental` 里带对象值：
    ///
    /// ```json
    /// "experimental": { "codex/auth-change": {} }
    /// ```
    ///
    /// 而 swift-sdk 把该字段定成 `[String: String]?`，解码直接失败 → 握手回 -32603
    /// → 客户端一个 Tool 都看不到。这条用例跑的是**真的那个二进制**，
    /// 所以它能同时拦住两种退化：清洗层被摘掉、以及 `main.swift` 忘了换成
    /// `SanitizingTransport`（进程内单测拦不住后者）。
    func testCodexShapeInitializeIsAccepted() throws {
        let run = try runHelper(with: [
            #"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.163.0-alpha.11"}}}"#,
            #"{"jsonrpc":"2.0","method":"notifications/initialized"}"#,
            #"{"jsonrpc":"2.0","id":2,"method":"tools/list"}"#,
        ], expectingResponses: 2)

        let parsed = try run.lines.map { line -> [String: Any] in
            let object = try JSONSerialization.jsonObject(with: Data(line.utf8))
            return try XCTUnwrap(object as? [String: Any], "stdout 出现非 JSON 的一行：\(line)")
        }
        let initialize = try XCTUnwrap(parsed.first { $0["id"] as? Int == 1 })
        XCTAssertNil(initialize["error"],
                     "Codex 形态的 initialize 被拒了：\(initialize["error"] ?? [:])")
        let result = try XCTUnwrap(initialize["result"] as? [String: Any], "没有 result")
        let serverInfo = try XCTUnwrap(result["serverInfo"] as? [String: Any])
        // ★ 期望值从**版本唯一事实来源**读，不用 `MCPHandler.serverVersion`：
        //   后者在测试进程里算的是测试宿主（实测报 16.0），不是 Helper 二进制里的值。
        //   断言真正的那个进程报了「包里的版本」，才算验到东西。
        XCTAssertEqual(serverInfo["version"] as? String, try packagingVersion())

        let listed = try XCTUnwrap(parsed.first { $0["id"] as? Int == 2 }?["result"] as? [String: Any])
        XCTAssertEqual((listed["tools"] as? [[String: Any]])?.count, 6,
                       "握上手之后必须能列出六个 Tool")
    }

    // MARK: - 起进程

    private struct Run {
        let lines: [String]
        let stderr: String
        let status: Int32
    }

    private struct HelperMissing: Error, CustomStringConvertible {
        let searched: [String]
        var description: String {
            "找不到已构建的 FlashFindMCP（找过：\(searched.joined(separator: "、"))）。"
            + "先跑 `swift build --product FlashFindMCP`，或设 FLASHFIND_MCP_BINARY 指过去。"
        }
    }

    private func runHelper(with requests: [String], expectingResponses expected: Int) throws -> Run {
        let binary = try builtHelper()
        let process = Process()
        process.executableURL = binary
        // ★ 把权威端指到一个不存在的路径：开发机上很可能真的有一份闪寻开着，
        //   不隔离的话「App 没在跑」这条断言会随那台机器的状态时红时绿。
        //   助手只在 DEBUG 构建里读这个变量（`main.swift` 的 `#if DEBUG`）。
        process.environment = ProcessInfo.processInfo.environment.merging(
            ["FF_AUTHORITY_SOCKET": uniqueMissingSocketPath()]) { _, new in new }

        let stdinPipe = Pipe()
        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardInput = stdinPipe
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        try process.run()

        // 两个管道都要有人读：只读 stdout 的话，stderr 写满 64 KB 会把子进程堵死。
        let stdoutBox = BufferBox()
        let stderrBox = BufferBox()
        drain(stdoutPipe.fileHandleForReading, into: stdoutBox)
        drain(stderrPipe.fileHandleForReading, into: stderrBox)

        for request in requests {
            stdinPipe.fileHandleForWriting.write(Data((request + "\n").utf8))
        }

        // 等到响应行数够了就收工；不够也要在 15 s 后收工，否则用例会挂住整条回归。
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, stdoutBox.lines.count < expected {
            Thread.sleep(forTimeInterval: 0.02)
        }

        // ★ 收完响应后**关掉 stdin**，让助手自己退出。
        //
        // 这一步不是收尾礼仪，是「stdout 无杂音」这条断言能成立的前提：
        // `print(...)` 走的是 libc 的 FILE* 缓冲，stdout 接管道时是**块缓冲**，
        // 一句几百字节的日志会一直躺在缓冲区里。SIGTERM 把进程打死，缓冲区
        // 一起消失 —— 用例就会对着一个被污染的二进制喊绿（实测过：
        // 把启动行改成 `print`，端到端用例照样通过）。正常退出才会 flush。
        try? stdinPipe.fileHandleForWriting.close()

        let exitDeadline = Date().addingTimeInterval(3)
        while Date() < exitDeadline, process.isRunning {
            Thread.sleep(forTimeInterval: 0.02)
        }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()

        // 收尾：把最后一批输出读干净（EOF 在进程退出之后到达）。
        let settle = Date().addingTimeInterval(2)
        while Date() < settle, !stdoutBox.finished {
            Thread.sleep(forTimeInterval: 0.02)
        }

        return Run(lines: stdoutBox.lines,
                   stderr: stderrBox.text,
                   status: process.terminationStatus)
    }

    /// 后台把管道读空。阻塞式 `availableData` 放在全局并发队列上跑，
    /// 子进程退出（EOF）后自然结束。
    private func drain(_ handle: FileHandle, into box: BufferBox) {
        DispatchQueue.global().async {
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                box.append(chunk)
            }
            box.finish()
        }
    }

    /// 跨线程累积管道输出。锁而不是 actor：读端在 GCD 队列上，用例在测试线程上，
    /// 用 actor 会让「等一下再看」变成一堆 await。
    private final class BufferBox: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = Data()
        private var isFinished = false

        func append(_ chunk: Data) {
            lock.lock()
            buffer.append(chunk)
            lock.unlock()
        }

        func finish() {
            lock.lock()
            isFinished = true
            lock.unlock()
        }

        var finished: Bool {
            lock.lock()
            defer { lock.unlock() }
            return isFinished
        }

        var text: String {
            lock.lock()
            defer { lock.unlock() }
            return String(decoding: buffer, as: UTF8.self)
        }

        var lines: [String] {
            text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        }
    }

    /// 一条**不存在**的 socket 路径。父目录也不用建：`connect` 直接 ENOENT。
    private func uniqueMissingSocketPath() -> String {
        "/tmp/ff-no-app-\(UUID().uuidString.prefix(8))/mcp.sock"
    }

    /// 包里的发布版本号，读 `Resources/Packaging/Info.plist`（版本唯一事实来源）。
    ///
    /// 走仓库真文件而不是 `Bundle.main`：测试进程的 `Bundle.main` 是测试宿主，
    /// 它的版本号与被测的 Helper 毫无关系。`HelperPackagingTests` 用同样的路子。
    private func packagingVersion() throws -> String {
        let client = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
        let plist = client.appendingPathComponent("Resources/Packaging/Info.plist")
        let data = try Data(contentsOf: plist)
        let parsed = try XCTUnwrap(
            try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        return try XCTUnwrap(parsed["CFBundleShortVersionString"] as? String,
                             "Info.plist 缺 CFBundleShortVersionString")
    }

    /// 找已构建的助手二进制。
    ///
    /// `swift test` 会构建整包（含 executableTarget），所以 `.build/debug/FlashFindMCP`
    /// 正常都在。找不到就**失败**而不是跳过——跳过等于「这条最重要的用例从来没跑过」。
    private func builtHelper() throws -> URL {
        if let override = ProcessInfo.processInfo.environment["FLASHFIND_MCP_BINARY"],
           !override.isEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isExecutableFile(atPath: url.path) { return url }
            throw HelperMissing(searched: [url.path])
        }

        let client = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
        let build = client.appendingPathComponent(".build")

        var candidates = [build.appendingPathComponent("debug/FlashFindMCP")]
        if let entries = try? FileManager.default.contentsOfDirectory(
            at: build, includingPropertiesForKeys: nil) {
            // 指定了三元组时路径是 .build/<triple>/debug/…，按名字排序保证可复现。
            for entry in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where entry.pathExtension.isEmpty {
                candidates.append(entry.appendingPathComponent("debug/FlashFindMCP"))
            }
        }

        for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
            return candidate
        }
        throw HelperMissing(searched: candidates.map(\.path))
    }
}
