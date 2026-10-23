import XCTest
@testable import FlashFindCore

/// Unix Socket 传输层（Phase 6.1）。
///
/// 这里守的是 §1.3.3 / §1.3.3.1 / §1.3.4 那三节写死的东西：
/// 权限位、`getpeereid`、stale 判定顺序、报文上限、读空闲超时、总预算。
///
/// ★ 所有用例都用 `/tmp/ff-xxxxxxxx/` 下的短路径：`sun_path` 只有 104 字节，
/// Xcode 的 DerivedData 路径轻松超过，写长了会得到一个和「路径不存在」分不清的报错。
final class AuthoritySocketTests: XCTestCase {

    private var root = ""
    private var path = ""
    private var listeners: [AuthorityListener] = []

    override func setUpWithError() throws {
        root = "/tmp/ff-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        path = root + "/mcp.sock"
    }

    override func tearDown() {
        for listener in listeners { listener.stop() }
        listeners = []
        try? FileManager.default.removeItem(atPath: root)
    }

    // MARK: - 小工具

    /// 一次 `list_sources` 调用（6.2 起唯一有实现的业务操作）。
    private func listSourcesCall() -> (tool: String, arguments: ToolArguments) {
        ("list_sources", ToolArguments())
    }

    @discardableResult
    private func start(_ service: any AuthorityServing = NotImplementedAuthorityService(),
                       limits: AuthorityLimits = AuthorityLimits())
        -> (listener: AuthorityListener, result: AuthorityListener.StartResult) {
        let listener = AuthorityListener(path: path, service: service, limits: limits, log: { _ in })
        listeners.append(listener)
        return (listener, listener.start())
    }

    private func exchange(_ payload: Data,
                          limits: AuthorityLimits = AuthorityLimits()) throws -> AuthorityWire.Response {
        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        try UnixSocket.writeAll(fd, payload)
        _ = shutdown(fd, SHUT_WR)
        let data = try UnixSocket.readLine(fd, maxBytes: limits.maxResponseBytes,
                                           deadline: Date().addingTimeInterval(3),
                                           idleTimeout: 3)
        return try AuthorityWire.decodeResponse(data)
    }

    private func exchange(_ line: String,
                          limits: AuthorityLimits = AuthorityLimits()) throws -> AuthorityWire.Response {
        try exchange(Data(line.utf8), limits: limits)
    }

    private func mode(of path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let permissions = attributes[.posixPermissions] as? NSNumber else { return -1 }
        return permissions.intValue
    }

