import Foundation

/// Unix Domain Socket 的薄封装（方案 §1.3）。
///
/// 只做「系统调用怎么用」这一件事：建 socket、bind、listen、connect、按行读、整块写、
/// 超时。**不含任何业务判断**——连不上是什么错误码、报文超限该回什么，
/// 都在 `UnixSocketAuthorityLink`（调用端）与 `AuthorityListener`（权威端）里定。
///
/// ## 为什么不用 `NWConnection` / `URLSession`
///
/// Unix Domain Socket 走 `Network.framework` 要 `NWEndpoint.unix`，那套 API 是
/// async 的、而且在「连接被拒」和「路径不存在」上给不出可区分的错误——而这两种
/// 恰恰是我们要映射成 `flashfind_app_unavailable` 与 `timeout` 的关键。
/// 系统调用是一手的，Spike 也是这么跑通的（`04-测试与验收/ipc-spike-20261020/`）。
public struct UnixSocketError: Error, Equatable, CustomStringConvertible, Sendable {

    public enum Kind: Equatable, Sendable {
        /// 路径超过 `sun_path` 的 104 字节。
        case pathTooLong
        /// `socket` / `bind` / `listen` / `connect` / `read` / `write` 失败，带 `errno`。
        case system(operation: String, code: Int32)
        /// 报文超过上限。**必须在读的过程中就抛**，读完了再判断等于已经吃进内存。
        case tooLarge
        /// 单次读空闲超时。
        case idleTimeout
        /// 对端关闭且没有数据。
        case closed
    }

    public let kind: Kind

    public init(_ kind: Kind) { self.kind = kind }

    public var description: String {
        switch kind {
        case .pathTooLong:
            return "socket path is too long"
        case .system(let operation, let code):
            return "\(operation) failed errno=\(code) \(String(cString: strerror(code)))"
        case .tooLarge:
            return "payload exceeds the size limit"
        case .idleTimeout:
            return "read timed out"
        case .closed:
            return "peer closed the connection"
        }
    }

    /// 是否是「没有人监听」这一类失败：调用端据此回 `flashfind_app_unavailable`。
    ///
    /// ★ 只认这三个 errno。别的失败（`EACCES`、`ENAMETOOLONG`…）是配置问题，
    /// 报成「闪寻没在跑」会把排查引到错的方向。
    public var meansNobodyIsListening: Bool {
        guard case .system(_, let code) = kind else { return false }
        return code == ENOENT || code == ECONNREFUSED || code == ENOTSOCK
    }
}

/// Unix Domain Socket 的系统调用。
public enum UnixSocket {

