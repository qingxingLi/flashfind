import Foundation

/// 在局域网里发现的一台候选设备。
///
/// ## 为什么要有这个类型
///
/// 「添加搜索来源」原本只有一条路：让用户自己敲 IP。家里/公司的 NAS 就在同一个
/// 网段里，却要用户去路由器后台翻地址——这是把网络知识摊给了用户。
///
/// 发现能力本身（Bonjour 浏览、TCP 探测）住在 App 层，因为要用 `Network` /
/// `Foundation` 的网络对象；但**「发现到的这些是什么、要不要显示、跟已有来源
/// 是否重复」全是判定**——那是 Core 的事，也因此能被测试锁住。
public struct DiscoveredDevice: Identifiable, Equatable, Sendable {
    /// 设备显示名。Bonjour 能给出实例名（如「公司 NAS」）；探测出来的只有地址。
    public var name: String
    /// 解析后的主机地址（纯 IP 或主机名，不含协议与端口）。
    public var host: String
    public var port: Int
    /// 来源的 Bonjour 服务类型；探测到的设备为空串。
    public var serviceType: String
    public var origin: Origin
    /// 这个地址是否已经在用户的来源列表里。
    public var alreadyAdded: Bool
    /// `_device-info._tcp` 的 TXT 里报出来的设备型号（如群晖的 `Xserve`）。拿不到为 `nil`。
    public var model: String?
    /// 这台设备**所在的主机**命中的所有服务类型。
    ///
    /// 一台设备通常广播多个服务（群晖会同时有 `_smb` 与 `_device-info`），
    /// 单看某一个类型判不准（Mac 也会广播 `_smb`），所以要按主机汇总后才好判。
    public var serviceTypes: Set<String>
    /// 判出来的设备类型。默认 `.unknown` —— 认不出就照实说认不出，不替用户猜。
    public var kind: DeviceKind

    public enum Origin: String, Sendable {
        /// 设备自己广播出来的（有名字，最可信）。
        case bonjour
        /// 端口探测命中的（只有地址）。
        case probe
    }

    public init(name: String, host: String, port: Int, serviceType: String = "",
                origin: Origin = .bonjour, alreadyAdded: Bool = false,
                model: String? = nil, serviceTypes: Set<String> = [],
                kind: DeviceKind = .unknown) {
        self.name = name
        self.host = host
        self.port = port
        self.serviceType = serviceType
        self.origin = origin
        self.alreadyAdded = alreadyAdded
        self.model = model
        self.serviceTypes = serviceTypes
        self.kind = kind
    }

    /// 同一台设备可能同时被 Bonjour 和端口探测命中：按「地址 + 端口」认。
    ///
    /// 不用显示名做键——改名不改变它是同一台设备，而且探测出来的那一条根本没有名字。
    public var id: String { "\(host):\(port)" }

    /// 从服务类型推断出来的品牌。推断不出来就是 `nil`，界面照实说「未知类型」，
    /// **不要**默认成某个品牌——那等于替用户做了一个他没法核对的判断。
    public var vendorHint: NASSourceConfig.Vendor? {
        NetworkDiscovery.vendorHint(forServiceType: serviceType)
    }

    /// 地址那一行的文案。
    ///
    /// ★ 没有任何端口证据（`port == 0`）时**只显示地址**——显示成
    /// `192.168.1.7:0` 既难看又像是我们编了个端口。
    public var addressText: String { port > 0 ? "\(host):\(port)" : host }
}

/// 局域网发现的判定逻辑。
///
/// 这里**只做判定，不做 IO**。所有函数都是纯函数，理由见 `DiscoveredDevice` 的说明。
public enum NetworkDiscovery {

    // MARK: - 浏览哪些服务

