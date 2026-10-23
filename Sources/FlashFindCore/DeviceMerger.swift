import Foundation

/// 一条发现证据来自哪个协议。
///
/// 顺序即「可信度」：越靠前越是**设备自己说清楚了自己是谁**，
/// 越靠后只能证明「网上有台机器」。`DeviceClassifier` 的优先级与此一致。
public enum DiscoverySource: String, Sendable, CaseIterable {
    /// Synology 官方发现协议（UDP 9999）。型号/序列号/MAC/DSM 端口全是设备自报。
    case synologyDiscovery = "synology-discovery"
    /// SSDP/UPnP。description.xml 里有厂商与型号。
    case ssdp
    /// Bonjour/mDNS 浏览。
    case bonjour
    /// ARP/neighbour 表。只知道「在线」和 MAC。
    case arp
    /// TCP 端口探测（fallback）。只知道「有端口开着」。
    case tcpProbe = "tcp-probe"
}

/// SSDP/UPnP 能拿到的身份信息。
///
/// 出处：`M-SEARCH` 响应的 `SERVER`/`LOCATION` 头，加上 LOCATION 指向的
/// description.xml 里的设备字段。实测群晖的 description.xml
/// 明写 `manufacturer: Synology`、`modelDescription: Synology NAS`——
/// 这是**不依赖 mDNS** 的第三条识别通道（DSM 自带 minissapd）。
public struct SSDPIdentity: Equatable, Sendable {
    /// `SERVER` 响应头。
    public var server: String?
    /// `LOCATION` 响应头（description.xml 的地址）。
    public var location: String?
    public var manufacturer: String?
    public var modelName: String?
    public var modelDescription: String?
    public var friendlyName: String?
    /// description.xml 的 `serialNumber`。
    ///
    /// 实测 DSM 把这个字段填成**去冒号的 MAC**——所以它能和 ARP/MAC 证据对上，
    /// 多网口设备因此能被归并成一台。
    public var serialNumber: String?
    /// description.xml 的 `deviceType`，如 `urn:schemas-upnp-org:device:InternetGatewayDevice:1`。
    public var deviceType: String?

    public init(server: String? = nil, location: String? = nil, manufacturer: String? = nil,
                modelName: String? = nil, modelDescription: String? = nil,
                friendlyName: String? = nil, serialNumber: String? = nil,
                deviceType: String? = nil) {
        self.server = server
        self.location = location
        self.manufacturer = manufacturer
        self.modelName = modelName
        self.modelDescription = modelDescription
        self.friendlyName = friendlyName
        self.serialNumber = serialNumber
        self.deviceType = deviceType
    }

    var completeness: Int {
        var score = 0
        for value in [manufacturer, modelName, modelDescription, friendlyName, serialNumber, deviceType] {
            if value != nil { score += 1 }
        }
        return score
    }
}

/// 一台设备的**一份**发现证据。
///
/// 每个发现协议各产各的：Synology 协议回一份、SSDP 回一份、Bonjour 一个实例一份、
/// ARP 一行一份、TCP 探测一个 (ip,port) 一份。它们描述的很可能是**同一台设备**——
/// 把这些碎片拼成一台，就是 `DeviceMerger` 的事。
///
/// 设计约束：**任何一个协议都不直接控制 UI**。协议只负责填证据，
/// 判不判、怎么显示，全是 Core 的纯函数说了算。
public struct DeviceEvidence: Equatable, Sendable {
    /// 主键：证据所属的 IP。
    public var host: String
    /// MAC（ARP 或 Synology 响应给）。
    public var mac: String?
    /// 主机名/实例名（Bonjour 实例名、`.local` 名、Synology server_name、SSDP friendlyName）。
    public var hostnames: Set<String>
    /// 型号（`_device-info` TXT 的 `model=`、Synology model、SSDP modelName）。
    public var models: Set<String>
    /// 序列号（Synology serial、SSDP serialNumber）。
    public var serials: Set<String>
    /// 命中的 Bonjour 服务类型，形如 `_smb._tcp`。
    public var serviceTypes: Set<String>
    /// 开着的端口（Bonjour 服务端口、TCP 探测命中、Synology 自报 DSM 端口）。
    public var openPorts: Set<Int>
    /// 这份证据来自哪些协议。
    public var sources: Set<DiscoverySource>
    /// Synology 发现协议的自述。
    public var synology: SynologyResponse?
    /// SSDP 身份。
    public var ssdp: SSDPIdentity?
    /// 同一设备的**其它网口** IP（如 SSDP LOCATION 里出现的地址）。
    ///
    /// 实测 DS1621+ 有三块网卡、跨三个网段，不归并的话用户会看到三台「NAS」。
    public var additionalHosts: Set<String>

