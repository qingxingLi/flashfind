import XCTest
@testable import FlashFindCore

/// Provider 终态契约（v0.8 新增，对应方案 §1.6.5）。
///
/// 契约只有一句：**一次 `search` 调用，在它 return 之前，必须已经发出恰好一个
/// `isTerminal` 的事件。**
///
/// 为什么要单独一个文件守着：这条契约以前只写在注释里，而三处实现在暗中分叉——
/// 本机侧把 `isComplete` 当「结果有没有收全」，取消路径又默认 `false`，
/// 于是同一个 `.cancelled` 终态在「排队被取消」与「在跑被取消」下取值不同；
/// 更糟的是两个真 Provider 的 `cancel()` **根本不发终态**，`search()` 返回时
/// 沉默退出。上层 `SearchCompletionTracker` 会把这种来源一直记在 pending 里，
/// 界面永久「正在搜索」。
///
/// 这些用例全是确定性的：目录真建、桥接层用闸门暂停，不靠 sleep 赌时序。
@MainActor
final class ProviderTerminalContractTests: XCTestCase {

    // MARK: - 断言

    /// 一次请求必须恰好一个终态，且终态是最后一条。
    private func assertExactlyOneTerminal(_ events: [ProviderEvent],
                                          expected: ProviderSearchState? = nil,
                                          file: StaticString = #filePath, line: UInt = #line) {
        let terminals = events.filter(\.isTerminal)
        XCTAssertEqual(terminals.count, 1,
                       "一次请求必须恰好一个终态，实际 \(terminals.count) 个：\(terminals.map(\.state))",
                       file: file, line: line)
        if let expected {
            XCTAssertEqual(terminals.first?.state, expected, file: file, line: line)
        }
        if let last = events.last {
            XCTAssertTrue(last.isTerminal,
                          "终态之后不得再有事件（最后一条是 \(last.state)）", file: file, line: line)
        }
        XCTAssertFalse(events.contains { $0.state == .searching && $0.isTerminal },
                       "searching 永远不是终态", file: file, line: line)
    }

