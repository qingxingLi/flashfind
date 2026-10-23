import XCTest
@testable import FlashFindCore

/// Phase 5.5 的结构边界（方案 §11.2 的三条结构测试 + 5.5 新增两条）。
///
/// ## 为什么这些只能扫源码
///
/// `FlashFindMCP` 是 executableTarget，testTarget 依赖不了它；而这几条守的
/// 都不是「算错了」，是「放错了地方」——SDK 渗进业务层、一句 `print` 写进 stdout、
/// 协议版本被抄成第二份。这类问题编译能过、单测能绿，只有人工看代码才发现。
///
/// 扫源码时必须**跳过整行注释**，否则谁在注释里提一句 `import MCP` 就会误报
/// （`AppLayerStructureTests` / `NoKeychainAccessTests` 都踩过这个坑）。
final class MCPBoundaryTests: XCTestCase {

    /// 测试文件在 `client/Tests/FlashFindCoreTests/`，上溯三级是 `client/`。
    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // client
    }

    // MARK: - 取源码

    private func swiftFiles(in directory: String) throws -> [URL] {
        let root = clientRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root,
                                                          includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" {
            files.append(url)
        }
        return files.sorted { $0.path < $1.path }
    }

    /// 去掉整行注释为空的行，留下真正的代码。
    ///
    /// 只去整行注释、不去行尾注释：行尾注释里的 `print(` 也值得被看见，
    /// 而误报的代价只是让人改一下注释写法。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func code(of relativePath: String) throws -> String {
        let url = clientRoot.appendingPathComponent(relativePath)
        return codeOnly(try String(contentsOf: url, encoding: .utf8))
    }

    private func sources(in directory: String) throws -> [(path: String, code: String)] {
        try swiftFiles(in: directory).map { url in
            let text = codeOnly(try String(contentsOf: url, encoding: .utf8))
            let relative = url.path.replacingOccurrences(of: clientRoot.path + "/", with: "")
            return (relative, text)
        }
    }

    // MARK: - 0. 扫描本身必须读到东西

    /// 读不到文件时，下面所有「不含 XX」的断言都会假绿。先守住扫描。
    func testScanActuallyReadsTheSources() throws {
        let core = try sources(in: "Sources/FlashFindCore")
        let helper = try sources(in: "Sources/FlashFindMCP")

        XCTAssertGreaterThan(core.count, 40, "Core 的源码没扫全")
        XCTAssertEqual(helper.count, 1, "FlashFindMCP 目前只有一个 main.swift")
        XCTAssertGreaterThan(core.map(\.code.count).reduce(0, +), 50_000, "读到的是空壳")
    }

    // MARK: - 1. SDK 只许出现在三个文件里

    /// `import MCP` 只能出现在：
    ///
    /// ```text
    /// Sources/FlashFindCore/MCP/MCPHandler.swift        ← Core 里的 Tool 适配层
    /// Sources/FlashFindCore/MCP/SanitizingTransport.swift ← 传输层适配器（Phase 11-lite）
    /// Sources/FlashFindMCP/main.swift                    ← 可执行文件的装配
    /// ```
    ///
    /// ★ 这条同时守住了「不要同时保留两个 SDK 入口」：5.1 的临时 target `MCPLink`
    /// 已经删除，它要是被谁加回来，这里会变成第四个文件。
    ///
    /// ★ 为什么 `SanitizingTransport` 允许进名单：它 `where` 不了 SDK——`Transport`
    /// 是 SDK 的协议，实现它就必须 import。`ClientCapabilitySanitizer`（真正的清洗
    /// 规则）反而是纯 Foundation 的，故意不带 SDK，这样规则本身可以被单测逐条压。
    /// 业务三层仍然不认识 SDK，见下一条。
    func testTheSDKIsImportedInExactlyThreeFiles() throws {
        var importers: [String] = []
        for (path, code) in try sources(in: "Sources") {
            let importsSDK = code.split(separator: "\n").contains {
                $0.trimmingCharacters(in: .whitespaces) == "import MCP"
            }
            if importsSDK { importers.append(path) }
        }

        XCTAssertEqual(importers.sorted(),
                       ["Sources/FlashFindCore/MCP/MCPHandler.swift",
                        "Sources/FlashFindCore/MCP/SanitizingTransport.swift",
                        "Sources/FlashFindMCP/main.swift"],
                       "SDK 被拿到了别的文件里：\(importers)")
    }

    /// 业务三层（schema / 路由 / 权限）必须**完全不认识 SDK**。
    ///
    /// 这三层是 1.1.2 里唯一能被红证覆盖的地方（§8.5）。它们一旦 `import MCP`，
    /// SDK 升级就会把红证一起拖下水——而那些用例测的是我们自己的契约。
    func testBusinessLayersDoNotKnowTheSDK() throws {
        let files = ["Sources/FlashFindCore/ToolSchema.swift",
                     "Sources/FlashFindCore/ToolRouter.swift",
                     "Sources/FlashFindCore/PermissionPolicy.swift",
                     "Sources/FlashFindCore/MCP/AuthorityLink.swift"]

        for path in files {
            let text = try code(of: path)
            XCTAssertFalse(text.isEmpty, "没读到 \(path)，这条断言会假绿")
            for marker in ["import MCP", "ListTools", "CallTool", "MCPError", "jsonrpc"] {
                XCTAssertFalse(text.contains(marker),
                               "\(path) 里出现了 SDK/协议痕迹「\(marker)」")
            }
        }
    }

    /// Router 不认识 JSON-RPC：错误码是 §4.2 的字符串，不是 `-32601` 那种数字。
    ///
    /// `-32601` 一旦进了 Core，就说明协议层的事漏进了业务层——那时「未知 Tool」
    /// 与「未知方法」会被同一个枚举表示，二者再也分不开。
    func testTheRouterNeverSpeaksJSONRPC() throws {
        for (path, text) in try sources(in: "Sources/FlashFindCore") {
            guard !path.hasSuffix("MCP/MCPHandler.swift") else { continue }
            for code in ["-32601", "-32602", "-32603", "-32700"] {
                XCTAssertFalse(text.contains(code), "\(path) 里出现了 JSON-RPC 错误号 \(code)")
            }
        }
    }

    // MARK: - 2. 协议版本不许手写

    /// 协议版本**只能**来自 SDK（`Version` 那一侧），Core 与助手源码里不许出现
    /// 形如 `2025-11-25` 的字面量。
    ///
    /// ★ 这条不是洁癖：SDK 升级时版本号跟着它走，我们手写一份就必然滞后；
    /// 而滞后的表现是「新客户端连不上」，报错还指不到我们（§8.1）。
    func testProtocolVersionIsNeverHardcoded() throws {
        let pattern = try NSRegularExpression(pattern: #"\b20\d\d-\d\d-\d\d\b"#)
        for directory in ["Sources/FlashFindCore", "Sources/FlashFindMCP"] {
            for (path, text) in try sources(in: directory) {
                let range = NSRange(text.startIndex..., in: text)
                let hits = pattern.matches(in: text, range: range).count
                XCTAssertEqual(hits, 0,
                               "\(path) 里手写了协议版本日期字面量——它只能来自 SDK 的 Version")
            }
        }
    }

    // MARK: - 3. stdout 只许有协议

    /// 助手源码里**禁止一切往 stdout 写东西**的入口。
    ///
    /// 一句调试 `print` 就能让客户端解析失败、整个功能不可用，而报错信息
    /// 不会指向我们的代码（§8.3）。允许的只有 `FileHandle.standardError`。
    func testTheHelperWritesNothingButProtocolToStdout() throws {
        let forbidden = ["print(", "debugPrint(", "dump(", "FileHandle.standardOutput",
                         "standardOutput", "stdout", "fputs("]
        for (path, text) in try sources(in: "Sources/FlashFindMCP") {
            for marker in forbidden {
                XCTAssertFalse(text.contains(marker),
                               "\(path) 里出现了往 stdout 写的入口「\(marker)」——"
                               + "stdout 只归 SDK 的 stdio transport")
            }
        }
        // 「扫描真的读到了文件」由 `testScanActuallyReadsTheSources` 守（它断言只有
        // 一个 main.swift），所以上面的循环不会是空循环。
        //
        // ★ 这里只在 main.swift 上要求「诊断走 stderr」：将来若有人加第二个文件
        //   （比如一个纯函数的工具文件），它不需要往 stderr 写任何东西，
        //   一刀切会逼人加一句毫无意义的日志来凑测试。
        let main = try code(of: "Sources/FlashFindMCP/main.swift")
        XCTAssertTrue(main.contains("FileHandle.standardError"),
                      "启动诊断应当写 stderr（§8.3）")
    }

    /// 助手源码里不许出现 `if`/`switch` 级别的判断？——不测这个：
    /// 「薄层」靠代码审查，靠正则去数 `if` 只会逼人写坏代码。
    /// 这里只测一条能机械验证的：**handler 不许自带 schema**。
    func testHandlerCarriesNoSecondSchema() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/MCPHandler.swift")

        XCTAssertTrue(text.contains("ToolCatalog.all"),
                      "tools/list 必须从 ToolCatalog 生成，不能另写一份")
        for marker in ["ToolSchema(", "ToolParameter(", "LimitRange("] {
            XCTAssertFalse(text.contains(marker),
                           "handler 里出现了「\(marker)」——schema 的第二份副本就是这么长出来的")
        }
    }

    // MARK: - 4. 6.2：权限判定只能发生在 App authority（方案 §5.2.2 / §14.3.5）

    /// ★ Helper 侧**不许**出现权限事实与工具语义的名字。
    ///
    /// 守的是 v0.17 撤回的那个错误：`facts` 让 App 交出事实、Helper 自己算授权范围，
    /// 实际就成了「事实在 App、决定在 Helper」；再加上 `facts → 判断 → 真请求`
    /// 之间的 TOCTOU 窗口，撤销授权可能被绕过。
    ///
    /// 决定性理由（§5.2.2）：socket 只校验同 UID，**任何同 UID 进程都能连**，
    /// 所以「Helper 已经解析并授权过的请求」在 App 眼里没有任何额外可信度。
    /// App 必须从原始参数重新解析，Helper 侧再解析一次纯属第二份语义。
    ///
    /// ★ 按文件切块扫，不用整棵树 `contains`：同名的类型在 App 侧是合法的，
    /// 全局扫会把 `AIAccessController` 之类一起判红。
    /// ★ 只扫代码行：文件头的说明性注释（`///`）里提到这些名字是**应该**的，
    /// 那条注释正是写给下一个想加 `facts` 的人看的。
    func testHelperSourcesDoNotReferencePermissionOrRouting() throws {
        var files = try sources(in: "Sources/FlashFindMCP")
        files.append(("Sources/FlashFindCore/MCP/MCPHandler.swift",
                      try code(of: "Sources/FlashFindCore/MCP/MCPHandler.swift")))

        // 反向守一道：确认真的读到了助手的装配文件（否则下面的循环是空转）。
        XCTAssertTrue(files.contains { $0.code.contains("UnixSocketAuthorityLink") },
                      "没读到 helper 的装配文件，这条断言会假绿")

        let forbidden = ["PermissionPolicy", "PermissionFacts", "PermissionDecision",
                         "AIAccessStore", "AIAccessSettings", "UserDefaults",
                         "ClientPreferences", "ToolRouter", "AuthorizationScope",
                         "AuthorityRequest", "ToolCall"]
        for (path, text) in files {
            XCTAssertFalse(text.isEmpty, "没读到 \(path)，这条断言会假绿")
            for marker in forbidden {
                XCTAssertFalse(text.contains(marker),
                               "\(path) 里出现了「\(marker)」——权限判定与工具语义只能在 App authority 里")
            }
        }
    }

    /// 报文里没有 `facts` 这个操作。**永远不做**：它就是把判定点挪回 Helper 的那个口子。
    func testAuthorityWireHasNoFactsOperation() throws {
        let wire = try code(of: "Sources/FlashFindCore/MCP/AuthorityWire.swift")
        XCTAssertFalse(wire.contains("\"facts\""), "报文层出现了 facts 操作")
        XCTAssertFalse(wire.contains("case facts"), "报文层出现了 facts 操作")
        XCTAssertFalse(AuthorityWire.Operation.allCases.contains { $0.rawValue == "facts" },
                       "Operation 里出现了 facts")
    }

    /// 报文里没有授权范围这个类型，`AuthorityJob` 也不许跨进程传 `sourceIDs`。
    ///
    /// ★ `source_ids` 作为**参数**是合法的（Agent 可以点名想搜哪些来源），
    /// 但它的含义是「请求」，不是「已批准」——App 收到后仍要走一遍判定。
    func testWireCarriesNoAuthorizationScope() throws {
        let wire = try code(of: "Sources/FlashFindCore/MCP/AuthorityWire.swift")
        XCTAssertFalse(wire.contains("AuthorizationScope"),
                       "报文层出现了授权范围类型：scope 只能在 App authority 里产生")
        XCTAssertFalse(wire.contains("scope"),
                       "报文层还在提「scope」——那是 App 内部的概念，不该出现在线上")

        let service = try code(of: "Sources/FlashFindCore/MCP/AuthorityService.swift")
        XCTAssertFalse(service.contains("sourceIDs"),
                       "AuthorityJob 还在跨进程传授权范围（sourceIDs）")
    }

    /// 线上 op 的闭集恒等于「六个 Tool 名 + ping」。
    ///
    /// `ping` 不是第七个 Tool：它回答「权威端还活着吗」，业务没接上时也必须答得出来
    /// （启动时的 stale 判定靠它）。做成 Tool 会让 Agent 以为有个叫 ping 的搜索工具。
    func testOperationSetEqualsSixToolsPlusPing() {
        let expected = Set(ToolCatalog.all.map(\.name))
            .union([AuthorityWire.Operation.ping.rawValue])
        XCTAssertEqual(Set(AuthorityWire.Operation.allCases.map(\.rawValue)), expected,
                       "线上 op 集合与 ToolCatalog 分叉了")
        XCTAssertEqual(ToolCatalog.all.count, 6)
    }

    /// `AuthoritySmoke` 只能是开发/测试工具：**不进 `products`**。
    ///
    /// 它是「第二个能向 authority socket 发请求的二进制」。§5.2.2 已经承认
    /// 「任何同 UID 进程都能连 socket」，我们能控制的只有**别主动多分发一个**——
    /// 尤其别让它被打进签名体系，那会让它看起来像产品的一部分。
    func testAuthoritySmokeIsNotAProduct() throws {
        let manifest = try code(of: "Package.swift")
        let products = try bracketedBlock(in: manifest, anchor: "products: [")
        XCTAssertFalse(products.contains("AuthoritySmoke"),
                       "开发期工具进了 products：它会变成被签名的产品的一部分")

        // 反向守一道：这个 target 本身还在（否则上面的断言靠「删掉它」也能绿）。
        XCTAssertTrue(manifest.contains(#"executableTarget(name: "AuthoritySmoke""#),
                      "AuthoritySmoke 应当仍以开发期 target 存在（Phase 6.1 的跨进程冒烟入口）")
    }

    // MARK: - 传输层：accepted fd 也必须关 SIGPIPE（Phase 6.3b-1 实测踩到）

    /// `acceptPending()` 取到一条连接之后，**在交给后台队列之前**必须设 `SO_NOSIGPIPE`。
    ///
    /// ## 为什么这条只能扫源码
    ///
    /// 它的**行为**证明是：客户端发完就走 → 监听端往已经关掉的 fd 写回包 →
    /// 没有这个选项，`write` 直接给进程一个 `SIGPIPE`，整个 App 消失（信号 13，
    /// 连 crash log 都没有）。而测试进程和监听端是同一个进程，所以那个证明一旦
    /// 跑起来就是**进程级死亡**，只能单跑（`tools/mutate_each_mapped.py` 里登记）——
    /// 放进批跑会让它后面所有用例都不再执行，红证于是变成一片假 MISS。
    ///
    /// 批跑这边守的是「这一行还在，而且仍在 `accept` 之后、交给队列之前」。
    /// ★ 用括号配平切出 `acceptPending()` 的函数体再查，不用全文 `contains`：
    /// `FileSecretStore` 之类的文件里也可能出现同名调用，全局扫会把它们一起算进来。
    func testTheAcceptedSocketSuppressesSIGPIPEToo() throws {
        let listener = try code(of: "Sources/FlashFindCore/MCP/AuthorityListener.swift")
        let body = try braceBalancedBlock(in: listener, anchor: "private func acceptPending()")

        guard let accept = body.range(of: "accept(listenFD") else {
            return XCTFail("acceptPending 里没有 accept(listenFD)：这条断言会假绿")
        }
        guard let suppress = body.range(of: "UnixSocket.suppressSIGPIPE(client)") else {
            return XCTFail("accepted fd 没有关 SIGPIPE：客户端提前断开就会打死 App")
        }
        guard let handoff = body.range(of: "connectionQueue.async") else {
            return XCTFail("acceptPending 里没有把连接交给后台队列：这条断言会假绿")
        }
        XCTAssertLessThan(accept.lowerBound, suppress.lowerBound,
                          "必须先 accept 拿到 fd，再给它设选项")
        XCTAssertLessThan(suppress.lowerBound, handoff.lowerBound,
                          "设选项必须发生在交给后台队列之前——serve 里马上就要用它写回包")
    }

    /// 阻塞式 socket 读写不许占用 Swift 并发的**协作线程池**（2026-10-23 公开仓 CI 首跑）。
    ///
    /// 症状：8 个并发请求在 3 核 runner 上 6 个报 `timeout`，同一条用例在本机 10 核
    /// 恒绿。根因不是「算得慢」，是**放错了地方**：`Task.detached` 跑在协作池上，
    /// 池宽≈活跃核心数且不允许阻塞；调用端一多就把池占满，服务端自己的
    /// `Task.detached { await service.handle(job) }` 也在同一个池里，于是抢不到线程。
    ///
    /// 所以这条断言锁的不是性能数字，是放置位置：阻塞往返必须在 GCD 队列上。
    ///
    /// ★ 用括号配平只切 `call(...)` 这一支，不用全文 `contains`：将来别处新增一个
    /// 低频的 `Task.detached`（比如探活）不该由这条用例判红，反过来
    /// `roundTrip` 在别处被同步调用也不归它管。
    func testTheBlockingRoundTripIsNotParkedOnACooperativeThread() throws {
        let link = try code(of: "Sources/FlashFindCore/MCP/UnixSocketAuthorityLink.swift")
        let body = try braceBalancedBlock(in: link, anchor: "public func call(tool: String")

        XCTAssertFalse(body.contains("Task.detached"),
                       """
                       阻塞读又回到了 Task.detached 上。协作线程池宽度≈核心数且不允许阻塞，
                       并发一多就会把服务端的业务 Task 饿死（CI 三核必红，本机十核看不出来）。
                       阻塞 I/O 要放到 GCD 队列：它允许 overcommit，也不参与协作池。
                       """)
        guard body.range(of: "Self.ioQueue.async") != nil else {
            return XCTFail("call 没有把往返派到 ioQueue：这条断言会假绿")
        }

        // 队列本身必须是 concurrent：串行队列会把 N 个并发请求排成一队。那样不会超时
        // （每个都很快），但「并发」被悄悄降级成「串行」，是另一类退化。
        guard let queue = link.range(of: "private static let ioQueue = DispatchQueue(") else {
            return XCTFail("找不到 ioQueue 的定义：这条断言会假绿")
        }
        let definition = String(link[queue.lowerBound...].prefix(240))
        XCTAssertTrue(definition.contains("attributes: .concurrent"),
                      "ioQueue 必须声明 .concurrent，否则并发请求会被排成一队")
    }

    /// 打包脚本不许拷贝任何开发期工具（Phase 10 加 `Contents/Helpers/` 时的闸）。
    func testPackagingScriptDoesNotCopyDevTools() throws {
        let url = clientRoot.appendingPathComponent("scripts/build_trial.py")
        let script = try String(contentsOf: url, encoding: .utf8)
        XCTAssertGreaterThan(script.count, 2_000, "没读到打包脚本，这条断言会假绿")
        for marker in ["AuthoritySmoke", "DevTools"] {
            XCTAssertFalse(script.contains(marker),
                           "打包脚本里出现了「\(marker)」：开发期工具不许进 .app")
        }
    }

    /// 打包脚本必须先签 Helper、再签主 App。
    ///
    /// 主 App 的签名会把 `Contents/` 下每个文件的内容纳入封存。反过来做（先签 App、
    /// 再签 Helper），App 的封存记的是「签它的那一刻 Helper 的样子」，之后再动 Helper
    /// 就对不上了。而这件事**本机未必当场炸**：`codesign --verify --strict` 有时仍过，
    /// 真正拒的是别人机器上的 Gatekeeper。
    ///
    /// 顺序写反不会有任何编译错误、也不会有任何行为测试变红，只能对源码验——
    /// 所以这条断言直接钉住脚本里那两行的先后。
    func testPackagingScriptSignsHelperBeforeTheApp() throws {
        let script = try String(contentsOf: clientRoot.appendingPathComponent("scripts/build_trial.py"),
                                encoding: .utf8)
        guard let helper = script.range(of: "run(sign_arguments(helpers / HELPER_NAME), 'sign-helper')") else {
            return XCTFail("打包脚本里没有单独签 Helper 的那一步：Helper 要么没签，要么被别的步骤顺手带过")
        }
        guard let app = script.range(of: "run(sign_arguments(app), 'sign')") else {
            return XCTFail("打包脚本里没有签主 App 的那一步")
        }
        XCTAssertLessThan(helper.lowerBound, app.lowerBound,
                          "必须先签 Helper 再签主 App：反过来的话 App 的封存记的是旧 Helper")
    }

    // MARK: - 小工具

    /// 从锚点（含左括号）开始配平取一整段。`products: [` 这种块没法用行号切。
    private func bracketedBlock(in text: String, anchor: String) throws -> String {
        guard let start = text.range(of: anchor) else {
            throw BlockNotFound(anchor: anchor)
        }
        var depth = 0
        var index = start.lowerBound
        while index < text.endIndex {
            let character = text[index]
            if character == "[" { depth += 1 }
            if character == "]" {
                depth -= 1
                if depth == 0 { return String(text[start.lowerBound...index]) }
            }
            index = text.index(after: index)
        }
        throw BlockNotFound(anchor: anchor)
    }

    /// 从锚点开始的**花括号**块（函数体），配平取整段。
    ///
    /// `bracketedBlock` 只认 `[`，函数体得用这个：否则「`acceptPending()` 里到底
    /// 有没有那一行」就只能退回全文 `contains`——而全文 `contains` 不是证据。
    private func braceBalancedBlock(in text: String, anchor: String) throws -> String {
        guard let hit = text.range(of: anchor) else {
            throw BlockNotFound(anchor: anchor)
        }
        guard let open = text[hit.upperBound...].firstIndex(of: "{") else {
            throw BlockNotFound(anchor: anchor)
        }
        var depth = 0
        var index = open
        while index < text.endIndex {
            let character = text[index]
            if character == "{" { depth += 1 }
            if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[open...index]) }
            }
            index = text.index(after: index)
        }
        throw BlockNotFound(anchor: anchor)
    }

    private struct BlockNotFound: Error, CustomStringConvertible {
        let anchor: String
        var description: String { "找不到配平的块：\(anchor)" }
    }
}
