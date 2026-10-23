import XCTest
@testable import FlashFindCore

/// Phase 3 验收：搜索会话隔离。共 20 条：
///
/// - #1–#11 对应方案 §1.6.4 的 9 + 2 条（第一轮验收）；
/// - #12–#14 是协议派发、跨来源扇出、sources 过滤；
/// - **#15–#20 是第二轮补洞**（v0.7）：全部是「状态组合」——UI 在跑 + MCP 排队 +
///   新 UI 取代、同 owner 在跑 + 排队 + cancelAll、取消后槽位何时释放、
///   跨 owner 取消、已完成的查询被再次取消、排队项被取代后的终态。
///
/// 为什么单独标出来：前一轮 14 条全绿之后仍有 6 个真实漏洞。**全绿只能证明
/// 已知路径没问题，不能证明组合没问题**——并发调度器的 bug 基本都在组合处。
///
/// 全部用**手动放行**的假 Provider 驱动，不 sleep 赌调度：
/// 每次 `search` 都停在 `release(queryID:)` 之前，测试能确定地构造
/// 「A 在跑、B 进来」「GUI 插队」「排队项过 deadline」这些顺序。
///
/// ★ 等待条件必须落在**provider 的 calls** 上，不能落在调度器的 `running` 上：
/// `start()` 是同步置位、`Task` 才去调 provider，两者之间有一个窗口。
/// 用 `running` 当判据会提前 `release`，而那时 provider 还没挂上 continuation，
/// 于是测试永远等下去——这不是产品缺陷，是测试写错了判据。
private let nasA = SearchSource(id: "nas-a", name: "NAS A", type: .nas, displayName: "NAS A")
private let nasB = SearchSource(id: "nas-b", name: "NAS B", type: .nas, displayName: "NAS B")

/// 可手动放行的假 Provider。记录每一次 search 的 owner，以及每一次 cancel。
@MainActor
private final class ManualProvider: SearchProvider {
    let source: SearchSource
    private(set) var calls: [(queryID: UUID, owner: SearchOwner)] = []
    private(set) var cancelled: [UUID] = []
    private(set) var finished: [UUID] = []
    private var pending: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var cancelledSet = Set<UUID>()

    /// `true` = `cancel()` 只记一笔，**不唤醒** `search()`（由测试自己 `release`）。
    ///
    /// 用来模拟真 provider 的行为：`cancel` 只是「请停下」，`search()` 还要等设备
    /// 回包、socket 收尾才真正 return。默认 `false` 是为了让不关心这个细节的用例
    /// 少写一行——但「取消后槽位有没有提前释放」这类断言必须把它置 `true`，
    /// 否则根本构造不出「旧查询还在退出」的窗口。
    var cancelDefersReturn = false

    init(_ source: SearchSource) { self.source = source }

    func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        await search(text, queryID: queryID, owner: .ui, emit: emit)
    }

    func search(_ text: String, queryID: UUID, owner: SearchOwner,
                emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        calls.append((queryID, owner))
        await withCheckedContinuation { pending[queryID] = $0 }
        finished.append(queryID)
        let wasCancelled = cancelledSet.contains(queryID)
        emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                           state: wasCancelled ? .cancelled : .completed))
    }

    func cancel(queryID: UUID) {
        cancelled.append(queryID)
        cancelledSet.insert(queryID)
        guard !cancelDefersReturn else { return }
        // 真 provider 被取消时会自己发终态并返回；这里同样放行，模拟真实返回。
        pending.removeValue(forKey: queryID)?.resume()
    }

    /// 让这次搜索正常跑完。
    func release(_ queryID: UUID) {
        pending.removeValue(forKey: queryID)?.resume()
    }

    func started(_ queryID: UUID) -> Bool { calls.contains { $0.queryID == queryID } }
}

/// 时钟替身：让 deadline 可以确定地推进。
@MainActor
private final class TestClock {
    var now = Date(timeIntervalSince1970: 1_000_000)
    func advance(_ seconds: TimeInterval) { now = now.addingTimeInterval(seconds) }
}

