import Foundation

/// 权威端（App 进程内的闪寻）在 Unix Domain Socket 上监听（方案 §1.3）。
///
/// ## 启动流程顺序不可调换（§1.3.3.1）
///
/// ```text
/// bind
///  ├─ 成功 → chmod 0600 → listen
///  └─ EADDRINUSE
///      ├─ 发一次 ping，拿到 pong？
///      │    ├─ 是 → 已有活实例：不 unlink、不 bind、不启动 authority
///      │    └─ 否（拒绝连接 / 没有 pong / 500 ms 超时）→ 判定 stale
///      │          → unlink **一次** → bind 重试 **一次**
///      └─ 重试仍占用 → 放弃（不循环重试）
/// ```
///
/// ★ 为什么不能「启动时先 unlink 再 bind」：第二个实例会把第一个实例正在用的
/// socket 路径删掉并自己绑同一路径，第一个实例还活着但已经不可达——
/// 「唯一权威端」被静默破坏。这条在 v0.2 写错过一次（§1.3.3.1）。
///
/// ★ 为什么判据是「拿到 pong」而不是「connect 成功」：`connect` 成功只说明
/// 有个东西在 listen，半死进程照样让它成功；只有完整一次往返才能区分
/// 「活着」和「僵住」。
public final class AuthorityListener: @unchecked Sendable {

    public enum StartResult: Equatable, Sendable {
        case listening(String)
        /// 已经有一个活实例占着这个 socket：本实例**不启动** authority，也不删它。
        case ownedByAnotherInstance
        case failed(String)

        public var isListening: Bool {
            if case .listening = self { return true }
            return false
        }
    }

    // MARK: 配置

    private let path: String
    private let limits: AuthorityLimits
    private let service: any AuthorityServing
    private let log: @Sendable (String) -> Void

    /// 诊断输出。默认走 stderr —— App 不是 MCP 助手，stderr 上写东西不影响协议。
    ///
    /// 三句固定的日志（与 §1.3.3.1 要求的措辞一致）：
    /// `another instance owns the IPC socket` / `ipc stale socket detected, unlinked` /
    /// `rejected a connection from another user`。排查「为什么有两份闪寻」只有这一条线索。
    @Sendable
    public static func stderrLog(_ line: String) {
        FileHandle.standardError.write(Data(("flashfind-app: " + line + "\n").utf8))
    }

    // MARK: 状态

    private let acceptQueue = DispatchQueue(label: "flashfind.authority.accept")
    private let connectionQueue = DispatchQueue(label: "flashfind.authority.connection",
                                                attributes: .concurrent)
    private let stateLock = NSLock()
    private var source: DispatchSourceRead?
    private var listenFD: Int32 = -1
    private var ownsSocketFile = false

    public init(path: String = AuthoritySocketPath.standard(),
                service: any AuthorityServing,
                limits: AuthorityLimits = AuthorityLimits(),
                log: @escaping @Sendable (String) -> Void = AuthorityListener.stderrLog) {
        self.path = path
        self.service = service
        self.limits = limits
        self.log = log
    }

    deinit { stop() }

