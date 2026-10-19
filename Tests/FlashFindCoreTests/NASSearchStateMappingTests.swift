import XCTest
@testable import FlashFindCore

/// 钉死「核心 resultState → 界面状态 → 用户看到的提示」这条链路。
///
/// 背景：用户搜「报告」时两台 NAS 都提示 `failed`，
/// 但核心能返回的状态里，`truncated`（结果超上限）、`needsAuth`（会话过期）、
/// `limitedTraversal`（降级遍历）在 `ProviderSearchState` 里**都不存在**，
/// 于是 `rawValue` 构造返回 nil、统一退化成 `failed`。
/// 结果是「结果太多」和「登录过期」在界面上一模一样，用户无法判断该做什么，
/// 排查的人也拿不到任何线索。
///
/// 这组测试锁三件事：
///   1. 每个核心状态都有对应的界面状态，不再被吞掉；
///   2. 失败提示必须带中文说明 + 核心 kind + 设备错误码；
///   3. 「结果截断 / 降级遍历」不计入失败，不会把来源打成「暂时不可用」。
@MainActor
final class NASSearchStateMappingTests: XCTestCase {

    // MARK: - 1. 状态映射（纯逻辑）

    func testEveryCoreStateMapsToItsOwnValue() {
        // 核心 `SearchOutcome.toJson()` 的 state 取值全集，见
        // MyNASCore/lib/core.dart 的 `_search` 里那个 switch。
        let table: [(String, ProviderSearchState)] = [
            ("searching", .searching),
            ("completed", .completed),
            ("cancelled", .cancelled),
            ("timedOut", .timedOut),
            ("truncated", .truncated),
            ("needsAuth", .needsAuth),
            ("limitedTraversal", .limitedTraversal),
            ("deviceBusy", .deviceBusy),
            ("failed", .failed),
        ]
        for (raw, expected) in table {
            XCTAssertEqual(ProviderSearchState.fromCore(raw), expected, "\(raw) 应映射为 \(expected)")
            XCTAssertTrue(ProviderSearchState.isKnownCoreState(raw), "\(raw) 是已知的核心状态")
        }
    }

    /// 回归：这三个取值曾经全部落到 `failed`。
    func testStatesThatUsedToCollapseIntoFailedAreDistinct() {
        for raw in ["truncated", "needsAuth", "limitedTraversal", "deviceBusy"] {
            XCTAssertNotEqual(ProviderSearchState.fromCore(raw), .failed,
                              "\(raw) 不能再退化成 failed —— 那正是用户看到的那个毫无信息量的提示")
        }
    }

    func testUnknownOrMissingResultStateFallsBackToFailedWithoutPretendingItIsKnown() {
        XCTAssertEqual(ProviderSearchState.fromCore(nil), .failed)
        XCTAssertEqual(ProviderSearchState.fromCore("somethingNewFromAServer"), .failed)
        XCTAssertFalse(ProviderSearchState.isKnownCoreState(nil))
        XCTAssertFalse(ProviderSearchState.isKnownCoreState("somethingNewFromAServer"))
    }

    // MARK: - 2. 失败提示文案

    func testFailureTextNamesTheCauseAndKeepsTheDeviceErrorCode() {
        let text = NASSearchFailureText.describe(kind: "SessionExpired", apiCode: 119)
        XCTAssertTrue(text.contains("登录已过期"), "要说清发生了什么：\(text)")
        XCTAssertTrue(text.contains("重新连接"), "要给出下一步：\(text)")
        XCTAssertTrue(text.contains("119"), "设备错误码是最有价值的排查字段：\(text)")
    }

