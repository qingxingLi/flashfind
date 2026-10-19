import XCTest
@testable import FlashFindCore

/// 多来源证据归并。
///
/// 用例尽量复刻**实测现场**（局域网 192.168.1.0/24）：
/// DS1621+ 有三块网卡且一条 mDNS 都不广播、DS124 四类证据齐全、
/// MacBook Air 只有 `_smb`、一百多台设备只有 ARP。
final class DeviceMergerTests: XCTestCase {

    // MARK: - 多网口归并（实测 DS1621+）

    /// ★ 同一台 NAS 的三块网卡必须归成一台。
    ///
    /// 实测 DS1621+：192.168.1.88（Synology 协议+SSDP+ARP）、
    /// 192.168.1.152 与 192.168.3.4（SSDP LOCATION 交叉引用 + ARP）。
    /// 不归并的话用户看到的是「三台 NAS」。
    func testMultiNICSynologyIsMergedIntoOneDevice() {
        let synology = SynologyResponse(serverName: "FAKENAS001",
                                        ip: "192.168.1.88",
                                        mac: "02:00:5E:00:00:88",
                                        dsmHTTPPort: 5002,
                                        dsmHTTPSPort: 5003,
                                        dsmVersion: "7.3.2",
                                        model: "DS1621+",
                                        serial: "SNFAKEDSM0001")
        var primary = DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery, .arp])
        primary.mac = "02:00:5E:00:00:88"
        primary.synology = synology
        primary.openPorts = [445]   // TCP fallback 的命中

        let second = DeviceEvidence(host: "192.168.1.152",
                                    sources: [.ssdp, .arp],
                                    ssdp: SSDPIdentity(location: "http://192.168.1.152:5000/description.xml",
                                                       manufacturer: "Synology",
                                                       modelName: "DS1621+",
                                                       serialNumber: "SNFAKEDSM0001"),
                                    additionalHosts: ["192.168.3.4"])
        let third = DeviceEvidence(host: "192.168.3.4", sources: [.arp])

        let merged = DeviceMerger.merge([primary, second, third])

        XCTAssertEqual(merged.count, 1, "三块网卡是同一台设备")
        XCTAssertEqual(merged[0].host, "192.168.1.88", "主 IP 取最小的那个，输出才稳定")
        XCTAssertEqual(merged[0].additionalHosts, ["192.168.1.152", "192.168.3.4"])
        XCTAssertEqual(merged[0].model, "DS1621+")
        XCTAssertEqual(merged[0].displayName, "FAKENAS001", "显示名优先用设备自报的服务器名")
        XCTAssertEqual(merged[0].bestPort, 5003, "DSM HTTPS 优先于 SMB 445")
        XCTAssertEqual(merged[0].evidence.sources,
                       Set<DiscoverySource>([.synologyDiscovery, .ssdp, .arp]),
                       "三路来源都要并进来")
    }

    /// ★ MAC 的两种写法必须视为同一个值。
    ///
    /// DSM 的 SSDP `serialNumber` 填的是**去冒号 MAC**，而 ARP/Synology 给的是
    /// 带冒号 MAC——不归一就对不上，多网口归并会失效。
    func testMACNormalizationMatchesAcrossFormats() {
        let a = DeviceEvidence(host: "192.168.1.10", mac: "02:00:5E:00:00:88", sources: [.arp])
        let b = DeviceEvidence(host: "192.168.1.11",
                               sources: [.ssdp],
                               ssdp: SSDPIdentity(serialNumber: "02005e000088"))
        let merged = DeviceMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].additionalHosts, ["192.168.1.11"])
    }

    /// SSDP LOCATION 指向的第三块网卡，即使只有 ARP 证据也要归进来。
    func testAdditionalHostIPAlsoMerges() {
        let a = DeviceEvidence(host: "192.168.1.88",
                               sources: [.ssdp],
                               ssdp: SSDPIdentity(location: "http://192.168.3.4:5000/desc.xml"),
                               additionalHosts: ["192.168.3.4"])
        let b = DeviceEvidence(host: "192.168.3.4", sources: [.arp])
        let merged = DeviceMerger.merge([a, b])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].host, "192.168.1.88")
        XCTAssertEqual(merged[0].additionalHosts, ["192.168.3.4"])
    }

    /// 传递归并：A-B 共享序列号、B-C 共享另一个序列号 → 三者是一台。
    ///
    /// 「见到就并」的一遍扫法在这里会漏；并查集不会。
    func testTransitiveMergeThroughSharedKeys() {
        let a = DeviceEvidence(host: "192.168.1.1", serials: ["S1"], sources: [.synologyDiscovery])
        let b = DeviceEvidence(host: "192.168.1.2", serials: ["S1", "S2"], sources: [.synologyDiscovery])
        let c = DeviceEvidence(host: "192.168.1.3", serials: ["S2"], sources: [.synologyDiscovery])
        let merged = DeviceMerger.merge([a, b, c])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].host, "192.168.1.1")
        XCTAssertEqual(merged[0].additionalHosts, ["192.168.1.2", "192.168.1.3"])
    }

    // MARK: - 不归并

    /// 没有共同点的两台设备各是各的。
    func testDifferentDevicesStaySeparate() {
        let nas = DeviceEvidence(host: "192.168.1.96", mac: "02:00:5E:00:00:96",
                                 serials: ["SNFAKEDSM0002"], sources: [.synologyDiscovery])
        let macBook = DeviceEvidence(host: "192.168.1.92", mac: "02:00:5E:00:00:11",
                                     serviceTypes: ["_smb._tcp"], sources: [.bonjour])
        let merged = DeviceMerger.merge([nas, macBook])
        XCTAssertEqual(merged.count, 2)
    }

    /// 同一 IP 的多份证据并成一份（Synology + SSDP + ARP + Bonjour）。
    func testSameHostEvidenceFoldsIntoOne() {
        var synology = DeviceEvidence(host: "192.168.1.96", sources: [.synologyDiscovery])
        synology.synology = SynologyResponse(serverName: "demo-synology",
                                             mac: "02:00:5E:00:00:96",
                                             model: "DS124",
                                             serial: "SNFAKEDSM0002")
        var ssdp = DeviceEvidence(host: "192.168.1.96", sources: [.ssdp])
        ssdp.ssdp = SSDPIdentity(manufacturer: "Synology", modelName: "DS124")
        let arp = DeviceEvidence(host: "192.168.1.96", mac: "02:00:5E:00:00:96", sources: [.arp])
        var bonjour = DeviceEvidence(host: "192.168.1.96", sources: [.bonjour])
        bonjour.serviceTypes = ["_smb._tcp", "_webdavs._tcp", "_afpovertcp._tcp", "_device-info._tcp"]
        bonjour.hostnames = ["demo-synology.local"]
        bonjour.models = ["Xserve"]
        bonjour.openPorts = [445, 5006, 548]

        let merged = DeviceMerger.merge([synology, ssdp, arp, bonjour])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].evidence.sources,
                       Set<DiscoverySource>([.synologyDiscovery, .ssdp, .arp, .bonjour]))
        XCTAssertEqual(merged[0].evidence.serviceTypes,
                       Set<String>(["_smb._tcp", "_webdavs._tcp", "_afpovertcp._tcp", "_device-info._tcp"]))
        XCTAssertEqual(merged[0].evidence.openPorts, Set<Int>([445, 5006, 548]))
        XCTAssertEqual(merged[0].model, "DS124", "Synology 自报型号优先于 _device-info 的 Xserve")
        XCTAssertEqual(merged[0].displayName, "demo-synology")
        XCTAssertEqual(merged[0].bestPort, 445, "没有 DSM 自报端口时，445 排在 5006/548 之前")
    }

    // MARK: - 显示值

    /// 显示名优先级：Synology server_name > SSDP friendlyName > 主机名 > IP。
    func testDisplayNamePreferenceOrder() {
        var withSynology = DeviceEvidence(host: "192.168.1.1", hostnames: ["某台设备.local"])
        withSynology.synology = SynologyResponse(serverName: "FAKENAS001")
        withSynology.ssdp = SSDPIdentity(friendlyName: "友好名")
        XCTAssertEqual(DeviceMerger.displayName(of: withSynology, fallback: "192.168.1.1"),
                       "FAKENAS001")

        var withSSDP = DeviceEvidence(host: "192.168.1.2", hostnames: ["某台设备.local"])
        withSSDP.ssdp = SSDPIdentity(friendlyName: "友好名")
        XCTAssertEqual(DeviceMerger.displayName(of: withSSDP, fallback: "192.168.1.2"),
                       "友好名")

        let bonjourOnly = DeviceEvidence(host: "192.168.1.3", hostnames: ["公司 NAS", "z.local"])
        XCTAssertEqual(DeviceMerger.displayName(of: bonjourOnly, fallback: "192.168.1.3"),
                       "公司 NAS")

        let bare = DeviceEvidence(host: "192.168.1.4")
        XCTAssertEqual(DeviceMerger.displayName(of: bare, fallback: "192.168.1.4"), "192.168.1.4")
    }

    /// ★ 最佳端口：DSM HTTPS > DSM HTTP > WebDAV > SMB。
    ///
    /// `.88` 把 DSM 开在 5003（非标准口）——不知道这个口的话，那台设备的
    /// 最佳端口会掉到 445 上，用户拿到的就是一条走不通的 SMB 地址。
    func testBestPortPrefersDSMOverEverythingElse() {
        var evidence = DeviceEvidence(host: "192.168.1.88")
        evidence.openPorts = [445, 5005]
        evidence.synology = SynologyResponse(dsmHTTPPort: 5002, dsmHTTPSPort: 5003)
        XCTAssertEqual(DeviceMerger.bestPort(of: evidence), 5003)

        var httpOnly = DeviceEvidence(host: "192.168.1.99")
        httpOnly.openPorts = [445]
        httpOnly.synology = SynologyResponse(dsmHTTPPort: 5002)
        XCTAssertEqual(DeviceMerger.bestPort(of: httpOnly), 5002)

        var bonjourOnly = DeviceEvidence(host: "192.168.1.96")
        bonjourOnly.openPorts = [5006, 548, 445]
        XCTAssertEqual(DeviceMerger.bestPort(of: bonjourOnly), 445,
                       "445 在端口优先级名单里，5006 不在——名单外的口排最后")
        var webdavOnly = DeviceEvidence(host: "192.168.1.97")
        webdavOnly.openPorts = [5006]
        XCTAssertEqual(DeviceMerger.bestPort(of: webdavOnly), 5006,
                       "只有 WebDAV 口时就用它，总比没有强")
    }

    /// 一个端口证据都没有 → 0，调用方照实显示 IP，不编一个端口。
    func testBestPortIsZeroWithoutAnyPortEvidence() {
        let arpOnly = DeviceEvidence(host: "192.168.1.7", sources: [.arp])
        XCTAssertEqual(DeviceMerger.bestPort(of: arpOnly), 0)
    }

    /// 同主机两份 Synology 自述，信息更完整的那份胜出（与到达顺序无关）。
    func testMoreCompleteSynologyWinsRegardlessOfOrder() {
        let sparse = SynologyResponse(serverName: "FAKENAS001")
        let rich = SynologyResponse(serverName: "FAKENAS001",
                                    mac: "02:00:5E:00:00:88",
                                    dsmHTTPPort: 5002,
                                    dsmHTTPSPort: 5003,
                                    dsmVersion: "7.3.2",
                                    model: "DS1621+",
                                    serial: "SNFAKEDSM0001")
        let forward = DeviceMerger.merge([
            DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery], synology: sparse),
            DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery], synology: rich),
        ])
        let backward = DeviceMerger.merge([
            DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery], synology: rich),
            DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery], synology: sparse),
        ])
        XCTAssertEqual(forward[0].evidence.synology?.model, "DS1621+")
        XCTAssertEqual(forward[0].evidence.synology, backward[0].evidence.synology,
                       "合并结果不许依赖证据到达顺序")
    }

    // MARK: - 稳定性

    /// ★ 输出按 **IP 数值**排序，不是字典序。
    ///
    /// 字典序会把 `192.168.1.10` 排到 `192.168.1.9` 前面——用户眼里就是乱的。
    func testOutputIsSortedByIPNumerically() {
        let devices = ["192.168.1.10", "192.168.1.9", "192.168.1.100", "192.168.1.2"]
            .map { DeviceEvidence(host: $0, sources: [.arp]) }
        XCTAssertEqual(DeviceMerger.merge(devices).map(\.host),
                       ["192.168.1.2", "192.168.1.9", "192.168.1.10", "192.168.1.100"])
    }

    /// 输入顺序打乱不影响输出（归并是确定性的）。
    func testMergeIsDeterministicRegardlessOfInputOrder() {
        let a = DeviceEvidence(host: "192.168.1.88", mac: "02:00:5E:00:00:88", sources: [.arp])
        let b = DeviceEvidence(host: "192.168.1.152", mac: "02:00:5E:00:00:88", sources: [.arp])
        let c = DeviceEvidence(host: "192.168.1.96", serials: ["SNFAKEDSM0002"], sources: [.arp])
        let forward = DeviceMerger.merge([a, b, c])
        let backward = DeviceMerger.merge([c, b, a])
        XCTAssertEqual(forward, backward)
        XCTAssertEqual(forward.count, 2)
    }

    /// 空输入不炸，也不冒占位设备。
    func testEmptyInputStaysEmpty() {
        XCTAssertTrue(DeviceMerger.merge([]).isEmpty)
    }

    /// host 为空的证据直接丢弃——没有主键的证据没法用。
    func testEvidenceWithoutHostIsDropped() {
        let merged = DeviceMerger.merge([
            DeviceEvidence(host: "", mac: "02:00:5E:00:00:88", sources: [.arp]),
            DeviceEvidence(host: "192.168.1.88", sources: [.arp]),
        ])
        XCTAssertEqual(merged.count, 1)
        XCTAssertEqual(merged[0].host, "192.168.1.88")
    }
}
