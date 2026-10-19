import Foundation
import Network
import FlashFindCore

/// 局域网设备发现。
///
/// ## 五条腿，各有各的用处
///
/// 一台设备能不能被找到、能不能被**认出来**，是两件事。以前只有 Bonjour 和
/// TCP 端口扫描两条腿，结果一台 DS1621+（一条 mDNS 都不广播、
/// DSM 开在非标准的 5002/5003）永远发现不了。现在按「信息量 × 成本」排：
///
/// 1. **ARP 表**（0.01 秒）——只回答「谁在线」和 MAC。不产生身份结论，
///    但把后面那一步的搜索空间从 253 台缩到实测的 128 台；
/// 2. **Bonjour 广播**（秒级）——设备主动报名字与端口，最可信，但**依赖设备开了服务**；
/// 3. **Synology 官方发现协议**（UDP 9999，~2.5 秒）——设备自报型号/序列号/MAC/DSM
///    端口。这是那台不广播的 DS1621+ **唯一的完整识别通道**；
/// 4. **SSDP / UPnP**（~3.5 秒）——通用标准，群晖 DSM 自带 minissapd 会应答，
///    description.xml 里明写 `manufacturer: Synology`。不依赖 mDNS，也不只认群晖；
/// 5. **TCP 端口探测**（fallback）——只对 ARP 说在线的主机试 `5001/5000/5005/445`。
///    **端口命中不产生默认显示资格**：一台开着 445 的机器可能是任何东西。
///    它只负责给已经在列表里的设备补一个能用的端口。
///
/// ## 谁也不许直接控制界面
///
/// 五条腿都只产出 `DeviceEvidence`（事实），交给 Core 的
/// `DeviceMerger`（按 IP / 序列号 / MAC 归并）→ `DeviceClassifier`（定性）→
/// `NetworkDiscovery.makeDevices`（装配）。**任何一个协议都不直接决定界面显示什么。**
///
/// ## 主线程
///
/// 整个类是 `@MainActor`：它只发布状态给 SwiftUI，真正的连接与探测都在
/// 后台队列上跑（见 `probe` 与各 client 的 `Task.detached`）。
/// `NetServiceBrowser` 的回调本来就在启动它的 RunLoop（主线程）上。
@MainActor
final class LocalNetworkDiscovery: NSObject, ObservableObject {

    /// 合并后的候选设备列表。
    @Published private(set) var devices: [DiscoveredDevice] = []
    @Published private(set) var isScanning = false
    /// 界面用的一句话状态。发现不到设备时也要说清「是没扫到，还是扫描失败」。
    @Published private(set) var statusMessage = ""

    private var browsers: [NetServiceBrowser] = []
    private var pendingServices: [NetService] = []
    private var existingSources: [NASSourceConfig] = []
    /// 本轮扫描是否已经跑过。重复打开向导时不该反复扫网段——
    /// 那会在每次开窗时对局域网红扫一遍。
    private var didScanSubnet = false

    // MARK: - 各来源的证据（每个协议各产各的，谁也不改别人的）

    /// Bonjour：按主机汇总。
    private var bonjourEvidence: [String: DeviceEvidence] = [:]
    /// ARP：在线主机与 MAC。
    private var arpEvidence: [DeviceEvidence] = []
    /// Synology 官方发现协议。
    private var synologyEvidence: [DeviceEvidence] = []
    /// SSDP / UPnP。
    private var ssdpEvidence: [DeviceEvidence] = []
    /// TCP 端口探测：按主机记命中的端口（一台机可能开好几个）。
    private var probeEvidence: [String: DeviceEvidence] = [:]
    /// ARP 说在线的主机（TCP fallback 的搜索空间）。
    private var onlineHosts: [String] = []

    /// 开始发现。`existing` 用来把已在来源列表里的设备标记成「已添加」。
    func start(existing: [NASSourceConfig]) {
        existingSources = existing
        guard !isScanning else { return }
        isScanning = true
        statusMessage = "正在查找附近的设备…"
        bonjourEvidence.removeAll()
        arpEvidence.removeAll()
        synologyEvidence.removeAll()
        ssdpEvidence.removeAll()
        probeEvidence.removeAll()
        onlineHosts.removeAll()

        startBrowsing()

        guard !didScanSubnet else { return }
        didScanSubnet = true
        Task { await runPipeline() }
    }