    func testFailureTextCoversTheKindsTheCoreActuallyEmits() {
        // 这些 kind 来自 MyNASCore/lib/protocol.dart 的 apiError + core.dart 直接抛出的种类。
        let kinds = ["AuthenticationFailed", "AccountDisabled", "NeedsOTP", "IPBlocked",
                     "PermissionDenied", "SessionExpired", "NeedsAuth", "NetworkFailure",
                     "TimedOut", "ProtocolViolation", "DirectoryUnstable", "UnknownSubmission",
                     "TaskNotFound", "PathMissing", "UnsupportedApi", "UnsupportedVersion",
                     "UnsupportedSearchNoFallback", "ScopeDenied", "ScopeUnavailable",
                     "IdentityUnverified", "ResultLimit", "UnsafeLogicalPath", "UnknownApiError",
                     "ResultsNotReady", "IncompleteResponse"]
        for kind in kinds {
            let text = NASSearchFailureText.describe(kind: kind, apiCode: nil)
            XCTAssertFalse(text.isEmpty, "\(kind) 不能没有解释")
            XCTAssertTrue(text.contains(where: { $0.unicodeScalars.first.map { $0.value > 0x2E80 } ?? false }),
                          "\(kind) 的提示必须是中文主句，而不是把开发者术语直接抛给用户：\(text)")
        }
    }

    func testFailureTextAdmitsWhenTheCoreToldUsNothing() {
        XCTAssertTrue(NASSearchFailureText.describe(kind: nil, apiCode: nil).contains("没有说明原因"))
    }

    func testFailureTextNamesAnUnrecognisedKindInsteadOfHidingIt() {
        let text = NASSearchFailureText.describe(kind: "BrandNewFailureKind", apiCode: nil)
        XCTAssertTrue(text.contains("BrandNewFailureKind"), "未识别的 kind 要原样带出来，否则下次故障又成谜：\(text)")
    }

    // MARK: - 3. 端到端：核心状态 → ProviderEvent

    func testProviderEmitsTheRealStateAndAnActionableMessage() async throws {
        let cases: [(String, String?, ProviderSearchState, String)] = [
            ("truncated", nil, .truncated, "上限"),
            ("needsAuth", "SessionExpired", .needsAuth, "登录已过期"),
            ("limitedTraversal", nil, .limitedTraversal, "逐层查找"),
            ("failed", "NetworkFailure", .failed, "网络"),
            ("failed", "UnknownApiError", .failed, "499"),
        ]
        for (raw, kind, expectedState, expectedFragment) in cases {
            let bridge = StateFixtureBridge()
            bridge.resultState = raw
            bridge.errorKind = kind
            bridge.apiCode = kind == "UnknownApiError" ? 499 : (kind == "SessionExpired" ? 119 : nil)
            let provider = makeProvider(bridge)
            try await provider.discover()
            try await provider.login(account: "u", password: "p")

            let events = await runSearch(provider, "报告")
            guard let last = events.last else { return XCTFail("\(raw) 没有发出任何事件") }
            XCTAssertEqual(last.state, expectedState, "\(raw) 的界面状态")
            let message = last.message ?? ""
            XCTAssertTrue(message.contains(expectedFragment),
                          "\(raw) 的提示应包含「\(expectedFragment)」，实际：\(message)")
        }
    }