    /// 值得浏览的 Bonjour 服务类型。
    ///
    /// 分两组，各有用处：
    ///
    /// **第一组是「候选设备」**——会指向文件服务的几类：
    ///
    /// * `_smb._tcp` —— NAS 几乎一定开 SMB（不开就没法在访达里用），命中率最高；
    /// * `_webdav._tcp` / `_webdavs._tcp` —— 开了 WebDAV 的会广播。
    ///   ** 实测补的 `_webdavs`**：群晖广播的是 HTTPS WebDAV
    ///   （`_webdavs`，实测 .96 开在 5006），**不是** `_webdav`——
    ///   只浏览 `_webdav` 在本网一台都匹配不到；
    /// * `_afpovertcp._tcp` —— 老 AFP 共享，旧 NAS 与旧 Mac 还在用；
    /// * `_synology-dsm._tcp` —— 群晖注册的 DSM 服务，**能直接认出群晖**。
    ///
    /// **第二组是「用来排除的」**——不产生候选，只用于判类型：
    ///
    /// * `_device-info._tcp` —— **类型判定的命脉**。macOS 访达就是靠它 TXT 里的
    ///   `model=` 把 Mac 和 NAS 画成不同图标的（实测群晖报 `model=Xserve`）。
    ///   它本身端口为 0、不提供文件服务，所以只取型号，不进候选列表。
    /// * `_airplay._tcp` / `_ipp._tcp` —— 命中说明这是音箱/Apple TV/打印机，不是 NAS。
    /// * `_diskstation._tcp` / `_qnap._tcp` —— 来自 MyNAS（`chenqi92/my-nas`）
    ///   的浏览清单；本网未实测到，但能直接认出群晖/QNAP，收着不亏。
    ///
    /// **刻意不收 `_http._tcp` / `_raop._tcp`**：实测一个普通家庭网段里这几类会把
    /// 路由器、摄像头、Apple TV、音箱全捞出来，列表变成一屏噪音，用户还是找不到
    /// NAS。「宁可少列，不要列错」。
    public static let browsedServiceTypes = [
        "_smb._tcp",
        "_webdav._tcp",
        "_webdavs._tcp",
        "_afpovertcp._tcp",
        "_synology-dsm._tcp",
        // 只用于判类型，不进候选列表（见 `browsedTypeOnlyServiceTypes`）。
        "_device-info._tcp",
        "_airplay._tcp",
        "_ipp._tcp",
        "_diskstation._tcp",
        "_qnap._tcp",
    ]

    /// 只用来判断类型、不单独作为候选设备的服务类型。
    ///
    /// `_device-info` 的端口是 0、`_airplay`/`_ipp` 与文件无关、
    /// `_diskstation`/`_qnap` 报的是 DSM 管理口（不是文件服务口），
    /// 让用户去「连接」它们没有意义——但它们能告诉我们这台设备**是不是** NAS。
    public static let browsedTypeOnlyServiceTypes: Set<String> = [
        "_device-info._tcp",
        "_airplay._tcp",
        "_ipp._tcp",
        "_diskstation._tcp",
        "_qnap._tcp",
    ]

    /// 由服务类型推断品牌。认不出来返回 `nil`。
    public static func vendorHint(forServiceType serviceType: String) -> NASSourceConfig.Vendor? {
        // NetService 传进来的类型可能带结尾的点，也可能不带；统一去掉再比。
        let normalized = serviceType.hasSuffix(".") ? String(serviceType.dropLast()) : serviceType
        switch normalized.lowercased() {
        case "_synology-dsm._tcp", "_diskstation._tcp":
            return .synology
        case "_qnap._tcp":
            return .qnap
        // SMB / WebDAV 是通用协议，任何品牌都可能提供，不能据此断言品牌。
        default:
            return nil
        }
    }

    // MARK: - 探测端口

    /// 网段探测要试的端口，按「像 NAS 的程度」排序。
    ///
    /// * `5001` / `5000` —— 群晖 DSM 的 HTTPS / HTTP 默认端口，最直接；
    /// * `5005` —— 群晖 / 飞牛的 WebDAV 明文端口。** 实测补上的**：
    ///   实测有一台群晖（首页 `Synology Web Station`）**一条 mDNS 都不广播**，
    ///   只开着 5005 与 445，DSM 的 5000/5001 没开。
    ///   没有 5005 就会命中 445，向导里预填成 SMB 端口，而那条路根本走不通；
    /// * `445` —— SMB，通用兜底（顺序最后：它只说明「有文件共享」，
    ///   不像 5001 那样能直接接着走群晖的登录流程）。
    public static let probePorts = [5001, 5000, 5005, 445]

    /// 探测时同时最多开多少个连接。
    ///
    /// 254 个地址 × 3 个端口 = 762 次连接。不限流会瞬间打满本地网络栈，
    /// 轻则在路由器上留下一串半开连接，重则触发家用路由的防护。20 路
    /// 是「几秒内扫完一个 /24」与「不惊动网络」之间的折中。
    public static let probeConcurrency = 20

