import XCTest
@testable import FlashFindCore

/// 核心进程生命周期的回归 —— 「核心重启后 Swift 还以为已连接」这一类。
///
/// 这里的故障有一个共同特征：**单次全绿，累积才发作，且表现为偶发**。
/// 进程外状态（helper 进程、DSM 上的 Search Task）不进 XCTest 的视野，
/// 所以只能靠「把代次变化显式建模 + 桩里模拟代次跳变」来锁。
@MainActor
final class CoreLifecycleTests: XCTestCase {

    /// 可脚本化、且**代次可变**的 Bridge 桩。
    ///
    /// `processGeneration` 故意做成可写：真实桥接层里它由进程生死驱动，
    /// 测试里我们直接模拟「核心重启了」这一个事实，不去真的起进程。
    private final class GenerationBridge: MyNASBridgeTransport {
        var processGeneration: Int = 1
        var responses: [String: [String: Any]] = [:]
        private(set) var calls: [String] = []

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(command)
            guard let response = responses[command] else {
                throw FlashFindError.message("未预期的命令：\(command)")
            }
            return response
        }
    }

    private func readyProvider(_ bridge: GenerationBridge) async throws -> NASSearchProvider {
        bridge.responses["login"] = ["event": "authState", "state": "scopeReady", "isManager": false]
        bridge.responses["selectScope"] = ["event": "scopeState", "state": "scopeReady",
                                           "scopes": ["/示例共享"]]
        let subject = NASSearchProvider(
            bridge: bridge,
            config: NASSourceConfig(host: "192.168.1.96", port: 5001,
                                    username: "nasuser", scopes: ["/示例共享"]),
            port: 5001)
        try await subject.login(account: "nasuser", password: "p")
        _ = try await subject.selectScopes(["/示例共享"])
        XCTAssertTrue(subject.ready, "前置：应已就绪")
        return subject
    }

    /// 核心没重启 ⇒ 已就绪的来源不该被判成失效。
    ///
    /// 这条是**防止矫枉过正**的：加了代次校验之后，最怕的是把健康连接
    /// 也一起判死，那会比原 bug 更糟（用户每次搜索都要重连）。
    func testHealthyConnectionIsNotMarkedStale() async throws {
        let bridge = GenerationBridge()
        let subject = try await readyProvider(bridge)

        XCTAssertFalse(subject.needsReconnectAfterCoreRestart, "代次没变就不该要求重连")
    }

    /// 核心重启 ⇒ 立即失效，且**不许再发搜索请求**。
    func testCoreRestartInvalidatesReadyState() async throws {
        let bridge = GenerationBridge()
        let subject = try await readyProvider(bridge)

        bridge.processGeneration = 2 // 核心重启
        XCTAssertTrue(subject.needsReconnectAfterCoreRestart, "代次一变就必须要求重连")

        var states: [ProviderSearchState] = []
        var messages: [String] = []
        await subject.search("报告", queryID: UUID()) { event in
            states.append(event.state); messages.append(event.message ?? "")
        }

        XCTAssertFalse(subject.ready, "★ 核心重启后必须立刻掉回未连接，不能继续显示已连接")
        XCTAssertEqual(states, [.failed], "应如实报失败并说明原因，而不是发一次注定失败的请求")
        XCTAssertTrue(messages.first?.contains("重新连接") == true, "提示必须说清要重新连接：\(messages)")
        XCTAssertFalse(bridge.calls.contains("search"), "★ 明知无效还发搜索请求，是这次要修的行为")
    }

    /// 复位之后不再重复触发：同一代次里连续搜索不应该每次都喊「核心重启」。
    func testStaleIsClearedAfterOneReport() async throws {
        let bridge = GenerationBridge()
        let subject = try await readyProvider(bridge)
        bridge.processGeneration = 2

        _ = await subject.searchCollecting("报告")
        XCTAssertFalse(subject.needsReconnectAfterCoreRestart, "复位后应同步到当前代次")
    }

    /// 从未连上的来源不算「被核心重启打断」。
    ///
    /// 否则每个未连接的来源在核心重启后都会报「需要重新连接」，
    /// 把「本来就没连」和「连过但失效了」混成同一种提示。
    func testNeverConnectedSourceIsNotReportedAsRestarted() async throws {
        let bridge = GenerationBridge()
        let subject = NASSearchProvider(
            bridge: bridge,
            config: NASSourceConfig(host: "192.168.1.96", port: 5001,
                                    username: "nasuser", scopes: ["/示例共享"]),
            port: 5001)
        bridge.processGeneration = 7

        XCTAssertFalse(subject.needsReconnectAfterCoreRestart, "没连过就谈不上「失效」")
    }

    /// 重新连上之后，代次记录必须更新到当前代。
    func testReconnectRebindsToCurrentGeneration() async throws {
        let bridge = GenerationBridge()
        let subject = try await readyProvider(bridge)
        bridge.processGeneration = 2
        _ = await subject.searchCollecting("报告")

        // 重新走一遍连接流程。
        bridge.responses["login"] = ["event": "authState", "state": "scopeReady", "isManager": false]
        try await subject.login(account: "nasuser", password: "p")
        XCTAssertTrue(subject.ready)
        XCTAssertFalse(subject.needsReconnectAfterCoreRestart, "重连后应绑定到新的代次")

        bridge.processGeneration = 2 // 代次没再变
        XCTAssertFalse(subject.needsReconnectAfterCoreRestart)
    }
}

