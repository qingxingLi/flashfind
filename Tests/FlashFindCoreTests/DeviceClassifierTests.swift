import XCTest
@testable import FlashFindCore

/// 设备分类。
///
/// 需求来源：「附近设备」列表里混着同事的电脑、打印机，NAS 不好找
/// ——问能不能像 macOS 访达那样认出谁是 NAS。
///
/// 访达靠的是 `_device-info._tcp` 的 TXT `model=` 字段：实测局域网里那台群晖
/// `demo-synology` 报的是 `model=Xserve`，而 MacBook Air 报的是机型标识符。
///
/// 判定用的证据来源共五路（Synology 官方协议 / SSDP / mDNS / ARP /
/// TCP 探测），判定优先级与实测依据见 `DeviceClassifier` 的文档。
/// 这些用例锁的就是这套判定，**每条输入都对得上实测或明确的出处**。
final class DeviceClassifierTests: XCTestCase {

    // MARK: - 型号：NAS

    func testXserveModelIsTreatedAsNAS() {
        // 实测：群晖 demo-synology 的 _device-info TXT model=Xserve。
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "Xserve"), .nas)
        XCTAssertEqual(DeviceClassifier.classify(model: "Xserve", serviceTypes: ["_smb._tcp"]), .nas)
    }

    func testRackMacIsTreatedAsNASNotAsAMac() {
        // RackMac 名字里有 Mac，但它是机架式服务器——顺序反了会误判成个人电脑。
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "RackMac3,1"), .nas)
    }

    func testModelEndingWithServerIsNAS() {
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "MacminiServer"), .nas)
    }

    // MARK: - 型号：电脑

    func testAppleComputerModelsAreComputers() {
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "MacBookAir10,1"), .computer)
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "Macmini9,1"), .computer)
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "MacPro7,1"), .computer)
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "iMac21,1"), .computer)
    }

    func testModelMatchingIsCaseInsensitive() {
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "xserve"), .nas)
        XCTAssertEqual(DeviceClassifier.kind(fromModel: "macbookair10,1"), .computer)
    }

    func testEmptyOrWhitespaceModelYieldsNothing() {
        XCTAssertNil(DeviceClassifier.kind(fromModel: nil))
        XCTAssertNil(DeviceClassifier.kind(fromModel: ""))
        XCTAssertNil(DeviceClassifier.kind(fromModel: "   "))
    }

    func testUnrecognizedModelYieldsNothingSoCallerCanFallBack() {
        // 认不出必须返回 nil（让调用方回落到服务类型），不能直接判成「不是 NAS」。
        XCTAssertNil(DeviceClassifier.kind(fromModel: "DS1621plus"))
        XCTAssertNil(DeviceClassifier.kind(fromModel: "RaspberryPi"))
    }

    // MARK: - 服务类型

    func testSynologyServiceWinsEvenWithoutModel() {
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_synology-dsm._tcp"]), .nas)
    }

    func testSMBAloneMakesAFileServerNotANAS() {
        // ★ SMB 只证明「这台在提供文件共享」，证明不了它是 NAS。
        // Mac 开了「文件共享」也会广播 _smb._tcp——只看 SMB 会把每台 Mac 都列成 NAS。
        // 但它确实在提供文件服务，所以是 fileServer 而不是 unknown：
        // 默认列表照样展示，只是标签从「未知设备」变成「文件服务器」。
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_smb._tcp"]), .fileServer)
    }

    func testSMBWithComputerModelIsAComputer() {
        XCTAssertEqual(
            DeviceClassifier.classify(model: "MacBookAir10,1", serviceTypes: ["_smb._tcp"]),
            .computer)
    }

    func testPrinterServicesAreAppliances() {
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_ipp._tcp"]), .appliance)
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_pdl-datastream._tcp"]), .appliance)
    }

    func testAppleConsumerServicesAreComputers() {
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_airplay._tcp"]), .computer)
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: ["_companion-link._tcp"]), .computer)
    }

    func testServiceTypesAreNormalizedBeforeMatching() {
        // NetService 给的类型可能带尾点，也可能大写。
        XCTAssertEqual(
            DeviceClassifier.classify(model: nil, serviceTypes: ["_SYNOLOGY-DSM._TCP."]),
            .nas)
        XCTAssertEqual(
            DeviceClassifier.classify(model: nil, serviceTypes: ["_AirPlay._tcp."]),
            .computer)
    }

    func testNothingToGoOnIsUnknown() {
        XCTAssertEqual(DeviceClassifier.classify(model: nil, serviceTypes: []), .unknown)
    }

    // MARK: - 证据接口：Synology 官方协议

    /// ★ 有 Synology 自述就是 NAS，其它证据一概不需要。
    ///
    /// 这是 `.88`（一条 mDNS 都不广播的 DS1621+）唯一的识别通道。
    func testSynologyResponseIsNASWithoutAnyOtherEvidence() {
        var evidence = DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery])
        evidence.synology = SynologyResponse(dsmVersion: "7.3.2", model: "DS1621+")
        let result = DeviceClassifier.classify(evidence)
        XCTAssertEqual(result.kind, .nas)
        XCTAssertTrue(result.reason.contains("DS1621+"), "依据里要说得上型号")
    }

    /// Synology 自述优先于任何其它证据——即使同时有电脑型号和文件服务。
    func testSynologyResponseBeatsEverythingElse() {
        var evidence = DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery, .bonjour])
        evidence.synology = SynologyResponse(model: "DS124")
        evidence.models = ["MacBookAir10,1"]     // 荒谬组合，但优先级必须明确
        evidence.serviceTypes = ["_smb._tcp", "_ipp._tcp"]
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas)
    }

    // MARK: - 证据接口：SSDP

    /// SSDP description.xml 明写厂商——不依赖 mDNS 的第二条通道。
    func testSSDPManufacturerIsNAS() {
        var evidence = DeviceEvidence(host: "192.168.1.88", sources: [.ssdp])
        evidence.ssdp = SSDPIdentity(manufacturer: "Synology", modelName: "DS1621+",
                                     modelDescription: "Synology NAS")
        let result = DeviceClassifier.classify(evidence)
        XCTAssertEqual(result.kind, .nas)
        XCTAssertTrue(result.reason.contains("Synology"))
    }

    func testSSDPModelDescriptionContainingNASIsNAS() {
        var evidence = DeviceEvidence(host: "192.168.1.10", sources: [.ssdp])
        evidence.ssdp = SSDPIdentity(manufacturer: "某厂商", modelDescription: "Home NAS Storage")
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas)
    }

    func testSSDPMediaRendererIsAppliance() {
        var evidence = DeviceEvidence(host: "192.168.1.58", sources: [.ssdp])
        evidence.ssdp = SSDPIdentity(modelDescription: "Windows Media Renderer",
                                     deviceType: "urn:schemas-upnp-org:device:MediaRenderer:1")
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .appliance)
    }

    func testSSDPInternetGatewayIsAppliance() {
        // 实测：本网段路由器（.89）报的就是 InternetGatewayDevice。
        var evidence = DeviceEvidence(host: "192.168.1.89", sources: [.ssdp])
        evidence.ssdp = SSDPIdentity(modelName: "FAC1900R",
                                     deviceType: "urn:schemas-upnp-org:device:InternetGatewayDevice:1")
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .appliance)
    }

    func testSSDPWithoutNASMarkersStaysUnknown() {
        var evidence = DeviceEvidence(host: "192.168.1.50", sources: [.ssdp])
        evidence.ssdp = SSDPIdentity(server: "SomeOS/1.0 UPnP/1.1", modelDescription: "Digital Camera")
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .unknown)
    }

    // MARK: - 证据接口：mDNS

    func testDiskStationAndQNAPServicesAreNAS() {
        // 来自 MyNAS（chenqi92/my-nas）浏览清单，本网未实测到，但能直接认出厂家。
        for type in ["_diskstation._tcp", "_qnap._tcp"] {
            var evidence = DeviceEvidence(host: "192.168.1.10", sources: [.bonjour])
            evidence.serviceTypes = [type]
            XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas, "\(type) 应当直接认出 NAS")
        }
    }

    func testWebDAVsServiceIsFileServer() {
        // 实测群晖广播的是 _webdavs（5006），不是 _webdav。
        var evidence = DeviceEvidence(host: "192.168.1.96", sources: [.bonjour])
        evidence.serviceTypes = ["_webdavs._tcp"]
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .fileServer)
    }

    func testEveryFileServiceTypeMakesAFileServer() {
        for type in ["_smb._tcp", "_webdav._tcp", "_webdavs._tcp", "_afpovertcp._tcp",
                     "_ftp._tcp", "_sftp-ssh._tcp", "_nfs._tcp"] {
            var evidence = DeviceEvidence(host: "192.168.1.10", sources: [.bonjour])
            evidence.serviceTypes = [type]
            XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .fileServer,
                           "\(type) 是文件服务，应当够得上「文件服务器」")
        }
    }

    // MARK: - 证据接口：优先级

    /// ★ 电脑型号必须先于文件服务：Mac 开了文件共享也广播 `_smb`。
    ///
    /// 顺序反了，用户那台 MacBook Air 就会以「文件服务器」的身份挤进默认列表。
    func testComputerModelBeatsFileService() {
        var evidence = DeviceEvidence(host: "192.168.1.92", sources: [.bonjour])
        evidence.models = ["MacBookAir10,1"]
        evidence.serviceTypes = ["_smb._tcp"]
        let result = DeviceClassifier.classify(evidence)
        XCTAssertEqual(result.kind, .computer)
        XCTAssertTrue(result.reason.contains("MacBookAir10,1"))
    }

    func testServerModelBeatsFileService() {
        var evidence = DeviceEvidence(host: "192.168.1.96", sources: [.bonjour])
        evidence.models = ["Xserve"]
        evidence.serviceTypes = ["_smb._tcp"]
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas)
    }

    /// 多个型号时先扫服务器特征再扫电脑特征，不取决于集合遍历顺序。
    func testServerFeatureWinsAcrossMultipleModels() {
        var evidence = DeviceEvidence(host: "192.168.1.96", sources: [.bonjour])
        evidence.models = ["MacBookAir10,1", "Xserve"]   // 顺序无关
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas)
    }

    // MARK: - 证据接口：不给默认资格的

    /// ★ 端口证据**不产生默认显示资格**。
    ///
    /// 实测本网段 20+ 台设备开着 445，其中绝大多数与文件共享无关；
    /// 拿「端口开着」当身份证据，默认列表会被无关设备填满。
    func testPortEvidenceNeverGrantsDefaultEligibility() {
        var evidence = DeviceEvidence(host: "192.168.1.9", sources: [.arp, .tcpProbe])
        evidence.openPorts = [445, 5005]
        let result = DeviceClassifier.classify(evidence)
        XCTAssertEqual(result.kind, .unknown)
        XCTAssertFalse(result.kind.shownInDefaultList)
        XCTAssertTrue(result.reason.contains("端口"))
    }

    /// 只有 ARP 在线 → 未知。实测 111 台在线主机里大半是这种。
    func testARPOnlyIsUnknown() {
        let evidence = DeviceEvidence(host: "192.168.1.7", mac: "02:00:5E:00:00:07", sources: [.arp])
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .unknown)
    }

    /// 每条判定都要带依据——排查误判时得能看出是哪条证据起了作用。
    func testEveryClassificationCarriesAReason() {
        let cases: [DeviceEvidence] = {
            var synology = DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery])
            synology.synology = SynologyResponse(model: "DS1621+")
            var ssdp = DeviceEvidence(host: "192.168.1.89", sources: [.ssdp])
            ssdp.ssdp = SSDPIdentity(manufacturer: "Synology", modelDescription: "Synology NAS")
            var smb = DeviceEvidence(host: "192.168.1.92", sources: [.bonjour])
            smb.serviceTypes = ["_smb._tcp"]
            return [synology, ssdp, smb, DeviceEvidence(host: "192.168.1.7", sources: [.arp])]
        }()
        for evidence in cases {
            XCTAssertFalse(DeviceClassifier.classify(evidence).reason.isEmpty,
                           "\(evidence.host) 的判定必须带依据")
        }
    }

    // MARK: - 列表筛选用

    func testDefaultListKeepsNASAndFileServerOnly() {
        // 规则：默认只展示被明确识别为 NAS/文件服务器的设备，
        // 所有未知网络设备只放到「显示全部设备」里。
        XCTAssertTrue(DeviceKind.nas.shownInDefaultList)
        XCTAssertTrue(DeviceKind.fileServer.shownInDefaultList)
        XCTAssertFalse(DeviceKind.computer.shownInDefaultList)
        XCTAssertFalse(DeviceKind.appliance.shownInDefaultList)
        XCTAssertFalse(DeviceKind.unknown.shownInDefaultList)
    }

    func testUnknownIsTitledAsUnknownRatherThanSomeSpecificKind() {
        // 界面不许把认不出的写成某个具体类型——那等于替用户下了个他没法核对的判断。
        XCTAssertEqual(DeviceKind.unknown.title, "未知设备")
    }

    func testFileServerIsTitledAsFileServer() {
        XCTAssertEqual(DeviceKind.fileServer.title, "文件服务器")
    }
}