    /// 建一条 `AF_UNIX` / `SOCK_STREAM` 的 fd，并设 `FD_CLOEXEC`。
    ///
    /// `FD_CLOEXEC` 不是洁癖：App 会 `fork`+`exec` 去跑探测命令（网络诊断、`nas` 工具），
    /// 没有这一位，监听 fd 会被子进程继承，`stop()` 之后端口仍然「有人占着」。
    public static func makeSocket() throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw UnixSocketError(.system(operation: "socket", code: errno)) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        suppressSIGPIPE(fd)
        return fd
    }

    /// 关掉这个 socket 上的 `SIGPIPE`：对端提前关掉连接时，`write()` 只返回 `EPIPE`，
    /// 而不是把整个进程杀掉。
    ///
    /// ★ 这不是「顺手加固」（Phase 6.3b-1 实测踩到）：一次往返只要 0.3 ms，而客户端
    /// 随时可能超时、被 Ctrl-C、或自己崩掉。默认行为下，监听端往一条已关闭的连接
    /// 写一次就会收到 `SIGPIPE`——**App 直接消失**，没有 crash log 可看，
    /// 只有一句「Exited with unexpected signal code 13」。
    ///
    /// 写失败仍然会被 `writeAll` 报成 `UnixSocketError`，语义没有变松，只是不再杀进程。
    public static func suppressSIGPIPE(_ fd: Int32) {
        var on: Int32 = 1
        _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
    }

    /// 路径 → `sockaddr_un`。超长直接抛，**不截断**：截断后的路径会 bind 到
    /// 一个和预期不同的文件上，且没有任何报错。
    public static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { throw UnixSocketError(.pathTooLong) }
        withUnsafeMutablePointer(to: &address.sun_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: capacity) { destination in
                for (index, byte) in bytes.enumerated() { destination[index] = CChar(bitPattern: byte) }
                destination[bytes.count] = 0
            }
        }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        return address
    }

    /// 用 `sockaddr_un` 调一个系统调用。
    public static func withAddress<T>(_ path: String,
                                      _ body: (UnsafePointer<sockaddr>, socklen_t) throws -> T) throws -> T {
        var address = try address(path)
        return try withUnsafePointer(to: &address) { pointer in
            try pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                try body($0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
    }

    /// 连到 `path`。失败时抛带 `errno` 的错误。
    public static func connect(_ path: String) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard Darwin.connect(fd, address, length) == 0 else {
                    throw UnixSocketError(.system(operation: "connect", code: errno))
                }
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    /// bind 一个路径。返回 fd，**调用方负责 `listen` 与 `close`**。
    ///
    /// ★ 失败时把 `errno` 原样带出去：`EADDRINUSE` 是「已经有实例在跑」的现成信号，
    /// 清理策略（先探活、确认 stale 才 unlink）在 `AuthorityListener` 里，不在这里。
    public static func bind(_ path: String) throws -> Int32 {
        let fd = try makeSocket()
        do {
            try withAddress(path) { address, length in
                guard Darwin.bind(fd, address, length) == 0 else {
                    throw UnixSocketError(.system(operation: "bind", code: errno))
                }
            }
        } catch {
            close(fd)
            throw error
        }
        return fd
    }

    public static func listen(_ fd: Int32, backlog: Int32 = 16) throws {
        guard Darwin.listen(fd, backlog) == 0 else {
            throw UnixSocketError(.system(operation: "listen", code: errno))
        }
    }

    /// 整块写完。短写会继续写，`EINTR` 重试。
    public static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let written = write(fd, base + offset, raw.count - offset)
                if written < 0 {
                    if errno == EINTR { continue }
                    throw UnixSocketError(.system(operation: "write", code: errno))
                }
                if written == 0 { throw UnixSocketError(.closed) }
                offset += written
            }
        }
    }

    /// 等 fd 可读。返回 `false` 表示超时（或出错——两种情况调用方的处理一样：放弃）。
    public static func waitReadable(_ fd: Int32, timeout: TimeInterval) -> Bool {
        var descriptor = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let milliseconds = Int32(max(0, min(Double(Int32.max), timeout * 1000)))
        while true {
            let ready = poll(&descriptor, 1, milliseconds)
            if ready < 0 {
                if errno == EINTR { continue }
                return false
            }
            return ready > 0
        }
    }

    /// 读到 `\n` 或 EOF 为止，带**边读边算**的大小上限与两层时间上限。
    ///
    /// - Parameters:
    ///   - maxBytes: 收到第 `maxBytes + 1` 个字节时立刻抛 `.tooLarge`，
    ///     **不把超限数据留在 buffer 里**（§1.3.4 的「计数必须边读边算」）。
    ///   - deadline: 整次请求的截止时刻。**首帧一直等到它为止**。
    ///   - idleTimeout: 已经收到过数据之后，两块之间的停顿上限。
    ///
    /// ## 为什么要把「首帧」和「中途停顿」分开（build 29 补）
    ///
    /// 这两个上限原本是同一个数，导致一个真实的故障：权威端把**整次操作跑完**
    /// 才回一帧（`locate` 要遍历、`search` 要问设备），5 秒内一个字节都不发是
    /// **完全正常的**；而调用方只等 `min(readIdleTimeout, 剩余预算)`，于是
    /// 正常耗时 5–8 秒的搜索被自己的客户端提前判成超时。
    ///
    /// ```text
    /// 首帧：等满整个请求预算（10 秒）——「还没开始回」不是「半死」
    /// 中途：每块之间只用 idleTimeout（5 秒）——「回到一半不吭声」才是半死
    /// ```
    ///
    /// ★ 两者都不越过 `deadline`。少写这一层，每收到一小块就等于续命一次，
    ///   总预算形同虚设（分段慢速发送能把一次 10 秒的请求拖成任意长）。
    public static func readLine(_ fd: Int32,
                                maxBytes: Int,
                                deadline: Date,
                                idleTimeout: TimeInterval) throws -> Data {
        var buffer = Data()
        var chunk = [UInt8](repeating: 0, count: 4096)
        while true {
            let remaining = deadline.timeIntervalSinceNow
            let wait = buffer.isEmpty ? remaining : min(idleTimeout, remaining)
            guard wait > 0, waitReadable(fd, timeout: wait) else {
                throw UnixSocketError(.idleTimeout)
            }
            let count = read(fd, &chunk, chunk.count)
            if count == 0 { break }                       // EOF：对端写完了
            if count < 0 {
                if errno == EINTR { continue }
                throw UnixSocketError(.system(operation: "read", code: errno))
            }
            if buffer.count + count > maxBytes { throw UnixSocketError(.tooLarge) }
            buffer.append(contentsOf: chunk[0..<count])
            if buffer.contains(0x0A) { break }             // 一行一个报文
        }
        if buffer.isEmpty { throw UnixSocketError(.closed) }
        return buffer
    }

    /// 对端的 uid。`getpeereid` 是权限位之外的第二道（§1.3.3）：
    /// `0600` 只挡住「别的用户」，挡不住「同用户下另一个被诱导的进程」——
    /// 而这一道至少让「不是同一个登录会话」的连接连不上来。
    public static func peerUID(_ fd: Int32) -> uid_t? {
        var uid: uid_t = 0
        var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 else { return nil }
        return uid
    }
}

/// 对端 uid 的判定。抽成纯函数是为了能测「不同 uid 会被拒」——
/// 真实场景要另一个用户的进程，测试里造不出来。
public enum AuthorityPeer {

    public static func accepts(peerUID: uid_t, currentUID: uid_t = getuid()) -> Bool {
        peerUID == currentUID
    }
}