/// 轮询等待某个条件成立。条件一满足立刻返回，超时才失败。
@MainActor
private func waitUntil(_ what: String,
                       timeout: TimeInterval = 3,
                       _ condition: @MainActor () -> Bool) async {
    let limit = Date().addingTimeInterval(timeout)
    while !condition() {
        if Date() > limit { XCTFail("等待超时：\(what)"); return }
        try? await Task.sleep(nanoseconds: 2_000_000)
    }
}

/// 等到 provider 真的进了 `search`（而不是只在调度器里占了槽位）。
@MainActor
private func waitStarted(_ p: ManualProvider, _ id: UUID, timeout: TimeInterval = 3) async {
    await waitUntil("provider 开始 \(id.uuidString.prefix(8))", timeout: timeout) { p.started(id) }
}

final class SearchSchedulerTests: XCTestCase {

    // MARK: - §1.6.4 #1  UI → UI：新查询取消自己的旧查询

    @MainActor func testNewUIQuerySupersedesPreviousUIQuery() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        var events = [ProviderEvent]()

        let first = UUID()
        s.submit(text: "旧", queryID: first, owner: .ui) { events.append($0) }
        await waitStarted(a, first)

        let second = UUID()
        s.submit(text: "新", queryID: second, owner: .ui) { events.append($0) }
        await waitStarted(a, second)