    /// 关窗时调用：停掉仍在跑的浏览，避免窗口关了还在收广播。
    func stop() {
        browsers.forEach { $0.stop() }
        browsers.removeAll()
        pendingServices.forEach { $0.stop() }
        pendingServices.removeAll()
        isScanning = false
    }

    /// 用户手动重扫。
    func rescan(existing: [NASSourceConfig]) {
        existingSources = existing
        didScanSubnet = false
        stop()
        start(existing: existing)
    }

    // MARK: - 流水线

    /// 按「便宜的先做」排：ARP → Synology → SSDP → TCP fallback。
    ///
    /// ARP 先跑，是为了让后面那步 TCP 探测只针对**真正在线的主机**——
    /// 实测整网扫要 33.5 秒，只对在线主机扫只要 12.2 秒。
    private func runPipeline() async {
        // 1) ARP：0.01 秒，先拿到「谁在线」。
        let entries = await ARPTableReader.read()
        arpEvidence = ARPTableReader.evidence(from: entries)
        onlineHosts = entries.map(\.address)
        publish()

        // 2) Synology 官方协议 + 3) SSDP：并行跑，都是几秒钟的事。
        //    这两路是「认出设备是什么」的主力，先于耗时的 TCP 探测发布。
        async let synology = SynologyDiscoveryClient.discover()
        async let ssdp = SSDPScanner.discover()
        synologyEvidence = await synology
        publish()
        ssdpEvidence = await ssdp
        publish()

        // 4) TCP 探测：降级为 fallback，只针对 ARP 说在线的主机。
        await probeOnlineHosts()

        finishScan(note: nil)
    }

    private func finishScan(note: String?) {
        isScanning = false
        publish()
        if devices.isEmpty {
            statusMessage = note ?? "附近没有找到设备。可以手动填写地址。"
        } else {
            statusMessage = ""
        }
    }

    /// 把所有证据汇成界面要的列表。
    ///
    /// 归并、定性、装配三步全在 Core（可测），这里只是把它们串起来。
    private func publish() {
        let all = Array(bonjourEvidence.values)
            + arpEvidence
            + synologyEvidence
            + ssdpEvidence
            + Array(probeEvidence.values)
        let merged = DeviceMerger.merge(all)
        devices = NetworkDiscovery.makeDevices(from: merged, existing: existingSources)
    }

    // MARK: - Bonjour

    private func startBrowsing() {
        for type in NetworkDiscovery.browsedServiceTypes {
            let browser = NetServiceBrowser()
            browser.delegate = self
            browsers.append(browser)
            // 第三个参数带结尾的点是 Foundation 的要求写法。
            browser.searchForServices(ofType: type + ".", inDomain: "local.")
        }
    }

    // MARK: - TCP 端口探测（fallback）

    /// 对**已知在线**的主机试 NAS 端口。
    ///
    /// 拿不到 ARP 表时（权限或接口问题）才退回整网扫描——那时仍然要扫，
    /// 否则「发现」这件事就整个没了。
    private func probeOnlineHosts() async {
        var hosts = onlineHosts
        if hosts.isEmpty {
            guard let local = Self.localIPv4() else { return }
            hosts = NetworkDiscovery.subnetHosts(localAddress: local.address, netmask: local.netmask)
        }
        guard !hosts.isEmpty else { return }

        let ports = NetworkDiscovery.probePorts
        let concurrency = NetworkDiscovery.probeConcurrency

        await withTaskGroup(of: (String, Int)?.self) { group in
            var index = 0
            func addNext() {
                guard index < hosts.count else { return }
                let host = hosts[index]
                index += 1
                group.addTask {
                    // 一台设备可能开着多个端口：命中一个就够，按端口顺序试。
                    for port in ports {
                        if await Self.probe(host: host, port: port) { return (host, port) }
                    }
                    return nil
                }
            }
            // 先灌满并发窗口，之后**每收一个再补一个**——保持恒定并发，
            // 不是「一次发几百个然后等」。
            for _ in 0..<min(concurrency, hosts.count) { addNext() }
            for await hit in group {
                if let hit {
                    var item = probeEvidence[hit.0] ?? DeviceEvidence(host: hit.0, sources: [.tcpProbe])
                    item.openPorts.insert(hit.1)
                    probeEvidence[hit.0] = item
                    // ★ 边扫边发：整轮要十几秒，等扫完才发布的话，第 5 秒就探到的
                    // 设备要等到最后才出现；而 Bonjour 那几台是增量回调的，
                    // 界面看着像「已经扫完了」，用户就以为剩下的设备没被识别出来
                    // （实测教训）。
                    publish()
                }
                addNext()
            }
        }
    }

