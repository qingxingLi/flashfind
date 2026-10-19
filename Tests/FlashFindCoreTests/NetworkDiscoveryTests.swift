import XCTest
@testable import FlashFindCore

/// 局域网设备发现（新增）。
///
/// 这里锁的是**判定**：能不能扫、扫哪些、扫到的东西怎么合并去重。
/// 真正的网络 IO（Bonjour 浏览、TCP 探测）在 App 层，测试目标 import 不到，
/// 所以凡是「可以抽成纯函数的部分」都抽到了 `NetworkDiscovery` 里——
/// 这样「只扫私有网段」「SMB 广播推不出品牌」这类**安全与诚实**的约束才守得住。
final class NetworkDiscoveryTests: XCTestCase {

    // MARK: - 只扫私有网段

    /// ★ 公网地址一律不扫。
    ///
    /// 用户可能挂着 VPN 或直连公网出口，拿那一段去枚举等于对外发扫描流量。
    /// 一个文件搜索工具不该有这种行为。
    func testOnlyPrivateIPv4IsScannable() {
        for address in ["10.0.0.1", "10.255.255.254", "172.16.0.1", "172.31.255.254",
                        "192.168.1.1", "192.168.255.254"] {
            XCTAssertTrue(NetworkDiscovery.isPrivateIPv4(address), "\(address) 是私有地址")
        }
        for address in ["8.8.8.8", "1.1.1.1", "172.15.0.1", "172.32.0.1",
                        "192.169.0.1", "11.0.0.1", "127.0.0.1", ""] {
            XCTAssertFalse(NetworkDiscovery.isPrivateIPv4(address), "\(address) 不该被当成可扫网段")
        }
        // 非法输入不猜：宁可什么都不做，也不要按某个默认段发探测包。
        XCTAssertFalse(NetworkDiscovery.isPrivateIPv4("192.168.1"))
        XCTAssertFalse(NetworkDiscovery.isPrivateIPv4("192.168.4.256"))
        XCTAssertFalse(NetworkDiscovery.isPrivateIPv4("nas.local"))
    }

    // MARK: - 网段枚举

    /// /24 网段：枚举 .1 ~ .254，不含网络号、广播地址与本机。
    func testSubnetHostsForSlash24ExcludesSelfAndEdges() {
        let hosts = NetworkDiscovery.subnetHosts(localAddress: "192.168.1.5", netmask: "255.255.255.0")
        XCTAssertEqual(hosts.count, 253,
                       "256 个地址去掉网络号、广播地址，再排掉本机自己，剩 253")
        XCTAssertEqual(hosts.first, "192.168.1.1")
        XCTAssertEqual(hosts.last, "192.168.1.254")
        XCTAssertFalse(hosts.contains("192.168.1.5"), "不该去连自己")
        XCTAssertFalse(hosts.contains("192.168.1.0"), "网络号不是主机")
        XCTAssertFalse(hosts.contains("192.168.1.255"), "广播地址不是主机")
    }

    /// ★ 宽掩码（/16 之类）**截断到自己那一个 /24**。
    ///
    /// 用户可能配着 255.255.0.0，那是 6 万多个地址，逐个扫要几分钟。
    /// 截断后扫的是本机所在的那一小段——NAS 几乎总在同一段。
    ///
    /// 这条同时钉住一个真出现过的错误：基准段必须是**本机所在的 /24**
    /// （`192.168.2.x`），而不是把掩码直接与运算得到的 `192.168.1.0`——
    /// 后者跟本机不在同一段，一台设备也发现不了。
    func testWideSubnetIsTruncatedToOneSlash24() {
        let hosts = NetworkDiscovery.subnetHosts(localAddress: "192.168.2.7", netmask: "255.255.0.0")
        XCTAssertEqual(hosts.count, 253, "宽掩码必须截断到一个 /24，不能枚举 6 万个地址")
        XCTAssertTrue(hosts.allSatisfy { $0.hasPrefix("192.168.2.") },
                      "截断后应当只扫本机所在的那一段，实际首个是：\(hosts.first ?? "空")")
        XCTAssertFalse(hosts.contains("192.168.2.7"))
    }

    /// 窄掩码（/25）按实际范围走，不多扫。
    func testNarrowSubnetUsesItsRealRange() {
        let hosts = NetworkDiscovery.subnetHosts(localAddress: "10.0.0.7", netmask: "255.255.255.128")
        XCTAssertEqual(hosts.count, 125,
                       "/25 有 126 个可用主机地址，排掉本机自己剩 125")
        XCTAssertEqual(hosts.first, "10.0.0.1")
        XCTAssertEqual(hosts.last, "10.0.0.126")
    }

