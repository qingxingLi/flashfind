import XCTest
@testable import FlashFindCore

/// 位置限定**真的下推到设备**的验证。
///
/// ★ 这是「在选定位置搜索能减少检索时间」的全部依据。
/// 界面上的位置标签只是表象；只有设备侧收到的根集合变小了，
/// 设备侧才真的少扫了那几��共享。
@MainActor
final class SearchRootLimitTests: XCTestCase {

    private final class RecordingBridge: MyNASBridgeTransport {
        private(set) var searchFields: [String: Any] = [:]
        private(set) var searchCallCount = 0

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            switch command {
            case "discover": return ["event": "capabilities"]
            case "login": return ["event": "authState", "state": "scopeReady", "isManager": false]
            case "selectScope": return ["event": "scopeState", "state": "scopeReady", "scopes": ["/照片", "/文档"]]
            case "search":
                searchCallCount += 1
                searchFields = fields
                event?(["event": "batch", "sourceID": sourceID, "queryID": queryID, "files": []])
                return ["resultState": "completed", "isComplete": true]
            default: return [:]
            }
        }
    }

    private func readyProvider(_ bridge: RecordingBridge) async throws -> NASSearchProvider {
        let subject = NASSearchProvider(
            bridge: bridge,
            config: NASSourceConfig(host: "192.0.2.96", port: 5001,
                                    username: "nasuser", scopes: ["/照片", "/文档"]),
            port: 5001)
        try await subject.login(account: "nasuser", password: "p")
        _ = try await subject.selectScopes(["/照片", "/文档"])
        XCTAssertTrue(subject.ready, "前置：应已就绪")
        return subject
    }

    // MARK: - 下推

    /// ★ 限定到某个根 ⇒ 设备侧只收到那一个根。
    ///
    /// 这是核心断言：少了这一半，界面看起来限制了位置，
    /// 设备却仍在扫两个共享 —— 检索时间一点没降。
    func testRootLimitIsPushedToDevice() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui,
                              rootLimit: SearchRootLimit(sourceID: provider.source.id, roots: ["/照片"])) { _ in }
        XCTAssertEqual(bridge.searchFields["roots"] as? [String], ["/照片"])
    }

    /// 不限定位置 ⇒ **一个字都不发**。
    ///
    /// 发一个空的 roots 与不发是两回事：空的会被核心当成「显式空集合」
    /// 拒掉（交集为空 ⇒ ScopeDenied），而「不发」才是「按已授权范围搜」。
    func testNoLimitMeansNoRootsField() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui, rootLimit: nil) { _ in }
        XCTAssertNil(bridge.searchFields["roots"], "不限定时不该发 roots 字段")
    }

    /// 限定的是**别的来源** ⇒ 对本来源不生效。
    ///
    /// 一次搜索可能同时打多个来源；限定只对那一个来源有意义，
    /// 其余来源照旧按各自授权范围搜。
    func testLimitForAnotherSourceIsIgnored() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui,
                              rootLimit: SearchRootLimit(sourceID: "someone-else", roots: ["/照片"])) { _ in }
        XCTAssertNil(bridge.searchFields["roots"])
    }

    // MARK: - 越权防护

    /// ★ 没授权过的根不下推。
    ///
    /// Swift 侧这道门是**第二道**（第一道在 `SearchRequestPlan`，
    /// 第三道在 Dart 核心）。客户端是��可信输入，中间这层协议也拦一道。
    func testUnauthorizedRootIsNotPushed() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui,
                              rootLimit: SearchRootLimit(sourceID: provider.source.id, roots: ["/别人的目录"])) { _ in }
        XCTAssertNil(bridge.searchFields["roots"], "没授权的根不该下推")
    }

    /// 授权范围内的根正常下推（与上面的反例成对，证明不是「一律不下推」）。
    func testAuthorizedRootIsPushedEvenWhenOthersAreNot() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui,
                              rootLimit: SearchRootLimit(sourceID: provider.source.id,
                                                        roots: ["/照片", "/别人的目录"])) { _ in }
        XCTAssertEqual(bridge.searchFields["roots"] as? [String], ["/照片"],
                       "只该下推授权范围内的那个")
    }

    /// 根集合为空 ⇒ 等价于不限定（不发字段），不是「搜不到任何东西」。
    func testEmptyRootsMeansNoLimit() async throws {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        await provider.search("报告", queryID: UUID(), owner: .ui,
                              rootLimit: SearchRootLimit(sourceID: provider.source.id, roots: [])) { _ in }
        XCTAssertNil(bridge.searchFields["roots"])
    }
}

/// 位置限定**逐层传递**的验证：调度器与协调器不能把它弄丢。
@MainActor
final class SearchRootLimitPropagationTests: XCTestCase {

    /// 记录自己收到的 rootLimit 的假 provider。
    private final class LimitRecordingProvider: SearchProvider {
        let source = SearchSource.nas(id: "nas-A", displayName: "NAS A")
        private(set) var receivedLimits: [SearchRootLimit?] = []

        func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            receivedLimits.append(nil)
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .completed))
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    rootLimit: SearchRootLimit?,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            receivedLimits.append(rootLimit)
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .completed))
        }

        func cancel(queryID: UUID) {}
    }

    /// ★ 协调器必须把限定原样送到 provider。
    ///
    /// 中间任何一层「顺手简化」都会让它变成 nil ——
    /// 而症状是「界面显示限定在照片，设备仍在扫全部共享」，
    /// 没有任何报错，只有检索时间没降。
    func testCoordinatorPassesRootLimitToProvider() async throws {
        let provider = LimitRecordingProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        let limit = SearchRootLimit(sourceID: "nas-A", roots: ["/照片"])
        coordinator.search("报告", sources: ["nas-A"], rootLimit: limit, queryID: UUID()) { _ in }
        // 远端侧有防抖，等它过去。
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(provider.receivedLimits.count, 1)
        XCTAssertEqual(provider.receivedLimits.first??.roots, ["/照片"])
        XCTAssertEqual(provider.receivedLimits.first??.sourceID, "nas-A")
    }

    /// 不限定 ⇒ provider 收到 nil（不能是「一个空的限定」）。
    func testCoordinatorWithoutLimitPassesNil() async throws {
        let provider = LimitRecordingProvider()
        let coordinator = SearchCoordinator(providers: [provider])
        coordinator.search("报告", sources: ["nas-A"], queryID: UUID()) { _ in }
        try await Task.sleep(for: .milliseconds(900))
        XCTAssertEqual(provider.receivedLimits.count, 1)
        XCTAssertNil(provider.receivedLimits.first ?? nil)
    }

    /// ★ 调度器排队时不得弄丢限定：排队的那一条也要带着它跑。
    func testSchedulerKeepsRootLimitWhileQueued() async throws {
        let provider = LimitRecordingProvider()
        let scheduler = SearchScheduler(providers: [provider])
        let limit = SearchRootLimit(sourceID: "nas-A", roots: ["/照片"])
        scheduler.submit(text: "报告", queryID: UUID(), owner: .ui,
                         sources: ["nas-A"], rootLimit: limit) { _ in }
        try await Task.sleep(for: .milliseconds(200))
        XCTAssertEqual(provider.receivedLimits.count, 1)
        XCTAssertEqual(provider.receivedLimits.first??.roots, ["/照片"])
    }
}
