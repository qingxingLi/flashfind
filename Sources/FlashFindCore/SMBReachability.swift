import Foundation
import Darwin

/// SMB 服务端的 TCP 可达性预检。
///
/// **为什么需要**：在挂载共享之前，闪寻以前会直接交给系统，
/// 而系统在拿不到凭据/连不上时会把访达的「连接到服务器」框弹出来。
/// 一旦弹出来，用户只能在「等它超时」和「手动取消」之间选；
/// 在 **用公网域名连接** 的场景下（445 一般不做公网映射，本机也
/// 不在 NAS 所在局域网）它**必然失败** —— 弹窗纯属打扰。
///
/// 所以这里先做一次 TCP 握手：
///   - 连得上  → 交给 `NSFileCoordinator` 复用系统钥匙串凭据，
///              失败才提示「需要手动登录」；
///   - 连不上  → 直接把「端口不可达」这个事实讲清楚，**不弹任何系统框**。
///
/// 只做 connect/close，不发送任何协议数据，不接触凭据，不读共享内容。
public enum SMBReachability {
    /// SMB over TCP 的标准端口。
    public static let standardPort: UInt16 = 445

    /// 主机当前是否可建立 SMB 端口连接。
    ///
    /// 解析不到主机名、超时、拒绝连接一律返回 `false` —— 对调用方来说
    /// 三者要做的事相同（不要惊动系统，直接把原因告诉用户）。
    public static func isReachable(host: String,
                                   port: UInt16 = standardPort,
                                   timeout: TimeInterval = 1.5) async -> Bool {
        let name = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return false }
        // 放到后台线程：connect + poll 会阻塞，而调用方通常在 MainActor 上。
        return await Task.detached(priority: .utility) {
            probe(host: name, port: port, timeout: timeout)
        }.value
    }

    /// 同步探测。逐条尝试解析出的地址，任意一条连通即算可达。
    static func probe(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        hints.ai_protocol = IPPROTO_TCP
        var list: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &list) == 0, let head = list else { return false }
        defer { freeaddrinfo(list) }

        var cursor: UnsafeMutablePointer<addrinfo>? = head
        while let info = cursor {
            if connectOnce(info.pointee, timeout: timeout) { return true }
            cursor = info.pointee.ai_next
        }
        return false
    }

    /// 非阻塞 connect + poll：把「等多久」攥在自己手里。
    ///
    /// 不用阻塞式 connect 是因为它没有超时参数，网络被丢包时
    /// 会挂到内核默认的数十秒，用户会觉得闪寻卡死了。
    private static func connectOnce(_ info: addrinfo, timeout: TimeInterval) -> Bool {
        guard info.ai_addr != nil else { return false }
        let fd = socket(info.ai_family, info.ai_socktype, info.ai_protocol)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) >= 0 else { return false }

        if connect(fd, info.ai_addr, info.ai_addrlen) == 0 { return true }   // 本机/回环即时成功
        guard errno == EINPROGRESS else { return false }

        var descriptor = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        let millis = Int32(max(1, timeout * 1000))
        guard poll(&descriptor, 1, millis) > 0 else { return false }

        // poll 可写只说明「有结论了」，成功与否要看 SO_ERROR。
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &error, &length) == 0 else { return false }
        return error == 0
    }
}
