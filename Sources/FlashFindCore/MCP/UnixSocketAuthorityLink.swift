import Foundation

/// socket 的标准位置。
///
/// ```text
/// ~/Library/Application Support/FlashFind2/ipc/mcp.sock
/// ```
///
/// ★ App 与 Helper 必须算出**同一个路径**，所以这里不接受「相对当前工作目录」
/// 或「跟着 App 的缓存目录走」：缓存目录在 UI 预览里会被换成另一个根，
/// 一旦 socket 跟着它走，预览构建会和正式构建抢两个不同的路径，看起来像「连不上」。
public enum AuthoritySocketPath {

    /// 目录名与文件名。两者都参与 `verify_clean.py` 的对外标识检查（§13）。
    public static let directoryName = "ipc"
    public static let fileName = "mcp.sock"

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String {
        home.appendingPathComponent("Library/Application Support/FlashFind2")
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
            .path
    }

    public static func directory(of socketPath: String) -> String {
        (socketPath as NSString).deletingLastPathComponent
    }
}

/// 调用端：每次请求新建一条连接（§1.3.1 / §1.5）。
///
/// ## 为什么每次重新 connect
///
/// 「App 重启后 Helper 不重启也能恢复」是最容易做错的一条：一旦在进程启动时
/// 建好一条连接并缓存 fd，App 退出后那条 fd 就永久死了，Helper 只能重启。
/// 每次请求新建连接把这个问题消掉，代价是 0.29 ms（Spike 实测），
/// 相对一次 NAS 搜索（秒级）可以忽略。
///
/// ## 这一层只管传输
///
/// 它不知道 `mcp_disabled`、不知道来源、不知道 Tool 语义。收到的码原样返回：
/// `source_unavailable` / `auth_required` 各有各的「Agent 该做什么」，
/// 在这里改码等于把 §4.2 那张表的语义销毁在传输层。
public struct UnixSocketAuthorityLink: AuthorityLink {

    // MARK: 对外错误

    /// 连不上权威端。**唯一**含义是「闪寻没在跑 / 刚退出」，不是「搜不到」。
    public static let appUnavailableCode = "flashfind_app_unavailable"
    public static let appUnavailableMessage = "FlashFind is not running. Open FlashFind and try again."

    public static let timeoutCode = "timeout"
    public static let timeoutMessage = "FlashFind did not answer in time. Try again."

    public static let internalCode = "internal_error"

    // MARK: 配置

    public let path: String
    public let limits: AuthorityLimits

    public init(path: String = AuthoritySocketPath.standard(),
                limits: AuthorityLimits = AuthorityLimits()) {
        self.path = path
        self.limits = limits
    }

    // MARK: AuthorityLink

    /// 把 Agent 的原话交给权威端。
    ///
    /// ★ 只编码 `{tool, args, context}`，**不追加任何授权范围**：6.1 的 `source_ids` 是
    /// 「Helper 判过、App 照办」，现在它只可能来自 Agent 自己，含义是「请求」（§5.2.2）。
    ///
    /// ★ `context` 只是标签：助手进程把它带上，App 端**仅**用于 History 与诊断，
    /// 不进判定。它可被任何同 UID 进程伪造，所以伪造的代价只能是「标签不准」。
    ///
    /// ★ 阻塞式 socket 读写放到 `Task.detached` 里跑：本方法被 `MCPHandler` 在
    /// SDK 的事件处理路径上调用，在那里同步阻塞读会把整个 MCP 服务器卡住——
    /// 一次 App 卡顿就会让客户端的 `initialize` 也超时。
    public func call(tool: String,
                     arguments: ToolArguments,
                     context: HistoryContext? = nil) async -> ToolOutcome {
        let wire = AuthorityWire.request(tool: tool, arguments: arguments, context: context)
        return await Task.detached(priority: .userInitiated) { [path, limits] in
            UnixSocketAuthorityLink.outcome(
                UnixSocketAuthorityLink.roundTrip(wire, path: path, limits: limits))
        }.value
    }

    // MARK: 往返