    /// 单个连接的超时（秒）。家用网段里不存在的地址应当快速失败；
    /// 这个值只影响扫完一个网段的总时长，不影响正常设备的发现。
    ///
    /// ** 实测**：同网段一个不存在的地址会让每个端口都耗到超时
    /// （ARP 无响应，不是 RST），所以整轮时长 ≈ 主机数 × 端口数 × 本值 ÷ 并发。
    /// 端口从 3 增到 4 时同步由 1.2 压到 0.9，把整轮按在 46s 左右
    /// （253 × 4 × 0.9 ÷ 20）。可达的主机实测 0.01s 就连上，压不坏。
    public static let probeTimeout: Double = 0.9

    // MARK: - 网段

    /// 是否是可以扫描的私有 IPv4 地址。
    ///
    /// **只扫私有段**：公网地址一律不碰。用户可能连着公司 VPN 或公网出口，
    /// 拿着那一段去枚举等于对外发扫描流量——这不是一个搜索工具该做的事。
    public static func isPrivateIPv4(_ host: String) -> Bool {
        guard let value = ipv4Value(host) else { return false }
        // 10.0.0.0/8
        if value >> 24 == 10 { return true }
        // 172.16.0.0/12
        if value >> 24 == 172, (value >> 16) & 0xFF >= 16, (value >> 16) & 0xFF <= 31 { return true }
        // 192.168.0.0/16
        if value >> 24 == 192, (value >> 16) & 0xFF == 168 { return true }
        return false
    }

    /// 枚举与 `localAddress` 同网段、值得探测的主机地址。
    ///
    /// ## 为什么最多只扫一个 /24
    ///
    /// 用户可能配着 `255.255.0.0` 甚至更宽的掩码，那是一个 6 万多个地址的网段，
    /// 逐个扫要几分钟。**截断到 /24（自己那一小段）**：家用与小型办公环境里
    /// NAS 几乎总在同一段；扫不到时用户还有「手动添加」，不会卡死。
    ///
    /// 结果**不含**本机地址，也不含网络号与广播地址。
    public static func subnetHosts(localAddress: String, netmask: String) -> [String] {
        guard let ip = ipv4Value(localAddress),
              let mask = ipv4Value(netmask),
              isPrivateIPv4(localAddress) else { return [] }

        // 掩码里 1 的个数；截断到至少 /24（即 host 位最多 8 位）。
        let maskBits = mask.nonzeroBitCount
        guard maskBits >= 1 else { return [] }
        let effectiveBits = min(max(maskBits, 24), 30)
        let hostBits = 32 - effectiveBits
        let hostCount = 1 << hostBits

        // ★ 这里判的是**原始掩码**，不是截断后的 `hostBits`。
        //
        //   `255.255.0.0` 的 host 位是 16，比一个 /24 宽，所以网络号必须压到
        //   **本机所在的那个 /24** 上（`ip & 255.255.255.0`）。
        //   如果按截断后的 hostBits 判（它是 8，不满足「> 8」），就会落到
        //   `ip & mask` 分支，扫的是 `192.168.1.0/24` —— 一个跟本机
        //   （`192.168.2.7`）根本不在同一段的网段，一台设备也发现不了。
        let rawHostBits = 32 - maskBits
        let base = rawHostBits > 8 ? (ip & 0xFFFFFF00) : (ip & mask)

        var hosts: [String] = []
        hosts.reserveCapacity(hostCount)
        for offset in 1..<max(hostCount - 1, 1) {
            let candidate = base | UInt32(offset)
            if candidate == ip { continue }
            hosts.append(stringValue(candidate))
        }
        return hosts
    }

    // MARK: - 合并

    /// 默认列表要显示的设备。
    ///
    /// 用户的规则：**默认只展示被明确识别为 NAS/文件服务器的设备**，
    /// 所有未知网络设备只放到「显示全部设备」里。
    /// （认不出的设备若全留在默认列表，实测一个网段 111 台在线主机里
    /// 108 台只有 ARP/端口证据，全列出来用户照样找不到 NAS。）
    public static func shownByDefault(_ devices: [DiscoveredDevice]) -> [DiscoveredDevice] {
        devices.filter { $0.kind.shownInDefaultList }
    }

    // MARK: - 多来源装配

