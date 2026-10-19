import XCTest
@testable import FlashFindCore

/// Synology 官方发现协议编解码。
///
/// 测试向量是**真实抓包**： 在用户局域网（192.168.1.0/24）向
/// `255.255.255.255:9999` 发最小 query，两台群晖的应答原样存盘于
/// ``。
///
/// 用真报文而不是手搓字节：协议里只有真报文能暴露的细节太多了——
/// `0x49` 是**数值**不是字符串（按字符串解出来是乱码）、`packet_type`
/// 在一次响应里出现两次、服务位图是 8 字节值、字段顺序两台设备还不一样。
final class SynologyDiscoveryPacketTests: XCTestCase {

    /// 192.168.1.88（DS1621+，DSM 7.3.2，**一条 mDNS 都不广播**的那台）。
    private let ds1621Hex = """
    1234567853594e4f191130323a30303a35653a30303a30303a38381204c0a80158100400000000\
    1304ffffff001804010000001504727272721404c0a80101a30400000000010402000000110a46\
    414b454e41533030311e04c0a8015cc00d534e46414b4544534d30303031730a4e464b45444d30\
    303031a40400000201a6047800000050005200540400000000560058005a005c00510053005504\
    00000000570059005b005d00a704010000004804010000004904f94f01007705372e332e329004\
    0400000078074453313632312b701473796e6f6c6f67795f76313030305f313632312bc1034453\
    4d8004000000007b040000000071040100000075048a13000076048b130000b008bf0200000000\
    0000b1080000000000000000b8088500000000000000b9080000000000000000
    """

    /// 192.168.1.96（DS124，DSM 7.2.2，有 mDNS 的那台）。
    private let ds124Hex = """
    1234567853594e4f191130323a30303a35653a30303a30303a39361204c0a801601004000000\
    001304ffffff001804010000001504727272721404c0a80101a3040000000001040200000011\
    0d64656d6f2d73796e6f6c6f67791e04c0a8015cc00d534e46414b4544534d30303032730a4e46\
    4b45444d30303032a40400000201a6047800000050005200540400000000560058005a005c00\
    51005300550400000000570059005b005d00a704010000004804010000004904661c01007705\
    372e322e3290040000000078054453313234701773796e6f6c6f67795f72746431363139625f\
    6473313234c10344534d8004000000007b040000000071040000000075048813000076048913\
    0000b0083f02000000000000b1080000000000000000b8080300000000000000b90800000000\
    00000000
    """

    private func data(fromHex hex: String) -> Data {
        var result = Data()
        var iterator = hex.makeIterator()
        while let high = iterator.next(), let low = iterator.next() {
            guard let byte = UInt8(String([high, low]), radix: 16) else { continue }
            result.append(byte)
        }
        return result
    }

    // MARK: - query

    /// ★ query 就是协议规定的最小 20 字节：magic + 版本 TLV + query TLV。
    ///
    /// 少一个字段 NAS 就不应答（实测最小 query 刚好能唤醒群晖）；
    /// 多带 0x7C/0xC4/0xC5 反而会逼出加密回复，字段全读不出来。
    func testBuildQueryIsTheMinimalTwentyBytePacket() {
        let query = SynologyDiscoveryPacket.buildQuery()
        XCTAssertEqual(query.count, 20)
        XCTAssertEqual(query.prefix(8), SynologyDiscoveryPacket.magic)
        // 12 34 56 78 53 59 4e 4f | a4 04 00 00 02 01 | 01 04 01 00 00 00
        let expected = Data([0x12, 0x34, 0x56, 0x78, 0x53, 0x59, 0x4E, 0x4F,
                             0xA4, 0x04, 0x00, 0x00, 0x02, 0x01,
                             0x01, 0x04, 0x01, 0x00, 0x00, 0x00])
        XCTAssertEqual(query, expected)
    }

    // MARK: - 真实响应