    /// 一次完整往返。同步实现，供 `execute` 与启动探活共用。
    ///
    /// 返回的 `Failure` 已经是**对外的**错误码（§4.2），不是 errno。
    public static func roundTrip(_ request: AuthorityWire.Request,
                                 path: String,
                                 limits: AuthorityLimits)
        -> Result<AuthorityWire.Response, AuthorityWire.Failure> {

        let deadline = Date().addingTimeInterval(limits.requestTimeout)

        let payload: Data
        do {
            payload = try AuthorityWire.line(request)
        } catch {
            // 报文里全是我们自己造的值，编不出来只可能是代码 bug；不能报成「App 没在跑」。
            return .failure(.init(code: internalCode,
                                  message: "FlashFind could not encode the request."))
        }

        // 请求超过上限的话，权威端一定会拒。与其发出去再被拒，不如本地就说清楚——
        // 报 `invalid_argument` 而不是 `internal_error`，因为这是**参数太大**。
        if payload.count > limits.maxRequestBytes {
            return .failure(.init(code: "invalid_argument", message: "request too large"))
        }

        let fd: Int32
        do {
            fd = try UnixSocket.connect(path)
        } catch let error as UnixSocketError where error.meansNobodyIsListening {
            return .failure(.init(code: appUnavailableCode, message: appUnavailableMessage))
        } catch {
            return .failure(.init(code: internalCode,
                                  message: "FlashFind could not open its local connection."))
        }
        defer { close(fd) }

        do {
            try UnixSocket.writeAll(fd, payload)
        } catch {
            // 连接刚建好就写不进去：权威端在两次系统调用之间退出了。
            return .failure(.init(code: appUnavailableCode, message: appUnavailableMessage))
        }
        // 告诉权威端「这一条写完了」。它靠 EOF 判断，不必等我们关连接。
        _ = shutdown(fd, SHUT_WR)

        // ★ 首帧等到 `deadline` 为止，不再用 `min(readIdleTimeout, remaining)`。
        //
        //   权威端是「整次操作跑完才回一帧」：`locate` 要遍历、`search` 要问设备，
        //   5 秒内一个字节都不发是正常行为。原先那个 `min(5, 10)` 把「还没开始回」
        //   当成了「半死进程」，于是冷启动的第一次调用必定被自己的客户端判超时，
        //   而 App 那边其实还在好好地跑（build 28 及以前，实测 5.01 秒被切断）。
        //
        //   中途停顿仍由 `readIdleTimeout` 管，两层都被 `deadline` 封住。
        do {
            let data = try UnixSocket.readLine(fd,
                                               maxBytes: limits.maxResponseBytes,
                                               deadline: deadline,
                                               idleTimeout: limits.readIdleTimeout)
            let response = try AuthorityWire.decodeResponse(data)

            // 版本与 id 都要对：同一连接上不会串包，但**版本不一致**意味着两端
            // 不是同一次构建（App 升级了、Helper 还是旧的），这时硬解出来的字段
            // 可能语义不同。宁可明确报错，也不要猜。
            guard response.v == AuthorityWire.version else {
                return .failure(.init(code: internalCode,
                                      message: "FlashFind speaks a different local protocol version."))
            }
            guard response.id == request.id else {
                return .failure(.init(code: internalCode,
                                      message: "FlashFind answered a different request."))
            }
            return .success(response)

        } catch let error as UnixSocketError {
            switch error.kind {
            case .tooLarge:
                return .failure(.init(code: internalCode, message: "response too large"))
            case .idleTimeout:
                return .failure(.init(code: timeoutCode, message: timeoutMessage))
            case .system:
                // 读到一半断了：权威端在那一边退出了。
                return .failure(.init(code: appUnavailableCode, message: appUnavailableMessage))
            case .closed:
                // 连上了、一个字都没回就关掉——只可能是对端主动拒绝（不同 uid）。
                return .failure(.init(code: internalCode,
                                      message: "FlashFind closed the connection without answering."))
            case .pathTooLong:
                return .failure(.init(code: internalCode,
                                      message: "FlashFind could not encode the request."))
            }
        } catch {
            return .failure(.init(code: internalCode,
                                  message: "FlashFind could not read the answer."))
        }
    }

    /// 线上响应 → 执行结果。
    public static func outcome(_ result: Result<AuthorityWire.Response, AuthorityWire.Failure>) -> ToolOutcome {
        switch result {
        case .failure(let failure):
            return .failure(code: failure.code, message: failure.message)

        case .success(let response):
            guard response.ok else {
                let failure = response.error
                    ?? .init(code: internalCode,
                             message: "FlashFind reported a failure without a reason.")
                return .failure(code: failure.code, message: failure.message)
            }
            guard let value = response.result,
                  let text = try? AuthorityWire.jsonString(value) else {
                // `ok: true` 却没有正文 = 执行端违约。报成功会让 Agent 拿到空结果，
                // 而空结果的语义是「搜过了，没有」——那是撒谎。
                return .failure(code: internalCode,
                                message: "FlashFind returned an empty result.")
            }
            return .success(json: text)
        }
    }

    // MARK: 探活

    /// 一次完整的 ping 往返。
    ///
    /// ★ 判据是「拿到 pong」，**不是「connect 成功」**（§1.3.3.1）：
    /// `connect` 成功只说明有个东西在 listen，半死进程照样会让它成功。
    /// 启动时的 stale 判定就靠这一条。
    public static func ping(path: String, limits: AuthorityLimits) -> Bool {
        let probe = AuthorityLimits(maxRequestBytes: limits.maxRequestBytes,
                                    maxResponseBytes: 8 * 1024,
                                    readIdleTimeout: limits.probeTimeout,
                                    requestTimeout: limits.probeTimeout,
                                    probeTimeout: limits.probeTimeout)
        guard case .success(let response) = roundTrip(AuthorityWire.pingRequest(), path: path, limits: probe) else {
            return false
        }
        return AuthorityWire.isPong(response)
    }
}