    /// 把 `DeviceMerger` 归并出来的设备装成界面能显示的 `DiscoveredDevice`。
    ///
    /// 这是「多来源发现」流水线的最后一环，也是**唯一**把证据变成界面的地方：
    /// 归并（`DeviceMerger`）→ 定性（`DeviceClassifier.classify(_:)`）→ 装配（这里）。
    /// 三步都是纯函数，所以都能被测试锁住。
    ///
    /// 端口为 `bestPort`；没有任何端口证据时是 0，`addressText` 会只显示地址。
    public static func makeDevices(from merged: [MergedDevice],
                                   existing: [NASSourceConfig]) -> [DiscoveredDevice] {
        let existingHosts = Set(existing.map { $0.hostName }.filter { !$0.isEmpty })
        return merged.map { device in
            let classification = DeviceClassifier.classify(device.evidence)
            // 服务类型取「最能说明品牌」的那一个：`vendorHint` 依赖这个字段，
            // 而一台群晖会同时广播 _smb / _webdavs / _afpovertcp。
            let serviceType = device.evidence.serviceTypes
                .sorted()
                .first { vendorHint(forServiceType: $0) != nil }
                ?? device.evidence.serviceTypes.sorted().first
                ?? ""
            return DiscoveredDevice(
                name: device.displayName,
                host: device.host,
                port: device.bestPort,
                serviceType: serviceType,
                origin: device.evidence.sources.contains(.bonjour) ? .bonjour : .probe,
                alreadyAdded: existingHosts.contains(device.host)
                    || device.additionalHosts.contains(where: { existingHosts.contains($0) }),
                model: device.model,
                serviceTypes: device.evidence.serviceTypes,
                kind: classification.kind)
        }
        .sorted { lhs, rhs in
            // 未添加的在前（用户要找的就是它们），其次 NAS 优先，最后按 IP 数值。
            if lhs.alreadyAdded != rhs.alreadyAdded { return !lhs.alreadyAdded }
            if lhs.kind != rhs.kind { return kindRank(lhs.kind) < kindRank(rhs.kind) }
            let l = ipv4Value(lhs.host) ?? 0
            let r = ipv4Value(rhs.host) ?? 0
            if l != r { return l < r }
            return lhs.host < rhs.host
        }
    }

    /// 显示顺序：NAS → 文件服务器 → 未知 → 电脑 → 外设。
    ///
    /// 电脑与外设排最后：它们是「认出来了但不是你要找的」——
    /// 未知至少还有可能是 NAS，电脑/外设基本不可能。
    static func kindRank(_ kind: DeviceKind) -> Int {
        switch kind {
        case .nas: return 0
        case .fileServer: return 1
        case .unknown: return 2
        case .computer: return 3
        case .appliance: return 4
        }
    }

    /// 端口优先级：越小越优先。不在清单里的排最后。
    ///
    /// 5002/5003 是**非标准口上的 DSM**：实测 DS1621+ 把
    /// DSM 开在 5002/5003 而不是标准的 5000/5001，不知道这两个口的话
    /// 那台设备的最佳端口会掉到 445（SMB）上去。
    static func portRank(_ port: Int) -> Int {
        switch port {
        case 5001: return 0   // 群晖 DSM HTTPS（标准口）
        case 5003: return 1   // 群晖 DSM HTTPS（非标准口，实测存在）
        case 5000: return 2   // 群晖 DSM HTTP（标准口）
        case 5002: return 3   // 群晖 DSM HTTP（非标准口，实测存在）
        case 5005: return 4   // 群晖/飞牛 WebDAV 明文
        case 443:  return 5
        case 445:  return 6   // SMB
        case 80:   return 7
        case 8080: return 8
        case 548:  return 9   // AFP（旧协议，最不优先）
        default:   return 10
        }
    }

    // MARK: - 内部

    /// 点分十进制 → 32 位整数。非法输入返回 `nil`（不会去猜）。
    public static func ipv4Value(_ text: String) -> UInt32? {
        let parts = text.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return nil }
        var value: UInt32 = 0
        for part in parts {
            guard let octet = UInt32(part), octet <= 255, !part.isEmpty else { return nil }
            value = (value << 8) | octet
        }
        return value
    }

    public static func stringValue(_ value: UInt32) -> String {
        "\((value >> 24) & 0xFF).\((value >> 16) & 0xFF).\((value >> 8) & 0xFF).\(value & 0xFF)"
    }
}