    public init(host: String,
                mac: String? = nil,
                hostnames: Set<String> = [],
                models: Set<String> = [],
                serials: Set<String> = [],
                serviceTypes: Set<String> = [],
                openPorts: Set<Int> = [],
                sources: Set<DiscoverySource> = [],
                synology: SynologyResponse? = nil,
                ssdp: SSDPIdentity? = nil,
                additionalHosts: Set<String> = []) {
        self.host = host
        self.mac = mac
        self.hostnames = hostnames
        self.models = models
        self.serials = serials
        self.serviceTypes = serviceTypes
        self.openPorts = openPorts
        self.sources = sources
        self.synology = synology
        self.ssdp = ssdp
        self.additionalHosts = additionalHosts
    }

    /// 把另一份同主机（或已判定为同设备）的证据并进来。
    ///
    /// 集合取并集；单值字段（synology/ssdp）取**信息更完整**的那份——
    /// 用完整度而不是输入顺序决定，合并结果才与证据到达顺序无关。
    mutating func merge(_ other: DeviceEvidence) {
        hostnames.formUnion(other.hostnames)
        models.formUnion(other.models)
        serials.formUnion(other.serials)
        serviceTypes.formUnion(other.serviceTypes)
        openPorts.formUnion(other.openPorts)
        sources.formUnion(other.sources)
        additionalHosts.formUnion(other.additionalHosts)
        if mac == nil { mac = other.mac }
        synology = preferred(synology, other.synology) { $0.completeness >= $1.completeness }
        ssdp = preferred(ssdp, other.ssdp) { $0.completeness >= $1.completeness }
    }

    private func preferred<T>(_ lhs: T?, _ rhs: T?, by keepLhs: (T, T) -> Bool) -> T? {
        switch (lhs, rhs) {
        case (nil, let value?): return value
        case (let value?, nil): return value
        case (let lhs?, let rhs?): return keepLhs(lhs, rhs) ? lhs : rhs
        case (nil, nil): return nil
        }
    }
}

/// 合并后的**一台**设备。
public struct MergedDevice: Equatable, Sendable {
    /// 主 IP（同设备多个 IP 里字典序/数值最小的那个，保证输出稳定）。
    public var host: String
    /// 同一设备的其它网口 IP。
    public var additionalHosts: [String]
    /// 并在一起的证据。
    public var evidence: DeviceEvidence
    /// 显示名：Synology server_name > SSDP friendlyName > 主机名 > IP。
    public var displayName: String
    /// 型号：Synology model > SSDP modelName > 其它来源的型号。
    public var model: String?
    public var mac: String?
    /// 最值得预填的端口：DSM HTTPS > DSM HTTP > 其它（见 `NetworkDiscovery.portRank`）。
    /// 一个端口证据都没有时为 0。
    public var bestPort: Int
}

