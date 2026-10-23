import XCTest
@testable import FlashFindCore

/// 「搜索结束后占用没释放」的回归测试。
///
/// ## 现场
///
/// 2026-10-22 实测：一次搜索正常结束后，换一个调用方（GUI ↔ MCP 会话）再搜同一台 NAS，
/// 会立刻拿到「这个来源正在被另一个调用方搜索，请稍后重试」，而设备侧其实早就空了。
/// 界面和 MCP 双向都会撞上，MCP 再把这类失败映射成 `source_unavailable`，
/// 现场看起来就像「NAS 不可用」。
///
/// ## 根因
///
/// `activeMachine` 只在 `cancel()` / `disconnect()` / 被新查询取代时被摘掉，
/// **正常结束的路径上从来没摘过**。于是：
/// * 同一 owner 看不出来 —— 它走「取代」分支，顺手把旧的清掉了；
/// * 换 owner 就必然撞上那条不变量检查（它本来只该在调度器被绕过时才触发）。
///
/// 这三条用例分别锁三件事：换 owner 能搜、真的在跑时仍然挡住、迟到补发窗口的边界。
@MainActor
final class NASSourceSlotReleaseTests: XCTestCase {

    // MARK: - 测试替身

    /// 可脚本化的桥：`search` 能停在闸门前，用来制造「真的还在跑」的窗口。
    private final class Bridge: MyNASBridgeTransport {
        var files: [[String: Any]] = []
        var gate: Gate?
        var searchCount = 0

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any],
                     event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            switch command {
            case "discover":
                return ["event": "capabilities"]
            case "login":
                return ["event": "authState", "state": "scopeReady"]
            case "search":
                searchCount += 1
                if let gate { await gate.wait() }
                event?(["event": "batch", "sourceID": sourceID, "queryID": queryID, "files": files])
                return ["resultState": "completed", "isComplete": true]
            default:
                return ["event": "controlAck"]
            }
        }
    }

    /// 闸门：与 `NASSearchPipelineTests.ScriptGate` 同一套路 —— 靠 `Task.yield()` 让出
    /// 主线程，让「谁先谁后」变成确定的顺序，而不是拿 `sleep` 赌调度。
    private final class Gate {
        private(set) var arrived = false
        var open = false

        func wait() async {
            arrived = true
            for _ in 0..<20_000 {
                if open { return }
                await Task.yield()
            }
        }
    }

    /// 事件收集器。用引用类型是因为 `search` 的 emit 是 escaping 闭包，
    /// 直接捕获局部 `var` 在 Swift 6 里会变成并发改写的告警。
    private final class Sink {
        var events: [ProviderEvent] = []
        var messages: [String] { events.compactMap(\.message) }
        var last: ProviderEvent? { events.last }
    }

    private func makeProvider(_ bridge: Bridge) async throws -> NASSearchProvider {
        let config = NASSourceConfig(id: "nas-slot", name: "NAS 槽位", vendor: .synology,
                                     host: "192.168.1.96", port: 5001, username: "u",
                                     scope: "/示例共享")
        let provider = NASSearchProvider(bridge: bridge, config: config, port: 5001)
        // 与产品连接流程一致：discover + login 之后 `ready` 才是 true。
        _ = try await provider.discover()
        try await provider.login(account: "u", password: "p")
        XCTAssertTrue(provider.ready, "装配完必须就绪，否则后面的失败与占用无关")
        return provider
    }

    // MARK: - 用例

    /// ★ 主回归：第一次搜索正常结束后，**另一个 owner** 必须能立刻搜。
    ///
    /// 修之前这里会拿到 `.failed` + 「这个来源正在被另一个调用方搜索」，
    /// 因为 `activeMachine` 还挂着上一次那个已经终结的状态机。
    func testAnotherOwnerCanSearchAfterTheQueryCompleted() async throws {
        let provider = try await makeProvider(Bridge())

        let first = UUID()
        let firstSink = Sink()
        await provider.search("投诉台账", queryID: first, owner: .ui) { firstSink.events.append($0) }
        XCTAssertEqual(firstSink.last?.state, .completed, "第一次搜索本身要先正常结束")

        let second = UUID()
        let secondSink = Sink()
        await provider.search("投诉台账", queryID: second, owner: .mcp(sessionID: "s-1")) {
            secondSink.events.append($0)
        }

        XCTAssertEqual(secondSink.last?.state, .completed,
                       "换调用方后被挡了：\(secondSink.messages)")
        XCTAssertFalse(secondSink.messages.contains { $0.contains("另一个调用方") },
                       "结束后不该再报占用：\(secondSink.messages)")
    }

    /// 反方向的顺序（MCP 先、GUI 后）同样是主回归 —— 现场两种方向都撞过。
    func testTheUICanSearchAfterAnMCPQueryCompleted() async throws {
        let provider = try await makeProvider(Bridge())

        let agentQuery = UUID()
        let agentSink = Sink()
        await provider.search("投诉台账", queryID: agentQuery, owner: .mcp(sessionID: "s-2")) {
            agentSink.events.append($0)
        }
        XCTAssertEqual(agentSink.last?.state, .completed)

        let uiQuery = UUID()
        let uiSink = Sink()
        await provider.search("投诉台账", queryID: uiQuery, owner: .ui) { uiSink.events.append($0) }

        XCTAssertEqual(uiSink.last?.state, .completed, "GUI 被 MCP 的残留占用挡住了：\(uiSink.messages)")
    }

    /// ★ 不变量没被削弱：**真的还在跑**的时候，跨 owner 仍然必须拒绝。
    ///
    /// 这条是第一条的对照 —— 否则「修好占用」很容易变成「把互斥整个拆掉」。
    func testAnotherOwnerIsStillRejectedWhileTheQueryIsReallyRunning() async throws {
        let bridge = Bridge()
        let gate = Gate()
        bridge.gate = gate
        let provider = try await makeProvider(bridge)

        let first = UUID()
        let firstSink = Sink()
        let running = Task { await provider.search("第一轮", queryID: first, owner: .ui) {
            firstSink.events.append($0)
        } }
        for _ in 0..<2_000 where !gate.arrived { await Task.yield() }
        XCTAssertTrue(gate.arrived, "桥没有停在 search 里，测试前提不成立")

        let second = UUID()
        let secondSink = Sink()
        await provider.search("第二轮", queryID: second, owner: .mcp(sessionID: "s-3")) {
            secondSink.events.append($0)
        }
        XCTAssertEqual(secondSink.last?.state, .failed, "真的在跑时必须拒绝，不能放两个任务进设备")
        XCTAssertTrue(secondSink.messages.contains { $0.contains("另一个调用方") },
                      "拒绝的理由要说得出来：\(secondSink.messages)")

        gate.open = true
        await running.value
        XCTAssertEqual(firstSink.last?.state, .completed, "被保护的那一次要正常跑完")
    }

    /// ★ 迟到补发窗口：搜索返回**之后**才到的「结果行可打开」必须还放行。
    ///
    /// 这条防的是修占用的副作用：解析挂载路径最多要 3 秒，那时 `activeMachine`
    /// 已经被摘掉了。若只按「当前查询」判断，NAS 结果会永远停在「不可打开」。
    func testLateMetadataIsStillAcceptedForTheQueryThatJustFinished() async throws {
        let provider = try await makeProvider(Bridge())

        let first = UUID()
        await provider.search("投诉台账", queryID: first, owner: .ui) { _ in }
        XCTAssertTrue(provider.acceptsLateMetadata(for: first),
                      "刚结束的那次，迟到补发必须还放行")
        XCTAssertFalse(provider.acceptsLateMetadata(for: UUID()),
                       "从没跑过的查询不该被放行")
    }

    /// 但窗口只能覆盖「刚刚那一次」：新查询一开始就必须关掉，否则旧查询的元数据
    /// 会把新查询的结果行改写成旧的那批。
    func testTheLateMetadataWindowClosesWhenANewQueryStarts() async throws {
        let provider = try await makeProvider(Bridge())

        let first = UUID()
        await provider.search("第一轮", queryID: first, owner: .ui) { _ in }
        XCTAssertTrue(provider.acceptsLateMetadata(for: first))

        let second = UUID()
        await provider.search("第二轮", queryID: second, owner: .ui) { _ in }
        XCTAssertFalse(provider.acceptsLateMetadata(for: first),
                       "新查询一开始，上一次的补发窗口必须关掉")
        XCTAssertTrue(provider.acceptsLateMetadata(for: second))
    }
}