/// 桥接层本身的回归 —— 用一个**真的子进程**当核心。
///
/// 为什么非要起真进程：`MyNASProcessBridge` 的坏 JSON / 版本不一致两条路径
/// 都发生在「读 stdout → 解析」这条链上，用桩替换传输层就绕过了被测代码本身。
/// 这两条的旧表现是**等 180 秒看门狗**，所以测试必须证明「很快就失败」。
@MainActor
final class MyNASProcessBridgeTests: XCTestCase {

    /// 客户端声明的核心修订号必须存在且是正数。
    /// 它的对手方是 Dart 侧的 `coreRevision` 常量，两边不一致会在启动时报错。
    func testExpectedCoreRevisionDeclared() {
        XCTAssertGreaterThan(MyNASProcessBridge.expectedCoreRevision, 0)
    }

    /// 登录应答必须把**终止事件之前**发过的事实一起带回来。
    ///
    /// 真实报障（2026-10-29，用户截图「无法打开文件：SMB 连不上，网页入口也没有拿到」）：
    /// 核心的登录分两条事件 —— 先 `sessionState`（会话、会话密钥、网页入口的地址），
    /// 再 `authState`（身份通过，它是终止事件）。桥接层只把**终止事件那一行**
    /// 交出去，于是 `webFileURL` 与 `sessionSecret`（飞牛的 refresh token）
    /// 在过桥时就没了。表现有两个，都很难从界面反推：
    ///   * 双击 fnOS 结果 → 没有网页入口可用 ⇒ 一句「打不开」；
    ///   * 重启闪寻 → 没有 refresh token 可续期 ⇒ 每台飞牛都要重新授权。
    ///
    /// 所以这里用真子进程复刻两段式应答，断言「后到的终止事件不许把先到的事实抹掉」。
    func testLoginKeepsFactsFromEarlierEventsOfTheSameRequest() async throws {
        let script = """
        id=$(printf '%s' "$line" | sed -E 's/.*"requestID":"([^"]+)".*/\\1/')
        printf '{"protocolVersion":1,"coreRevision":10,"requestID":"%s","sourceID":"src","queryID":"none","event":"sessionState","state":"authenticated","sessionPresent":true,"sessionSecret":"rt-abc","webFileURL":"https://nas.local:5666/"}\\n' "$id"
        printf '{"protocolVersion":1,"coreRevision":10,"requestID":"%s","sourceID":"src","queryID":"none","event":"authState","state":"authenticated","isManager":false}\\n' "$id"
        """
        let bridge = MyNASProcessBridge(executable: try fakeCore(script), stateDirectory: scratch)
        let result = try await bridge.command("login", sourceID: "src",
                                               fields: ["account": "", "password": ""])

        XCTAssertEqual(result["sessionSecret"] as? String, "rt-abc",
                       "★ 会话密钥（refresh token）丢了 ⇒ 用户每次启动都要重新授权")
        XCTAssertEqual(result["webFileURL"] as? String, "https://nas.local:5666/",
                       "★ 网页入口丢了 ⇒ 双击结果只能报「打不开」")
        XCTAssertEqual(result["state"] as? String, "authenticated",
                       "终止事件自己的字段仍以它为准")
        bridge.shutdown()
    }

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-bridge-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    /// 造一个当核心用的 shell 脚本。`body` 在读到一行 stdin 之后执行。
    ///
    /// 「读到 stdin 才输出」是必须的：桥接层是先登记请求、再写 stdin。
    /// 脚本一启动就输出的话，坏行会在请求登记**之前**到达，
    /// 那时 `pending` 是空的，什么都不会失败 —— 测试就假绿了。
    ///
    /// - Parameter linger: 输出完是否再 `sleep 5` 挂着不退。
    ///   默认挂着（多数用例要的是「进程一直在」）；要逼出一次**真实的代次前进**
    ///   （进程退出 → terminationHandler → `failed()`）就传 `false`。
    private func fakeCore(_ body: String, waitsForStdin: Bool = true, linger: Bool = true) throws -> URL {
        let url = scratch.appendingPathComponent("fake-core")
        let prelude = waitsForStdin ? "read -r line" : ""
        let script = "#!/bin/sh\n\(prelude)\n\(body)\n" + (linger ? "sleep 5\n" : "")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    /// 坏 JSON 必须**立刻**让请求失败，而不是静默跳过等看门狗。
    ///
    /// 旧行为：`received()` 里 `guard let m = … else { return }` —— 那一行若是
    /// 某个请求的终止事件，这个请求就永远等不到头，界面转圈三分钟才报超时。
    func testMalformedJSONFailsRequestImmediately() async throws {
        let binary = try fakeCore("printf '{invalid json\\n'")
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch)

        let started = Date()
        do {
            _ = try await bridge.command("discover", sourceID: "src")
            XCTFail("★ 坏 JSON 必须让请求失败；静默通过就是这次要修的 bug")
        } catch {
            XCTAssertTrue("\(error)".contains("通讯已损坏"),
                          "错误必须说清是通讯损坏，实际：\(error)")
        }
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertLessThan(elapsed, 20, "★ 必须很快失败，而不是等 180 秒看门狗；实际 \(elapsed) 秒")
        bridge.shutdown()
    }