        XCTAssertEqual(a.cancelled, [first], "GUI 的新查询必须取消自己的旧查询")
        XCTAssertEqual(s.queuedTotal, 0, "同 owner 取代不能留下排队项")
        // 旧查询的终态必须是 cancelled，不能是 completed（否则界面会当成正常结果）。
        XCTAssertTrue(events.contains { $0.queryID == first && $0.state == .cancelled })
    }

    // MARK: - §1.6.4 #2（修正）同 session 的 MCP 请求**不自动取代**，改为排队

    /// 为什么与方案原文不同：`locate_many` 会展开成 5 条同 session 的子查询。
    /// 如果「同 owner 自动取代」，第 2 条会把第 1 条取消，**5 条只剩 1 条结果**。
    /// 所以取代是**调用方的意图**（GUI 打字），不是 owner 的属性；
    /// Agent 要取消自己的旧请求，走显式 `cancel` / `cancelAll`。
    @MainActor func testSameMCPSessionQueuesInsteadOfSuperseding() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let owner = SearchOwner.mcp(sessionID: "session-A")

        let first = UUID()
        s.submit(text: "旧", queryID: first, owner: owner) { _ in }
        await waitStarted(a, first)

        let second = UUID()
        s.submit(text: "新", queryID: second, owner: owner) { _ in }

        XCTAssertEqual(a.cancelled, [], "同 session 的连续请求不得互相取消")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [owner])

        a.release(first)
        await waitStarted(a, second)
    }

    // MARK: - §1.6.4 #3  UI + MCP A：互不取消

    @MainActor func testUIAndMCPDoNotCancelEachOther() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        var events = [ProviderEvent]()

        let gui = UUID()
        s.submit(text: "用户搜的", queryID: gui, owner: .ui) { events.append($0) }
        await waitStarted(a, gui)

        let agent = UUID()
        s.submit(text: "Agent 搜的", queryID: agent,
                 owner: .mcp(sessionID: "A")) { events.append($0) }

        // 关键断言：GUI 那条**没有被取消**，而且仍在跑。
        XCTAssertEqual(a.cancelled, [], "MCP 请求不得取消 GUI 查询")
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), gui, "正在跑的仍是 GUI 那条")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [.mcp(sessionID: "A")])

        // GUI 跑完后，Agent 那条才被放出来。
        a.release(gui)
        await waitStarted(a, agent)
        XCTAssertEqual(events.filter { $0.queryID == gui }.map(\.state), [.completed],
                       "GUI 的终态是正常完成，不是被取消")

        a.release(agent)
        await waitUntil("都结束") { s.queuedTotal == 0 && s.runningSources.isEmpty }
        XCTAssertEqual(a.finished, [gui, agent], "两条都真的跑完了")
    }

    // MARK: - §1.6.4 #4  MCP A + MCP B：互不取消，同 source 排队（FIFO）

    @MainActor func testTwoMCPSessionsQueueFIFOWithoutCancelling() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let ownerA = SearchOwner.mcp(sessionID: "A")
        let ownerB = SearchOwner.mcp(sessionID: "B")

        let qa = UUID(), qb = UUID()
        s.submit(text: "A", queryID: qa, owner: ownerA) { _ in }
        await waitStarted(a, qa)
        s.submit(text: "B", queryID: qb, owner: ownerB) { _ in }

        XCTAssertEqual(a.cancelled, [], "两个 Agent 之间不得互相取消")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [ownerB])

        a.release(qa)
        await waitStarted(a, qb)
        a.release(qb)
        await waitUntil("结束") { s.runningSources.isEmpty }

        XCTAssertEqual(a.finished, [qa, qb], "FIFO：先到的先跑")
    }

    // MARK: - §1.6.4 #5  locate_many：同 source 5 条串行，不自相残杀

    @MainActor func testFiveQueriesFromSameOwnerRunSerially() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let owner = SearchOwner.mcp(sessionID: "A")

        // 一次 locate_many 展开成 5 条同 session 子查询，**连续提交、不等完成**。
        let ids = (0..<5).map { _ in UUID() }
        for (i, id) in ids.enumerated() {
            s.submit(text: "q\(i)", queryID: id, owner: owner) { _ in }
        }
        await waitStarted(a, ids[0])
        XCTAssertEqual(s.queuedCount(sourceID: nasA.id), 4, "其余 4 条排队，不是被取消")

        for (i, id) in ids.enumerated() {
            await waitStarted(a, id)
            a.release(id)
            await waitUntil("第 \(i) 条完成") { a.finished.contains(id) }
        }

        XCTAssertEqual(a.finished, ids, "五条都跑完，顺序未被打乱")
        XCTAssertEqual(a.cancelled, [], "五条互为兄弟，不应有任何一条被取消")
    }

    // MARK: - §1.6.4 #6  GUI 插队只成为 next，不抢占 active

    @MainActor func testGUITakesNextSlotWithoutPreemptingActive() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])

        let activeQuery = UUID()
        s.submit(text: "Agent 在跑", queryID: activeQuery,
                 owner: .mcp(sessionID: "A")) { _ in }
        await waitStarted(a, activeQuery)

        // 已有两个不同 owner 在排队，GUI 后到。
        let mcpA = UUID(), mcpB = UUID(), gui = UUID()
        s.submit(text: "A2", queryID: mcpA, owner: .mcp(sessionID: "A")) { _ in }
        s.submit(text: "B", queryID: mcpB, owner: .mcp(sessionID: "B")) { _ in }
        s.submit(text: "用户", queryID: gui, owner: .ui) { _ in }

        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), activeQuery, "正在跑的完全没被动过")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id),
                       [.ui, .mcp(sessionID: "A"), .mcp(sessionID: "B")],
                       "GUI 插到队首，但排在 active 之后")
        XCTAssertEqual(a.cancelled, [])

        a.release(activeQuery)
        await waitStarted(a, gui)
        XCTAssertEqual(a.cancelled, [], "插队不是抢占：active 是正常跑完的")
    }

    // MARK: - §1.6.4 #7  deadline：排队超时后从队列移除

    @MainActor func testQueuedQueryIsRemovedAtDeadlineAndReportsTimeout() async {
        let clock = TestClock()
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a], now: { clock.now })
        s.queueWaitMs = 1_000
        var events = [ProviderEvent]()

        let active = UUID(), queued = UUID()
        s.submit(text: "在跑", queryID: active, owner: .ui) { events.append($0) }
        await waitStarted(a, active)
        s.submit(text: "排队", queryID: queued, owner: .mcp(sessionID: "A")) { events.append($0) }
        XCTAssertEqual(s.queuedTotal, 1)

        clock.advance(2)
        let expired = s.reapExpired()

        XCTAssertEqual(expired.map(\.queryID), [queued])
        XCTAssertEqual(expired.first?.state, .timedOut)
        XCTAssertEqual(s.queuedTotal, 0, "超时项必须离开队列")
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), active, "在跑的那条不受影响")
        XCTAssertTrue(events.contains { $0.queryID == queued && $0.state == .timedOut },
                      "调用方必须收到终态，否则界面永远转圈")
    }

    // MARK: - §1.6.4 #8  取消自己的排队项：发终态、不碰 provider

    /// 这条原来叫 `testCancelByQueryIDNeverTouchesAnotherOwnersQuery`，但它实际做的是
    /// 「Agent 取消自己的、GUI 取消自己的」——**没有构造跨 owner 的任何一步**，
    /// 名字比内容大。跨 owner 拒绝另立 #19 专门测（需要 `requester` 参数才测得出来）。
    @MainActor func testCancelOwnQueuedQueryEmitsTerminalWithoutTouchingProvider() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        var events = [ProviderEvent]()

        let gui = UUID(), agent = UUID()
        s.submit(text: "GUI", queryID: gui, owner: .ui) { events.append($0) }
        await waitStarted(a, gui)
        s.submit(text: "Agent", queryID: agent, owner: .mcp(sessionID: "A")) { events.append($0) }

        s.cancel(queryID: agent, requester: .mcp(sessionID: "A"))

        XCTAssertEqual(a.cancelled, [], "取消排队项不应触碰 provider")
        XCTAssertEqual(s.queuedTotal, 0)
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), gui, "在跑的 GUI 不受影响")
        XCTAssertEqual(events.filter { $0.queryID == agent }.map(\.state), [.cancelled],
                       "排队项被取消也必须收到终态，否则调用方永远 pending")
        XCTAssertEqual(events.filter { $0.queryID == agent }.map(\.isTerminal), [true])
    }

    // MARK: - §1.6.4 #9  source 隔离：NAS A 忙不影响 NAS B

    @MainActor func testBusySourceDoesNotBlockAnotherSource() async {
        let a = ManualProvider(nasA), b = ManualProvider(nasB)
        let s = SearchScheduler(providers: [a, b])

        let slow = UUID()
        // ★ 必须点名只搜 A：不传 sources 等于「打全部来源」，
        //   那样 A 和 B 都会被这次查询占住，后面测的就不是「A 忙而 B 空闲」了。
        s.submit(text: "A 上很慢的一次", queryID: slow, owner: .ui,
                 sources: [nasA.id]) { _ in }
        await waitStarted(a, slow)

        let onB = UUID()
        s.submit(text: "B 上的查询", queryID: onB, owner: .mcp(sessionID: "A")) { _ in }
        await waitStarted(b, onB)

        XCTAssertEqual(s.queuedCount(sourceID: nasB.id), 0, "B 不该排队等 A")
        XCTAssertEqual(a.cancelled, [])
    }

    // MARK: - §1.6.4 #10  GUI 持续输入导致 MCP 饥饿：队列不泄漏

    @MainActor func testContinuousGUITrafficDoesNotLeakQueue() async {
        let clock = TestClock()
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a], now: { clock.now })
        s.queueWaitMs = 1_000

        // 一个 MCP 查询在跑（占着来源）。
        let mcpActive = UUID()
        s.submit(text: "Agent", queryID: mcpActive, owner: .mcp(sessionID: "A")) { _ in }
        await waitStarted(a, mcpActive)

        // MCP 再排一条，用户随后连续输入 10 次，每次都插到队首。
        let starving = UUID()
        s.submit(text: "排队的 Agent", queryID: starving, owner: .mcp(sessionID: "B")) { _ in }
        for i in 0..<10 {
            let gui = UUID()
            s.submit(text: "a" + String(repeating: "b", count: i), queryID: gui, owner: .ui) { _ in }
            XCTAssertEqual(s.queuedCount(sourceID: nasA.id), 2,
                           "GUI 的旧排队项被自己取代，队列恒为 2（1 GUI + 1 MCP）")
        }

        clock.advance(2)
        let expired = s.reapExpired()
        XCTAssertEqual(s.queuedTotal, 0, "持续插队不得留下任何泄漏项")
        XCTAssertTrue(expired.contains { $0.queryID == starving }, "MCP 那条到 deadline 必须被移除")
        XCTAssertEqual(expired.count, 2, "GUI 最后那条也在同一次 tick 里超时")
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), mcpActive, "正在跑的不受 deadline 影响")
    }

    // MARK: - §1.6.4 #11  排队中的请求被调用方取消（Helper 退出）

    @MainActor func testCancelAllForOwnerRemovesQueuedWorkImmediately() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let agent = SearchOwner.mcp(sessionID: "A")

        let active = UUID()
        s.submit(text: "GUI 在跑", queryID: active, owner: .ui) { _ in }
        await waitStarted(a, active)

        let q1 = UUID(), q2 = UUID()
        s.submit(text: "排 1", queryID: q1, owner: agent) { _ in }
        s.submit(text: "排 2", queryID: q2, owner: agent) { _ in }
        XCTAssertEqual(s.queuedTotal, 2)

        s.cancelAll(owner: agent)

        XCTAssertEqual(s.queuedTotal, 0, "会话结束时排队项立刻移除，不必等 deadline")
        XCTAssertEqual(a.cancelled, [], "只清排队项，不动 provider 上正在跑的 GUI 查询")
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), active)
    }

    // MARK: - 协议派发：owner 必须真的传到 provider

    /// 这条守的是 Swift 的一个坑：如果带 owner 的 `search` 只写成 protocol extension
    /// 方法而不是协议要求，通过 `any SearchProvider` 调用时会静态派发到默认实现，
    /// provider 里写的 owner 判断**根本不会执行**，而且编译期没有任何提示。
    @MainActor func testOwnerReachesProviderImplementation() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let agent = SearchOwner.mcp(sessionID: "session-X")

        let id = UUID()
        s.submit(text: "x", queryID: id, owner: agent) { _ in }
        await waitStarted(a, id)

        XCTAssertEqual(a.calls.first?.owner, agent, "provider 收到的必须是真实 owner，不是默认的 .ui")
    }

    // MARK: - 一次提交跨多个来源：各来源独立排队

    @MainActor func testOneSubmitFansOutToAllSourcesWithIndependentQueues() async {
        let a = ManualProvider(nasA), b = ManualProvider(nasB)
        let s = SearchScheduler(providers: [a, b])

        let id = UUID()
        s.submit(text: "资料", queryID: id, owner: .ui) { _ in }
        await waitStarted(a, id)
        await waitStarted(b, id)

        XCTAssertEqual(a.calls.map(\.queryID), [id])
        XCTAssertEqual(b.calls.map(\.queryID), [id])
        XCTAssertEqual(s.queuedTotal, 0)
    }

    // MARK: - sources 过滤

    @MainActor func testSubmitHonoursSourceFilter() async {
        let a = ManualProvider(nasA), b = ManualProvider(nasB)
        let s = SearchScheduler(providers: [a, b])

        let id = UUID()
        s.submit(text: "只搜 A", queryID: id, owner: .ui, sources: [nasA.id]) { _ in }
        await waitStarted(a, id)

        XCTAssertEqual(b.calls.count, 0, "未点名的来源不得收到请求")
        XCTAssertEqual(s.queuedTotal, 0)
    }

    // =====================================================================
    // 第二阶段（v0.7）：状态机补洞。以下 6 条各自对应一个**曾经会漏**的组合。
    //
    // 为什么加：前 14 条把「已写出来的场景」跑绿了，但漏掉的都是状态**组合**，
    // 而并发调度器只在组合处出事。全绿不等于没有洞，只等于已知路径没问题。
    // =====================================================================

    // MARK: - #15 ★ 硬 Gate：UI 在跑 + MCP 排队 + 新 UI 取代 → 来源不得卡死

    /// 曾经的 Bug：取代时直接把 `running[sid]` 清空，然后 enqueue 发现
    /// 「running 为空但 queue 非空」，于是只排队不启动；而旧查询返回时
    /// `finished` 的 guard 又因为槽位已空而 return。结果：没有任何人推进队首。
    @MainActor func testUISupersedeWhileMCPQueuedDoesNotStallSource() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        let agent = SearchOwner.mcp(sessionID: "A")

        let gui1 = UUID()
        s.submit(text: "第一轮", queryID: gui1, owner: .ui) { _ in }
        await waitStarted(a, gui1)

        let agentQuery = UUID()
        s.submit(text: "Agent", queryID: agentQuery, owner: agent) { _ in }
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [agent])

        // 用户继续打字：新 GUI 取代旧 GUI，而队列里还躺着一条 MCP。
        let gui2 = UUID()
        s.submit(text: "第二轮", queryID: gui2, owner: .ui) { _ in }

        XCTAssertEqual(a.cancelled, [gui1], "只取消自己的旧查询")
        XCTAssertNil(s.runningQuery(sourceID: nasA.id), "旧查询已退出执行位")
        XCTAssertEqual(s.cancellingQuery(sourceID: nasA.id), gui1,
                       "但它还占着槽位——cancel 不等于 finished")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [.ui, agent],
                       "新 GUI 插队首，MCP 仍排在它后面")

        // 关键：旧查询真正返回后，队列必须自己往前走，不能停在这里。
        await waitStarted(a, gui2)
        a.release(gui2)
        await waitStarted(a, agentQuery)
        a.release(agentQuery)
        await waitUntil("全部结束") { s.runningSources.isEmpty && s.cancellingSources.isEmpty }

        XCTAssertEqual(a.finished, [gui1, gui2, agentQuery],
                       "三轮都真的跑过（gui1 被取消后返回）")
        XCTAssertFalse(a.cancelled.contains(agentQuery), "MCP 那条从未被 UI 取消")
        XCTAssertEqual(s.queuedTotal, 0)
    }

    // MARK: - #16 排队中的 GUI 被新 GUI 取代 → 必须收到 cancelled 终态

    /// 曾经的 Bug：清理队列是 `filter` 直接删，删掉的项**永远收不到终态**。
    /// 表现为「某个 pending 状态一直不结束」——界面转圈不停，而且没有任何报错。
    @MainActor func testSupersededQueuedQueryReceivesCancelledTerminal() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])
        var events = [ProviderEvent]()

        // MCP 占着来源，GUI 只能排队。
        let active = UUID()
        s.submit(text: "Agent", queryID: active, owner: .mcp(sessionID: "A")) { events.append($0) }
        await waitStarted(a, active)

        let gui1 = UUID()
        s.submit(text: "第一轮", queryID: gui1, owner: .ui) { events.append($0) }
        XCTAssertEqual(s.queuedTotal, 1)

        let gui2 = UUID()
        s.submit(text: "第二轮", queryID: gui2, owner: .ui) { events.append($0) }

        let gui1Events = events.filter { $0.queryID == gui1 }
        XCTAssertEqual(gui1Events.map(\.state), [.cancelled],
                       "被取代的排队项必须恰好收到一个 cancelled 终态")
        XCTAssertEqual(gui1Events.map(\.isTerminal), [true])
        XCTAssertNil(gui1Events.first?.message,
                     "被新输入取代是正常路径，不能塞 message——App 层会把它当用户可见警告")
        XCTAssertEqual(s.queuedOwners(sourceID: nasA.id), [.ui])
        XCTAssertFalse(a.cancelled.contains(gui1), "它从没进过 provider，不该取消 provider")
    }

    // MARK: - #17 ★ 硬 Gate：Agent A 在跑 + Agent A 排队 + cancelAll(A) → 排队那条绝不能被启动

    /// 曾经的 Bug：`cancelAll` 先 cancel running 再 `drain`，而队首往往就是同一个
    /// owner 的排队项——于是「要求全部取消」反过来把它启动了。
    @MainActor func testCancelAllNeverStartsTheOwnersQueuedWork() async {
        let a = ManualProvider(nasA)
        a.cancelDefersReturn = true          // 模拟「provider 不会立刻返回」
        let s = SearchScheduler(providers: [a])
        let agent = SearchOwner.mcp(sessionID: "A")
        var events = [ProviderEvent]()

        let q1 = UUID(), q2 = UUID()
        s.submit(text: "在跑", queryID: q1, owner: agent) { events.append($0) }
        await waitStarted(a, q1)
        s.submit(text: "排队", queryID: q2, owner: agent) { events.append($0) }
        XCTAssertEqual(s.queuedTotal, 1)

        s.cancelAll(owner: agent)

        XCTAssertEqual(s.queuedTotal, 0, "排队项立刻移除，不必等 deadline")
        XCTAssertEqual(events.filter { $0.queryID == q2 }.map(\.state), [.cancelled],
                       "排队的 q2 必须有终态")
        XCTAssertFalse(a.started(q2), "★ 排队的 q2 绝对不能因为 drain 被启动")
        XCTAssertEqual(a.cancelled, [q1], "只对真正在跑的那条请求 provider 取消")
        XCTAssertEqual(s.cancellingQuery(sourceID: nasA.id), q1,
                       "q1 还占着槽位，等它真正返回")

        a.release(q1)                        // provider 这次真的返回了
        await waitUntil("槽位释放") { s.cancellingQuery(sourceID: nasA.id) == nil }
        XCTAssertFalse(a.started(q2), "★ 释放槽位后也不得启动已被取消的 q2")
        XCTAssertTrue(s.runningSources.isEmpty)
        XCTAssertEqual(a.finished, [q1])
    }

    // MARK: - #18 ★ 硬 Gate：取消后，旧 search 真正返回前新查询不得进 provider

    /// 「同 source 一次最多执行一个请求」这条，不能在 `cancel()` 里靠清空槽位来兑现。
    ///
    /// ★ 同时锁住**终态契约**：`running → cancelling → provider 真正返回`这条路上，
    /// 调用方必须拿到**恰好一个** `isTerminal` 的 `.cancelled`。v0.7 只对「排队时被取消」
    /// 断言过 `isComplete`，而这条路径一条断言都没有——两边语义一分叉就没人发现。
    @MainActor func testNewQueryWaitsForCancellingSearchToActuallyReturn() async {
        let a = ManualProvider(nasA)
        a.cancelDefersReturn = true
        let s = SearchScheduler(providers: [a])
        var events = [ProviderEvent]()

        let old = UUID()
        s.submit(text: "旧", queryID: old, owner: .ui) { events.append($0) }
        await waitStarted(a, old)

        s.cancel(queryID: old, requester: .ui)
        XCTAssertEqual(s.cancellingQuery(sourceID: nasA.id), old)
        XCTAssertNil(s.runningQuery(sourceID: nasA.id))
        XCTAssertEqual(a.cancelled, [old])

        let new = UUID()
        s.submit(text: "新", queryID: new, owner: .ui) { events.append($0) }

        XCTAssertEqual(a.calls.count, 1, "★ 旧查询还在退出，新查询绝不能进 provider")
        XCTAssertFalse(a.started(new))
        XCTAssertEqual(a.cancelled, [old], "已在取消中的项不得被重复取消（provider.cancel 不幂等）")

        a.release(old)                       // 旧 search 真正 return
        await waitStarted(a, new)
        XCTAssertEqual(a.calls.count, 2)
        XCTAssertEqual(a.calls.map(\.queryID), [old, new], "顺序不能颠倒")
        a.release(new)
        await waitUntil("全部结束") { s.runningSources.isEmpty && s.cancellingSources.isEmpty }

        let oldTerminals = events.filter { $0.queryID == old && $0.isTerminal }
        XCTAssertEqual(oldTerminals.map(\.state), [.cancelled],
                       "在跑阶段被取消也必须恰好收到一个终态——否则调用方永远 pending")
        XCTAssertEqual(oldTerminals.map(\.isMetadataUpdate), [false])
        XCTAssertNil(oldTerminals.first?.message,
                     "取消是正常路径，message 必须是 nil（App 层会把非空 message 当用户可见警告）")
    }

    // MARK: - #19 跨 owner 取消：必须拒绝

    /// 光有 `cancel(queryID:)` 时，任何拿到别人 queryID 的调用方都能取消别人的查询——
    /// 「owner 隔离」只写在注释里，API 并不强制。现在 `requester` 是必填参数。
    @MainActor func testCrossOwnerCancelIsRejected() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])

        let gui = UUID()
        s.submit(text: "GUI 的", queryID: gui, owner: .ui) { _ in }
        await waitStarted(a, gui)

        let intruder = SearchOwner.mcp(sessionID: "A")
        s.cancel(queryID: gui, requester: intruder)

        XCTAssertEqual(a.cancelled, [], "跨 owner 取消绝不能到 provider")
        XCTAssertEqual(s.runningQuery(sourceID: nasA.id), gui, "GUI 的查询仍在跑")
        XCTAssertNil(s.cancellingQuery(sourceID: nasA.id))
        XCTAssertEqual(s.rejectedCancelCount, 1, "拒绝必须可观测，不能静默")
        XCTAssertEqual(s.lastRejectedCancel?.requester, intruder)
        XCTAssertEqual(s.lastRejectedCancel?.targetOwner, .ui)
        XCTAssertEqual(s.lastRejectedCancel?.queryID, gui)
        XCTAssertEqual(s.lastRejectedCancel?.sourceID, nasA.id)

        // 排队项同理：别的 owner 也删不掉。
        let queued = UUID()
        s.submit(text: "排队的", queryID: queued, owner: .ui) { _ in }
        s.cancel(queryID: queued, requester: intruder)
        XCTAssertEqual(s.queuedTotal, 1, "跨 owner 不得从队列里移除")
        XCTAssertEqual(s.rejectedCancelCount, 2)
    }

    // MARK: - #20 已完成的查询不得在下一次取代时被再次取消

    /// `lastQuery` 的典型后果：正常跑完的旧 queryID 仍被记着，下一次 GUI 打字
    /// 会再 `provider.cancel` 它一遍。`cancel` 不幂等，诊断计数与状态都会脏。
    /// 现在的做法是不另存「最后 Query」——真实的活跃状态就在 running/cancelling/queues 里。
    @MainActor func testSupersedeDoesNotCancelAlreadyCompletedQuery() async {
        let a = ManualProvider(nasA)
        let s = SearchScheduler(providers: [a])

        let first = UUID()
        s.submit(text: "第一轮", queryID: first, owner: .ui) { _ in }
        await waitStarted(a, first)
        a.release(first)
        await waitUntil("第一轮彻底结束") {
            s.runningSources.isEmpty && s.cancellingSources.isEmpty && s.queuedTotal == 0
        }

        let second = UUID()
        s.submit(text: "第二轮", queryID: second, owner: .ui) { _ in }
        await waitStarted(a, second)

        XCTAssertEqual(a.cancelled, [], "已完成的旧查询不得被再次取消")
        XCTAssertEqual(a.finished, [first])
    }
}