    /// 拿不到私有地址 / 掩码非法时不产生任何目标。
    func testSubnetHostsReturnsEmptyWhenNotScannable() {
        XCTAssertTrue(NetworkDiscovery.subnetHosts(localAddress: "8.8.8.8", netmask: "255.255.255.0").isEmpty,
                      "公网地址不该产生扫描目标")
        XCTAssertTrue(NetworkDiscovery.subnetHosts(localAddress: "192.168.4.5", netmask: "").isEmpty)
        XCTAssertTrue(NetworkDiscovery.subnetHosts(localAddress: "", netmask: "255.255.255.0").isEmpty)
        XCTAssertTrue(NetworkDiscovery.subnetHosts(localAddress: "192.168.4.5", netmask: "0.0.0.0").isEmpty)
    }

    // MARK: - 服务类型与品牌推断

    /// ★ 会把满屋子设备都捞出来的通用服务类型，不许变成候选设备。
    ///
    /// 实测一个普通家庭网段里 `_http._tcp` / `_airplay._tcp` / `_raop._tcp`
    /// 会把路由器、打印机、Apple TV、音箱全列出来，用户还是找不到 NAS。
    ///
    /// 要分清两件事：**浏览**某些噪音类型是有用的——
    /// 我们需要知道某台设备「还开着 AirPlay」，以此判定它不是 NAS。
    /// 真正要锁死的是「它们不许出现在候选列表里」，见下面两条。
    func testBrowseListExcludesTrueNoise() {
        for noisy in ["_http._tcp", "_https._tcp", "_raop._tcp", "_companion-link._tcp", "_(audio?)._tcp"] {
            XCTAssertFalse(NetworkDiscovery.browsedServiceTypes.contains(noisy),
                           "\(noisy) 会把无关设备全捞出来，不该浏览")
        }
    }

    /// ★ 只用来判断类型、不能当成「可连接设备」的服务。
    ///
    /// `_device-info` 端口是 0（连不上）、`_airplay` / `_ipp` 与文件无关、
    /// `_diskstation` / `_qnap` 报的是 DSM 管理口而不是文件服务口——
    /// 让用户去「连接」一台打印机没有意义。它们唯一的用处是告诉我们这台设备是不是 NAS。
    func testTypeOnlyServicesNeverBecomeCandidates() {
        let typeOnly = NetworkDiscovery.browsedTypeOnlyServiceTypes
        XCTAssertTrue(typeOnly.isSubset(of: Set(NetworkDiscovery.browsedServiceTypes)),
                      "只用于判类型的服务也必须被浏览，否则拿不到它的信息")
        for type in typeOnly {
            XCTAssertTrue(["_device-info._tcp", "_airplay._tcp", "_ipp._tcp",
                           "_diskstation._tcp", "_qnap._tcp"].contains(type),
                          "\(type) 不在已知的「只判类型」清单里，要连得上才该浏览")
        }
    }

    /// ★ 浏览清单必须覆盖 `_webdavs`：群晖广播的是它，不是 `_webdav`。
    ///
    /// 实测：群晖注册的是 `_webdavs._tcp`（5006），
    /// 而 `_webdav._tcp` 一台都匹配不到——漏掉它就会少一条
    /// 「这台在提供 WebDAV」的证据。
    func testBrowseListCoversWebDAVs() {
        XCTAssertTrue(NetworkDiscovery.browsedServiceTypes.contains("_webdavs._tcp"),
                      "群晖广播的是 _webdavs（HTTPS WebDAV），不是 _webdav")
    }

    /// ★ 默认列表只留**明确识别**的设备；认不出的进「显示全部」。
    ///
    /// 认不出的设备若全留在默认列表，实测一个网段 111 台在线主机里
    /// 108 台只有 ARP/端口证据，全列出来用户照样找不到 NAS。
    func testShownByDefaultKeepsOnlyNASAndFileServers() {
        let nas = DiscoveredDevice(name: "a", host: "192.168.4.2", port: 5001, kind: .nas)
        let fileServer = DiscoveredDevice(name: "b", host: "192.168.4.6", port: 445, kind: .fileServer)
        let computer = DiscoveredDevice(name: "c", host: "192.168.4.3", port: 445, kind: .computer)
        let appliance = DiscoveredDevice(name: "d", host: "192.168.4.4", port: 631, kind: .appliance)
        let unknown = DiscoveredDevice(name: "e", host: "192.168.4.5", port: 445, kind: .unknown)

        let shown = NetworkDiscovery.shownByDefault([nas, fileServer, computer, appliance, unknown])
        XCTAssertEqual(Set(shown.map(\.host)), ["192.168.4.2", "192.168.4.6"])
    }

    /// ★ 候选清单里只放真正连得上、能接着走登录流程的文件服务。
    func testCandidateServiceTypesAreConnectable() {
        let candidates = Set(NetworkDiscovery.browsedServiceTypes)
            .subtracting(NetworkDiscovery.browsedTypeOnlyServiceTypes)
        XCTAssertTrue(candidates.isSubset(of: ["_smb._tcp", "_webdav._tcp", "_webdavs._tcp",
                                               "_afpovertcp._tcp", "_synology-dsm._tcp"]))
        XCTAssertTrue(candidates.contains("_smb._tcp"), "SMB 是命中率最高的一类，不能丢")
        XCTAssertTrue(candidates.contains("_synology-dsm._tcp"), "群晖私有服务能直接认出群晖，不能丢")
    }