    /// 版本不一致必须**立刻**失败并拆掉核心，不允许继续通讯。
    ///
    /// 版本对不上意味着事件名/字段/终止条件都可能变了，
    /// 继续通讯的结果只会是「等一个永远不会来的事件」。
    func testCoreRevisionMismatchFailsFast() async throws {
        let binary = try fakeCore(
            "printf '{\"protocolVersion\":1,\"coreRevision\":1,\"requestID\":\"R1\",\"sourceID\":\"src\",\"queryID\":\"none\",\"event\":\"capabilities\"}\\n'")
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch)

        do {
            _ = try await bridge.command("discover", sourceID: "src")
            XCTFail("版本不一致必须失败")
        } catch {
            XCTAssertTrue("\(error)".contains("版本不一致"), "实际：\(error)")
        }
        bridge.shutdown()
    }

    /// 核心退出 ⇒ 代次必须前进。Provider 靠这个数字判断自己是否失效。
    func testProcessGenerationAdvancesOnHelperExit() async throws {
        // 不读 stdin —— 这个用例要的是「进程自己退出」，
        // 若还 `read -r line` 它会一直等，进程永远不退，测试会假绿在等待里。
        let binary = try fakeCore("exit 0", waitsForStdin: false)
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch)

        let before = bridge.processGeneration
        try bridge.start()
        let afterStart = bridge.processGeneration
        XCTAssertGreaterThan(afterStart, before, "起新进程必须推进代次")

        // 等进程真的退出，terminationHandler 才会跑。
        for _ in 0..<50 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if bridge.processGeneration > afterStart { break }
        }
        XCTAssertGreaterThan(bridge.processGeneration, afterStart,
                             "★ 核心退出后必须推进代次，否则 Provider 会一直以为自己还连着")
        bridge.shutdown()
    }

    /// 看门狗必须在 **MainActor** 上触发（OSS-06）。
    ///
    /// 旧写法是 `DispatchWorkItem` + `DispatchQueue.global().asyncAfter(deadline:execute:)`：
    /// 180 秒后 `timeOut(id)` 在**全局队列**上被调用，而它读写的
    /// `pending` / `watchdogs` / `commands` / `events` 全归 MainActor 所有 ——
    /// 响应与超时同刻到达时，两边就在同一本字典上并发读改。这不是「可能出错」，
    /// 而是未定义行为：轻则 continuation 漏恢复（请求永远挂住，界面一直转圈），
    /// 重则重复恢复触发运行时崩溃。`Swift 5 模式编译通过` 从来不代表线程隔离正确。
    ///
    /// 这条用 1 秒的看门狗把那条分支**真跑一遍**（默认 180 秒的话，快速回归里
    /// 永远跑不到 —— 这正是它藏了这么久的原因），并断言观测回调落在主线程上。
    func testWatchdogFiresOnTheMainActor() async throws {
        // 读掉一行 stdin 之后什么都不输出：核心不回话，只能等看门狗。
        let binary = try fakeCore(":")
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch, watchdogSeconds: 1)

        var fired = false
        var firedOnMain: Bool?
        bridge.observeProtocol = { event in
            guard event["event"] as? String == "watchdogFired" else { return }
            fired = true
            firedOnMain = Thread.isMainThread
        }

        do {
            _ = try await bridge.command("discover", sourceID: "src")
            XCTFail("核心不回话时请求必须超时失败")
        } catch {
            XCTAssertTrue("\(error)".contains("没有响应"), "错误要说清是超时，实际：\(error)")
        }
        XCTAssertTrue(fired, "看门狗触发时应留下协议观测，否则线上定位不了「搜索卡住」")
        XCTAssertEqual(firedOnMain, true,
                       "★ 看门狗必须在 MainActor 上执行；跑到全局队列上就是这次要修的跨线程访问")
        bridge.shutdown()
    }

    /// 旧核心排到主线程队列里的坏帧，绝不能再动到**新**核心（OSS-07）。
    ///
    /// 场景：进程 A 退出（或主动被拆）、进程 B 起来之后，A 的读循环此前投到
    /// MainActor 队列里的那几行才被送达。旧代码投递时不校验来源，
    /// `received` 里一行畸形输出就会 `abortAll` + `terminateHelper`，
    /// 把 B 连同它的连接与正在进行的搜索一起结束掉。靠 requestID 挡不住 ——
    /// 协议损坏恰好是在做 requestID 校验**之前**判定的。
    ///
    /// 构造方式：让核心一口气吐出**两行**坏帧。第一行让核心被判为「通道损坏」
    /// 并拆掉（代次前进）；第二行送达时已经属于旧代。旧代码报两次损坏，修好后只报一次。
    func testStaleHelperOutputCannotAbortTheNewCore() async throws {
        let binary = try fakeCore("printf '{bad one\\n{bad two\\n'")
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch)

        var corruptions: [String] = []
        bridge.observeProtocol = { event in
            guard event["event"] as? String == "protocolCorruption" else { return }
            corruptions.append(event["reason"] as? String ?? "")
        }

        _ = try? await bridge.command("discover", sourceID: "src")
        // 给排在后面的第二行一点送达时间。
        try await Task.sleep(nanoseconds: 500_000_000)
        XCTAssertEqual(corruptions.count, 1,
                       "★ 旧代的坏帧不得再触发一次协议损坏；它会把新核心一起拆掉。实际：\(corruptions)")
        bridge.shutdown()
    }

    /// 闸门的另一面：代次前进之后，**新**核心的正常输出必须照样被接受。
    ///
    /// 「认不出是当前代就丢弃」这种闸门最容易犯的错是矫枉过正 —— 把新核心的输出
    /// 一起丢掉。那比原来的 bug 更难查：请求石沉大海，界面既不报错也不超时，
    /// 只能干等 180 秒看门狗。所以这条**哨兵**必须存在（修复前后都该是绿的）。
    ///
    /// 构造：假核心读一条请求、回一条合法响应，然后**等测试放行**才退出
    /// （逼出一次真实的代次前进）；再发第二条请求，这时已经是新一代核心，
    /// 它照样要把请求走完。
    ///
    /// ★ 退出不能「回完就退」（CI 首跑就是栽在这里）：
    /// 回完立刻退出会和「记下当前代次」赛跑——退出通知若先被处理，代次已经前进、
    /// 进程也已经没了，后面再怎么等都不会有人推进，5 秒后必然断言失败。
    /// 本机调度快、通知总是后到，于是一直是绿的；GitHub 的 arm64 runner 慢一截，
    /// 这个顺序就翻了过来。改成「测试写完代次再放行退出」，顺序确定。
    func testNewCoreOutputIsStillAcceptedAfterGenerationBump() async throws {
        // 用 expectedCoreRevision 插值而不是写死 6：协议修订号是**单一出处**，
        // 写死的话哪天升号，这条测试会以「版本不一致」的形态红掉，误导半天。
        let answer = "id=$(printf '%s' \"$line\" | sed -n 's/.*\"requestID\":\"\\([^\"]*\\)\".*/\\1/p')\n"
            + "printf '{\"protocolVersion\":1,\"coreRevision\":\(MyNASProcessBridge.expectedCoreRevision),"
            + "\"requestID\":\"%s\",\"sourceID\":\"src\",\"queryID\":\"none\",\"event\":\"capabilities\"}\\n' \"$id\"\n"
        // 退出闸门：文件出现前核心一直活着。路径写进脚本，不靠环境变量——
        // 子进程的环境是白名单（PATH/LANG/FF2_TRUST_DIR），传不进别的东西。
        let gate = scratch.appendingPathComponent("exit-now")
        let body = answer + "while [ ! -f \"\(gate.path)\" ]; do sleep 0.05; done"
        let binary = try fakeCore(body, waitsForStdin: true, linger: false)
        let bridge = MyNASProcessBridge(executable: binary, stateDirectory: scratch)

        let first = try await bridge.command("discover", sourceID: "src")
        XCTAssertEqual(first["event"] as? String, "capabilities", "前置：第一代核心要能正常应答")
        let started = bridge.processGeneration

        // 先记代次、后放行退出：退出通知只可能落在这之后。
        try Data().write(to: gate)
        // 最多等 20 秒。CI 的调度比本机慢一个数量级，只给 5 秒等于把机器快慢当断言。
        for _ in 0..<200 {
            try await Task.sleep(nanoseconds: 100_000_000)
            if bridge.processGeneration > started { break }
        }
        XCTAssertGreaterThan(bridge.processGeneration, started, "前置：核心应已退出并推进代次")

        let second = try await bridge.command("discover", sourceID: "src")
        XCTAssertEqual(second["event"] as? String, "capabilities",
                       "★ 代次前进后就不认新一代的核心输出 —— 闸门做成了断路，请求只会石沉大海")
        bridge.shutdown()
    }
}

@MainActor
private extension NASSearchProvider {
    /// 把一次搜索的结果收集起来，便于断言。
    func searchCollecting(_ text: String) async -> [(ProviderSearchState, String)] {
        var collected: [(ProviderSearchState, String)] = []
        await search(text, queryID: UUID()) { event in
            collected.append((event.state, event.message ?? ""))
        }
        return collected
    }
}