    /// 单个 TCP 连接探测。成功即 `.ready`。
    ///
    /// 用 `NWConnection` 而不是裸 socket：它在不可达时会明确落到 `.waiting` /
    /// `.failed`，不需要自己处理 `select` 与 `EINPROGRESS` 的各种边界情形。
    private nonisolated static func probe(host: String, port: Int) async -> Bool {
        guard let nwPort = NWEndpoint.Port(rawValue: UInt16(port)) else { return false }
        return await withCheckedContinuation { (continuation: CheckedContinuation<Bool, Never>) in
            let connection = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
            let gate = ProbeGate(continuation)
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: gate.settle(true)
                case .failed, .cancelled: gate.settle(false)
                case .waiting: gate.settle(false)
                default: break
                }
            }
            connection.start(queue: .global(qos: .utility))
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + NetworkDiscovery.probeTimeout) {
                gate.settle(false)
                connection.cancel()
            }
        }
    }

    /// 本机第一个活跃的私有 IPv4 地址与掩码。
    ///
    /// 会跳过回环地址，也**只认私有段**——如果这台机器只有公网地址
    /// （例如挂着 VPN 出口），那就没有可扫的网段，返回 `nil`。
    nonisolated static func localIPv4() -> (address: String, netmask: String)? {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return nil }
        defer { freeifaddrs(head) }

        for pointer in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(pointer.pointee.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            guard let address = pointer.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET) else { continue }

            let host = Self.numericHost(address)
            guard NetworkDiscovery.isPrivateIPv4(host) else { continue }
            // ifa_netmask 是隐式解包的可选指针，且**可能真的是 nil**
            // （隧道类接口就没有掩码）。拿不到掩码就返回空串，
            // 由 `subnetHosts` 判定为「不可扫」——不猜一个默认掩码。
            var mask = ""
            if let netmask = pointer.pointee.ifa_netmask {
                mask = Self.numericHost(netmask)
            }
            return (host, mask)
        }
        return nil
    }

    private nonisolated static func numericHost(_ address: UnsafePointer<sockaddr>) -> String {
        var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
        let status = getnameinfo(address, socklen_t(address.pointee.sa_len),
                                 &buffer, socklen_t(buffer.count),
                                 nil, 0, NI_NUMERICHOST)
        guard status == 0 else { return "" }
        return String(cString: buffer)
    }
}

// MARK: - Bonjour 回调