    /// ★ 真实 DS1621+ 响应：这台**不广播任何 mDNS**，全靠这个协议认出它。
    func testParseRealDS1621PlusResponse() throws {
        let response = try XCTUnwrap(
            SynologyDiscoveryPacket.parseResponse(data(fromHex: ds1621Hex), responderAddress: "192.168.1.88"))
        XCTAssertEqual(response.model, "DS1621+")
        XCTAssertEqual(response.serial, "SNFAKEDSM0001")
        XCTAssertEqual(response.mac, "02:00:5E:00:00:88")
        XCTAssertEqual(response.serverName, "FAKENAS001")
        XCTAssertEqual(response.ip, "192.168.1.88")
        XCTAssertEqual(response.netmask, "255.255.255.0")
        XCTAssertEqual(response.gateway, "192.168.1.1")
        XCTAssertEqual(response.clientIPSeenByNAS, "192.168.1.92")
        XCTAssertEqual(response.dsmVersion, "7.3.2")
        XCTAssertEqual(response.dsmBuild, 86009)
        XCTAssertEqual(response.platform, "synology_v1000_1621+")
        XCTAssertEqual(response.product, "DSM")
        XCTAssertEqual(response.shortSerialFragment, "NFKEDM0001")
        XCTAssertEqual(response.state, 1, "1 = Ready")
        XCTAssertEqual(response.ipAssignment, 1, "1 = 手动")
        XCTAssertEqual(response.dsmHTTPPort, 5002, "这台把 DSM 开在非标准口 5002/5003")
        XCTAssertEqual(response.dsmHTTPSPort, 5003)
        XCTAssertEqual(response.packetType, 2, "2 = 响应")
        XCTAssertEqual(response.responderAddress, "192.168.1.88")
        XCTAssertFalse(response.encrypted)
    }

    /// 真实 DS124 响应（有 mDNS 的那台，DSM 在标准口 5000/5001）。
    func testParseRealDS124Response() throws {
        let response = try XCTUnwrap(
            SynologyDiscoveryPacket.parseResponse(data(fromHex: ds124Hex), responderAddress: "192.168.1.96"))
        XCTAssertEqual(response.model, "DS124")
        XCTAssertEqual(response.serial, "SNFAKEDSM0002")
        XCTAssertEqual(response.mac, "02:00:5E:00:00:96")
        XCTAssertEqual(response.serverName, "demo-synology")
        XCTAssertEqual(response.dsmVersion, "7.2.2")
        XCTAssertEqual(response.dsmBuild, 72806)
        XCTAssertEqual(response.platform, "synology_rtd1619b_ds124")
        XCTAssertEqual(response.dsmHTTPPort, 5000)
        XCTAssertEqual(response.dsmHTTPSPort, 5001)
    }

    /// ★ `0x49` 是 **u32 build 号**，不是字符串。
    ///
    /// 按 UTF-8 字符串解 `f9 4f 01 00` 得到的是乱码 "�O "。
    /// 这条锁住类型判断——改回字符串解析，上面两条真实报文测试立刻变红。
    func testBuildNumberIsNumericNotText() throws {
        let response = try XCTUnwrap(
            SynologyDiscoveryPacket.parseResponse(data(fromHex: ds1621Hex)))
        XCTAssertEqual(response.dsmBuild, 86009)
    }

    /// 8 字节的 u32 字段（服务位图）不能把解析带偏。
    func testEightByteNumericFieldDoesNotBreakTheWalk() throws {
        // 真实报文里 0xB0/0xB1/0xB8/0xB9 都是 len=8；走到它们之后的
        // 0x75/0x76（端口）仍然要解析对，说明 TLV 步进没被带偏。
        let response = try XCTUnwrap(
            SynologyDiscoveryPacket.parseResponse(data(fromHex: ds1621Hex)))
        XCTAssertEqual(response.dsmHTTPPort, 5002)
        XCTAssertEqual(response.dsmHTTPSPort, 5003)
    }

    // MARK: - 边界

    /// ★ 自己发出去的 query 会环回，必须丢掉——否则本机会被自己列成一台 NAS。
    func testQueryEchoIsDropped() {
        let query = SynologyDiscoveryPacket.buildQuery()
        XCTAssertNil(SynologyDiscoveryPacket.parseResponse(query),
                     "packet_type == 1 的是 query 不是响应")
    }

    /// 加密报文（magic `12 34 55 66 SYNO`）字段读不了，但足以证明对面是群晖。
    func testEncryptedMagicIsRecognizedAsSynology() {
        var packet = SynologyDiscoveryPacket.encryptedMagic
        packet.append(contentsOf: [0x01, 0x04, 0x02, 0x00, 0x00, 0x00])   // packet_type = 2
        let response = try? XCTUnwrap(SynologyDiscoveryPacket.parseResponse(packet))
        XCTAssertNotNil(response)
        XCTAssertEqual(response?.encrypted, true)
        XCTAssertNil(response?.model, "加密报文里没有可读字段")
    }