/// 多来源发现证据的归并器。
///
/// ## 为什么需要它
///
/// 同一个网段里，一台群晖会同时被 Synology 协议、SSDP、Bonjour、ARP 看到，
/// 还可能因为多网卡出现好几个 IP。**每个协议一条记录**的话，用户看到的是
/// 「三四台 NAS」——正是 build 5 修过的那种错觉，只是换了个来源复发。
///
/// ## 归并键
///
/// 1. **IP 是主键**：同一 IP 的多份证据先并成一份；
/// 2. **序列号 / MAC 是次键**：不同 IP 但序列号或 MAC 相同 → 同一台设备
///    （DSM 的 SSDP serialNumber 恰好是去冒号 MAC，两边因此能对上）；
/// 3. **additionalHosts 也是键**：SSDP LOCATION 指向的地址若另有证据，归并到一处。
///
/// 归一化：序列号/MAC 去掉所有非字母数字字符后小写比对——`02:00:5E:00:00:88`
/// 与 `02005e000088` 必须视为同一个值。
public enum DeviceMerger {

    public static func merge(_ evidence: [DeviceEvidence]) -> [MergedDevice] {
        // 1) 同 IP 的多份证据先并成一份。
        var byHost: [String: DeviceEvidence] = [:]
        for item in evidence where !item.host.isEmpty {
            if var existing = byHost[item.host] {
                existing.merge(item)
                byHost[item.host] = existing
            } else {
                byHost[item.host] = item
            }
        }
        guard !byHost.isEmpty else { return [] }

        // 2) 跨 IP 归并：序列号 / MAC / 额外 IP 任一相同即同一设备。
        //    用并查集而不是「见到就并」：A-B 共享键1、B-C 共享键2 时，
        //    三者也必须并到一处，且结果与遍历顺序无关。
        // ★ 全程按 **IP 数值**排，不能按字典序：字典序会把 192.168.1.152 排到
        //   192.168.1.88 前面，主 IP 就选错了（用户记的是 .88 那台）。
        let hosts = byHost.keys.sorted(by: Self.ipLess)
        var parent = Dictionary(uniqueKeysWithValues: hosts.map { ($0, $0) })
        func find(_ host: String) -> String {
            var current = host
            while parent[current] != current {
                current = parent[current]!
            }
            // 路径压缩
            var walker = host
            while parent[walker] != walker {
                let next = parent[walker]!
                parent[walker] = current
                walker = next
            }
            return current
        }
        func union(_ a: String, _ b: String) {
            let rootA = find(a), rootB = find(b)
            guard rootA != rootB else { return }
            // IP 数值小的当根，输出才稳定。
            if Self.ipLess(rootA, rootB) { parent[rootB] = rootA } else { parent[rootA] = rootB }
        }

        var keyToHost: [String: String] = [:]
        for host in hosts {
            guard let item = byHost[host] else { continue }
            var keys = Set(item.serials.compactMap { normalizeKey($0) })
            if let mac = item.mac, let normalized = normalizeKey(mac) { keys.insert(normalized) }
            // ★ Synology 自述里的序列号/MAC 也是身份键。
            //   实测 DS1621+：.88 只有 Synology 自述（序列号 FAKE000000001、MAC），
            //   .152 只有 SSDP（serialNumber 是同一个值）——两边不同协议、不同 IP，
            //   靠这两个键才能归成一台。少了它，三块网卡就是「三台 NAS」。
            if let serial = item.synology?.serial, let normalized = normalizeKey(serial) {
                keys.insert(normalized)
            }
            if let mac = item.synology?.mac, let normalized = normalizeKey(mac) {
                keys.insert(normalized)
            }
            // SSDP 的 serialNumber 实测填的是去冒号 MAC，也是身份键。
            if let serial = item.ssdp?.serialNumber, let normalized = normalizeKey(serial) {
                keys.insert(normalized)
            }
            // 自己的 IP 也当键：这样「A 的 LOCATION 提到 B」能与「B 自己那条证据」对上。
            keys.insert("ip:\(host)")
            for extra in item.additionalHosts { keys.insert("ip:\(extra)") }
            for key in keys {
                if let existing = keyToHost[key] {
                    union(existing, host)
                } else {
                    keyToHost[key] = host
                }
            }
        }

        var groups: [String: [String]] = [:]
        for host in hosts {
            groups[find(host), default: []].append(host)
        }

        // 3) 每组产出一台设备。
        var result: [MergedDevice] = []
        for members in groups.values {
            let sortedMembers = members.sorted(by: Self.ipLess)
            let primary = sortedMembers[0]
            guard var combined = byHost[primary] else { continue }
            var extras: Set<String> = combined.additionalHosts
            extras.remove(primary)
            for member in sortedMembers where member != primary {
                if let other = byHost[member] {
                    combined.merge(other)
                    extras.insert(member)
                    extras.formUnion(other.additionalHosts)
                }
            }
            extras.remove(primary)
            result.append(MergedDevice(host: primary,
                                       additionalHosts: extras.sorted(),
                                       evidence: combined,
                                       displayName: displayName(of: combined, fallback: primary),
                                       model: model(of: combined),
                                       mac: combined.mac,
                                       bestPort: bestPort(of: combined)))
        }

        // 输出按 IP 数值排序：既稳定，也符合用户「从上往下看」的直觉。
        return result.sorted { lhs, rhs in
            let l = NetworkDiscovery.ipv4Value(lhs.host) ?? 0
            let r = NetworkDiscovery.ipv4Value(rhs.host) ?? 0
            if l != r { return l < r }
            return lhs.host < rhs.host
        }
    }