extension LocalNetworkDiscovery: NetServiceBrowserDelegate, NetServiceDelegate {

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didFind service: NetService,
                                       moreComing: Bool) {
        // 服务对象必须被持有，否则 resolve 结果没人接。
        Task { @MainActor in
            self.pendingServices.append(service)
            service.delegate = self
            service.resolve(withTimeout: 4)
        }
    }

    nonisolated func netServiceBrowser(_ browser: NetServiceBrowser, didNotSearch errorDict: [String: NSNumber]) {
        Task { @MainActor in
            // 浏览器没起来（极少见，通常是网络栈问题）时说清楚，
            // 不要让界面停在「正在查找」上不动。
            if self.devices.isEmpty {
                self.statusMessage = "局域网查找没能启动。仍可手动填写地址。"
            }
        }
    }

    nonisolated func netServiceDidResolveAddress(_ sender: NetService) {
        // 先按主机汇总「型号」与「命中了哪些服务」——哪怕这条服务本身不成候选
        // （`_device-info` 端口是 0、`_airplay` 跟文件无关），它也在告诉我们
        // 这台设备是什么、不是什么。
        //
        // **两个键都写**：同一个服务这次解析出来的是 IP、下次可能是主机名，
        // 而候选设备用的是 IP。只写一个键会让型号对不上设备。
        let normalizedType = DeviceClassifier.normalize(sender.type)
        let model = Self.txtValue(sender.txtRecordData(), key: "model")
        var keys: [String] = []
        let resolvedIP = Self.firstIPv4(in: sender.addresses)
        if let ip = resolvedIP, !ip.isEmpty { keys.append(ip) }
        let hostName = Self.strippedHostName(sender.hostName ?? "")
        if !hostName.isEmpty, !keys.contains(hostName) { keys.append(hostName) }

        if !keys.isEmpty {
            Task { @MainActor in
                for host in keys {
                    var item = self.bonjourEvidence[host] ?? DeviceEvidence(host: host, sources: [.bonjour])
                    item.serviceTypes.insert(normalizedType)
                    if let model, !model.isEmpty { item.models.insert(model) }
                    self.bonjourEvidence[host] = item
                }
                self.publish()
            }
        }

        // 只用于判类型的服务到此为止，不进候选列表。
        guard !NetworkDiscovery.browsedTypeOnlyServiceTypes.contains(normalizedType) else { return }

        Task { @MainActor in
            guard let port = Int(exactly: sender.port), port > 0 else { return }
            guard let host = resolvedIP ?? (hostName.isEmpty ? nil : hostName) else { return }
            var item = self.bonjourEvidence[host] ?? DeviceEvidence(host: host, sources: [.bonjour])
            if !sender.name.isEmpty { item.hostnames.insert(sender.name) }
            if !hostName.isEmpty { item.hostnames.insert(hostName) }
            // 顺着群晖的 `_smb._tcp` 会把端口报成 445：那不是 DSM 的端口。
            // 界面要预填的端口得是**能接着走登录流程**的那个，所以这里按品牌纠一次。
            item.openPorts.insert(Self.preferredPort(reported: port, serviceType: sender.type))
            self.bonjourEvidence[host] = item
            self.publish()
        }
    }

    /// 从 Bonjour 的 TXT 记录里取一个键的值。
    ///
    /// TXT 记录是「长度前缀 + key=value」的裸字节，空值给的是 `Data()` 而不是 nil，
    /// 所以判空要同时看长度和内容。
    nonisolated static func txtValue(_ record: Data?, key: String) -> String? {
        guard let record, !record.isEmpty else { return nil }
        let dictionary = NetService.dictionary(fromTXTRecord: record)
        guard let value = dictionary[key], !value.isEmpty else { return nil }
        return String(decoding: value, as: UTF8.self)
    }

    nonisolated func netService(_ sender: NetService, didNotResolve errorDict: [String: NSNumber]) {
        // 单个服务解析失败不影响其它设备，静默跳过即可。
    }

    /// 广播端口 → 该设备**默认该用的管理端口**。
    ///
    /// 只处理能确定的映射：群晖广播 `_synology-dsm._tcp` 时端口就是 DSM 端口，
    /// 原样用。其它一律原样保留——**不能再把 `_smb._tcp` 强改成 5001**：
    /// 实测 Mac 也广播 `_smb._tcp`，强改会让 MacBook Air 显示成 `:5001`，
    /// 既错又误导。
    nonisolated static func preferredPort(reported: Int, serviceType: String) -> Int {
        if NetworkDiscovery.vendorHint(forServiceType: serviceType) == .synology {
            return reported
        }
        return reported
    }

    nonisolated static func firstIPv4(in addresses: [Data]?) -> String? {
        guard let addresses else { return nil }
        for data in addresses {
            let host = data.withUnsafeBytes { raw -> String? in
                guard let base = raw.baseAddress else { return nil }
                let family = base.assumingMemoryBound(to: sockaddr.self).pointee.sa_family
                guard family == UInt8(AF_INET) else { return nil }
                return numericHost(base.assumingMemoryBound(to: sockaddr.self))
            }
            if let host, !host.isEmpty { return host }
        }
        return nil
    }

    /// `nas.local.` → `nas.local`；解析不出来时至少去掉结尾的点。
    nonisolated static func strippedHostName(_ name: String) -> String {
        name.hasSuffix(".") ? String(name.dropLast()) : name
    }
}

/// 只允许恢复一次的续体闸门。
///
/// `CheckedContinuation` 被恢复两次会直接让进程崩掉，而在这个探测里
/// 「连接状态变化」与「超时定时器」确实可能几乎同时到达（`probeTimeout`
/// 到了、连接也刚好 ready）。这里用一个加锁的一次性开关把两者收敛成一次。
private final class ProbeGate: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Bool, Never>?

    init(_ continuation: CheckedContinuation<Bool, Never>) {
        self.continuation = continuation
    }

    func settle(_ value: Bool) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(returning: value)
    }
}