    private func inode(of path: String) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path),
              let number = attributes[.systemFileNumber] as? NSNumber else { return -1 }
        return number.intValue
    }

    // MARK: - 权限位

    func testDirectoryIsOwnerOnly() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")
        XCTAssertEqual(mode(of: root), 0o700, "IPC 目录必须是 0700")
    }

    func testSocketIsOwnerOnly() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")
        XCTAssertEqual(mode(of: path), 0o600, "socket 必须是 0600")
    }

    /// `0600` 只挡别的用户；同一用户下被诱导的进程要靠 `getpeereid` 这一道。
    /// 真实场景要另一个用户的进程，测试里造不出来，所以守判定函数。
    func testPeerUIDMustMatchTheCurrentUser() {
        XCTAssertTrue(AuthorityPeer.accepts(peerUID: getuid()))
        XCTAssertFalse(AuthorityPeer.accepts(peerUID: getuid() &+ 1))
    }

    // MARK: - SIGPIPE（Phase 6.3b-1 实测踩到）

    /// 每条 socket 建出来就关了 `SIGPIPE`。
    ///
    /// ★ 这条断言的是**选项真的设上了**，不是「行为大致正常」：默认设置下，
    /// 客户端提前断开会让监听端收到 `SIGPIPE`，整个 App 直接消失（信号 13，
    /// 没有 crash log）。红证时这条会立刻暴露「有人把那一行删了」。
    func testSocketsAreCreatedWithSIGPIPESuppressed() throws {
        let fd = try UnixSocket.makeSocket()
        defer { close(fd) }

        var value: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        XCTAssertEqual(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &value, &size), 0)
        XCTAssertEqual(value, 1, "socket 上没有关掉 SIGPIPE")
    }

    /// 客户端发完就走（不等回包）不许把监听端打死。
    ///
    /// ★ 真实的触发形态：Agent 侧的 10 秒预算到了 → 客户端关 fd 走人 →
    /// App 这边正在写回包。没有 `SO_NOSIGPIPE` 时这一下就是进程级死亡。
    func testAClientThatLeavesBeforeTheResponseCannotKillTheListener() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let line = try AuthorityWire.line(AuthorityWire.Request(id: "x", op: "list_sources", args: [:]))
        for _ in 0..<3 {
            let fd = try UnixSocket.connect(path)
            try UnixSocket.writeAll(fd, line)
            close(fd)                     // 不读回包，直接走
        }

        // 到这一步进程还活着就说明没被 SIGPIPE 打死；再确认监听仍然可用。
        usleep(150_000)
        let pong = try exchange(try AuthorityWire.line(AuthorityWire.Request(id: "p", op: "ping", args: [:])))
        XCTAssertEqual(pong.ok, true, "监听在客户端提前断开之后不再应答")
    }

    // MARK: - 探活

    func testPingAnswersOverTheSocket() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: AuthorityLimits()))
    }

    /// `ping` 由传输层自己答，**不受业务实现影响**：业务没接上时探活仍然要成功，
    /// 否则启动时的 stale 判定会把「活着但业务没实现」误判成 stale 并抢掉 socket。
    func testPingDoesNotDependOnTheBusinessService() throws {
        let service = RecordingService()
        service.outcome = .failure(code: "internal_error", message: "not implemented")
        let started = start(service)
        XCTAssertTrue(started.result.isListening, "\(started.result)")
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: AuthorityLimits()))
    }

    // MARK: - 连不上 / 重启恢复

    func testMissingSocketMapsToAppUnavailable() async {
        let call = listSourcesCall()
        let outcome = await UnixSocketAuthorityLink(path: path).call(tool: call.tool,
                                                                    arguments: call.arguments)
        XCTAssertEqual(outcome,
                       .failure(code: UnixSocketAuthorityLink.appUnavailableCode,
                                message: UnixSocketAuthorityLink.appUnavailableMessage))
    }

    /// 同一个 `link`（同一个 Helper 进程）在 App 退出再起来之后必须能用。
    ///
    /// ★ 这是最容易做成「一次连接，断了就永久失败」的一条（§1.5）。
    func testLinkRecoversAfterTheAuthorityRestarts() async {
        let link = UnixSocketAuthorityLink(path: path)
        let service = RecordingService()
        let call = listSourcesCall()

        let first = start(service)
        XCTAssertTrue(first.result.isListening, "\(first.result)")
        let up = await link.call(tool: call.tool, arguments: call.arguments)
        XCTAssertEqual(up, .success(json: #"{"ok":true}"#))

        first.listener.stop()
        let down = await link.call(tool: call.tool, arguments: call.arguments)
        XCTAssertEqual(down,
                       .failure(code: UnixSocketAuthorityLink.appUnavailableCode,
                                message: UnixSocketAuthorityLink.appUnavailableMessage))

        let second = start(service)
        XCTAssertTrue(second.result.isListening, "\(second.result)")
        let recovered = await link.call(tool: call.tool, arguments: call.arguments)
        XCTAssertEqual(recovered, .success(json: #"{"ok":true}"#),
                       "App 重启后同一个 Helper 必须恢复，不能要求重启 Helper")
    }

    // MARK: - stale 判定（§1.3.3.1）

    /// 已经有活实例时，第二个实例**不许 unlink**。
    ///
    /// ★ 断言的是 **inode 没变**，不是「第一个还能 ping」——后者在
    /// 「B 把 A 的 socket 删了、自己绑上」这种错误实现下也会成功（pong 来自 B），
    /// 那正是 v0.2 写错的地方：两个实例都活着，但 A 已经不可达。
    func testSecondInstanceDoesNotStealTheSocket() throws {
        let first = start()
        XCTAssertTrue(first.result.isListening, "\(first.result)")
        let inodeBefore = inode(of: path)

        let second = start()
        XCTAssertEqual(second.result, .ownedByAnotherInstance)
        XCTAssertFalse(second.listener.isListening, "第二个实例不该启动 authority")

        XCTAssertEqual(inode(of: path), inodeBefore, "第二个实例换了 socket 文件")
        XCTAssertTrue(first.listener.isListening)
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: AuthorityLimits()))
    }

    /// 「文件在、没人在听」= stale，可以接管。
    func testStaleSocketIsTakenOver() throws {
        let stale = try UnixSocket.bind(path)
        try UnixSocket.listen(stale)
        close(stale)                       // 只关 fd，不删文件：这就是崩溃后的现场
        XCTAssertTrue(FileManager.default.fileExists(atPath: path))

        let started = start()
        XCTAssertTrue(started.result.isListening, "stale socket 没被接管：\(started.result)")
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: AuthorityLimits()))
    }

    /// 「连得上但不回 pong」也是 stale。
    ///
    /// ★ 这一条专门打「`connect` 成功就算活着」的实现：半死进程照样让
    /// `connect` 成功，只有完整一次 ping 往返才分得清。
    ///
    /// ★ 这里**先直接断言 `ping` 为 false**，再去断言 start() 接管了 socket。
    /// 只断言后者是不够的：把「启动时无条件抢 socket」和「探活失败也算活着」
    /// 两处同时改坏时，抢 socket 的那条路径根本不走探活，这个用例会假绿。
    func testAConnectedButSilentSocketCountsAsStale() throws {
        let silent = try UnixSocket.bind(path)
        try UnixSocket.listen(silent)      // 只 listen，不 accept、不回话
        defer { close(silent) }

        var limits = AuthorityLimits()
        limits.probeTimeout = 0.2

        XCTAssertFalse(UnixSocketAuthorityLink.ping(path: path, limits: limits),
                       "connect 成功就当成活着，等于把半死进程当活实例")

        let started = start(limits: limits)
        XCTAssertTrue(started.result.isListening, "连上但不回话的 socket 必须判 stale：\(started.result)")
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: limits))
    }

    /// 两个实例同时启动：只有一个拿到 authority，另一个安静退出这条路径。
    func testConcurrentStartsHaveExactlyOneOwner() {
        let first = AuthorityListener(path: path, service: NotImplementedAuthorityService(), log: { _ in })
        let second = AuthorityListener(path: path, service: NotImplementedAuthorityService(), log: { _ in })
        listeners.append(contentsOf: [first, second])

        let lock = NSLock()
        var results: [AuthorityListener.StartResult?] = [nil, nil]
        DispatchQueue.concurrentPerform(iterations: 2) { index in
            let result = index == 0 ? first.start() : second.start()
            lock.lock(); results[index] = result; lock.unlock()
        }

        let owners = results.compactMap { $0 }.filter(\.isListening).count
        XCTAssertEqual(owners, 1, "拿到 authority 的必须恰好一个：\(results)")
        XCTAssertTrue(UnixSocketAuthorityLink.ping(path: path, limits: AuthorityLimits()))
    }

    func testStoppingRemovesTheSocketFile() {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")
        started.listener.stop()
        XCTAssertFalse(FileManager.default.fileExists(atPath: path),
                       "正常退出要顺手删掉 socket（SIGKILL 那条路靠 stale 判定兜）")
    }

    // MARK: - 报文上限与超时（§1.3.4）

    func testOversizedRequestIsRejected() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let payload = Data(String(repeating: "a", count: 70 * 1024).utf8)
        let response = try exchange(payload)

        XCTAssertFalse(response.ok)
        XCTAssertEqual(response.error?.code, "invalid_argument")
        XCTAssertEqual(response.error?.message, "request too large")
    }

    func testOversizedResponseBecomesAnError() throws {
        let service = RecordingService()
        service.outcome = .success(json: "{\"blob\":\""
                                   + String(repeating: "x", count: 4 * 1024 * 1024 + 4096) + "\"}")
        let started = start(service)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange(AuthorityWire.line(AuthorityWire.Request(id: "big", op: "list_sources")))

        XCTAssertFalse(response.ok, "超过 4 MB 的响应不能发出去")
        XCTAssertEqual(response.error?.code, "internal_error")
        XCTAssertEqual(response.error?.message, "response too large")
        XCTAssertEqual(response.id, "big", "错误响应也要带回原 id，否则客户端认不出这是哪一条")
    }

    /// 连上了不说话：读空闲超时后服务端关连接。
    func testIdleConnectionIsClosed() throws {
        var limits = AuthorityLimits()
        limits.readIdleTimeout = 0.2
        let started = start(limits: limits)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let fd = try UnixSocket.connect(path)
        defer { close(fd) }
        Thread.sleep(forTimeInterval: 0.6)

        XCTAssertThrowsError(try UnixSocket.readLine(fd, maxBytes: 1024,
                                                    deadline: Date().addingTimeInterval(1),
                                                    idleTimeout: 1)) { error in
            XCTAssertEqual((error as? UnixSocketError)?.kind, .closed)
        }
    }

    /// 权威端超过总预算没答完 → `timeout`，不是 `app_unavailable`：
    /// 两者的「Agent 下一步」不同（重试 vs 请用户打开闪寻）。
    func testSlowAuthorityTimesOut() throws {
        let service = RecordingService()
        service.delay = 0.6
        var limits = AuthorityLimits()
        limits.requestTimeout = 0.1
        let started = start(service, limits: limits)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange(AuthorityWire.line(AuthorityWire.Request(id: "slow", op: "list_sources")),
                                    limits: limits)
        XCTAssertEqual(response.error?.code, "timeout")
        XCTAssertEqual(response.id, "slow")
    }

    // MARK: - 首帧预算 vs 中途空闲（build 29，代码审核 BUG-112-02）

    /// ★ 首帧等待必须覆盖**整个请求预算**，不能被 `readIdleTimeout` 压住。
    ///
    /// 权威端是「整次操作跑完才回一帧」：`locate` 要遍历、`search` 要问设备，
    /// 中间一个字节都不发是**正常行为**。旧实现只等 `min(readIdleTimeout, 剩余预算)`，
    /// 于是正常耗时 5–8 秒的调用被自己的客户端判成超时，而 App 那边还在好好地跑。
    ///
    /// 这条走的是真实链路（`AuthorityListener` + `UnixSocketAuthorityLink`），
    /// 数字缩小只是为了跑得快：`idle 0.2s < 实际 0.6s < 预算 3s`。
    func testSlowButWithinBudgetResponseIsNotCutByTheIdleTimeout() throws {
        let service = RecordingService()
        service.delay = 0.6
        var limits = AuthorityLimits()
        limits.requestTimeout = 3
        limits.readIdleTimeout = 0.2
        let started = start(service, limits: limits)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let result = UnixSocketAuthorityLink.roundTrip(
            AuthorityWire.Request(id: "slow-ok", op: "list_sources"),
            path: path,
            limits: limits)

        guard case .success(let response) = result else {
            return XCTFail("0.6 秒的响应落在 3 秒预算里，不该判超时：\(result)")
        }
        XCTAssertNil(response.error)
        XCTAssertEqual(response.id, "slow-ok")
    }

    /// 已经收到数据之后的停顿，仍然只等 `idleTimeout`。
    ///
    /// ★ 这一条守的是「别把首帧预算顺手套到中途」：`locate` 的响应是一次性写出来的，
    /// 回到一半卡住就是真的半死，不该再等满整个总预算。
    func testAStallAfterTheFirstChunkStillUsesTheIdleTimeout() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        // 先喂一小块（不带换行）让对方「已经开始收到数据」，然后彻底不写。
        try UnixSocket.writeAll(fds[0], Data("abc".utf8))

        let began = Date()
        XCTAssertThrowsError(try UnixSocket.readLine(fds[1],
                                                     maxBytes: 1024,
                                                     deadline: Date().addingTimeInterval(5),
                                                     idleTimeout: 0.2)) { error in
            XCTAssertEqual((error as? UnixSocketError)?.kind, .idleTimeout)
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 2,
                          "中途停顿只该等 idleTimeout，等满 5 秒预算就是把「半死」当成了「还在算」")
    }

    /// 分段慢速发送**不能**把总预算续命。
    ///
    /// 每 100 ms 喂一个字节，单看两次之间的间隔（0.1s）永远不超 idleTimeout（0.3s），
    /// 但它们加起来早就越过 0.5 秒的总预算了。少写 `min(…, remaining)` 那一层，
    /// 一次请求就能被拖成任意长。
    func testDribbledChunksCannotExtendTheTotalBudget() throws {
        var fds: [Int32] = [-1, -1]
        XCTAssertEqual(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds), 0)
        defer { close(fds[0]); close(fds[1]) }

        let writeFD = fds[0]
        let writer = Thread {
            for _ in 0..<40 {
                guard (try? UnixSocket.writeAll(writeFD, Data("x".utf8))) != nil else { return }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
        writer.start()

        let began = Date()
        XCTAssertThrowsError(try UnixSocket.readLine(fds[1],
                                                     maxBytes: 1024,
                                                     deadline: Date().addingTimeInterval(0.5),
                                                     idleTimeout: 0.3)) { error in
            XCTAssertEqual((error as? UnixSocketError)?.kind, .idleTimeout,
                           "总预算到了就该报超时，不是慢慢等对方写完")
        }
        XCTAssertLessThan(Date().timeIntervalSince(began), 1.5)
    }

    // MARK: - 报文本身

    /// 报文 id 必须**过河到业务层**（v0.20 / §4.7）。
    ///
    /// App 侧拿它算 `SearchOwner`：所有请求都落进同一个空 id 的话，
    /// 「同一个请求的子查询同 owner、不同请求不同 owner」这条契约就地失效，
    /// 而回归的表现只是「偶尔搜不到」——所以这条必须单独守着。
    func testTheRequestIDReachesTheService() throws {
        let service = RecordingService()
        let started = start(service)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange(AuthorityWire.line(AuthorityWire.Request(id: "req-7", op: "list_sources")))

        XCTAssertTrue(response.ok)
        XCTAssertEqual(service.jobs.count, 1)
        XCTAssertEqual(service.jobs.first?.id, "req-7", "报文 id 没有交给业务层")
    }

    /// 未知 op 与「未知工具」**同一个码**（v0.18）：Agent 不该因为写错名字的位置不同
    /// 而拿到两种不同的错误码。
    func testUnknownOperationIsRejectedAsUnknownTool() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange(AuthorityWire.line(AuthorityWire.Request(id: "u", op: "do_the_thing")))
        XCTAssertEqual(response.error?.code, "unknown_tool")
        XCTAssertEqual(response.id, "u")
        XCTAssertEqual(response.v, AuthorityWire.version)
    }

    func testUnreadableRequestIsRejected() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange("this is not json\n")
        XCTAssertEqual(response.error?.code, "invalid_argument")
    }

    func testResponseEchoesTheRequestID() throws {
        let started = start()
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let response = try exchange(AuthorityWire.line(AuthorityWire.Request(id: "abc-123", op: "list_sources")))
        XCTAssertEqual(response.id, "abc-123")
    }

    // MARK: - 交给业务层的东西

    /// 传输层交给业务层的只有「op + 原始参数」，**没有授权范围**（§5.2.2）。
    ///
    /// `source_ids` 在这条报文里是 Agent 自己写的，原样到达；它是不是被批准，
    /// 由业务层（App 的 `RoutingAuthorityService`）重新判一次。
    func testTheAuthorityReceivesTheRawArguments() throws {
        let service = RecordingService()
        let started = start(service)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let request = AuthorityWire.Request(id: "j1", op: "locate",
                                            args: ["query": .string("  年报  "),
                                                   "limit": .int(5),
                                                   "source_ids": .array([.string("src_mac")])])
        _ = try exchange(AuthorityWire.line(request))

        let job = try XCTUnwrap(service.jobs.first)
        XCTAssertEqual(job.op, .locate)
        XCTAssertEqual(job.arguments["query"], .string("  年报  "),
                       "传输层不许 trim：参数语义是 App 的事")
        XCTAssertEqual(job.arguments["source_ids"], .array([.string("src_mac")]),
                       "Agent 点名的来源原样送达，由 App 审")
        XCTAssertEqual(Set(job.arguments.keys), ["query", "limit", "source_ids"])
    }

    func testLinkForwardsTheAuthorityFailureVerbatim() async {
        let service = RecordingService()
        service.outcome = .failure(code: "auth_required", message: "Reconnect the share in FlashFind.")
        let started = start(service)
        XCTAssertTrue(started.result.isListening, "\(started.result)")

        let call = listSourcesCall()
        let outcome = await UnixSocketAuthorityLink(path: path).call(tool: call.tool,
                                                                    arguments: call.arguments)
        XCTAssertEqual(outcome, .failure(code: "auth_required",
                                         message: "Reconnect the share in FlashFind."),
                       "传输层不许改码")
    }
}

// MARK: - 测试替身

/// 记下权威端收到的 job，并按配置返回结果 / 拖延。
private final class RecordingService: AuthorityServing, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [AuthorityJob] = []

    var outcome: ToolOutcome = .success(json: #"{"ok":true}"#)
    var delay: TimeInterval = 0

    func handle(_ job: AuthorityJob) async -> ToolOutcome {
        if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
        // `NSLock.lock()` 在异步上下文里会被 Swift 6 判错（跨 await 持锁），
        // `withLock` 把临界区收成一个同步闭包。
        lock.withLock { storage.append(job) }
        return outcome
    }

    var jobs: [AuthorityJob] { lock.withLock { storage } }
}