    // MARK: - 显示值

    static func displayName(of evidence: DeviceEvidence, fallback: String) -> String {
        if let name = evidence.synology?.serverName, !name.isEmpty { return name }
        if let name = evidence.ssdp?.friendlyName, !name.isEmpty { return name }
        let names = evidence.hostnames.filter { !$0.isEmpty }
        // ★ 用户自己起的实例名优先于 `.local` 主机名：`.local` 是 mDNS 按机器名
        //   自动生成的（`MacBook-Air.local`），而实例名才是用户在 NAS 上填的那个。
        //   纯字典序会让 `z.local` 排到「公司 NAS」前面——中文排序总吃亏。
        if let named = names.filter({ !$0.hasSuffix(".local") }).sorted().first { return named }
        if let named = names.sorted().first { return named }
        return fallback
    }

    static func model(of evidence: DeviceEvidence) -> String? {
        if let model = evidence.synology?.model, !model.isEmpty { return model }
        if let model = evidence.ssdp?.modelName, !model.isEmpty { return model }
        return evidence.models.first { !$0.isEmpty }
    }

    /// 挑最值得预填的端口。
    ///
    /// 候选 = Synology 自报的 DSM 端口 ∪ 其它来源的开端口。
    /// DSM HTTPS 优先于 DSM HTTP，两者都优先于 SMB/WebDAV：那是能直接接着走
    /// 群晖登录流程的口。一个端口证据都没有时返回 0（调用方照实显示 IP）。
    static func bestPort(of evidence: DeviceEvidence) -> Int {
        var candidates = evidence.openPorts
        if let https = evidence.synology?.dsmHTTPSPort { candidates.insert(https) }
        if let http = evidence.synology?.dsmHTTPPort { candidates.insert(http) }
        return candidates.min { NetworkDiscovery.portRank($0) < NetworkDiscovery.portRank($1) } ?? 0
    }

    // MARK: - 内部

    /// IP 数值比较（组根、主 IP、输出排序共用同一个序，才不会互相打架）。
    static func ipLess(_ lhs: String, _ rhs: String) -> Bool {
        let l = NetworkDiscovery.ipv4Value(lhs) ?? 0
        let r = NetworkDiscovery.ipv4Value(rhs) ?? 0
        if l != r { return l < r }
        return lhs < rhs
    }

    /// 序列号/MAC 归一：去掉所有非字母数字字符，转小写。
    ///
    /// `02:00:5E:00:00:88` 与 `02005e000088` 必须是同一个值——DSM 的 SSDP
    /// serialNumber 就是去冒号 MAC，两边格式不同但指的是同一个东西。
    static func normalizeKey(_ raw: String) -> String? {
        let filtered = raw.lowercased().filter { $0.isLetter || $0.isNumber }
        return filtered.isEmpty ? nil : filtered
    }
}
