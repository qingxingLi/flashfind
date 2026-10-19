import Foundation
import FlashFindCore

/// Synology 官方发现协议的客户端（UDP 9999）。
///
/// ## 为什么必须自己实现
///
/// 群晖有两台形态完全不同的机器在这一个网里：
///
/// * DS124 —— 老老实实广播 mDNS，Bonjour 就能找到；
/// * DS1621+ —— **一条 mDNS 都不广播**，DSM 还开在
///   非标准的 5002/5003 上。Bonjour 永远找不到它，TCP 端口扫描也只会命中 445。
///
/// 官方的 Synology Assistant 找得到它，靠的就是这个私有协议：
/// 同子网 UDP 广播，NAS 自报型号 / 序列号 / MAC / DSM 端口。
/// **这是唯一能让这类不广播的机型被完整识别的通道。**
///
/// ## 协议要点
///
/// * 端口 **UDP 9999**；9998 / 9997 不应答 discovery；
/// * 客户端**必须 bind 9999**（`SO_REUSEADDR | SO_REUSEPORT | SO_BROADCAST`），
///   NAS 会同时回 `255.255.255.255:9999` 广播与 `<查询方>:9999` 单播；
/// * query 只带两个字段就能应答（`0xA4` 协议版本 + `0x01`）；带 `0x7C/0xC4/0xC5`
///   反而会逼出加密回复，我们不带；
/// * 自己发出去的 query 会环回回来，`packet_type == 1` 的那份必须丢掉
///   （`SynologyDiscoveryPacket.parseResponse` 已经处理）。
///
/// ## 只做 discovery
///
/// 只发发现查询、只读设备自述。**不发任何配置/管理命令。**
enum SynologyDiscoveryClient {

    /// 等响应的时长（秒）。实测两台 NAS 都在 1~3s 内应答，且广播+单播**成对**到达。
    static let waitSeconds: TimeInterval = 2.5

    /// 发一轮发现广播，收集设备自述。
    ///
    /// 同一台设备会回广播和单播两份相同内容，按 IP 归并即可——
    /// 去重交给 `DeviceMerger`，这里照实把每一份都交出去。
    ///
    /// - Returns: 每台设备的证据；不广播 / 不在线 / 不是群晖 → 空数组。
    static func discover(wait: TimeInterval = waitSeconds) async -> [DeviceEvidence] {
        await Task.detached(priority: .utility) {
            Self.collect(wait: wait)
        }.value
    }

    // MARK: - 内部（后台线程，含阻塞 socket 调用）

    private static func collect(wait: TimeInterval) -> [DeviceEvidence] {
        let port = UInt16(SynologyDiscoveryPacket.discoveryPort)
        let socketHandle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard socketHandle >= 0 else { return [] }
        defer { close(socketHandle) }

        var yes: Int32 = 1
        setsockopt(socketHandle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketHandle, SOL_SOCKET, SO_REUSEPORT, &yes, socklen_t(MemoryLayout<Int32>.size))
        setsockopt(socketHandle, SOL_SOCKET, SO_BROADCAST, &yes, socklen_t(MemoryLayout<Int32>.size))

        var local = sockaddr_in()
        local.sin_family = sa_family_t(AF_INET)
        local.sin_port = port.bigEndian      // ★ 必须 bind 9999，否则收不到单播回包
        local.sin_addr.s_addr = 0
        let bindOK = withUnsafePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socketHandle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { return [] }

        let query = SynologyDiscoveryPacket.buildQuery()
        for destination in broadcastDestinations() {
            query.withUnsafeBytes { raw in
                guard let base = raw.baseAddress else { return }
                var target = sockaddr_in()
                target.sin_family = sa_family_t(AF_INET)
                target.sin_port = port.bigEndian
                target.sin_addr.s_addr = inet_addr(destination)
                withUnsafePointer(to: &target) { pointer in
                    pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                        _ = sendto(socketHandle, base, query.count, 0,
                                   $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                    }
                }
            }
        }

        // 收到就解析；packet_type == 1 的环回由 parseResponse 丢掉。
        var results: [DeviceEvidence] = []
        var seen: Set<String> = []
        let deadline = Date().addingTimeInterval(wait)
        var buffer = [UInt8](repeating: 0, count: 65535)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // 用 poll 而不是 select：Swift 导入不进 select 的 fd_set 宏。
            var poller = pollfd()
            poller.fd = socketHandle
            poller.events = Int16(POLLIN)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0 else { continue }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let read = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(socketHandle, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard read > 0 else { continue }

            let address = String(cString: inet_ntoa(from.sin_addr))
            guard !address.isEmpty else { continue }
            let data = Data(buffer[0..<Int(read)])
            guard let response = SynologyDiscoveryPacket.parseResponse(data, responderAddress: address),
                  !seen.contains(address) else { continue }
            seen.insert(address)
            results.append(evidence(from: response, at: address))
        }
        return results
    }

    /// 广播目标：全子网广播优先，本机所在子网的定向广播兜底。
    ///
    /// 实测两台 NAS 对 `255.255.255.255` 都应答；有些网络会拦全广播，
    /// 所以再补一个 `x.y.z.255`——两份都发，重复响应按 IP 去重。
    private static func broadcastDestinations() -> [String] {
        var destinations = ["255.255.255.255"]
        if let local = LocalNetworkDiscovery.localIPv4(),
           let value = NetworkDiscovery.ipv4Value(local.address),
           let mask = NetworkDiscovery.ipv4Value(local.netmask), mask != 0 {
            let directed = (value & mask) | ~mask
            let text = NetworkDiscovery.stringValue(directed)
            if text != "255.255.255.255" { destinations.append(text) }
        }
        return destinations
    }

    /// 设备自述 → 一份发现证据。
    ///
    /// 型号/序列号/MAC/DSM 端口全部填进去：`DeviceMerger` 靠序列号把多网卡
    /// 归成一台，`DeviceMerger.bestPort` 靠 DSM 端口挑出能走登录流程的那个口。
    private static func evidence(from response: SynologyResponse, at address: String) -> DeviceEvidence {
        var item = DeviceEvidence(host: address, sources: [.synologyDiscovery])
        item.mac = response.mac
        if let name = response.serverName, !name.isEmpty { item.hostnames = [name] }
        if let model = response.model, !model.isEmpty { item.models = [model] }
        if let serial = response.serial, !serial.isEmpty { item.serials = [serial] }
        var ports: Set<Int> = []
        if let http = response.dsmHTTPPort { ports.insert(http) }
        if let https = response.dsmHTTPSPort { ports.insert(https) }
        item.openPorts = ports
        item.synology = response
        return item
    }
}
