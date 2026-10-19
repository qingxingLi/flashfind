import XCTest
@testable import FlashFindCore

/// 单台 NAS 断开的**隔离性**（BUG-NAS-DISCONNECT-01）。
///
/// 用户报障：在「网络存储」里点某一台 NAS 的「断开」，结果**全部** NAS 都断开了。
///
/// ⚠️ 本文件的查询词一律用「报告」而不是 `doc`：`doc` 是
/// **格式词**（「名称 + 格式」解析），单独搜它会变成「列出所有文档类文件」，
/// 而这里要的是一条**普通关键词**查询 —— 否则测的是格式过滤，不是断开隔离。
///
/// 断开的正确语义（产品要求）：
///   * 断开 B 只结束 B 自己的会话与活跃查询；A 等其它来源的连接状态、
///     Provider 实例、可搜索性一律不动；
///   * 不删除配置与已保存的凭据，B 之后可以再连；
///   * 共享的核心进程不许因 B 断开而停止、重启或全局登出；
///   * B 断开后，它的迟到结果 / 迟到的重连成功**不许把它复活成在线**。
///
/// 这类缺陷单元测试抓不到的地方在于「跨持有者」：所以这里用真实
/// `NASConnectionManager` + 真实 `NASSearchProvider` + 真实 `SearchCoordinator`
/// 配一台**记录命令、可门控**的假传输层，按 App 的真实调用顺序驱动。
/// 真实 NAS 未执行：本文件全部为本机 fake 传输层证据。
@MainActor final class NASDisconnectIsolationTests: XCTestCase {

    // MARK: - 假传输层：记录命令、可门控、代次可控

    private final class IsolationBridge: MyNASBridgeTransport {
        struct Call: Equatable { let command: String; let sourceID: String }

        private(set) var calls: [Call] = []
        private(set) var processGeneration = 3
        private(set) var loginCount = 0

        func bumpGeneration() { processGeneration += 1 }

        func calls(_ command: String, for sourceID: String) -> [Call] {
            calls.filter { $0.command == command && $0.sourceID == sourceID }
        }
        func hasCall(_ command: String, for sourceID: String) -> Bool {
            !calls(command, for: sourceID).isEmpty
        }

        // 门控：让某个来源的 search 停在传输层，模拟设备还没返回。
        private var heldSearch: Set<String> = []
        private var searchWaiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        // 门控：让注入的自动重连钩子停住，模拟「重连进行到一半」。
        private var reconnectStarted = false
        private var reconnectWaiter: CheckedContinuation<Void, Never>?
        private var holdReconnect = false

        func holdSearch(_ sourceID: String) { heldSearch.insert(sourceID) }
        func holdReconnectHook() { holdReconnect = true }

        func releaseSearch(_ sourceID: String) {
            heldSearch.remove(sourceID)
            let waiters = searchWaiters[sourceID] ?? []
            searchWaiters[sourceID] = []
            for waiter in waiters { waiter.resume() }
        }
        func releaseReconnectHook() {
            holdReconnect = false
            reconnectWaiter?.resume()
            reconnectWaiter = nil
        }

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(Call(command: command, sourceID: sourceID))
            switch command {
            case "discover":
                return ["event": "capabilities"]
            case "confirmTrust":
                return ["event": "capabilities"]
            case "login":
                loginCount += 1
                return ["state": "scopeReady"]
            case "selectScope":
                return ["state": "scopeReady"]
            case "listShares":
                return ["event": "batch", "shares": ["/share"]]
            case "search":
                if heldSearch.contains(sourceID) {
                    await withCheckedContinuation { (continue_: CheckedContinuation<Void, Never>) in
                        searchWaiters[sourceID, default: []].append(continue_)
                    }
                }
                // 一批结果。就绪判据要求 rows 能被 Provider 解析（path/name/id/sourceID）。
                event?(["event": "batch", "queryID": queryID, "sourceID": sourceID,
                        "files": [["id": sourceID + ":1", "path": "/share/a.txt", "name": "a.txt",
                                   "fileType": "file", "sourceID": sourceID]]])
                return ["resultState": "completed", "isComplete": true,
                        "cleanupState": "cleaned", "reportedTotal": 1]
            case "cancel":
                return ["event": "controlAck", "command": "cancel"]
            case "disconnect":
                return ["event": "sourceState", "state": "disconnected"]
            default:
                return ["status": "ok"]
            }
        }