    /// 不是我们的协议 / 太短 / 空 → `nil`，不许猜。
    func testForeignOrShortPacketsReturnNil() {
        XCTAssertNil(SynologyDiscoveryPacket.parseResponse(Data()))
        XCTAssertNil(SynologyDiscoveryPacket.parseResponse(Data([0x12, 0x34])))
        XCTAssertNil(SynologyDiscoveryPacket.parseResponse(Data("GET / HTTP/1.1\r\n\r\n".utf8)))
        // 明文 magic 对但一个 TLV 都没有：不是响应也不是 query，按「无字段」收下也行，
        // 但不该崩。这里只要求不崩且不返回假数据。
        let bare = SynologyDiscoveryPacket.parseResponse(SynologyDiscoveryPacket.magic)
        XCTAssertNil(bare?.model)
    }

    /// 报文被截断时保住已解析的字段，不整体判废。
    ///
    /// 路由器/防火墙可能动手脚；前面已经解析出来的型号/MAC 仍然可信。
    func testTruncatedPacketKeepsParsedFields() throws {
        let full = data(fromHex: ds1621Hex)
        let cut = full.prefix(120)   // MAC(0x19)/IP(0x12)/serverName(0x11)/serial(0xC0) 都在前 120 字节里
        let response = try XCTUnwrap(SynologyDiscoveryPacket.parseResponse(Data(cut)))
        XCTAssertEqual(response.mac, "02:00:5E:00:00:88")
        XCTAssertEqual(response.serverName, "FAKENAS001")
        XCTAssertEqual(response.serial, "SNFAKEDSM0001", "serial 落在前 120 字节里，截到这儿还保得住")
        XCTAssertNil(response.model, "model(0x78) 在后半段，被截掉了就是没有——不许猜")
    }

    /// 未知字段 id 直接跳过，不当成数据也不崩。
    func testUnknownFieldIDsAreIgnored() throws {
        var packet = SynologyDiscoveryPacket.magic
        packet.append(contentsOf: [0x99, 0x03, 0xAA, 0xBB, 0xCC])       // 未知字段，len 3
        packet.append(contentsOf: [0x78, 0x06])                          // model，len 6
        packet.append(Data("DS923+".utf8))
        let response = try XCTUnwrap(SynologyDiscoveryPacket.parseResponse(packet))
        XCTAssertEqual(response.model, "DS923+")
    }

    /// 空字符串字段 → `nil`（「没有」和「空的」要分开）。
    func testEmptyStringFieldBecomesNil() throws {
        var packet = SynologyDiscoveryPacket.magic
        packet.append(contentsOf: [0x01, 0x04, 0x02, 0x00, 0x00, 0x00])  // packet_type = 2
        packet.append(contentsOf: [0x78, 0x00])                          // model，len 0
        let response = try XCTUnwrap(SynologyDiscoveryPacket.parseResponse(packet))
        XCTAssertNil(response.model)
        XCTAssertEqual(response.packetType, 2)
    }

    /// 端口字段也要能当 u32 读（4 字节小端）。
    func testPortsAreLittleEndianU32() throws {
        var packet = SynologyDiscoveryPacket.magic
        packet.append(contentsOf: [0x01, 0x04, 0x02, 0x00, 0x00, 0x00])
        packet.append(contentsOf: [0x76, 0x04, 0x8B, 0x13, 0x00, 0x00])  // 5003
        let response = try XCTUnwrap(SynologyDiscoveryPacket.parseResponse(packet))
        XCTAssertEqual(response.dsmHTTPSPort, 5003)
    }

    /// 响应里带来源地址：多网口设备自报的 `ip` 未必是报文源，合并时以源为准。
    func testResponderAddressIsRecordedSeparatelyFromSelfReportedIP() throws {
        let response = try XCTUnwrap(
            SynologyDiscoveryPacket.parseResponse(data(fromHex: ds1621Hex), responderAddress: "192.168.3.4"))
        XCTAssertEqual(response.ip, "192.168.1.88", "自报 IP")
        XCTAssertEqual(response.responderAddress, "192.168.3.4", "报文源")
    }
}