    func testTruncatedIsNotTreatedAsAFailureSoTheSourceIsNotDegraded() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "truncated"
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        // 连续三次截断。若被当成失败计数，第三次就会被 degradedUntil 拦成
        // 「暂时不可用」，根本不会再走到桥接层。
        for _ in 0..<3 {
            let events = await runSearch(provider, "报告")
            XCTAssertEqual(events.last?.state, .truncated,
                           "结果偏多只是不完整，不该把来源打成暂时不可用：\(events.last?.message ?? "")")
        }
        XCTAssertEqual(bridge.searchCount, 3, "三次搜索都应该真的发到核心")
    }

    func testNeedsAuthTakesTheSourceOutOfReadySoTheNextSearchSaysSoInsteadOfFailing() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "needsAuth"
        bridge.errorKind = "SessionExpired"
        bridge.apiCode = 119
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")
        XCTAssertTrue(provider.ready)

        _ = await runSearch(provider, "报告")
        XCTAssertFalse(provider.ready, "会话已失效就必须退出就绪态，不能拿着死会话再撞一次")

        // 第二次搜索应当直接被「尚未连接」挡住，而不是再报一个含糊的 failed。
        let second = await runSearch(provider, "报告")
        XCTAssertEqual(second.last?.state, .failed)
        XCTAssertTrue((second.last?.message ?? "").contains("尚未连接"),
                      "要明说需要重新连接，实际：\(second.last?.message ?? "")")
    }

    // MARK: - 4. 设备未就绪（deviceBusy）：不许说成失败，也不许往退化窗口里丢任务

    /// 真机上出现过的形态之一：设备 `finished=true` 却没有 `total`。
    ///
    /// 旧核心把它当成协议违规 → 界面显示「搜索失败」。
    /// 事实是设备**还没把结果算出来**，既不是失败，更不是「没有找到文件」。
    func testDeviceBusyIsNotReportedAsFailureOrAsZeroResults() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "deviceBusy"
        bridge.errorKind = "ResultsNotReady"
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let events = await runSearch(provider, "报告")
        XCTAssertEqual(events.last?.state, .deviceBusy)
        let message = events.last?.message ?? ""
        XCTAssertTrue(message.contains("设备暂时没有给出结果"),
                      "要说清是设备没准备好，而不是搜索失败：\(message)")
        XCTAssertFalse(message.contains("搜索失败"), "这不是失败，不能这么说：\(message)")
        XCTAssertFalse(message.contains("没有找到"), "更不能说成 0 条结果：\(message)")
    }

    /// 连续两次「设备未就绪」之后必须刹车。
    ///
    /// 理由不是「惩罚设备」：连续搜索会触发设备侧
    /// 数分钟的退化窗口，而快速重试只会继续往这个窗口里丢新任务。
    /// 所以这里断言**第三次查询根本不发到设备**。
    func testRepeatedDeviceBusyThrottlesInsteadOfPilingOnNewTasks() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "deviceBusy"
        bridge.errorKind = "ResultsNotReady"
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let first = await runSearch(provider, "报告")
        XCTAssertEqual(first.last?.state, .deviceBusy)
        let second = await runSearch(provider, "报告")
        XCTAssertEqual(second.last?.state, .deviceBusy)
        let third = await runSearch(provider, "报告")
        XCTAssertEqual(third.last?.state, .degraded, "第二次未就绪后应暂停来源，而不是继续丢任务")
        XCTAssertEqual(bridge.searchCount, 2, "第三次查询不该发到设备上")
    }

    /// 有行无法解析时必须如实告知，不能静默丢行。
    ///
    /// 静默丢行会让用户以为「设备上就是没有这些文件」。
    func testUnparsedRowsAreReportedInsteadOfSilentlyDropped() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "completed"
        bridge.unparsedCount = 3
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let events = await runSearch(provider, "报告")
        XCTAssertTrue((events.last?.message ?? "").contains("3 条结果因格式异常被跳过"),
                      "跳过的行数要如实告诉用户：\(events.last?.message ?? "")")
    }

    /// 被合并掉的重复结果也要如实告知。
    ///
    /// 与「无法解析」分开说：一个是设备给了行、我们看不懂；另一个是设备把
    /// 同一条结果给重了（DSM 的 `Search.list` 不保证返回集合严格唯一，
    /// 实测第一页内部就会出现重复 path，界面上的重复结果正是这么来的）。
    /// 混成一句话，下一次排查就没有线索了。
    func testMergedDuplicatesAreReportedAndNotCountedAsUnparsed() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "completed"
        bridge.duplicateCount = 2
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let events = await runSearch(provider, "报告")
        let message = events.last?.message ?? ""
        XCTAssertEqual(events.last?.state, .completed, "合并重复不是失败")
        XCTAssertTrue(message.contains("2 条重复的结果已合并"), "重复条数要如实告知：\(message)")
        XCTAssertFalse(message.contains("格式异常"), "重复不是解析失败，不能混为一谈：\(message)")
    }

    /// 两类都要如实上报时，一句话里分得清。
    func testUnparsedAndDuplicatesAreReportedSeparately() async throws {
        let bridge = StateFixtureBridge()
        bridge.resultState = "completed"
        bridge.unparsedCount = 1
        bridge.duplicateCount = 4
        let provider = makeProvider(bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let message = (await runSearch(provider, "报告")).last?.message ?? ""
        XCTAssertTrue(message.contains("1 条结果因格式异常被跳过"), message)
        XCTAssertTrue(message.contains("4 条重复的结果已合并"), message)
    }

    // MARK: - 桩

    private func makeProvider(_ bridge: StateFixtureBridge) -> NASSearchProvider {
        let config = NASSourceConfig(id: "statefixture", name: "测试 NAS", vendor: .synology,
                                     host: "nas.example", port: 5001, username: "u",
                                     scopes: ["/share"])
        return NASSearchProvider(bridge: bridge, config: config, port: 5001)
    }

    private func runSearch(_ provider: NASSearchProvider, _ text: String) async -> [ProviderEvent] {
        var events: [ProviderEvent] = []
        await provider.search(text, queryID: UUID()) { events.append($0) }
        return events
    }
}