    /// 只有群晖自己的服务类型能推出品牌；SMB / WebDAV 是通用协议，推不出来。
    ///
    /// ★ 推不出来就必须是 `nil`：默认成某个品牌等于替用户做了一个他没法核对的判断。
    func testVendorHintOnlyClaimsWhatItKnows() {
        XCTAssertEqual(NetworkDiscovery.vendorHint(forServiceType: "_synology-dsm._tcp"), .synology)
        XCTAssertEqual(NetworkDiscovery.vendorHint(forServiceType: "_synology-dsm._tcp."), .synology,
                       "NetService 传来的类型带尾点也要能认")
        XCTAssertNil(NetworkDiscovery.vendorHint(forServiceType: "_smb._tcp"),
                     "SMB 任何品牌都可能提供，不能据此断言品牌")
        XCTAssertNil(NetworkDiscovery.vendorHint(forServiceType: "_webdav._tcp"))
        XCTAssertNil(NetworkDiscovery.vendorHint(forServiceType: ""))
    }

    /// 设备身份按「地址 + 端口」定，与显示名无关——改名不改变它是同一台设备。
    func testDeviceIdentityIgnoresDisplayName() {
        func device(_ name: String, _ port: Int) -> DiscoveredDevice {
            DiscoveredDevice(name: name, host: "192.168.1.96", port: port,
                             serviceType: "_smb._tcp", origin: .bonjour)
        }
        XCTAssertEqual(device("甲", 5001).id, device("乙", 5001).id)
        XCTAssertNotEqual(device("甲", 5001).id, device("甲", 5000).id)
    }

    /// 探测端口按「像 NAS 的程度」排序，5001 在前。
    func testProbePortsPutDSMFirst() {
        XCTAssertEqual(NetworkDiscovery.probePorts, [5001, 5000, 5005, 445])
        XCTAssertGreaterThan(NetworkDiscovery.probeConcurrency, 0)
        // 并发必须真的限流：一次把上千个连接全放出去会打满家用路由器。
        XCTAssertLessThanOrEqual(NetworkDiscovery.probeConcurrency, 32)
        XCTAssertGreaterThan(NetworkDiscovery.probeTimeout, 0)
    }

    /// ★ 探测端口必须覆盖 WebDAV（5005）：**不广播 mDNS 的设备只能靠探测找到**。
    ///
    /// 实测：有一台群晖（首页 `Hello! Welcome to Synology Web Station!`）
    /// **一条 mDNS 服务都不广播** —— `_smb`、`_device-info` 里都没有它，
    /// 但开着 5005（群晖 WebDAV，`PROPFIND` 返回 401）与 445。
    /// 只探 5001/5000/445 就会在向导里把它填成 SMB 端口，
    /// 而它压根没开 DSM 的 5000/5001 —— 找到了也对不上能用的端口。
    func testProbePortsCoverWebDAVForSilentDevices() {
        XCTAssertTrue(NetworkDiscovery.probePorts.contains(5005),
                      "5005 是群晖/飞牛 WebDAV 的明文端口，不广播的设备只能靠它命中")
        XCTAssertTrue(NetworkDiscovery.probePorts.contains(445),
                      "SMB 445 是通用兜底，不能丢")
        // 顺序也要对：先试能直接走登录流程的端口，445 垫底。
        guard let idx5005 = NetworkDiscovery.probePorts.firstIndex(of: 5005),
              let idx445 = NetworkDiscovery.probePorts.firstIndex(of: 445) else {
            return XCTFail("5005 与 445 必须都在探测端口里")
        }
        XCTAssertLessThan(idx5005, idx445, "5005 要排在 445 前面，否则命中 SMB 端口")
    }

    /// ★ 整轮 /24 扫描的预算：加端口就必须同步压缩单口超时。
    ///
    /// 实测一个**不存在**的地址会把每个端口都耗到超时（同网段 ARP 无响应，
    /// 不是 RST），所以总时长 ≈ 主机数 × 端口数 × 单口超时 ÷ 并发。
    /// 端口从 3 增到 4 时若不把 1.2s 压到 0.9s，整轮会从 45s 涨到 61s —— 用户以为卡住了。
    ///
    /// 端口数这里按**最坏情况 4** 写死，不读 `probePorts`：否则「去掉 5005」
    /// 会把端口数降回 3，跟「超时退回 1.2s」正好抵消，这条锁就形同虚设
    /// （红证是所有变异一起应用的）。
    func testFullSubnetScanStaysWithinBudget() {
        let worst = 253.0 * 4.0 * NetworkDiscovery.probeTimeout
            / Double(NetworkDiscovery.probeConcurrency)
        XCTAssertLessThanOrEqual(worst, 60.0,
                                 "整轮扫描最坏 \(worst)s 超过 60s：加端口就要同步压超时")
    }
}
