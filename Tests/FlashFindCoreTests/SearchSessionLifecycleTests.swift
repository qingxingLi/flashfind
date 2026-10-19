import XCTest
@testable import FlashFindCore

/// 第三批回归：统一 queryID（P1-01）与搜索状态机（P1-02）、自动重连（P1-03）。
///
/// 这里锁的是**搜索这件事本身的状态**，不是设备行为：
/// 一次搜索必须能被一个 ID 从头串到尾，必须走完一条合法的状态轨迹，
/// 并且「成功但设备上有遗留任务」必须被记成 orphaned 而不是 finished。
@MainActor
final class SearchSessionLifecycleTests: XCTestCase {

    /// 可脚本化的 Bridge 桩。代次可变，用来模拟核心重启。
    private final class Bridge: MyNASBridgeTransport {
        var processGeneration: Int = 1
        var responses: [String: [String: Any]] = [:]
        /// 命令 → 抛错（模拟传输层失败）。
        var failures: Set<String> = []
        /// 在「已发出一批结果、终端响应还没回来」这个窗口里触发的钩子。
        /// 用来模拟用户在这一刻取消（设备侧任务已建，正是最容易遗留的时刻）。
        var onBatch: (() -> Void)?
        private(set) var calls: [String] = []
        /// 清空调用记录，便于只断言「某一段」的命令序列。
        func resetCalls() { calls.removeAll() }

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(command)
            if failures.contains(command) { throw FlashFindError.message("\(command) 失败（注入）") }
            // 搜索：先发一批结果，再返回终端响应。
            if command == "search" {
                event?(["event": "batch", "queryID": queryID, "sourceID": sourceID, "files": [[:]]])
                onBatch?()
            }
            guard let response = responses[command] else {
                throw FlashFindError.message("未预期的命令：\(command)")
            }
            return response
        }
    }

    private let scope = "/示例共享"

    private func readyProvider(_ bridge: Bridge) async throws -> NASSearchProvider {
        bridge.responses["discover"] = ["event": "capabilities"]
        bridge.responses["login"] = ["event": "authState", "state": "scopeReady", "isManager": false]
        bridge.responses["selectScope"] = ["event": "scopeState", "state": "scopeReady", "scopes": [scope]]
        bridge.responses["search"] = ["event": "terminal", "resultState": "completed",
                                      "isComplete": true, "cleanupState": "cleaned", "reportedTotal": 1]
        let subject = NASSearchProvider(
            bridge: bridge,
            config: NASSourceConfig(host: "192.168.1.96", port: 5001,
                                    username: "nasuser", scopes: [scope]),
            port: 5001)
        try await subject.login(account: "nasuser", password: "p")
        _ = try await subject.selectScopes([scope])
        XCTAssertTrue(subject.ready, "前置：应已就绪")
        return subject
    }

    // MARK: - P1-02 状态机本身

    /// 一次正常搜索必须走完一整条合法轨迹，且**没有任何一条非法转移**。
    func testHealthySearchLeavesACompleteTrail() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)

        await subject.search("报告", queryID: UUID()) { _ in }

        XCTAssertEqual(subject.lastSessionTrail, ["starting", "fetching", "stopping", "cleaning", "finished"],
                       "正常搜索的轨迹应当完整：轨迹=\(subject.lastSessionTrail)")
        XCTAssertTrue(subject.lastSessionRejected.isEmpty,
                      "不允许出现非法转移：\(subject.lastSessionRejected)")
    }

    /// 终结态之后不得再回到进行中。
    ///
    /// 这条锁的是「已结束的搜索又收到一批结果」——它在旧的 Bool 组合里
    /// 根本无法表达，只会表现为结果莫名其妙多出来一批。
    func testTerminalStateCannotBeRevived() {
        let machine = SearchSessionMachine(session: SearchSession(queryID: UUID(), sourceID: "s"))
        XCTAssertTrue(machine.transition(to: .starting))
        XCTAssertTrue(machine.forceTerminal(.finished))
        XCTAssertFalse(machine.transition(to: .fetching), "已终结就不许再回到取结果")
        XCTAssertEqual(machine.rejected.count, 1)
        XCTAssertEqual(machine.state, .finished, "被拒的转移不得改变状态")
    }

    /// 结果全部拿到了，但设备上的任务没清掉 ⇒ 必须记 orphaned。
    ///
    /// 记成 finished 就等于宣布「这次很成功」，而实际上设备侧多了一个
    /// 可能永远清不掉的任务——累积起来就是「File Station 正常、闪寻搜不到」。
    func testCleanupPendingIsOrphanedNotFinished() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        bridge.responses["search"] = ["event": "terminal", "resultState": "completed",
                                      "isComplete": true, "cleanupState": "pending", "reportedTotal": 1]

        await subject.search("报告", queryID: UUID()) { _ in }

        XCTAssertEqual(subject.lastSessionTrail.last, "orphaned",
                       "cleanup 没成功就不能记 finished：轨迹=\(subject.lastSessionTrail)")
    }

    /// 传输层在设备任务已建之后炸掉 ⇒ orphaned，而不是 failed。
    /// 两者的处置完全不同：前者要去看设备上的遗留任务，后者是登录/参数问题。
    func testTransportFailureAfterBatchesIsOrphaned() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        bridge.failures = ["search"]

        await subject.search("报告", queryID: UUID()) { _ in }

        XCTAssertEqual(subject.lastSessionTrail.last, "orphaned",
                       "任务已建就崩 ⇒ 记 orphaned：轨迹=\(subject.lastSessionTrail)")
    }

    /// 在「任务已建、终端响应还没回来」时取消 ⇒ 记 orphaned。
    ///
    /// 这是最容易遗留设备任务的时刻；记成 finished 就会宣称一次
    /// 「干干净净的结束」，而实际上没人知道设备上那个任务后来怎么样了。
    func testCancelledSearchIsRecordedAsOrphaned() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        let id = UUID()
        bridge.onBatch = { subject.cancel(queryID: id) }

        await subject.search("报告", queryID: id) { _ in }

        XCTAssertEqual(subject.lastSessionTrail.last, "orphaned",
                       "任务已建时取消 ⇒ 记 orphaned：轨迹=\(subject.lastSessionTrail)")
        // cancel 是 fire-and-forget 的 Task（不能让取消动作阻塞调用方），
        // 所以要等它真正落地再断言，否则测的是「还没轮到它跑」。
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(bridge.calls.contains("cancel"), "取消必须真的发到设备侧：\(bridge.calls)")
    }

    // MARK: - P1-01 统一 queryID

    /// 同一个 queryID 必须贯穿 AppModel → Coordinator → Provider → 事件。
    ///
    /// 旧行为：Coordinator 自己另造一个 UUID，于是界面手里的 ID 与事件里的
    /// ID 是两个东西，取消与旧结果迟到时无法判断「这是哪一次搜索」。
    func testQueryIDIsPassedThroughEndToEnd() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        let coordinator = SearchCoordinator(providers: [subject])
        let mine = UUID()
        var seen: [UUID] = []

        coordinator.search("报告", sources: nil, queryID: mine) { event in seen.append(event.queryID) }
        // 等防抖窗口过（search 不走防抖，但事件回调是异步的）。
        try await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertTrue(coordinator.queryID == mine, "Coordinator 必须沿用调用方给的 queryID")
        XCTAssertTrue(seen.allSatisfy { $0 == mine },
                      "事件里的 queryID 必须就是调用方那个：\(seen.map(\.uuidString))")
    }

    // MARK: - P1-03 自动重连

    /// 核心重启后能自己恢复 ⇒ 用户不需要手动重连，搜索照常出结果。
    func testCoreRestartRecoversAutomatically() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        var recovered = 0
        subject.autoReconnect = { provider in
            recovered += 1
            _ = try? await provider.discover()
            try? await provider.login(account: "nasuser", password: "p")
            return (try? await provider.selectScopes([self.scope])) ?? false
        }
        bridge.processGeneration = 2 // 核心重启

        var states: [ProviderSearchState] = []
        await subject.search("报告", queryID: UUID()) { states.append($0.state) }

        XCTAssertEqual(recovered, 1, "核心重启后应当尝试一次自动恢复")
        XCTAssertFalse(states.contains(.failed), "自动恢复成功就不该报失败：\(states)")
        XCTAssertTrue(subject.ready, "恢复后应回到可搜索状态")
        XCTAssertFalse(subject.needsReconnectAfterCoreRestart, "代次应已同步到新核心")
    }

    /// 没有注入重连钩子时，行为退回「如实报需要重新连接」——不能假装连着。
    func testWithoutHookItStillReportsNeedToReconnect() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        bridge.processGeneration = 2

        var states: [ProviderSearchState] = []
        var messages: [String] = []
        await subject.search("报告", queryID: UUID()) { states.append($0.state); messages.append($0.message ?? "") }

        XCTAssertFalse(subject.ready, "恢复不了就必须复位，不能继续显示已连接")
        XCTAssertEqual(states, [.failed])
        XCTAssertTrue(messages.first?.contains("重新连接") == true, "要说清该做什么：\(messages)")
    }

    /// 恢复不了时不许每次搜索都重试一轮登录——
    /// 设备可能正在退化窗口里，反复撞只会把它推得更深。
    func testFailedRecoveryIsNotRetriedOnEverySearch() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        var attempts = 0
        subject.autoReconnect = { _ in attempts += 1; return false }
        bridge.processGeneration = 2

        await subject.search("报告", queryID: UUID()) { _ in }
        await subject.search("报告", queryID: UUID()) { _ in }
        await subject.search("季度", queryID: UUID()) { _ in }

        XCTAssertEqual(attempts, 1,
                       "冷却窗口内不该反复重试登录（会把设备推进更深的退化窗口）：实际 \(attempts) 次")
    }

    /// 自动重放的顺序必须是 discover → login → 重新绑定范围，三步缺一不可。
    func testAutoReconnectReplaysTheFullHandshake() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        subject.autoReconnect = { provider in
            await NASAutoReconnect.recover(provider) {
                NASAutoReconnect.Credential(account: provider.config.username, password: "p")
            }
        }
        bridge.processGeneration = 2
        bridge.resetCalls()

        var states: [ProviderSearchState] = []
        await subject.search("报告", queryID: UUID()) { states.append($0.state) }

        XCTAssertEqual(bridge.calls.prefix(3), ["discover", "login", "selectScope"],
                       "重放顺序必须是 discover → login → 绑定范围：\(bridge.calls)")
        XCTAssertTrue(subject.ready, "三步走完才谈得上恢复")
    }

    /// 没有可用凭据时**不许**拿空密码去撞设备（会触发设备的防暴力破解）。
    func testEmptyCredentialSkipsReconnect() async throws {
        let bridge = Bridge()
        let subject = try await readyProvider(bridge)
        var asked = 0
        subject.autoReconnect = { provider in
            asked += 1
            return await NASAutoReconnect.recover(provider) { nil }
        }
        bridge.processGeneration = 2
        bridge.resetCalls()

        await subject.search("报告", queryID: UUID()) { _ in }

        XCTAssertFalse(bridge.calls.contains("login"),
                       "没有凭据就不许发登录请求：\(bridge.calls)")
        XCTAssertEqual(asked, 1)
    }
}