@MainActor private final class StateFixtureBridge: MyNASBridgeTransport {
    var resultState = "completed"
    var errorKind: String?
    var apiCode: Int?
    var unparsedCount = 0
    var duplicateCount = 0
    var searchCount = 0

    func request(_ command: String, sourceID: String, queryID: String,
                 fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        switch command {
        case "discover": return ["event": "capabilities"]
        case "login": return ["event": "authState", "state": "scopeReady"]
        case "search":
            searchCount += 1
            var m: [String: Any] = ["resultState": resultState, "isComplete": resultState == "completed",
                                    "unparsedCount": unparsedCount, "duplicateCount": duplicateCount]
            if let errorKind {
                var body: [String: Any] = ["kind": errorKind]
                if let apiCode { body["apiCode"] = apiCode }
                m["error"] = body
            }
            return m
        default: return ["event": "controlAck"]
        }
    }
}

// MARK: - 有核心给的原因时，优先用它

/// 同一个 `AuthenticationFailed` 底下可能是「密码错」，也可能是
/// 「端口只讲明文 HTTP，TLS 握手失败」。按 kind 猜只能猜中前者，
/// 所以核心一旦给了 `reason`，界面就必须用它 ——
/// 否则用户会跑去反复重输密码，而真因在别处。
final class NASFailureTextReasonTests: XCTestCase {
    func testCoreReasonWinsOverTheKindMapping() {
        let text = NASSearchFailureText.describe(kind: "AuthenticationFailed", apiCode: nil,
                                                 reason: "无法连接 WebDAV 服务（TLS 握手失败）")
        XCTAssertEqual(text, "无法连接 WebDAV 服务（TLS 握手失败）")
        XCTAssertFalse(text.contains("账号或密码"), "不能把协议问题说成密码问题：\(text)")
    }

    func testFallsBackToKindMappingWhenReasonIsMissing() {
        let noReason = NASSearchFailureText.describe(kind: "AuthenticationFailed", apiCode: nil, reason: nil)
        XCTAssertTrue(noReason.contains("账号或密码被设备拒绝"), "没有 reason 时仍按 kind 说：\(noReason)")
        let empty = NASSearchFailureText.describe(kind: "AuthenticationFailed", apiCode: nil, reason: "")
        XCTAssertEqual(empty, noReason, "空串等同没有，不能显示成空白提示")
    }

    func testUnexpectedFailureHasItsOwnSentence() {
        let text = NASSearchFailureText.describe(kind: "UnexpectedFailure", apiCode: nil)
        XCTAssertTrue(text.contains("闪寻内部"), "兜底失败必须说清是客户端这边的问题：\(text)")
        XCTAssertFalse(text.contains("设备返回的内容不符合预期"),
                       "不能再说成设备的问题 —— 那正是被冒充掉的那一类：\(text)")
    }

    func testRateLimitedSaysItIsNotThePassword() {
        // 真机实测：openlist 的 nginx 对 PROPFIND 全体回 429，
        // 与凭据对错无关。这条 kind 若没有专属文案，会被兜成「设备返回的内容
        // 不符合预期」，用户就会去反复重输密码。
        let text = NASSearchFailureText.describe(kind: "RateLimited", apiCode: 429)
        XCTAssertTrue(text.contains("限流"), "\(text)")
        XCTAssertTrue(text.contains("等几分钟"), "要给出可操作的下一步：\(text)")
        XCTAssertFalse(text.contains("账号或密码"), "限流不是凭据问题：\(text)")
    }
}
