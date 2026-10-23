import XCTest
@testable import FlashFindCore

/// Phase 6.2 的产品验收：**权限判定只在 App authority，每个请求现读一次**（方案 §14.3.5）。
///
/// 这一组用例守的是 v0.17 撤回 `facts` 之后的新边界：
///
/// ```text
/// 报文（未受信）{tool, args}
///   ↓  AuthorityJob
/// 现读设置 + 现读来源     ← 每个请求一次，绝不缓存
///   ↓
/// ToolRouter → PermissionPolicy     ← 唯一判定点
///   ↓
/// AuthorizationScope（只能在这里产生）
///   ↓
/// list_sources（6.2 唯一有实现的业务操作）
/// ```
///
/// ★ 所有 id 与名字都是编造的：测试不许出现真实设备名或来源名。
/// 数「路由被调用了几次」。锁而不是 actor：断言要同步读。
private final class RouteCounter: @unchecked Sendable {

    private let lock = NSLock()
    private var value = 0

    func bump() { lock.withLock { value += 1 } }

    var count: Int { lock.withLock { value } }
}

final class AuthorityServiceTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let archive = "src_nas_private"

    private var root = ""
    private var path = ""
    private var listeners: [AuthorityListener] = []

    override func setUpWithError() throws {
        root = "/tmp/ff-svc-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        path = root + "/mcp.sock"
    }

    override func tearDown() {
        for listener in listeners { listener.stop() }
        listeners = []
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - 替身

    /// 可变的「当前事实」。读一次就记一次数——用来证明**没有缓存**。
    private final class Holder: @unchecked Sendable {

        private let lock = NSLock()
        private var settingsValue: AIAccessSettings
        private var sourcesValue: [AuthoritySource]
        private var settingsReads = 0
        private var sourcesReads = 0

        init(settings: AIAccessSettings, sources: [AuthoritySource]) {
            self.settingsValue = settings
            self.sourcesValue = sources
        }

        /// 每次访问都算一次「现读」。**不要**在服务里把它存起来。
        var currentSettings: AIAccessSettings {
            lock.withLock {
                settingsReads += 1
                return settingsValue
            }
        }

        var currentSources: [AuthoritySource] {
            lock.withLock {
                sourcesReads += 1
                return sourcesValue
            }
        }

        var settingsReadCount: Int { lock.withLock { settingsReads } }
        var sourcesReadCount: Int { lock.withLock { sourcesReads } }

        /// 模拟用户在设置页里的动作（撤销授权 / 删掉一台 NAS）。
        func update(settings: AIAccessSettings? = nil, sources: [AuthoritySource]? = nil) {
            lock.withLock {
                if let settings { settingsValue = settings }
                if let sources { sourcesValue = sources }
            }
        }
    }

    private func sources(_ ids: [String]) -> [AuthoritySource] {
        ids.map { AuthoritySource(id: $0, name: name(of: $0)) }
    }

    private func name(of id: String) -> String {
        switch id {
        case mac:     return "This Mac"
        case work:    return "Work NAS"
        case archive: return "Private Archive"
        default:      return "Source \(id)"
        }
    }

    private func enabled(_ ids: [String]) -> AIAccessSettings {
        AIAccessSettings(isEnabled: true, allowedSources: Set(ids))
    }

    /// ★ `route` 用可选写法而不是默认 `ToolRouter.route`：静态方法值不是 `@Sendable`，
    /// 直接当默认实参会冒一条假警告（服务那边已经用闭包包过一层）。
    private func service(_ holder: Holder,
                         route: RoutingAuthorityService.Router? = nil,
                         store: FileReferenceStore? = nil)
        -> RoutingAuthorityService {
        if let route {
            return RoutingAuthorityService(settings: { holder.currentSettings },
                                           sources: { holder.currentSources },
                                           route: route,
                                           referenceStore: store)
        }
        return RoutingAuthorityService(settings: { holder.currentSettings },
                                       sources: { holder.currentSources },
                                       referenceStore: store)
    }

    /// 一张**临时**的反查表。
    ///
    /// ★ 用临时目录而不是产品路径：产品路径在 `~/Library/Application Support`
    /// 下，测试往里写会在用户机器上留下一条「AI 看过哪些文件」的痕迹，
    /// 而且两个并发的测试会互相撞锁。
    private func temporaryStoreURL() -> URL {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ff2-ref-\(UUID().uuidString)", isDirectory: true)
        return directory.appendingPathComponent("ai-file-reference.sqlite")
    }

    private func job(_ op: AuthorityWire.Operation,
                     _ arguments: [String: AuthorityWire.Value] = [:]) -> AuthorityJob {
        // 每条 job 一个独立请求 id（v0.20）：owner 由它算出来，缺了就没法断言搜索隔离。
        AuthorityJob(id: UUID().uuidString, op: op, arguments: arguments)
    }

    /// 起一个真实监听（跨进程语义的替身：走 socket、走真报文）。
    @discardableResult
    private func serve(_ service: any AuthorityServing) -> AuthorityListener {
        let listener = AuthorityListener(path: path, service: service, log: { _ in })
        listeners.append(listener)
        XCTAssertTrue(listener.start().isListening, "监听没起来")
        return listener
    }

    /// 绕过助手、直接往 socket 写一行报文——这就是「同 UID 的另一个进程」。
    private func rawExchange(_ request: AuthorityWire.Request) throws -> AuthorityWire.Response {
        try Self.exchange(request, path: path)
    }

    /// 阻塞式一收一发。`static` + 显式 path：要能在后台线程上调用（见 `rawExchangeInBackground`）。
    private static func exchange(_ request: AuthorityWire.Request,
                                 path: String) throws -> AuthorityWire.Response {
        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, try AuthorityWire.line(request))
        _ = shutdown(fd, SHUT_WR)
        let data = try UnixSocket.readLine(fd, maxBytes: AuthorityLimits().maxResponseBytes,
                                           deadline: Date().addingTimeInterval(5),
                                           idleTimeout: 5)
        return try AuthorityWire.decodeResponse(data)
    }

    /// ★ 在**后台线程**上收发（Phase 6.3b-1）。
    ///
    /// `locate` 的执行要跳 `MainActor`（provider 与调度器都在主线程上）。
    /// 若测试在主线程上同步等这一条回包，`MainActor` 就被这次读挡住了 —— 死锁，
    /// 表现是 `read timed out`。生产里 App 的 socket 全在后台线程上，没有这个问题；
    /// 这是测试自己必须避开的一件事，不是产品缺陷。
    private func rawExchangeInBackground(_ request: AuthorityWire.Request) async throws
        -> AuthorityWire.Response {
        let path = self.path
        return try await Task.detached { try Self.exchange(request, path: path) }.value
    }

    /// 解析 `list_sources` 的返回体。
    private func listed(_ outcome: ToolOutcome) throws -> [[String: String]] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw NotSuccess()
        }
        let parsed = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let object = try XCTUnwrap(parsed as? [String: Any], "返回体不是对象：\(json)")
        let items = try XCTUnwrap(object["sources"] as? [[String: Any]], "没有 sources 数组：\(json)")
        return items.map { item in
            ["source_id": item["source_id"] as? String ?? "",
             "name": item["name"] as? String ?? ""]
        }
    }

    private struct NotSuccess: Error {}

    // MARK: - ① 总开关关闭 → mcp_disabled

    /// 关着的时候不能回「空列表」：空列表的语义是「你有权限，但没有来源」，
    /// 而事实是「这个功能关着」。两者的下一步动作完全不同（先去设置 vs 什么都不用做）。
    func testListSourcesIsDisabledWhenAIIsOff() async {
        let off = Holder(settings: AIAccessSettings(isEnabled: false, allowedSources: [mac]),
                         sources: sources([mac]))
        let outcome = await service(off).handle(job(.listSources))

        XCTAssertEqual(outcome, .failure(code: "mcp_disabled",
                                         message: PermissionPolicy.switchOffMessage))
    }

    /// 开着但一个来源都没授权（例如授权都指向已删除的来源）→ 也是 `mcp_disabled`。
    func testListSourcesIsDisabledWhenNothingIsUsable() async {
        let holder = Holder(settings: enabled([archive]), sources: sources([mac, work]))
        let outcome = await service(holder).handle(job(.listSources))

        XCTAssertEqual(outcome, .failure(code: "mcp_disabled",
                                         message: PermissionPolicy.nothingAuthorizedMessage))
    }

    // MARK: - ② 只返回授权来源

    func testListSourcesReturnsOnlyAllowedSources() async throws {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac, work]))
        let items = try listed(await service(holder).handle(job(.listSources)))

        XCTAssertEqual(items, [["source_id": mac, "name": "This Mac"]])
    }

    /// 注册表顺序是任意的（`AppModel.aiAccessCandidates` 的顺序跟着用户添加顺序走），
    /// 结果必须按 `source_id` 升序——否则同一份设置两次请求可能产出不同串。
    func testListSourcesIsSortedBySourceID() async throws {
        let holder = Holder(settings: enabled([work, mac, archive]),
                            sources: sources([work, archive, mac]))
        let items = try listed(await service(holder).handle(job(.listSources)))

        // 升序是按 ASCII 排的："local_mac" < "src_nas_private" < "src_nas_work"。
        XCTAssertEqual(items.map { $0["source_id"] }, [mac, archive, work],
                       "输出顺序必须由 list_sources 自己保证，不能靠注册表恰好有序")
    }

    // MARK: - ③ 未授权来源的名字不许出现

    /// ★ 这是 §4.3.1 的硬要求：未授权来源的名字本身就是信息（「私人归档」这种名字
    /// 一旦进了 Agent 的上下文就撤不回来）。所以断言的是**整串 JSON 反扫**，
    /// 不是「数组里只有两条」——后者挡不住把名字塞进别的字段。
    func testUnauthorizedSourceNeverAppearsInListSources() async throws {
        let holder = Holder(settings: enabled([mac, work]),
                            sources: sources([mac, work, archive]))
        guard case .success(let json) = await service(holder).handle(job(.listSources)) else {
            return XCTFail("应当成功")
        }

        XCTAssertFalse(json.contains(archive), "未授权来源的 id 出现在返回里：\(json)")
        XCTAssertFalse(json.contains("Private Archive"), "未授权来源的名字出现在返回里：\(json)")
        XCTAssertTrue(json.contains(work), "已授权的来源应当出现")
    }

    // MARK: - ④ 撤销授权在下一次请求生效（助手不重启）

    /// ★ 这一条是「不缓存事实」的直接验证，也是 v0.17 的 `facts` 方案最容易踩的坑：
    /// 一旦助手或 App 留下快照，撤销要等重启才生效。
    ///
    /// 用**同一个 link 实例**（= 同一个助手进程）连两次，中间只改 App 侧的设置。
    func testRevokingASourceTakesEffectOnTheNextRequest() async throws {
        let holder = Holder(settings: enabled([mac, work]), sources: sources([mac, work]))
        serve(service(holder))
        let link = UnixSocketAuthorityLink(path: path)

        let first = try listed(await link.call(tool: "list_sources", arguments: ToolArguments()))
        XCTAssertEqual(first.map { $0["source_id"] }, [mac, work])

        holder.update(settings: enabled([work]))

        let second = try listed(await link.call(tool: "list_sources", arguments: ToolArguments()))
        XCTAssertEqual(second.map { $0["source_id"] }, [work],
                       "撤销授权后下一次请求还看得见：事实被缓存了")
        XCTAssertEqual(holder.settingsReadCount, 2, "两次请求应当各读一次设置")
    }

    // MARK: - ⑤ 删掉最后一个授权来源 → 下一次请求 mcp_disabled

    func testDeletingTheLastAllowedSourceDisablesTheService() async throws {
        let holder = Holder(settings: enabled([work]), sources: sources([work]))
        serve(service(holder))
        let link = UnixSocketAuthorityLink(path: path)

        let before = try listed(await link.call(tool: "list_sources", arguments: ToolArguments()))
        XCTAssertEqual(before.map { $0["source_id"] }, [work])

        // 用户在设置里删掉了这台 NAS：授权 id 还留着，但来源已经不存在。
        holder.update(sources: [])

        let after = await link.call(tool: "list_sources", arguments: ToolArguments())
        XCTAssertEqual(after, .failure(code: "mcp_disabled",
                                       message: PermissionPolicy.nothingAuthorizedMessage),
                       "来源删光之后还在服务，说明判定看的是旧快照")
    }

    // MARK: - ⑥ 并发请求各读当时最新权限

    /// 两个（这里放八个）助手同时来：每一次都要各读一次事实，不许共享一份快照。
    func testTwoConcurrentRequestsEachReadTheLatestSettings() async throws {
        let holder = Holder(settings: enabled([mac, work]), sources: sources([mac, work]))
        serve(service(holder))
        let link = UnixSocketAuthorityLink(path: path)

        let outcomes = await withTaskGroup(of: ToolOutcome.self, returning: [ToolOutcome].self) { group in
            for _ in 0..<8 {
                group.addTask {
                    await link.call(tool: "list_sources", arguments: ToolArguments())
                }
            }
            var collected: [ToolOutcome] = []
            for await outcome in group { collected.append(outcome) }
            return collected
        }

        XCTAssertEqual(outcomes.count, 8)
        for outcome in outcomes {
            XCTAssertEqual(try listed(outcome).map { $0["source_id"] }, [mac, work])
        }
        XCTAssertEqual(holder.settingsReadCount, 8, "并发请求共享了一份快照")
        XCTAssertEqual(holder.sourcesReadCount, 8)
    }

    // MARK: - ⑦ 别的进程伪造 source_ids 仍然被拒

    /// ★ 这条用例**绕过助手**直接往 socket 写报文——正是「同 UID 的任何进程都能连」
    /// 这个前提下的攻击形态（§5.2.2）。
    ///
    /// 报文里写 `source_ids: [未授权的来源]`，App 必须照样 `source_denied`：
    /// 授权从来不是报文说了算。
    func testForgedSourceIDsFromAnotherProcessAreStillDenied() throws {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac, archive]))
        serve(service(holder))

        let forged = AuthorityWire.Request(id: "forged", op: "locate",
                                           args: ["query": .string("年报"),
                                                  "source_ids": .array([.string(archive)])])
        let response = try rawExchange(forged)

        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "source_denied",
                       "App 相信了报文里的 source_ids：伪造一个 id 就拿到未授权来源")
        XCTAssertFalse(response.error?.message.contains(archive) ?? true,
                       "错误文案里不许出现来源 id/名字（§4.3.1）")
    }

    /// 反过来：报文里点名一个**已授权**的来源，App 正常往下走。
    ///
    /// 6.3b-1 起 `locate` 是真搜索，所以终点不再是 `internal_error`，而是
    /// 「这个来源没有 provider」→ `source_unavailable`。关键是**仍然不是 `source_denied`**：
    /// 它过了判定，只是没东西可搜。这条用来证明上一条不是「一律拒绝」。
    func testForgedButAuthorizedSourceIDsReachTheNormalPath() async throws {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        serve(service(holder))

        let request = AuthorityWire.Request(id: "ok", op: "locate",
                                            args: ["query": .string("年报"),
                                                   "source_ids": .array([.string(mac)])])
        let response = try await rawExchangeInBackground(request)

        XCTAssertEqual(response.ok, false)
        XCTAssertEqual(response.error?.code, "source_unavailable",
                       "已授权来源应当过判定，卡在「没有可执行的来源」而不是「没权限」")
    }

    // MARK: - ⑧ 每请求恰好一次路由

    /// ★ 一次请求判两次权限，就会出现「第一次允许、第二次拒绝」这种只有并发才复现的分叉。
    func testRoutingHappensExactlyOncePerRequest() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))

        let counter = RouteCounter()

        let counted = service(holder) { tool, arguments, facts in
            counter.bump()
            return ToolRouter.route(tool: tool, arguments: arguments, permission: facts)
        }

        _ = await counted.handle(job(.listSources))
        XCTAssertEqual(counter.count, 1)

        // 被拒的请求也只判一次（不能「先粗判一次、拒绝前再复核一次」）。
        holder.update(settings: AIAccessSettings(isEnabled: false, allowedSources: []))
        _ = await counted.handle(job(.listSources))
        XCTAssertEqual(counter.count, 2)
    }

    // MARK: - 六个 Tool 全部接上

    /// `recent` 已不再是「明确失败」——7b 有了库、7c 接了写者，它现在真执行。
    ///
    /// ★ **空列表不等于假实现**：本用例装配的是「没有 History 库」的服务
    ///   （`service(holder)` 不带 `historyStore`），此时 `recent` 返回空结果，
    ///   并且必须在 `warnings` 里如实说 `recent_unavailable`。
    ///   这与 6.4a 时被禁止的那种「假 `recent: []`」的区别就在这条 warning 上：
    ///   那时它假装「搜过了、没有」，现在它说的是「这个功能没开」。
    ///
    /// ★ 顺带说明：6.4a 曾经有一条 `testRecentStillFailsExplicitly` 守着
    ///   「不许为了让六个 Tool 全亮起来先做一个假实现」，那条契约现已由本条
    ///   与 7d 的「recent 真执行」用例接管，因此原用例删除。
    func testRecentIsRealAndSaysSoWhenThereIsNoHistoryStore() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        let outcome = await service(holder).handle(job(.recent, [:]))
        guard case .success(let json) = outcome else {
            return XCTFail("recent 不该再是 internal_error：\(outcome)")
        }
        XCTAssertTrue(json.contains("recent_unavailable"),
                      "没有 History 库时必须如实说明，不能静默返回空列表：\(json)")
    }

    /// `get_metadata` 已经真的执行了：它不再落到「未实现」那条分支上。
    ///
    /// ★ 这条守的是**接线**：它不问结果对不对（那是 `GetMetadataExecutionTests`
    /// 的事），只要求 `get_metadata` 已经从 `NotImplementedAuthorityService`
    /// 里搬出来了。少这条的话，「路由分支漏了 get_metadata」不会有任何用例红。
    func testGetMetadataIsNoLongerNotImplemented() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        let store = try? FileReferenceStore(url: temporaryStoreURL())
        defer { store?.close() }
        let outcome = await service(holder, store: store).handle(
            job(.getMetadata, ["file_id": .string("ff1_" + String(repeating: "0", count: 32))]))
        guard case .failure(let code, _) = outcome else {
            return XCTFail("get_metadata 对未知 id 必须是失败")
        }
        XCTAssertNotEqual(code, NotImplementedAuthorityService.code)
        // 表里没有这个 id → file_not_found（不是 internal_error、不是未实现）。
        XCTAssertEqual(code, MetadataExecutor.FailureCode.fileNotFound.rawValue)
    }

    // MARK: - 参数语义只在 App：schema 说了算

    /// `list_sources` 不接受 `source_ids`（schema 里没有这个参数）→ `invalid_argument`。
    ///
    /// ★ 这条同时证明「助手没有替 App 校验」：助手把键原样送过来，App 才拒。
    func testListSourcesRejectsUndeclaredArguments() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        let outcome = await service(holder).handle(
            job(.listSources, ["source_ids": .array([.string(archive)])]))

        guard case .failure(let code, let message) = outcome else {
            return XCTFail("应当被拒：\(outcome)")
        }
        XCTAssertEqual(code, "invalid_argument")
        XCTAssertTrue(message.contains("source_ids"))
    }

    /// `source_ids: null`（线上是 `.null`）必须报类型错，**不能**变成「没传」。
    ///
    /// 变成「没传」= 一次参数错误静默放大成「搜所有已授权来源」（§4.3.1）。
    func testNullSourceIDsIsInvalidArgumentNotOmitted() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        let outcome = await service(holder).handle(
            job(.locate, ["query": .string("q"), "source_ids": .null]))

        XCTAssertEqual(outcome, .failure(code: "invalid_argument",
                                         message: "source_ids must be an array of source_id strings. "
                                                + "Omit it to search every authorized source."))
    }

    /// 空数组是「点了名但一个都没给」→ `source_denied`，不是「没点名」。
    func testEmptySourceIDsIsDeniedRatherThanOmitted() async {
        let holder = Holder(settings: enabled([mac]), sources: sources([mac]))
        let outcome = await service(holder).handle(
            job(.locate, ["query": .string("q"), "source_ids": .array([])]))

        XCTAssertEqual(outcome, .failure(code: "source_denied",
                                         message: PermissionPolicy.nothingRequestedMessage))
    }

    // MARK: - ⑧ 判权与执行共用同一份来源（§15 #23，Phase 6.3b-0）

    /// ★ 这条守的是「判权之后来源变了，**可以失败，但不能扩权**」。
    ///
    /// 复现的正是危险窗口：
    ///
    /// ```text
    /// T0  判权：读注册表 → [mac, work] 都在，放行
    /// T1  用户删掉它们
    /// T2  执行侧若再读一次 → 拿到 [] 或全新的来源
    /// ```
    ///
    /// 这里让第二次读**返回另一个来源**（模拟「删掉 A、新建 A'」）。执行侧只要不是
    /// 又读了一次，输出就只会是 T0 那两个；一旦多读一次，结果里就会出现新来源的 id。
    func testTheExecutorUsesTheSnapshotThatWasAuthorized() async throws {
        let macID = mac, workID = work
        let reads = RouteCounter()
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID, workID]) },
            sources: {
                reads.bump()
                // 第一次 = 判权那次；之后 = 用户在设置里改了来源集合。
                return reads.count == 1
                    ? [AuthoritySource(id: macID, name: "This Mac"),
                       AuthoritySource(id: workID, name: "Work NAS")]
                    : [AuthoritySource(id: "src_nas_new", name: "Brand New NAS")]
            })

        let items = try listed(await service.handle(job(.listSources)))

        XCTAssertEqual(items.map { $0["source_id"] }, [macID, workID])
        XCTAssertFalse(items.contains { $0["source_id"] == "src_nas_new" },
                       "执行侧又读了一次注册表：这次请求拿到了判权时并不存在的来源")
        XCTAssertEqual(reads.count, 1, "一次请求只许读一次来源")
    }

    /// 判权之后来源被删光：**这次请求正常失败**，不是「换成空列表继续跑」。
    /// 失败是可接受的（用户刚删的），扩权不是。
    func testADeletedSourceFailsTheRequestInsteadOfSubstitutingAnother() async {
        let workID = work
        let reads = RouteCounter()
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [workID]) },
            sources: {
                reads.bump()
                return reads.count == 1
                    ? [AuthoritySource(id: workID, name: "Work NAS")]
                    : []
            })

        let outcome = await service.handle(job(.locate, ["query": .string("年报")]))

        // 6.3b-1 起 `locate` 是真搜索：这份读数里没有执行句柄（来源已删），
        // 所以结果是 `source_unavailable`。关键是**不是成功**，
        // 更不是「换成别的来源搜一遍」。
        XCTAssertEqual(outcome, .failure(code: "source_unavailable",
                                         message: LocateFailureCode.sourceUnavailable.message))
        XCTAssertEqual(reads.count, 1, "一次请求只许读一次来源")
    }

    // MARK: - ⑨ locate 真的搜（Phase 6.3b-1）

    /// 一个只产出固定结果的 provider。**不发终态以外的任何事件**。
    private final class StubProvider: SearchProvider, @unchecked Sendable {

        let source: SearchSource
        private let rows: [SearchResult]
        private let state: ProviderSearchState
        private(set) var searchCount = 0
        private(set) var owners: [SearchOwner] = []

        init(id: String, rows: [SearchResult], state: ProviderSearchState = .completed) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.rows = rows
            self.state = state
        }

        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            searchCount += 1
            owners.append(owner)
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, results: rows, state: state))
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            await search(text, queryID: queryID, owner: .ui, emit: emit)
        }

        func cancel(queryID: UUID) {}
    }

    private func located(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw NotSuccess()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func stubRow(_ path: String) -> SearchResult {
        SearchResult(id: path, name: (path as NSString).lastPathComponent, relativePath: path,
                     sourceID: nil, sourceName: "", kind: "file", size: 1, localURL: nil)
    }

    /// 走真 socket 的一次 `locate`：`results` 里是 §4.4 冻结的字段，
    /// `file_id` 由 `FileID.make` 产出（不是拼出来的）。
    @MainActor
    func testLocateReturnsTheFrozenPayloadThroughTheSocket() async throws {
        let macID = mac
        let provider = StubProvider(id: macID, rows: [stubRow("/Users/example/年报.pdf")])
        let scheduler = SearchScheduler(providers: [provider])
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID]) },
            sources: { [AuthoritySource(id: macID, name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))] },
            timing: LocateExecutor.Timing(now: { Date(timeIntervalSince1970: 1_800_000_000) }))
        serve(service)
        let link = UnixSocketAuthorityLink(path: path)

        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("年报")])))
        XCTAssertEqual(body["truncated"] as? Bool, false)
        XCTAssertEqual(body["limit_applied"] as? Int, 5)
        XCTAssertEqual(body["warnings"] as? [String], [])

        let hit = try XCTUnwrap((body["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(hit["relative_path"] as? String, "Users/example/年报.pdf")
        XCTAssertEqual(hit["source_id"] as? String, macID)
        XCTAssertEqual(hit["kind"] as? String, "file")
        // 七个字段的清单由 `LocateResponseTests` 钉住，这里只确认 id 真的能解析回来。
        let fileID = try XCTUnwrap(hit["file_id"] as? String)
        XCTAssertNotNil(FileID.parse(fileID), "返回的 file_id 自己都解析不了：\(fileID)")
    }

    /// ★ 执行侧用的 provider 必须来自**判权那一次**读数。
    ///
    /// 两次读数给的是两个**同 id** 的不同对象：只要执行侧读完注册表再换一次，
    /// 被搜的就是 `second`。这个形态比「删掉来源」更狠——删掉只会失败，
    /// 换成另一个对象则是静默地搜错设备。
    @MainActor
    func testLocateUsesTheProviderFromTheSameReadAsThePermissionDecision() async {
        let first = StubProvider(id: mac, rows: [stubRow("/Users/example/年报.pdf")])
        let second = StubProvider(id: mac, rows: [stubRow("/Users/example/别的.pdf")])
        let reads = RouteCounter()
        let scheduler = SearchScheduler(providers: [first, second])
        let macID = mac

        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID]) },
            sources: {
                reads.bump()
                let provider = reads.count == 1 ? first : second
                return [AuthoritySource(id: macID, name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))]
            })

        let body = try? located(await service.handle(job(.locate, ["query": .string("年报")])))
        XCTAssertEqual(reads.count, 1, "一次请求只许读一次来源")
        XCTAssertEqual(first.searchCount, 1)
        XCTAssertEqual(second.searchCount, 0, "执行侧又读了一次：搜的是另一个 provider")
        XCTAssertEqual((body?["results"] as? [[String: Any]])?.first?["name"] as? String,
                       "年报.pdf")
    }

    // MARK: - ⑩ search / locate_many 也真的搜（Phase 6.4a）

    /// `search` 走**同一条** `ToolRouter → PermissionPolicy → snapshot → Scheduler`，
    /// 只是返回体换成五字段（没有 `score` / `reasons`）。
    ///
    /// ★ 这条守的是「接上了」：6.3b 阶段这两个 Tool 还回 `internal_error`，
    /// 如果只在执行层写好了、`RoutingAuthorityService` 忘了接分支，
    /// 执行层的用例全绿而产品仍然不可用。
    @MainActor
    func testSearchReachesTheProviderThroughTheSameAuthority() async throws {
        let macID = mac
        let provider = StubProvider(id: macID, rows: [stubRow("/Users/example/年报.pdf")])
        let scheduler = SearchScheduler(providers: [provider])
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID]) },
            sources: { [AuthoritySource(id: macID, name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))] })
        serve(service)
        let link = UnixSocketAuthorityLink(path: path)

        let body = try located(await link.call(tool: "search",
                                               arguments: ToolArguments(["query": .string("年报")])))
        XCTAssertEqual(body["limit_applied"] as? Int, 10, "search 的默认条数是 10")
        XCTAssertEqual(body["truncated"] as? Bool, false)

        let hit = try XCTUnwrap((body["results"] as? [[String: Any]])?.first)
        XCTAssertEqual(Set(hit.keys),
                       ["file_id", "name", "relative_path", "source_id", "kind"],
                       "search 的结果不许带 score / reasons")
        XCTAssertEqual(hit["relative_path"] as? String, "Users/example/年报.pdf")
    }

    /// `locate_many`：一条入参回一条分组，**顺序即输入顺序**，且 N 条子查询共用一个 owner。
    @MainActor
    func testLocateManyReturnsOneGroupPerQueryInInputOrder() async throws {
        let macID = mac
        let provider = StubProvider(id: macID, rows: [stubRow("/Users/example/年报.pdf")])
        let scheduler = SearchScheduler(providers: [provider])
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID]) },
            sources: { [AuthoritySource(id: macID, name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))] })
        serve(service)
        let link = UnixSocketAuthorityLink(path: path)

        let body = try located(await link.call(
            tool: "locate_many",
            arguments: ToolArguments(["queries": .stringArray(["甲", "乙", "丙"])])))

        let groups = try XCTUnwrap(body["queries"] as? [[String: Any]])
        XCTAssertEqual(groups.compactMap { $0["query"] as? String }, ["甲", "乙", "丙"])
        XCTAssertEqual(body["limit_applied"] as? Int, 3, "per_query_limit 的默认值是 3")
        XCTAssertEqual(groups.map { ($0["results"] as? [Any])?.count }, [1, 1, 1])
        XCTAssertEqual(provider.searchCount, 3, "三条子查询各打一次 provider")

        let owners = Set(provider.owners.map { "\($0)" })
        XCTAssertEqual(owners.count, 1, "三条子查询必须是同一个 owner：\(owners)")
    }

    /// 一次 wire 请求 = 一个 owner：两个不同的请求 id 必须落到两个不同的 owner 上。
    ///
    /// 这条断言的是**服务层**（`AuthorityJob.owner`），不是调度器：
    /// 服务若自己造一个固定 owner，两个 Agent 会互相取消。
    @MainActor
    func testEachWireRequestReachesTheProviderAsItsOwnOwner() async throws {
        let provider = StubProvider(id: mac, rows: [stubRow("/Users/example/年报.pdf")])
        let scheduler = SearchScheduler(providers: [provider])
        let macID = mac
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [macID]) },
            sources: { [AuthoritySource(id: macID, name: "This Mac",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                         scheduler: scheduler))] })

        _ = await service.handle(AuthorityJob(id: "req-one", op: .locate,
                                              arguments: ["query": .string("年报")]))
        _ = await service.handle(AuthorityJob(id: "req-two", op: .locate,
                                              arguments: ["query": .string("年报")]))

        XCTAssertEqual(provider.owners.count, 2, "两次请求没有各搜一次")
        // ★ 先判长度再取下标：红证把「locate 路由」整条改坏时这里是 0 条，
        // 直接 `owners[0]` 会让整个测试进程崩掉（Fatal error: Index out of range），
        // 后面所有用例都不再执行——红证就只剩前 30 条。
        guard provider.owners.count == 2 else { return }
        XCTAssertNotEqual(provider.owners[0], provider.owners[1], "两个请求共用了同一个 owner")
        XCTAssertFalse(provider.owners.contains(.ui), "MCP 请求不许冒充 GUI")
    }
}