        /// 注入给 Provider 的自动重连：停在门上，放行后按真实顺序重放
        /// discover → login → selectScopes（与 `NASAutoReconnect.recover` 同形）。
        func makeAutoReconnect() -> (NASSearchProvider) async -> Bool {
            { [weak self] provider in
                guard let self else { return false }
                if self.holdReconnect {
                    self.reconnectStarted = true
                    await withCheckedContinuation { (continue_: CheckedContinuation<Void, Never>) in
                        self.reconnectWaiter = continue_
                    }
                }
                do {
                    _ = try await provider.discover()
                    try await provider.login(account: "u", password: "p")
                    return try await provider.selectScopes(provider.config.scopes)
                } catch { return false }
            }
        }
        var reconnectHookStarted: Bool { reconnectStarted }
    }

    // MARK: - 夹具

    private var bridge: IsolationBridge!
    private var manager: NASConnectionManager!

    override func setUp() {
        super.setUp()
        bridge = IsolationBridge()
        manager = NASConnectionManager { _, _ in self.bridge }
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: Self.makeResourceDirectory()))
    }

    /// 让 `ensureBridge` 能找到核心可执行文件；状态目录落在临时目录里。
    private static func makeResourceDirectory() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-disconnect-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("MyNAS/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("mynas-core").path, contents: Data("fake".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("README-目录说明.md").path, contents: Data())
        return root
    }

    private func config(id: String, host: String) -> NASSourceConfig {
        NASSourceConfig(id: id, name: host, host: host, port: 5001, username: "u", scopes: ["/share"])
    }

    /// 按启动时序造两台已连接（ready）的来源：rebuild 出空白实例 → 选范围置 ready。
    /// 这与「静默自动连接 + install 交接」在管理器里落到的状态一致：
    /// 配置相等 ⇒ rebuild 一直复用同一实例。
    private func makeReadyPair() async throws -> (a: NASSearchProvider, b: NASSearchProvider,
                                                   configA: NASSourceConfig, configB: NASSourceConfig) {
        let configA = config(id: "AAAA", host: "a.example")
        let configB = config(id: "BBBB", host: "b.example")
        manager.rebuild(configs: [configA, configB], queryBudgetMs: 60_000, mountService: nil)
        let a = try XCTUnwrap(manager.provider(for: configA.id))
        let b = try XCTUnwrap(manager.provider(for: configB.id))
        let readyA = try await a.selectScopes(["/share"])
        XCTAssertTrue(readyA)
        let readyB = try await b.selectScopes(["/share"])
        XCTAssertTrue(readyB)
        XCTAssertTrue(a.ready, "夹具要求 A 已连接")
        XCTAssertTrue(b.ready, "夹具要求 B 已连接")
        a.autoReconnect = bridge.makeAutoReconnect()
        b.autoReconnect = bridge.makeAutoReconnect()
        return (a, b, configA, configB)
    }

    /// 轮询等待一个条件（全部在 MainActor 上，不会死锁）。
    private func waitUntil(_ file: StaticString = #filePath, _ line: UInt = #line,
                           timeout: TimeInterval = 2,
                           _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline {
                XCTFail("等待条件超时", file: file, line: line)
                return
            }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: - 断开隔离（核心验收 1：断开 B 不动 A）

    /// 断开 B 时，A 不得收到任何 disconnect / cancel / login / reset；
    /// A 的实例身份、ready、核心代次不变，且在飞的查询照常返回结果。
    func testDisconnectingOneSourceLeavesTheOtherConnectedAndSearching() async throws {
        let (a, b, configA, _) = try await makeReadyPair()
        let queryID = UUID()
        bridge.holdSearch("AAAA")
        bridge.holdSearch("BBBB")
        var eventsA: [ProviderEvent] = []
        let taskA = Task { await a.search("报告", queryID: queryID) { eventsA.append($0) } }
        var eventsB: [ProviderEvent] = []
        let taskB = Task { await b.search("报告", queryID: queryID) { eventsB.append($0) } }
        await waitUntil { self.bridge.hasCall("search", for: "AAAA") && self.bridge.hasCall("search", for: "BBBB") }

        // 用户点 B 的「断开」。App 的动作等价于：只对 B 发 disconnect。
        await b.disconnect()

        bridge.releaseSearch("AAAA")
        bridge.releaseSearch("BBBB")
        await taskA.value
        await taskB.value

        // A 没有任何断开 / 重连 / 会话复位动作。
        XCTAssertFalse(bridge.hasCall("disconnect", for: "AAAA"), "断开 B 不得给 A 发 disconnect")
        XCTAssertFalse(bridge.hasCall("cancel", for: "AAAA"), "断开 B 不得取消 A 的活跃查询")
        XCTAssertFalse(bridge.hasCall("login", for: "AAAA"), "断开 B 不得触发 A 重新登录")
        XCTAssertEqual(bridge.calls("login", for: "AAAA").count, 0)
        // A 实例身份与 ready 不变。
        XCTAssertTrue(manager.provider(for: configA.id) === a, "断开 B 不得替换 A 的 Provider 实例")
        XCTAssertTrue(a.ready, "断开 B 后 A 必须仍然已连接")
        XCTAssertEqual(bridge.processGeneration, 3, "共享核心进程不许因 B 断开重启")
        // A 的在飞查询照常返回结果并正常完成。
        let aResults = eventsA.filter { !$0.results.isEmpty }
        XCTAssertFalse(aResults.isEmpty, "A 的搜索必须照常返回结果")
        XCTAssertEqual(eventsA.last?.state, .completed, "A 的搜索必须照常完成")
        // B 被断开：不再就绪。
        XCTAssertFalse(b.ready)
        XCTAssertTrue(bridge.hasCall("disconnect", for: "BBBB"), "B 必须真的收到 disconnect")
    }

    /// 核心验收 3：B 在查询中断开，迟到结果不许继续涌出、更不许把它变成在线。
    ///
    /// ★ 不能断言「断开返回之后不许再收到任何事件」：那会把
    /// 「补发取消终态」这个**正确且必需**的行为判成失败 —— 而没有它，
    /// 上层「请求过的来源全部落终态才停止转圈」的判据永远不成立，界面永久转圈。
    /// 所以这里要求**恰好一次**取消终态，其余迟到结果批次一律屏蔽。
    func testLateResultsDoNotReviveDisconnectedSource() async throws {
        let (_, b, _, _) = try await makeReadyPair()
        let queryID = UUID()
        bridge.holdSearch("BBBB")
        var events: [ProviderEvent] = []
        let task = Task { await b.search("报告", queryID: queryID) { events.append($0) } }
        await waitUntil { self.bridge.hasCall("search", for: "BBBB") }

        await b.disconnect()
        bridge.releaseSearch("BBBB")
        await task.value

        XCTAssertFalse(b.ready, "断开后 B 不得变成在线")
        XCTAssertTrue(events.contains { $0.state == .searching },
                      "夹具要求断开前至少有过一次 searching 事件")
        let batches = events.filter { !$0.results.isEmpty }
        XCTAssertTrue(batches.isEmpty,
                      "断开之后不得再收到任何结果批次（收到 \(batches.count) 批）")
        let terminals = events.filter { !$0.isMetadataUpdate && $0.state != .searching }
        XCTAssertEqual(terminals.count, 1, "断开必须补发**恰好一次**终态，否则上层永久转圈")
        XCTAssertEqual(terminals.first?.state, .cancelled)
    }

    /// 核心验收 3（重连分支）：B 在自动重连进行到一半时被断开，
    /// 迟到的重连成功不许把它复活成在线、也不许接着把旧查询发出去。
    func testAutoReconnectDoesNotReviveDisconnectedSource() async throws {
        let (_, b, _, _) = try await makeReadyPair()
        // 核心重启过 ⇒ B 的登录态失效，下次搜索会先走自动重连。
        bridge.bumpGeneration()
        XCTAssertTrue(b.needsReconnectAfterCoreRestart)

        bridge.holdReconnectHook()
        let queryID = UUID()
        var events: [ProviderEvent] = []
        let task = Task { await b.search("报告", queryID: queryID) { events.append($0) } }
        await waitUntil { self.bridge.reconnectHookStarted }

        // 重连进行到一半，用户点了断开。
        await b.disconnect()
        let searchCallsBeforeRelease = bridge.calls("search", for: "BBBB").count
        bridge.releaseReconnectHook()
        await task.value

        XCTAssertFalse(b.ready, "断开后迟到的重连成功不许把 B 复活成在线")
        XCTAssertEqual(bridge.calls("search", for: "BBBB").count, searchCallsBeforeRelease,
                       "断开之后不许再把（旧）查询提交给设备")
        XCTAssertTrue(events.contains { $0.state == .failed },
                      "断开后的那次搜索必须如实结束，不许静默挂着")
    }

    // MARK: - 幂等与重连（核心验收 2 / 4）

    /// 连续断开 / 重复点击必须幂等，且不得影响其它来源；
    /// 断开后 B 可以再连接并恢复搜索。
    func testRepeatedDisconnectIsIdempotentAndSourceCanBeReconnected() async throws {
        let (a, b, configA, configB) = try await makeReadyPair()

        await b.disconnect()
        await b.disconnect()
        await b.disconnect()

        XCTAssertTrue(manager.provider(for: configA.id) === a)
        XCTAssertTrue(a.ready, "重复断开 B 不得影响 A")
        // 断开不删配置：scope、凭据相关的配置字段原样保留（B 可以再连）。
        XCTAssertEqual(b.config, configB, "断开不得改动 B 的已保存配置（含搜索位置）")

        // B 重新连接（同一实例重放：登录 + 绑范围），然后能搜。
        let readyAgain = try await b.selectScopes(["/share"])
        XCTAssertTrue(readyAgain)
        XCTAssertTrue(b.ready, "重新连接后 B 必须恢复就绪")
        var events: [ProviderEvent] = []
        await b.search("报告", queryID: UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.state, .completed, "重新连接后 B 的搜索必须可用")
        XCTAssertFalse(events.flatMap { $0.results }.isEmpty)
    }

    /// 断开 B 之后的 rebuild：A 的实例与 ready 不变；B 仍在表内（配置保留）。
    func testRebuildAfterDisconnectKeepsOtherSourceInstanceAndReady() async throws {
        let (a, b, configA, configB) = try await makeReadyPair()
        await b.disconnect()
        manager.rebuild(configs: [configA, configB], queryBudgetMs: 60_000, mountService: nil)
        XCTAssertTrue(manager.provider(for: configA.id) === a, "rebuild 不得替换 A 的实例")
        XCTAssertTrue(a.ready, "rebuild 不得把 A 踢下线")
        XCTAssertTrue(manager.provider(for: configB.id) === b, "断开的 B 配置仍在，rebuild 不得把它凭空换掉")
        XCTAssertFalse(b.ready)
        XCTAssertEqual(b.config, configB)
    }
}