    private func waitUntil(_ what: String, timeout: TimeInterval = 5,
                           file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await condition() { return }
            await Task.yield()
        }
        XCTFail("等待超时：\(what)", file: file, line: line)
    }

    // MARK: - 本机来源

    private var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-contract-\(UInt32.random(in: 0..<UInt32.max))", isDirectory: true)
    }

    /// 建一个 `depth × perDir` 的目录树。数量不是凑数：取消窗口必须真实存在，
    /// 否则「取消 → 仍是终态」的断言会退化成「跑完了 → 终态」。
    private func makeTree(at root: URL, depth: Int, perDir: Int) throws {
        for d in 0..<depth {
            let dir = root.appendingPathComponent("layer-\(d)", isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for f in 0..<perDir {
                try Data("x".utf8).write(to: dir.appendingPathComponent("note-\(d)-\(f).txt"))
            }
        }
    }

    /// 正常跑完：恰好一个终态，且是 `completed`。
    func testLocalFolderSearchEmitsExactlyOneTerminal() async throws {
        let root = scratchRoot
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("报告-甲.txt"))

        let p = LocalSearchProvider()
        p.mode = .selectedFolders
        p.folders = [root]

        var events = [ProviderEvent]()
        await p.search("报告", queryID: UUID()) { events.append($0) }

        assertExactlyOneTerminal(events, expected: .completed)
        XCTAssertEqual(events.flatMap(\.results).count, 1)
        XCTAssertFalse(events.last?.resultsIncomplete ?? true, "没触到上限时不该标成不完整")
    }

    /// ★ 取消之后仍然必须有一个终态。
    ///
    /// 旧实现：`cancel` 把 `active` 置空 → `search()` 的每条分支都被
    /// `guard active == queryID` 挡住 → **一条事件都不发**就返回了。
    func testLocalCancelStillEmitsExactlyOneTerminal() async throws {
        let root = scratchRoot
        defer { try? FileManager.default.removeItem(at: root) }
        try makeTree(at: root, depth: 12, perDir: 150)

        let p = LocalSearchProvider()
        p.mode = .selectedFolders
        p.folders = [root]

        let id = UUID()
        var events = [ProviderEvent]()
        let task = Task { await p.search("note", queryID: id) { events.append($0) } }

        await waitUntil("搜索已经开始") { events.contains { $0.state == .searching } }
        p.cancel(queryID: id)

        XCTAssertEqual(events.filter(\.isTerminal).map(\.state), [.cancelled],
                       "cancel 必须立刻补发取消终态，不能等 search 返回")

        await task.value
        assertExactlyOneTerminal(events, expected: .cancelled)
        XCTAssertEqual(events.filter(\.isTerminal).count, 1,
                       "cancel 与 search 返回两处都可能发终态——必须仍然只有一个")
    }

    // MARK: - 应用程序来源

    func testAppSearchEmitsExactlyOneTerminal() async {
        let p = AppSearchProvider(scan: { [] })
        var events = [ProviderEvent]()
        await p.search("设置", queryID: UUID()) { events.append($0) }
        assertExactlyOneTerminal(events, expected: .completed)

        // 只有格式、没有关键词：走提前返回那条分支，同样只能有一个终态。
        var filtered = [ProviderEvent]()
        await p.search("报告 ppt", queryID: UUID()) { filtered.append($0) }
        assertExactlyOneTerminal(filtered, expected: .completed)
    }

    // MARK: - NAS 来源

    /// 闸门桥接层：`search` 停在「设备还没回包」，于是取消窗口是确定的。
    @MainActor private final class GatedBridge: MyNASBridgeTransport {
        var requests = [String]()
        private var gate: CheckedContinuation<Void, Never>?
        var resultsComplete = true

        func waitForSearch() -> Bool { gate != nil }
        func releaseSearch() { gate?.resume(); gate = nil }

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            requests.append(command)
            switch command {
            case "discover":
                return ["event": "capabilities"]
            case "login":
                return ["event": "authState", "state": "scopeReady"]
            case "search":
                await withCheckedContinuation { gate = $0 }
                var response: [String: Any] = ["resultState": "completed",
                                               "cleanupState": "cleaned",
                                               "reportedTotal": 0]
                response["isComplete"] = resultsComplete
                return response
            default:
                return ["event": "controlAck"]
            }
        }
    }

    private func nasConfig() -> NASSourceConfig {
        NASSourceConfig(id: "nas-contract", name: "契约来源", vendor: .synology,
                        host: "192.168.1.96", port: 5001, username: "nasuser", scope: "/示例共享")
    }

    /// 在飞时被取消：必须补发恰好一个 `.cancelled`，并且取消之后 `search` 返回时
    /// **不能**再补第二个。
    func testNASCancelEmitsExactlyOneTerminalAndNeverTwice() async throws {
        let bridge = GatedBridge()
        let p = NASSearchProvider(bridge: bridge, config: nasConfig(), port: 5001)
        _ = try await p.discover()
        try await p.login(account: "fixture", password: "fixture-only")

        let id = UUID()
        var events = [ProviderEvent]()
        let task = Task { await p.search("资料", queryID: id) { events.append($0) } }

        await waitUntil("请求已到设备") { bridge.waitForSearch() }
        p.cancel(queryID: id)

        XCTAssertEqual(events.filter(\.isTerminal).map(\.state), [.cancelled],
                       "取消必须补发终态，否则该来源永远留在 pending 里")
        XCTAssertNil(events.last?.message, "取消是正常路径，不能塞用户可见警告")

        bridge.releaseSearch()
        await task.value
        assertExactlyOneTerminal(events, expected: .cancelled)
        XCTAssertTrue(bridge.requests.contains("cancel"), "设备侧任务仍要尽力清掉")
    }

    /// 正常完成：恰好一个终态；核心说「没收集全」时，这条信息走 `resultsIncomplete`，
    /// 与「是否终态」彻底分开。
    func testNASCompletedEmitsOneTerminalAndKeepsIncompletenessSeparate() async throws {
        let bridge = GatedBridge()
        bridge.resultsComplete = false
        let p = NASSearchProvider(bridge: bridge, config: nasConfig(), port: 5001)
        _ = try await p.discover()
        try await p.login(account: "fixture", password: "fixture-only")

        var events = [ProviderEvent]()
        let task = Task { await p.search("资料", queryID: UUID()) { events.append($0) } }
        await waitUntil("请求已到设备") { bridge.waitForSearch() }
        bridge.releaseSearch()
        await task.value

        assertExactlyOneTerminal(events, expected: .completed)
        XCTAssertEqual(events.last?.resultsIncomplete, true,
                       "核心的 isComplete=false 是「结果没收集全」，必须落在 resultsIncomplete 上")
        XCTAssertEqual(events.last?.isTerminal, true,
                       "结果不全 ≠ 请求没结束：这两件事任何一方都不能冒充另一方")
    }
}
