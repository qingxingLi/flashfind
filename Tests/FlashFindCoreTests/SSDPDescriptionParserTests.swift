import XCTest
@testable import FlashFindCore

/// SSDP description.xml 解析与「多来源装配」。
///
/// XML 夹具是**真实抓下来的**（局域网 192.168.1.96 的 DSM 7.2，
/// 取自 `http://192.168.1.96:5000/ssdp/desc-DSM-eth0.xml`），不自己编。
final class SSDPDescriptionParserTests: XCTestCase {

    /// ★ 真实夹具：群晖 DS124 的 description.xml。
    ///
    /// 关键事实：`serialNumber` 是**去冒号的 MAC**（`02005e000096` ↔ `02:00:5e:00:00:96`）。
    /// 这是 `DeviceMerger` 能把 SSDP 证据和 ARP/Synology 证据并成一台的前提。
    private let ds124XML = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
        <specVersion>
            <major>1</major>
            <minor>0</minor>
        </specVersion>
        <device>
            <deviceType>urn:schemas-upnp-org:device:Basic:1</deviceType>
            <friendlyName>demo-synology (DS124)</friendlyName>
            <manufacturer>Synology</manufacturer>
            <manufacturerURL>https://www.synology.com</manufacturerURL>
            <modelDescription>Synology NAS</modelDescription>
            <modelName>DS124</modelName>
            <modelNumber>DS124 7.2-72806</modelNumber>
            <modelType>NAS</modelType>
            <serialNumber>02005e000096</serialNumber>
            <UDN>uuid:73796E6F-6473-6D00-0000-02005e000096</UDN>
            <serviceList>
                <service>
                    <URLBase>http://192.168.1.96:5000</URLBase>
                    <serviceType>urn:schemas-dummy-com:service:Dummy:1</serviceType>
                </service>
            </serviceList>
            <presentationURL>http://192.168.1.96:5000/</presentationURL>
        </device>
    </root>
    """

    /// 真实夹具：一台 TCL 电视（同为 SSDP 应答者，但不是 NAS）。
    private let tvXML = """
    <?xml version="1.0"?>
    <root xmlns="urn:schemas-upnp-org:device-1-0">
    <device>
    <deviceType>urn:schemas-upnp-org:device:MediaRenderer:1</deviceType>
    <friendlyName>FF 75S365C-5475(192.168.1.58)</friendlyName>
    <manufacturer>TCL</manufacturer>
    <modelDescription>Media Renderer</modelDescription>
    <modelName>Windows Media Player</modelName>
    <UDN>uuid:cccc0000-1111-4222-8333-000000000003</UDN>
    </device>
    <URLBase>http://192.168.1.58:49152</URLBase>
    </root>
    """

    // MARK: - 解析

    func testParsesRealDS124Description() {
        let identity = SSDPDescriptionParser.parse(ds124XML)
        XCTAssertEqual(identity.manufacturer, "Synology")
        XCTAssertEqual(identity.modelName, "DS124")
        XCTAssertEqual(identity.modelDescription, "Synology NAS")
        XCTAssertEqual(identity.friendlyName, "demo-synology (DS124)")
        XCTAssertEqual(identity.serialNumber, "02005e000096",
                       "serialNumber 是去冒号 MAC，归并时就靠它跟 ARP 的 MAC 对上")
        XCTAssertEqual(identity.deviceType, "urn:schemas-upnp-org:device:Basic:1")
    }

    /// ★ 解析出来的 SSDP 身份要能直接判成 NAS。
    ///
    /// 这条通道的价值在于**不依赖 mDNS**：那台一条 mDNS 都不广播的 DS1621+ 就靠它。
    func testParsedIdentityIsClassifiedAsNAS() {
        let identity = SSDPDescriptionParser.parse(ds124XML)
        var evidence = DeviceEvidence(host: "192.168.1.96", sources: [.ssdp])
        evidence.ssdp = identity
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas)
    }

    /// 电视也是 SSDP 应答者，但不能被当成 NAS。
    func testTVIsNotMistakenForNAS() {
        let identity = SSDPDescriptionParser.parse(tvXML)
        XCTAssertEqual(identity.manufacturer, "TCL")
        var evidence = DeviceEvidence(host: "192.168.1.58", sources: [.ssdp])
        evidence.ssdp = identity
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .appliance)
    }

    /// 空/烂输入不猜：全部留 nil，而不是造一个默认值出来。
    func testGarbageInputStaysEmpty() {
        let identity = SSDPDescriptionParser.parse("")
        XCTAssertNil(identity.manufacturer)
        XCTAssertNil(identity.modelName)
        XCTAssertNil(identity.serialNumber)
        XCTAssertEqual(SSDPDescriptionParser.parse("not xml at all").manufacturer, nil)
    }

    /// 空标签等于「没有」，不是空字符串。
    func testEmptyTagBecomesNil() {
        let identity = SSDPDescriptionParser.parse("<device><manufacturer></manufacturer></device>")
        XCTAssertNil(identity.manufacturer)
    }

    // MARK: - SERVER 头兜底

    /// ★ XML 拉不到时，`SERVER: Synology/DSM/...` 这一行也要能定性。
    ///
    /// 实测一台群晖的 SSDP LOCATION 指向 `192.168.3.4:5002`——它的另一块网卡，
    /// 从本机连不上（超时）。**这一路是它唯一还能被认出来的机会。**
    func testServerHeaderAloneIdentifiesSynology() {
        XCTAssertEqual(SSDPDescriptionParser.vendorHint(fromServerHeader: "Synology/DSM/192.168.3.4"),
                       .synology)
        var identity = SSDPIdentity()
        identity.server = "Synology/DSM/192.168.3.4"
        var evidence = DeviceEvidence(host: "192.168.1.88", sources: [.ssdp])
        evidence.ssdp = identity
        XCTAssertEqual(DeviceClassifier.classify(evidence).kind, .nas,
                       "description.xml 拉不到，只剩 SERVER 头也要认出群晖")
    }

    func testServerHeaderWithoutVendorYieldsNil() {
        XCTAssertNil(SSDPDescriptionParser.vendorHint(fromServerHeader: "vxWorks/5.5 UPnP/1.0 FAC1900R/1.1"))
        XCTAssertNil(SSDPDescriptionParser.vendorHint(fromServerHeader: nil))
        XCTAssertNil(SSDPDescriptionParser.vendorHint(fromServerHeader: ""))
    }

    // MARK: - 装配

    /// 归并出来的设备要装成界面能用的 `DiscoveredDevice`：名字、端口、类型都对。
    func testMakeDevicesCarriesNamePortAndKind() {
        var synology = DeviceEvidence(host: "192.168.1.88", sources: [.synologyDiscovery])
        synology.synology = SynologyResponse(serverName: "FAKENAS001", dsmHTTPPort: 5002,
                                             dsmHTTPSPort: 5003, model: "DS1621+")
        let merged = DeviceMerger.merge([synology])
        let devices = NetworkDiscovery.makeDevices(from: merged, existing: [])
        XCTAssertEqual(devices.count, 1)
        XCTAssertEqual(devices[0].name, "FAKENAS001")
        XCTAssertEqual(devices[0].host, "192.168.1.88")
        XCTAssertEqual(devices[0].port, 5003, "DSM HTTPS 优于 HTTP")
        XCTAssertEqual(devices[0].kind, .nas)
        XCTAssertEqual(devices[0].model, "DS1621+")
    }

    /// ★ 一个端口证据都没有时，地址行只显示地址——不许显示成 `192.168.1.7:0`。
    func testAddressTextOmitsPortWhenThereIsNoPortEvidence() {
        let arpOnly = DeviceEvidence(host: "192.168.1.7", sources: [.arp])
        let devices = NetworkDiscovery.makeDevices(from: DeviceMerger.merge([arpOnly]), existing: [])
        XCTAssertEqual(devices[0].port, 0)
        XCTAssertEqual(devices[0].addressText, "192.168.1.7")
        XCTAssertEqual(devices[0].kind, .unknown, "只有 ARP 证据不给默认显示资格")
    }

    /// 已在来源列表里的设备要标「已添加」并排到后面。
    func testMakeDevicesMarksAndSortsAlreadyAddedLast() {
        let existing = NASSourceConfig(name: "已添加", vendor: .synology,
                                       host: "192.168.1.96", port: 5001, username: "u")
        func host(_ ip: String) -> DeviceEvidence {
            var item = DeviceEvidence(host: ip, sources: [.synologyDiscovery])
            item.synology = SynologyResponse(serverName: ip, dsmHTTPSPort: 5001)
            return item
        }
        let devices = NetworkDiscovery.makeDevices(
            from: DeviceMerger.merge([host("192.168.1.96"), host("192.168.1.88")]),
            existing: [existing])
        XCTAssertEqual(devices.map(\.host), ["192.168.1.88", "192.168.1.96"], "没添加的排前面")
        XCTAssertTrue(devices[1].alreadyAdded)
        XCTAssertFalse(devices[0].alreadyAdded)
    }

    /// NAS 排在文件服务器前面，文件服务器排在未知前面。
    func testMakeDevicesSortsNASFirst() {
        var nas = DeviceEvidence(host: "192.168.1.2", sources: [.synologyDiscovery])
        nas.synology = SynologyResponse(serverName: "nas", model: "DS124")
        var fileServer = DeviceEvidence(host: "192.168.1.1", sources: [.bonjour])
        fileServer.serviceTypes = ["_smb._tcp"]
        let unknown = DeviceEvidence(host: "192.168.1.3", sources: [.arp])
        let devices = NetworkDiscovery.makeDevices(
            from: DeviceMerger.merge([unknown, fileServer, nas]), existing: [])
        XCTAssertEqual(devices.map(\.kind), [.nas, .fileServer, .unknown])
    }
}