/// App 层的断开入口是 executableTarget，测试依赖不了 —— 只能锁结构。
/// 这是**辅助**验收：行为验收在上面用真实 Core 类型完成。
/// 断言锁的是「动作」而不是名字。
@MainActor final class NASDisconnectAppWiringTests: XCTestCase {

    private func appModelCode() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try AppModelSource.readRaw(callerFilePath: #filePath)
        // 扫描必须跳过整行注释：注释里提一句旧实现就会误报。
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 提取 `func disconnectSource` 的函数体（到与之配对的右花括号为止）。
    private func disconnectSourceBody() throws -> String {
        let code = try appModelCode()
        guard let range = code.range(of: "func disconnectSource(") else {
            XCTFail("AppModel 里找不到 disconnectSource")
            return ""
        }
        var index = range.lowerBound
        var depth = 0
        var started = false
        while index < code.endIndex {
            let character = code[index]
            if character == "{" { depth += 1; started = true }
            if character == "}" {
                depth -= 1
                if started && depth == 0 { break }
            }
            index = code.index(after: index)
        }
        return String(code[range.lowerBound..<index])
    }

    /// 断开单台**不得**触发全局重建、全局查询重置或字典摘除——
    /// 那三步正是「断开一台、全部断开」的机制：
    /// rebuild 把全部 Provider 换一轮核对，changedQuery 把所有在飞查询一起取消，
    /// removeValue 再由 rebuild 装回一个从未登录的实例。
    func testDisconnectSourceOnlyTouchesThatSource() throws {
        let body = try disconnectSourceBody()
        XCTAssertTrue(body.contains("disconnectOne"), "断开必须走管理器的单来源入口 disconnectOne")
        XCTAssertFalse(body.contains("rebuildNativeProviders"), "断开单台不得触发全局 rebuild")
        XCTAssertFalse(body.contains("changedQuery"), "断开单台不得重置整个搜索（会取消其它来源的在飞查询）")
        XCTAssertFalse(body.contains("nativeProviders.removeValue"), "断开不是移除：B 仍在表内，配置保留")
    }
}
