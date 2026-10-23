import XCTest
@testable import FlashFindCore

/// 断开一台 NAS 之后，**迟到的成功不许把它复活**（BUG-NAS-DISCONNECT-01）。
///
/// 「断开一台触发全局 rebuild / 全局查询重置」之外还有三处会让刚断开的来源复活、
/// 并牵动其它来源：
///
///   #1 静默 / 向导连接**迟到成功**仍会 `install` 已断开的来源 —— install 会发布
///      「Provider 集合变化」，上层随即整体重建搜索协调器，其它来源在飞的查询被一起取消。
///   #2 `disconnect()` 清掉活跃状态机却**不发终态** —— 上层「请求过的来源全部落终态
///      才停止转圈」的判据永远不成立，界面在这条搜索上永久转圈。
///   #3 布尔闸门 `sessionClosed` 分不清「断开**之前**发起的登录/选范围的迟到成功」——
///      那两处 `await` 之后无条件解闸并抬 `ready`，来源就复活了。
///
/// 本文件全部为本机 fake 传输层 / 假本机来源证据，**未连任何真实 NAS**。
@MainActor final class NASDisconnectLateArrivalTests: XCTestCase {

    // MARK: - 假传输层：记录命令、可门控任意命令

    private final class GatedBridge: MyNASBridgeTransport {
        struct Call: Equatable { let command: String; let sourceID: String }

        private(set) var calls: [Call] = []
        private(set) var processGeneration = 3

        func bumpGeneration() { processGeneration += 1 }
        func calls(_ command: String, for sourceID: String) -> [Call] {
            calls.filter { $0.command == command && $0.sourceID == sourceID }
        }
        func hasCall(_ command: String, for sourceID: String) -> Bool {
            !calls(command, for: sourceID).isEmpty
        }

        // 门控：`hold("login", "BBBB")` 之后，该来源的那条命令会停在传输层。
        private var held: Set<String> = []
        private var waiters: [String: [CheckedContinuation<Void, Never>]] = [:]
        private func key(_ command: String, _ sourceID: String) -> String { "\(command)|\(sourceID)" }