    /// 现在是否在监听。测试与「设置里关掉 AI」的收尾路径都用它。
    public var isListening: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return source != nil
    }

    public var socketPath: String { path }

    // MARK: 启动

    public func start() -> StartResult {
        if isListening { return .listening(path) }

        // 目录 0700：`~/Library/Application Support` 本身对同用户可读，
        // 单独把这个子目录收起来，别的账户连目录项都看不见。
        let directory = AuthoritySocketPath.directory(of: path)
        do {
            try FileManager.default.createDirectory(atPath: directory,
                                                    withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            return .failed("could not create the IPC directory")
        }
        // 目录已存在时 `createDirectory` 不会改权限，这里显式收一次：
        // 老版本可能留下 0755 的目录。
        guard chmod(directory, 0o700) == 0 else {
            return .failed("could not restrict the IPC directory")
        }

        let fd: Int32
        do {
            fd = try UnixSocket.bind(path)
        } catch let error as UnixSocketError {
            guard case .system(_, let code) = error.kind, code == EADDRINUSE else {
                return .failed("could not bind the IPC socket")
            }
            // 有东西占着这个路径。先问一句：它活着吗？
            if UnixSocketAuthorityLink.ping(path: path, limits: limits) {
                log("another instance owns the IPC socket")
                return .ownedByAnotherInstance
            }
            log("ipc stale socket detected, unlinked")
            unlink(path)                                  // 只 unlink 一次
            do {
                fd = try UnixSocket.bind(path)            // 只重试一次
            } catch {
                // 竞态里被别人抢走了。按「已有实例」处理，不做 while 重试——
                // 重试循环会让两个实例互相删对方的 socket。
                log("another instance owns the IPC socket")
                return .ownedByAnotherInstance
            }
        } catch {
            return .failed("could not bind the IPC socket")
        }

        // socket 文件 0600：只有本用户能连。权限位是第一道，`getpeereid` 是第二道。
        guard chmod(path, 0o600) == 0 else {
            close(fd)
            unlink(path)
            return .failed("could not restrict the IPC socket")
        }

        do {
            try UnixSocket.listen(fd)
        } catch {
            close(fd)
            unlink(path)
            return .failed("could not listen on the IPC socket")
        }

        // 非阻塞 + `DispatchSourceRead`：没有常驻线程，`stop()` 时能干净地取消。
        let flags = fcntl(fd, F_GETFL, 0)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }

        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: acceptQueue)
        source.setEventHandler { [weak self] in self?.acceptPending() }
        source.setCancelHandler { close(fd) }

        stateLock.lock()
        self.source = source
        self.listenFD = fd
        self.ownsSocketFile = true
        stateLock.unlock()

        source.resume()
        log("listening on the IPC socket")
        return .listening(path)
    }

    /// 停止监听。
    ///
    /// ★ **不依赖 `applicationWillTerminate`**（§1.3.3）：SIGTERM / SIGKILL 下它不执行。
    /// 所以「正常退出时删 socket」只是个顺手动作，真正保证下次能起来的是
    /// `start()` 里的 stale 判定。
    public func stop() {
        stateLock.lock()
        let source = self.source
        let owns = self.ownsSocketFile
        self.source = nil
        self.ownsSocketFile = false
        self.listenFD = -1
        stateLock.unlock()

        source?.cancel()          // cancel handler 负责 close(fd)
        if owns { unlink(path) }
    }

    // MARK: 接受连接

    private func acceptPending() {
        // 一次事件最多取 32 条，避免一个灌连接的进程把 accept 循环卡在这里。
        for _ in 0..<32 {
            let client = accept(listenFD, nil, nil)
            if client < 0 {
                if errno == EINTR { continue }
                return                                  // EAGAIN：这一轮取完了
            }
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            // ★ 必须在这里也设一次：`SO_NOSIGPIPE` 不会被 accept 继承（Linux 的
            // MSG_NOSIGNAL 是每次发送时给，macOS 是每条 fd 一次）。少了这一行，
            // 客户端提前断开就会把 App 直接打死——见 `UnixSocket.suppressSIGPIPE`。
            UnixSocket.suppressSIGPIPE(client)
            // 监听 fd 是非阻塞的；accepted fd 在 BSD 上会继承这个标志（不同系统不一致），
            // 显式清掉：`serve` 里用 poll + read 的阻塞语义。
            let flags = fcntl(client, F_GETFL, 0)
            if flags >= 0 { _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK) }

            connectionQueue.async { [weak self] in self?.serve(client) }
        }
    }

    // MARK: 一条连接

    private func serve(_ fd: Int32) {
        defer { close(fd) }

        guard let uid = UnixSocket.peerUID(fd) else {
            log("rejected a connection with no peer credentials")
            return
        }
        guard AuthorityPeer.accepts(peerUID: uid) else {
            // ★ 不回任何错误详情：一个「你是谁」的报错本身就是探测工具（§1.3.3）。
            log("rejected a connection from another user")
            return
        }

        let line: Data
        do {
            // 服务端等一条请求：这里**没有**「正常要跑很久」的情况，
            // 连上却不说话就该被掐掉，所以首帧预算仍用 `readIdleTimeout`。
            // 与调用端相反（那边首帧等满整个请求预算），别把两处的数抄成一致。
            line = try UnixSocket.readLine(
                fd,
                maxBytes: limits.maxRequestBytes,
                deadline: Date().addingTimeInterval(limits.readIdleTimeout),
                idleTimeout: limits.readIdleTimeout)
        } catch let error as UnixSocketError where error.kind == .tooLarge {
            // 能回就回再关：静默断开在客户端看来是「闪寻不稳定」（§1.3.4）。
            respond(fd, AuthorityWire.failure(id: "",
                                              code: "invalid_argument",
                                              message: "request too large"))
            log("rejected an oversized request")
            return
        } catch {
            // 空闲超时 / 对端早退：没有 id 可回，也没有可说的。
            return
        }

        guard let request = try? AuthorityWire.decodeRequest(line) else {
            respond(fd, AuthorityWire.failure(id: "",
                                              code: "invalid_argument",
                                              message: "The request is not a readable message."))
            return
        }
        guard request.v == AuthorityWire.version else {
            respond(fd, AuthorityWire.failure(id: request.id,
                                              code: "invalid_argument",
                                              message: "Unsupported local protocol version."))
            return
        }

        // `ping` 由传输层自己答：它问的是「这个权威端还活着吗」，与业务无关，
        // 也不该因为业务实现没接上就答不上来（启动探活依赖它）。
        if request.op == AuthorityWire.Operation.ping.rawValue {
            respond(fd, AuthorityWire.pong(id: request.id))
            return
        }

        guard let op = request.operation else {
            // ★ 与 Router 的码对齐（v0.18）：Agent 看到的是同一个 `unknown_tool`，
            // 不管它把名字写错在这一次调用里、还是写错在工具名上。
            respond(fd, AuthorityWire.failure(id: request.id,
                                              code: "unknown_tool",
                                              message: "Unknown tool '\(request.op)'. "
                                                     + "Call tools/list to see the available tools."))
            return
        }

        // ★ 只交「请求 id + 操作名 + Agent 给的原始参数 + History 标签」。
        // **不带授权范围**：判定发生在 `AuthorityServing` 里面（App 侧），
        // 不在传输层（§5.2.2）。id 带过去只为了一件事：`MCPOwner` 用它决定
        // 这次搜索的 owner（§4.7）——它**不是** session，两者别混（`HistoryContext`）。
        let job = AuthorityJob(id: request.id,
                               op: op,
                               arguments: request.args,
                               history: request.context)
        respond(fd, response(for: run(job), id: request.id))
    }

    /// 带总预算地跑业务实现。
    ///
    /// 同步等待一个 `Task` 的结果：`serve` 跑在自己的线程上（每条连接一个），
    /// 阻塞它不影响 accept 循环，也不影响别的连接。
    private func run(_ job: AuthorityJob) -> ToolOutcome {
        let box = OutcomeBox()
        let semaphore = DispatchSemaphore(value: 0)

        Task.detached { [service] in
            let outcome = await service.handle(job)
            box.set(outcome)
            semaphore.signal()
        }

        if semaphore.wait(timeout: .now() + limits.requestTimeout) == .timedOut {
            return .failure(code: UnixSocketAuthorityLink.timeoutCode,
                            message: "FlashFind did not finish this request in time.")
        }
        return box.value ?? .failure(code: UnixSocketAuthorityLink.internalCode,
                                     message: "FlashFind lost the answer to this request.")
    }

    private func response(for outcome: ToolOutcome, id: String) -> AuthorityWire.Response {
        switch outcome {
        case .success(let json):
            guard let value = try? AuthorityWire.value(fromJSON: json) else {
                return AuthorityWire.failure(id: id,
                                             code: UnixSocketAuthorityLink.internalCode,
                                             message: "FlashFind produced an unreadable result.")
            }
            return AuthorityWire.Response(id: id, ok: true, result: value)

        case .failure(let code, let message):
            return AuthorityWire.failure(id: id, code: code, message: message)
        }
    }

    private func respond(_ fd: Int32, _ response: AuthorityWire.Response) {
        guard var data = try? AuthorityWire.line(response) else { return }

        if data.count > limits.maxResponseBytes {
            // 不发超限体，改回一个错误（§1.3.4）：静默截断会让 Agent 拿到半截 JSON。
            log("response too large")
            let fallback = AuthorityWire.failure(id: response.id,
                                                 code: UnixSocketAuthorityLink.internalCode,
                                                 message: "response too large")
            guard let replacement = try? AuthorityWire.line(fallback) else { return }
            data = replacement
        }
        try? UnixSocket.writeAll(fd, data)
    }
}

/// 跨线程传一个 `ToolOutcome`（`DispatchSemaphore` 只同步信号，不同步值）。
private final class OutcomeBox: @unchecked Sendable {

    private let lock = NSLock()
    private var stored: ToolOutcome?

    func set(_ outcome: ToolOutcome) {
        lock.lock()
        stored = outcome
        lock.unlock()
    }

    var value: ToolOutcome? {
        lock.lock()
        defer { lock.unlock() }
        return stored
    }
}
