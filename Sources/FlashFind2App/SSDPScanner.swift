import Foundation
import FlashFindCore

/// SSDP / UPnP 发现（`M-SEARCH` → `239.255.255.250:1900`）。
///
/// ## 为什么要有第三条通道
///
/// mDNS 依赖设备主动广播，Synology 私有协议只认群晖。SSDP 是**通用标准**：
/// 实测群晖 DSM 自带 minissapd，对 `upnp:rootdevice` 应答，
/// description.xml 里明写 `manufacturer: Synology`、`modelDescription: Synology NAS`。
/// 除了群晖，网里的路由器、电视、打印机也会应答——所以 SSDP 是**证据来源**，
/// 不是结论：定性仍然交给 `DeviceClassifier`。
///
/// ## 两条实测注意
///
/// * **`LOCATION` 可能指向一个本机到不了的地址**。DS1621+ 的 LOCATION 是
///   `http://<另一块网卡的地址>:5002/...`——它的第三块网卡，实测超时。
///   这时 XML 拉不到，**但 `SERVER: Synology/DSM/<地址>` 这行头已经够定性**，
///   所以拉失败不丢弃整条证据，只留 SERVER 头。
/// * **`LOCATION` 里的地址是归并线索**：SSDP 从 A 网口发来、LOCATION 指向
///   B 网口，这两个 IP 就是同一台机器的两块网卡。这份地址填进
///   `additionalHosts`，`DeviceMerger` 才能把它们并成一台。
enum SSDPScanner {

    static let multicastAddress = "239.255.255.250"
    static let multicastPort: UInt16 = 1900

    /// 等响应的时长（秒）。SSDP 的 `MX` 是 2 秒，留到 3.5 秒收得齐。
    static let waitSeconds: TimeInterval = 3.5

    /// 拉 description.xml 的单条超时。
    static let descriptionTimeout: TimeInterval = 3

    /// 一轮 SSDP 发现。
    ///
    /// - Returns: 每台设备的证据；同一地址的多条响应只留一条。
    static func discover(wait: TimeInterval = waitSeconds) async -> [DeviceEvidence] {
        let headers = await Task.detached(priority: .utility) {
            Self.search(wait: wait)
        }.value
        guard !headers.isEmpty else { return [] }

        var results: [DeviceEvidence] = []
        for hit in headers {
            let identity = await Self.identity(for: hit)
            results.append(evidence(from: identity, at: hit.address))
        }
        return results
    }

    // MARK: - M-SEARCH

    private struct Hit {
        var address: String
        var server: String?
        var location: String?
    }

    private static func search(wait: TimeInterval) -> [Hit] {
        guard let local = LocalNetworkDiscovery.localIPv4() else { return [] }
        let handle = socket(AF_INET, SOCK_DGRAM, IPPROTO_UDP)
        guard handle >= 0 else { return [] }
        defer { close(handle) }

        var yes: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var bindAddress = sockaddr_in()
        bindAddress.sin_family = sa_family_t(AF_INET)
        bindAddress.sin_port = 0                 // 随机源端口：1900 常被别的 UPnP 进程占着
        bindAddress.sin_addr.s_addr = 0
        let bindOK = withUnsafePointer(to: &bindAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) == 0
            }
        }
        guard bindOK else { return [] }

        // 从本机那块网卡发组播：不指定 MULTICAST_IF 的话，多网卡机器会走错口，
        // 结果一台设备都收不到。
        var interfaceAddress = in_addr()
        inet_pton(AF_INET, local.address, &interfaceAddress)
        setsockopt(handle, IPPROTO_IP, IP_MULTICAST_IF, &interfaceAddress,
                   socklen_t(MemoryLayout<in_addr>.size))

        var query = "M-SEARCH * HTTP/1.1\r\n"
            + "HOST: \(multicastAddress):\(multicastPort)\r\n"
            + "MAN: \"ssdp:discover\"\r\n"
            + "MX: 2\r\n"
            + "ST: upnp:rootdevice\r\n"
            + "\r\n"
        var target = sockaddr_in()
        target.sin_family = sa_family_t(AF_INET)
        target.sin_port = multicastPort.bigEndian
        inet_pton(AF_INET, multicastAddress, &target.sin_addr)
        query.withUTF8 { raw in
            guard let base = raw.baseAddress else { return }
            withUnsafePointer(to: &target) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    _ = sendto(handle, base, raw.count, 0, $0,
                               socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        }

        var hits: [String: Hit] = [:]
        let deadline = Date().addingTimeInterval(wait)
        var buffer = [UInt8](repeating: 0, count: 65535)

        while Date() < deadline {
            let remaining = deadline.timeIntervalSinceNow
            guard remaining > 0 else { break }
            // 用 poll 而不是 select：Swift 导入不进 select 的 fd_set 宏。
            var poller = pollfd()
            poller.fd = handle
            poller.events = Int16(POLLIN)
            guard poll(&poller, 1, Int32(remaining * 1000)) > 0 else { continue }

            var from = sockaddr_in()
            var fromLength = socklen_t(MemoryLayout<sockaddr_in>.size)
            let read = withUnsafeMutablePointer(to: &from) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    recvfrom(handle, &buffer, buffer.count, 0, $0, &fromLength)
                }
            }
            guard read > 0 else { continue }

            let address = String(cString: inet_ntoa(from.sin_addr))
            guard !address.isEmpty else { continue }
            let text = String(decoding: Data(buffer[0..<Int(read)]), as: UTF8.self)
            var hit = hits[address] ?? Hit(address: address)
            for line in text.split(separator: "\r\n").dropFirst() {
                guard let colon = line.firstIndex(of: ":") else { continue }
                let key = String(line[line.startIndex..<colon]).uppercased()
                let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
                switch key {
                case "SERVER": hit.server = value
                case "LOCATION": hit.location = value
                default: break
                }
            }
            hits[address] = hit
        }
        return hits.values.sorted { $0.address < $1.address }
    }

    // MARK: - description.xml

    /// 取一份完整的 SSDP 身份：**有 XML 就用 XML，没有就只剩 SERVER 头**。
    private static func identity(for hit: Hit) async -> SSDPIdentity {
        var identity = SSDPIdentity()
        identity.server = hit.server
        identity.location = hit.location
        guard let location = hit.location, let url = URL(string: location) else { return identity }

        var request = URLRequest(url: url)
        request.timeoutInterval = descriptionTimeout
        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let xml = String(data: data, encoding: .utf8) else {
            // 拉不到也要留着 SERVER 头——见文件头那条「LOCATION 指向到不了的地址」。
            return identity
        }
        let parsed = SSDPDescriptionParser.parse(xml)
        identity.manufacturer = parsed.manufacturer
        identity.modelName = parsed.modelName
        identity.modelDescription = parsed.modelDescription
        identity.friendlyName = parsed.friendlyName
        identity.serialNumber = parsed.serialNumber
        identity.deviceType = parsed.deviceType
        return identity
    }

    private static func evidence(from identity: SSDPIdentity, at address: String) -> DeviceEvidence {
        var item = DeviceEvidence(host: address, sources: [.ssdp])
        item.ssdp = identity
        if let name = identity.friendlyName, !name.isEmpty { item.hostnames = [name] }
        if let model = identity.modelName, !model.isEmpty { item.models = [model] }
        if let serial = identity.serialNumber, !serial.isEmpty { item.serials = [serial] }
        // LOCATION 指向的可能是同一台设备的另一块网卡（跨网段的那个地址）。
        if let host = URL(string: identity.location ?? "")?.host,
           !host.isEmpty, host != address {
            item.additionalHosts = [host]
        }
        return item
    }
}