        func hold(_ command: String, _ sourceID: String) { held.insert(key(command, sourceID)) }
        func release(_ command: String, _ sourceID: String) {
            held.remove(key(command, sourceID))
            let list = waiters[key(command, sourceID)] ?? []
            waiters[key(command, sourceID)] = []
            for waiter in list { waiter.resume() }
        }

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(Call(command: command, sourceID: sourceID))
            let gate = key(command, sourceID)
            if held.contains(gate) {
                await withCheckedContinuation { (continue_: CheckedContinuation<Void, Never>) in
                    waiters[gate, default: []].append(continue_)
                }
            }
            switch command {
            case "discover", "confirmTrust": return ["event": "capabilities"]
            case "login": return ["state": "scopeReady"]
            case "selectScope": return ["state": "scopeReady"]
            case "listShares": return ["event": "batch", "shares": ["/share"]]
            case "search":
                event?(["event": "batch", "queryID": queryID, "sourceID": sourceID,
                        "files": [["id": sourceID + ":1", "path": "/share/a.txt", "name": "a.txt",
                                   "fileType": "file", "sourceID": sourceID]]])
                return ["resultState": "completed", "isComplete": true,
                        "cleanupState": "cleaned", "reportedTotal": 1]
            case "cancel": return ["event": "controlAck", "command": "cancel"]
            case "disconnect": return ["event": "sourceState", "state": "disconnected"]
            default: return ["status": "ok"]
            }
        }
    }

    /// 假的**本机**来源（真实 `SearchProvider` 协议）：立刻给出结果并正常结束。
    /// 用它替代 `LocalSearchProvider`（后者会真的去查 Spotlight，测试里不该依赖系统索引）。
    private final class StubLocalProvider: SearchProvider {
        let source = SearchSource.local
        private var active: UUID?
        private(set) var cancelled: [UUID] = []
        func cancel(queryID: UUID) { if active == queryID { active = nil; cancelled.append(queryID) } }
        func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            active = queryID
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
            guard active == queryID, !Task.isCancelled else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                               results: [SearchResult(id: "local:1", name: "本机.txt", relativePath: "/tmp/本机.txt",
                                                      sourceID: source.id, sourceName: "本机", kind: "file", size: 1,
                                                      localURL: URL(fileURLWithPath: "/tmp/本机.txt"))],
                               state: .completed))
        }
    }

    // MARK: - 夹具

    private var bridge: GatedBridge!
    private var manager: NASConnectionManager!

    override func setUp() {
        super.setUp()
        bridge = GatedBridge()
        manager = NASConnectionManager { _, _ in self.bridge }
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: Self.makeResourceDirectory()))
    }

    private static func makeResourceDirectory() -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-rework2-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("MyNAS/bin", isDirectory: true)
        try? FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("mynas-core").path, contents: Data("fake".utf8))
        FileManager.default.createFile(atPath: root.appendingPathComponent("README-目录说明.md").path, contents: Data())
        return root
    }

    private func config(id: String, host: String) -> NASSourceConfig {
        NASSourceConfig(id: id, name: host, host: host, port: 5001, username: "u", scopes: ["/share"])
    }

    private func waitUntil(_ file: StaticString = #filePath, _ line: UInt = #line,
                           timeout: TimeInterval = 3, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() {
            if Date() > deadline { XCTFail("等待条件超时", file: file, line: line); return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    /// 造两台已连接来源（与生产路径落到的状态一致：配置相等 ⇒ rebuild 复用同一实例）。
    private func makeReadyPair() async throws -> (a: NASSearchProvider, b: NASSearchProvider,
                                                  configA: NASSourceConfig, configB: NASSourceConfig) {
        let configA = config(id: "AAAA", host: "a.example")
        let configB = config(id: "BBBB", host: "b.example")
        manager.rebuild(configs: [configA, configB], queryBudgetMs: 60_000, mountService: nil)
        let a = try XCTUnwrap(manager.provider(for: configA.id))
        let b = try XCTUnwrap(manager.provider(for: configB.id))
        let readyA = try await a.selectScopes(["/share"]); XCTAssertTrue(readyA)
        let readyB = try await b.selectScopes(["/share"]); XCTAssertTrue(readyB)
        return (a, b, configA, configB)
    }

    // MARK: - 统一搜索（本机 + A + B）在 B 断开后必须收敛

    /// 验收：A + B + 本机一起搜；B 在搜索中断开 ⇒
    ///   * B 恰好收到**一次**取消终态（不再永久转圈）；
    ///   * A 与本机照常完成，整体最终不再 searching；
    ///   * A 没有 cancel / disconnect / login，实例身份与 helper 代次不变。
    func testUnifiedSearchConvergesAndKeepsOtherSourcesWhenOneDisconnects() async throws {
        let (a, b, configA, _) = try await makeReadyPair()
        let local = StubLocalProvider()

        let requested = SearchRequestPlan(localSourceID: SearchSource.local.id,
                                          appSourceID: SearchSource.apps.id,
                                          includeLocal: true, includeApps: false, includeNAS: true,
                                          nasCandidates: [(configA.sourceID, a.ready, true),
                                                          ("BBBB", b.ready, true)]).sourceIDs
        XCTAssertEqual(requested, [SearchSource.local.id, "AAAA", "BBBB"])

        // 真实 SearchCoordinator + 真实 SearchCompletionTracker（与 AppModel 同一套判据）。
        let coordinator = SearchCoordinator(providers: [local, a, b])
        var completion = SearchCompletionTracker(requested: requested)
        var searching = false
        var eventsA: [ProviderEvent] = []
        var eventsB: [ProviderEvent] = []

        bridge.hold("search", "AAAA")
        bridge.hold("search", "BBBB")
        let queryID = UUID()
        coordinator.search("报告", sources: requested, queryID: queryID) { event in
            switch event.sourceID {
            case "AAAA": eventsA.append(event)
            case "BBBB": eventsB.append(event)
            default: break
            }
            completion.note(event)
            searching = completion.isSearching
        }
        await waitUntil { self.bridge.hasCall("search", for: "AAAA") && self.bridge.hasCall("search", for: "BBBB") }
        XCTAssertTrue(searching, "三台来源都在飞时必须处于搜索中")
        XCTAssertTrue(eventsA.contains { $0.state == .searching })
        XCTAssertTrue(eventsB.contains { $0.state == .searching })

        // 用户点 B 的「断开」。
        await b.disconnect()

        // ★ B 必须恰好收到一次取消终态 —— 否则 requested 里永远缺 BBBB，
        // 上层的 searching 永远为真（界面永久转圈）。
        let terminalsB = eventsB.filter { !$0.isMetadataUpdate && $0.state != .searching }
        XCTAssertEqual(terminalsB.count, 1, "断开必须给 B 补发**恰好一次**终态")
        XCTAssertEqual(terminalsB.first?.state, .cancelled)
        XCTAssertTrue(terminalsB.first?.results.isEmpty ?? false)
        XCTAssertFalse(completion.pendingSources.contains("BBBB"), "B 落终态后不该再吊住「正在搜索」")
        XCTAssertEqual(completion.pendingSources, ["AAAA"], "A 还在飞，仍在搜索中")
        XCTAssertTrue(searching)

        // A 照常返回结果并完成。
        bridge.release("search", "AAAA")
        await waitUntil { eventsA.contains { $0.state == .completed } }

        XCTAssertFalse(searching, "所有请求的来源都落终态后，整体必须不再 searching")
        XCTAssertEqual(eventsA.last?.state, .completed)
        XCTAssertFalse(eventsA.allSatisfy { $0.results.isEmpty }, "A 必须照常返回结果")

        // A 完全没被碰过。
        XCTAssertFalse(bridge.hasCall("disconnect", for: "AAAA"), "断开 B 不得给 A 发 disconnect")
        XCTAssertFalse(bridge.hasCall("cancel", for: "AAAA"), "断开 B 不得取消 A 的活跃查询")
        XCTAssertTrue(bridge.calls("login", for: "AAAA").isEmpty, "断开 B 不得触发 A 重新登录")
        XCTAssertTrue(manager.provider(for: configA.id) === a, "断开 B 不得替换 A 的实例")
        XCTAssertTrue(a.ready, "断开 B 后 A 必须仍然已连接")
        XCTAssertEqual(bridge.processGeneration, 3, "共享 helper 代次不许因 B 断开变化")
        XCTAssertFalse(b.ready)

        // B 断开之后不许再涌出任何结果批次。
        XCTAssertFalse(eventsB.contains { !$0.results.isEmpty }, "断开后 B 不得再发出结果")
    }

    // MARK: - 断开之前发起的登录 / 选范围迟到成功不得复活

    /// 断开**之前**发起的登录，迟到成功时不许解闸、不许抬 ready。
    func testLateLoginSuccessDoesNotReviveDisconnectedProvider() async throws {
        let configB = config(id: "BBBB", host: "b.example")
        let b = NASSearchProvider(bridge: bridge, config: configB, port: 5001)

        bridge.hold("login", "BBBB")
        let login = Task { try await b.login(account: "u", password: "p") }
        await waitUntil { self.bridge.hasCall("login", for: "BBBB") }
        await b.disconnect()
        bridge.release("login", "BBBB")
        _ = try? await login.value

        XCTAssertFalse(b.ready, "断开之前发起的登录迟到成功不许把 B 抬回在线")

        // 但**断开之后**用户重新发起的显式连接必须能正常恢复（代次是单调递增的）。
        try await b.login(account: "u", password: "p")
        let scopeOK = try await b.selectScopes(["/share"]); XCTAssertTrue(scopeOK)
        XCTAssertTrue(b.ready, "断开后的新显式连接必须能恢复")
    }

    /// 断开**之前**发起的 selectScopes，迟到成功时不许解闸、不许抬 ready，
    /// 并且必须如实返回 false（返回 true 等于告诉调用方「恢复成功」）。
    func testLateScopeSelectionDoesNotReviveDisconnectedProvider() async throws {
        let configB = config(id: "BBBB", host: "b.example")
        let b = NASSearchProvider(bridge: bridge, config: configB, port: 5001)
        try await b.login(account: "u", password: "p")

        bridge.hold("selectScope", "BBBB")
        let selecting = Task { try await b.selectScopes(["/share"]) }
        await waitUntil { self.bridge.hasCall("selectScope", for: "BBBB") }
        await b.disconnect()
        bridge.release("selectScope", "BBBB")
        let confirmed = try? await selecting.value

        XCTAssertEqual(confirmed, false, "过期的那次绑范围不许报「成功」")
        XCTAssertFalse(b.ready, "断开之前发起的绑范围迟到成功不许把 B 抬回在线")

        // 断开之后的新一次显式绑范围正常。
        let scopeOK = try await b.selectScopes(["/share"]); XCTAssertTrue(scopeOK)
        XCTAssertTrue(b.ready)
    }

    /// 自动重连**进行到一半**时不许显示已连接（就绪只能在 attemptAutoReconnect 收尾提交）。
    func testAutoReconnectDoesNotExposeReadyMidFlight() async throws {
        let (_, b, _, _) = try await makeReadyPair()
        bridge.bumpGeneration()
        XCTAssertTrue(b.needsReconnectAfterCoreRestart)
        b.autoReconnect = { provider in
            _ = try? await provider.discover()
            try? await provider.login(account: "u", password: "p")
            return (try? await provider.selectScopes(provider.config.scopes)) ?? false
        }
        // 让重连停在 selectScope 上，观察「中途」的 ready。
        // 注意先记下既有调用数：`makeReadyPair` 里那次绑范围已经记过一条同名调用，
        // 只按「有没有这条调用」等会立刻返回（那时重连还没开始、ready 还是 true）。
        let scopeCallsBefore = bridge.calls("selectScope", for: "BBBB").count
        bridge.hold("selectScope", "BBBB")
        var events: [ProviderEvent] = []
        let task = Task { await b.search("报告", queryID: UUID()) { events.append($0) } }
        await waitUntil { self.bridge.calls("selectScope", for: "BBBB").count > scopeCallsBefore }

        XCTAssertFalse(b.ready, "重连进行到一半时不许显示已连接")

        bridge.release("selectScope", "BBBB")
        await task.value
        XCTAssertTrue(b.ready, "重连完成后必须恢复就绪")
        XCTAssertEqual(events.last?.state, .completed, "恢复后这次搜索必须照常完成")
    }

    // MARK: - 静默连接的迟到成功不得 install / 不得全局 invalidate

    private struct QuietOutcome: Equatable { var installed = false; var coreResetSkipped = false }

    /// 复刻 AppModel `performConnectQuietly` 的顺序：
    /// `resetCore → discover → login → loadShares → selectScopes →（守卫）→ install → invalidate`。
    ///
    /// - Parameter guarded: `false` 复刻**不复核连接意图**的写法：`await` 之后直接往下走。
    private func quietConnectLikeAppModel(config: NASSourceConfig, guarded: Bool,
                                          isStillValid: @escaping () -> Bool) async -> QuietOutcome {
        var outcome = QuietOutcome()
        await manager.resetCoreSource(config.sourceID)
        if guarded, !isStillValid() { outcome.coreResetSkipped = true; return outcome }
        let provider = NASSearchProvider(bridge: bridge, config: config, port: config.port)
        do {
            _ = try await provider.discover()
            if guarded, !isStillValid() { return outcome }
            try await provider.login(account: config.username, password: "p")
            if guarded, !isStillValid() { return outcome }
            let shares = try await provider.loadShares()
            if guarded, !isStillValid() { return outcome }
            if !shares.isEmpty { _ = try await provider.selectScopes(shares) }
            if guarded, !isStillValid() { return outcome }
            guard provider.ready else { return outcome }
            manager.install(provider)
            outcome.installed = true
        } catch { return outcome }
        return outcome
    }

    /// 场景：A 已连接且在飞搜索；B 的**静默连接**进行到「绑定搜索位置」时，
    /// 用户在来源卡片上点了 B 的「断开」。
    ///
    /// 判据（每个 await 之后复核连接意图）必须让这次连接作废：
    /// 不 install、不触发全局 invalidate（= 不重建协调器）、A 在飞查询不受影响。
    ///
    /// 同一条序列在不复核连接意图时会 `install` 成功 ——
    /// 见 `testUnguardedLateQuietConnectInstallsAndInvalidates`。
    func testLateQuietConnectDoesNotInstallDisconnectedSource() async throws {
        try await assertQuietConnectLateArrival(guarded: true, expectInstall: false)
    }

    func testUnguardedLateQuietConnectInstallsAndInvalidates() async throws {
        try await assertQuietConnectLateArrival(guarded: false, expectInstall: true)
    }

    private func assertQuietConnectLateArrival(guarded: Bool, expectInstall: Bool) async throws {
        let (a, b, configA, configB) = try await makeReadyPair()
        // install 次数 = 全局「Provider 集合变化」次数。AppModel 在这个回调里
        // 整体重建搜索协调器 —— 那就是「其它来源在飞查询被取消」的机制。
        var installNotifications = 0
        manager.onProvidersChanged = { _ in installNotifications += 1 }

        // A 的在飞搜索。
        bridge.hold("search", "AAAA")
        var eventsA: [ProviderEvent] = []
        let searchA = Task { await a.search("报告", queryID: UUID()) { eventsA.append($0) } }
        await waitUntil { self.bridge.hasCall("search", for: "AAAA") }

        // B 的静默连接进行到 selectScope 就停住。
        let intent = SourceConnectIntent()
        let token = intent.begin(configB)
        bridge.hold("selectScope", "BBBB")
        let quiet = Task { await self.quietConnectLikeAppModel(config: configB, guarded: guarded,
                                                              isStillValid: { intent.isCurrent(token) }) }
        await waitUntil { self.bridge.hasCall("selectScope", for: "BBBB") }
        XCTAssertTrue(b.ready, "夹具：连接意向到期前 B 的实例已就绪")

        // 用户点 B 的「断开」：作废连接意图 + 断开管理器里那一台。
        intent.invalidate(configB.sourceID)
        await manager.disconnectOne(configB.sourceID)
        bridge.release("selectScope", "BBBB")
        let outcome = await quiet.value

        XCTAssertEqual(outcome.installed, expectInstall,
                       expectInstall ? "未修版本会照旧 install（这份用例复现的就是它）"
                                     : "断开之后迟到的静默连接不许 install 回来")
        XCTAssertEqual(installNotifications, expectInstall ? 1 : 0,
                       "过期连接不得发布 Provider 变化（= 不得触发全局重建协调器）")
        if expectInstall {
            // 未修版本：迟到连接把管理器里 B 的实例顶掉了 —— 正是缺陷本身。
            XCTAssertFalse(manager.provider(for: configB.sourceID) === b,
                           "未修版本会把迟到的实例装进管理器（复现缺陷）")
        } else {
            XCTAssertTrue(manager.provider(for: configB.sourceID) === b,
                          "管理器里 B 的实例不许被迟到的连接顶掉")
        }
        XCTAssertFalse(b.ready, "B 必须保持已断开")

        // A 的在飞查询不受影响。
        bridge.release("search", "AAAA")
        await searchA.value
        XCTAssertEqual(eventsA.last?.state, .completed, "A 的在飞查询必须照常完成")
        XCTAssertFalse(bridge.hasCall("disconnect", for: configA.sourceID), "不得给 A 发 disconnect")
        XCTAssertFalse(bridge.hasCall("cancel", for: configA.sourceID), "不得取消 A 的查询")
        XCTAssertTrue(manager.provider(for: configA.id) === a, "不得替换 A 的实例")
        XCTAssertTrue(a.ready, "A 必须仍然已连接")
        XCTAssertEqual(bridge.processGeneration, 3, "共享 helper 不得重启")
    }

    // MARK: - 连接意图登记表本身

    func testConnectIntentInvalidationAndLaterSessionSurvives() throws {
        let intent = SourceConnectIntent()
        let configB = config(id: "BBBB", host: "b.example")
        let first = intent.begin(configB)
        XCTAssertTrue(intent.isCurrent(first, config: configB))
        XCTAssertTrue(intent.isCurrent(first))

        intent.invalidate(configB.sourceID)
        XCTAssertFalse(intent.isCurrent(first), "断开必须作废在飞的连接意图")

        let second = intent.begin(configB)
        XCTAssertTrue(intent.isCurrent(second), "作废不得伤到后来的同 sourceID 新会话")
        XCTAssertFalse(intent.isCurrent(first), "旧凭证仍然无效")

        // 指纹：配置改了（换主机 / 换账号 / 换协议）即视为另一次连接目标。
        var retargeted = configB
        retargeted.host = "other.example"
        XCTAssertFalse(intent.isCurrent(second, config: retargeted))
        XCTAssertTrue(intent.isCurrent(second, config: configB))
        // 只写回搜索位置不算换目标（连接流程自己会写 scopes）。
        var scoped = configB
        scoped.scopes = ["/share", "/other"]
        XCTAssertTrue(intent.isCurrent(second, config: scoped), "scopes 回写不得把本次连接判成过期")
    }

    func testCompletionTrackerCountsOnlyRealTerminals() throws {
        let queryID = UUID()
        var tracker = SearchCompletionTracker(requested: ["local_mac", "AAAA", "BBBB"])
        XCTAssertTrue(tracker.isSearching)
        tracker.note(ProviderEvent(queryID: queryID, sourceID: "AAAA", state: .searching))
        XCTAssertTrue(tracker.isSearching, "searching 不是终态")
        tracker.note(ProviderEvent(queryID: queryID, sourceID: "AAAA", state: .searching,
                                   isMetadataUpdate: true))
        XCTAssertTrue(tracker.isSearching, "元数据补发不是终态")
        tracker.note(ProviderEvent(queryID: queryID, sourceID: "AAAA", state: .completed))
        tracker.note(ProviderEvent(queryID: queryID, sourceID: "BBBB", state: .cancelled))
        tracker.note(ProviderEvent(queryID: queryID, sourceID: "local_mac", state: .completed))
        XCTAssertFalse(tracker.isSearching)
        XCTAssertTrue(tracker.pendingSources.isEmpty)
    }
}

/// App 层（executableTarget）依赖不了 —— 关键动作只能扫源码锁结构。
/// 断言锁**动作**（在哪个函数体里、与 install 的先后），不锁名字；
/// 每一条都已反向验证：把实现改回未加保护的版本，它就变红。
@MainActor final class NASDisconnectLateArrivalAppWiringTests: XCTestCase {

    private func readSource(_ relative: String) throws -> String {
        // AppModel 已拆成主文件 + 分区：读它必须走整套入口，只读主文件会让
        // 搬到分区里的实现「消失」（假绿或崩溃）。
        if relative.hasSuffix("AppModel.swift") {
            return try AppModelSource.read(callerFilePath: #filePath)
        }
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
        // 扫描必须跳过整行注释：注释里提一句旧实现就会误报。
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 取出 `func <name>` 的函数体（配对花括号）。
    private func body(of name: String, in code: String) -> String {
        guard let range = code.range(of: "func \(name)(") ?? code.range(of: "func \(name)<") else {
            XCTFail("找不到 func \(name)")
            return ""
        }
        var index = range.lowerBound
        var depth = 0, started = false
        while index < code.endIndex {
            let ch = code[index]
            if ch == "{" { depth += 1; started = true }
            if ch == "}" { depth -= 1; if started && depth == 0 { break } }
            index = code.index(after: index)
        }
        return String(code[range.lowerBound..<index])
    }

    // MARK: - 连接意图守卫（App 层）

    func testDisconnectSourceInvalidatesIntentAndCancelsConnectTask() throws {
        let code = try readSource("Sources/FlashFind2App/AppModel.swift")
        let body = body(of: "disconnectSource", in: code)
        XCTAssertTrue(body.contains("connectIntent.invalidate"),
                      "断开必须同步作废该来源在飞的连接意图")
        XCTAssertTrue(body.contains("connectTasks") && body.contains(".cancel()"),
                      "断开必须取消该来源的静默连接任务")
        XCTAssertFalse(body.contains("rebuildNativeProviders"), "断开单台不得触发全局 rebuild")
        XCTAssertFalse(body.contains("changedQuery"), "断开单台不得重置整个搜索")
        XCTAssertFalse(body.contains("nativeProviders.removeValue"), "断开不是移除")
    }

    func testQuietConnectRevalidatesIntentBeforeInstall() throws {
        let code = try readSource("Sources/FlashFind2App/AppModel.swift")
        // ★ 断言要落在真正干活的那个函数上。
        //
        // `performConnectQuietly` 退化成「重试驱动器」，
        // discover → login → selectScopes → install 整条链搬进了 `quietConnectSteps`
        // ——因为开机自动连接现在要退避重试，「重试」与「怎么连一次」必须分开。
        // 断言仍挂在旧函数上的话，它检查的是一个**已经不含连接逻辑**的函数体，
        // 表现为「守卫被删了测试照样绿」：假绿。
        let body = body(of: "quietConnectSteps", in: code)
        let guards = body.components(separatedBy: "guard quietConnectStillValid").count - 1
        XCTAssertGreaterThanOrEqual(guards, 5, "每个 await 之后都要复核连接意图（实际 \(guards) 处）")
        guard let install = body.range(of: "install(provider)") else {
            XCTFail("quietConnectSteps 里必须有 install")
            return
        }
        // install 紧邻之前必须有一次守卫。不能拿「最后一次守卫」比 ——
        // 函数末尾的 catch 里也有一条守卫，那是**失败路径**上的，位置更靠后。
        let window = String(body[body.startIndex..<install.lowerBound].suffix(400))
        XCTAssertTrue(window.contains("quietConnectStillValid"),
                      "install 之前必须再过一次连接意图守卫")
        // 「全局 invalidate」只能在确认这次连接仍然有效之后才做。
        XCTAssertTrue(body.contains("invalidate()"))
    }

    func testWizardSharesConnectIntentWithAppModel() throws {
        let model = try readSource("Sources/FlashFind2App/AppModel.swift")
        XCTAssertTrue(model.contains("wizard.connectIntent = self.connectIntent"),
                      "向导必须与 AppModel 共用**同一个**连接意图登记表，否则断开作废不到它")
        let wizard = try readSource("Sources/FlashFind2App/NASSourceWizardController.swift")
        XCTAssertTrue(wizard.contains("var connectIntent = SourceConnectIntent()"),
                      "向导必须持有连接意图登记表")
        let connect = body(of: "performConnect", in: wizard)
        XCTAssertTrue(connect.contains("beginConnectIntent("), "向导连接开始必须登记连接意图")
        XCTAssertGreaterThanOrEqual(connect.components(separatedBy: "guard attemptStillValid(").count - 1, 3,
                                    "向导连接的每个 await 之后都要复核")
        let login = body(of: "finishLogin", in: wizard)
        XCTAssertGreaterThanOrEqual(login.components(separatedBy: "guard attemptStillValid(").count - 1, 3,
                                    "登录链路的每个 await 之后都要复核")
        let commit = body(of: "commitDraft", in: wizard)
        guard let guardAt = commit.range(of: "guard connectIntent.isCurrent") ?? commit.range(of: "!connectIntent.isCurrent"),
              let install = commit.range(of: "installProvider(") else {
            XCTFail("commitDraft 必须在 installProvider 之前复核连接意图")
            return
        }
        XCTAssertTrue(guardAt.lowerBound < install.lowerBound,
                      "installProvider 之前必须复核连接意图（断开之后不许把来源装回来）")
    }

    // MARK: - 搜索完成判据（App 层）

    func testSearchCompletionUsesCoreTracker() throws {
        let code = try readSource("Sources/FlashFind2App/AppModel.swift")
        let body = body(of: "changedQuery", in: code)
        XCTAssertTrue(body.contains("SearchCompletionTracker(requested: requested)"),
                      "「还在搜吗」的判据必须用 Core 的 SearchCompletionTracker（可被断言）")
        XCTAssertTrue(body.contains("completion.note(event)"))
        XCTAssertTrue(body.contains("self.searching = completion.isSearching"))
        XCTAssertFalse(body.contains("requested.isSubset(of:"),
                       "不得再留着那份无法被测试覆盖的内联判据")
    }
}
