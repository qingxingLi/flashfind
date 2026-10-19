import Foundation

/// Synology 官方发现协议里 NAS 回给我们的那份自述。
///
/// ## 为什么值得单独立一个类型
///
/// 实测：一台群晖 DS1621+ **一条 mDNS 都不广播**，
/// TCP 探测只能告诉我们「有台机器开着 445/5005」——
/// 告诉不了我们它是谁、是什么型号、DSM 开在哪个端口。而这个协议的响应里
/// 型号、序列号、MAC、DSM 端口**全是设备自己报的**，识别从此不靠猜。
///
/// 字段名与协议字段一一对应，出处见 `SynologyDiscoveryPacket` 的文档。
public struct SynologyResponse: Equatable, Sendable {

    /// 报文类型：query=1，响应=2。自己发出去的 query 会环回，靠这个值丢掉。
    public var packetType: UInt32?

    /// 服务器名（hostname），如 `demo-synology` / `FAKENAS001`。
    public var serverName: String?

    /// 设备自报的 IP。
    public var ip: String?

    public var netmask: String?

    public var gateway: String?

    /// DNS。
    public var dns: String?

    /// IP 获取方式：1=手动，0=DHCP。
    public var ipAssignment: UInt32?

    /// MAC 地址，形如 `02:00:5E:00:00:88`。
    public var mac: String?

    /// NAS 看到的查询方 IP（多网卡时有意义）。
    public var clientIPSeenByNAS: String?

    /// 状态：1 = Ready。
    public var state: UInt32?

    /// DSM build 号（**数值**，实测 DS1621+ 报 85977、DS124 报 73318）。
    public var dsmBuild: UInt32?

    /// 平台标识，如 `synology_v1000_1621+`。
    public var platform: String?

    /// 序列号片段（serial 去掉头尾的一截）。
    public var shortSerialFragment: String?

    /// DSM HTTP 端口（实测 DS1621+ 是 **5002**，不是标准的 5000）。
    public var dsmHTTPPort: Int?

    /// DSM HTTPS 端口（实测 DS1621+ 是 **5003**，不是标准的 5001）。
    public var dsmHTTPSPort: Int?

    /// DSM 版本，如 `7.3.2`。
    public var dsmVersion: String?

    /// 型号，如 `DS1621+` / `DS124`。
    public var model: String?

    /// 序列号，如 `SNFAKEDSM0001`。
    public var serial: String?

    /// 产品名，如 `DSM`。
    public var product: String?

    /// 报文实际来源地址（UDP 源）。
    ///
    /// 与 `ip` 分开记：多网口设备自报的 `ip` 未必是响应的来源，
    /// 而合并证据时**必须以报文源为准**（那是我们真正收到回复的地址）。
    public var responderAddress: String?

    /// 是不是加密报文（magic `12 34 55 66 SYNO`）。
    ///
    /// 是的话字段解析不出来，但**足以证明对面是群晖**——这个 magic 只有
    /// Synology 用。带上 0x7C/0xC4/0xC5 才会逼出加密回复，我们的 query 不带。
    public var encrypted: Bool

    public init(packetType: UInt32? = nil,
                serverName: String? = nil,
                ip: String? = nil,
                netmask: String? = nil,
                gateway: String? = nil,
                dns: String? = nil,
                ipAssignment: UInt32? = nil,
                mac: String? = nil,
                clientIPSeenByNAS: String? = nil,
                state: UInt32? = nil,
                dsmBuild: UInt32? = nil,
                platform: String? = nil,
                shortSerialFragment: String? = nil,
                dsmHTTPPort: Int? = nil,
                dsmHTTPSPort: Int? = nil,
                dsmVersion: String? = nil,
                model: String? = nil,
                serial: String? = nil,
                product: String? = nil,
                responderAddress: String? = nil,
                encrypted: Bool = false) {
        self.packetType = packetType
        self.serverName = serverName
        self.ip = ip
        self.netmask = netmask
        self.gateway = gateway
        self.dns = dns
        self.ipAssignment = ipAssignment
        self.mac = mac
        self.clientIPSeenByNAS = clientIPSeenByNAS
        self.state = state
        self.dsmBuild = dsmBuild
        self.platform = platform
        self.shortSerialFragment = shortSerialFragment
        self.dsmHTTPPort = dsmHTTPPort
        self.dsmHTTPSPort = dsmHTTPSPort
        self.dsmVersion = dsmVersion
        self.model = model
        self.serial = serial
        self.product = product
        self.responderAddress = responderAddress
        self.encrypted = encrypted
    }

    /// 「这份自述有多完整」——合并同主机的多份证据时，信息多的那份胜出。
    var completeness: Int {
        var score = 0
        for value in [model, serial, mac, serverName, dsmVersion, platform] {
            if value != nil { score += 1 }
        }
        if dsmHTTPSPort != nil { score += 1 }
        if dsmHTTPPort != nil { score += 1 }
        return score
    }
}

/// Synology 官方发现协议（Synology Assistant 用的那个）的编解码。
///
/// ## 协议要点（依据 `kai-h/synology-finder` PROTOCOL.md）
///
/// * UDP **9999**，IPv4；query 广播到 `255.255.255.255:9999`（子网广播 `x.x.x.255` 也可）；
/// * 报文头 8 字节明文 magic：`12 34 56 78 53 59 4E 4F`（即 `\x12\x34\x56\x78SYNO`）；
/// * 头之后是 TLV 序列：`[id u8][len u8][value len 字节]`；
/// * 最小可应答 query：`0xA4 = u32le 0x01020000`（协议版本）+ `0x01 = u32le 1`（query）；
/// * **不要**带 `0x7C`（目标 MAC 过滤）与 `0xC4`/`0xC5`（会逼 NAS 回加密报文）；
/// * 客户端必须 **bind 9999**（`SO_REUSEADDR|SO_REUSEPORT|SO_BROADCAST`）：
///   NAS 同时回 `255.255.255.255:9999` 广播与 `<查询方>:9999` 单播，与 query 源端口无关；
/// * 响应约 1~3s 后到达，且**成对**（广播+单播）两份相同内容——同一台设备会收到两次，
///   按 IP 去重即可；
/// * 自己 query 的环回要丢掉：`packet_type == 1` 的是 query，`== 2` 的才是响应；
/// * 9998 / 9997 **不应答** discovery（实测，发现只用 9999）。
///
/// ## 只做 discovery
///
/// 这个类型只负责「发现+自述」，**不做任何配置/管理命令**——那是另一条产品线的事。
public enum SynologyDiscoveryPacket {

    public static let discoveryPort: UInt16 = 9999

    /// 明文报文 magic。
    public static let magic = Data([0x12, 0x34, 0x56, 0x78, 0x53, 0x59, 0x4E, 0x4F])

    /// 加密报文 magic（`12 34 55 66 SYNO`）。见到它就知道对面是群晖，但字段读不了。
    public static let encryptedMagic = Data([0x12, 0x34, 0x55, 0x66, 0x53, 0x59, 0x4E, 0x4F])

    /// 构造最小可应答 query（20 字节）。
    ///
    /// 实测两台群晖（DS124 / DS1621+）都只靠这两个字段就应答，无需 OEM 那种
    /// 157 字节的长 query——而长 query 里的 0x7C/0xC4/0xC5 反而会逼出加密回复。
    public static func buildQuery() -> Data {
        var packet = magic
        packet.append(tlv(0xA4, u32(0x01020000)))   // 协议版本
        packet.append(tlv(0x01, u32(1)))            // query
        return packet
    }

    /// 解析一份收到的报文。不是我们的协议、或太短 → `nil`。
    ///
    /// - Parameters:
    ///   - data: 收到的 UDP 报文。
    ///   - responderAddress: 报文源地址（UDP from）。合并证据时以它为准。
    /// - Returns: 解析结果；**自己 query 的环回返回 `nil`**。
    public static func parseResponse(_ data: Data, responderAddress: String? = nil) -> SynologyResponse? {
        guard data.count >= magic.count else { return nil }
        let header = data.prefix(magic.count)

        // 加密回复：字段读不了，但足以证明对面是群晖。
        if header == encryptedMagic {
            return SynologyResponse(responderAddress: responderAddress, encrypted: true)
        }
        guard header == magic else { return nil }

        var response = SynologyResponse(responderAddress: responderAddress)
        var index = data.startIndex + magic.count
        let end = data.endIndex

        while index + 2 <= end {
            let field = data[index]
            let length = Int(data[index + 1])
            index += 2
            // 长度越界 = 报文被截断：保住已解析出来的字段，不整体判废。
            // （实测报文 305~308 字节，UDP 一般不截；但路由器/防火墙会动手脚。）
            guard index + length <= end else { break }
            let value = data[index..<(index + length)]
            index += length
            apply(field: field, value: value, to: &response)
        }

        // 自己发出去的 query 会环回回来，那不是响应。
        if response.packetType == 1 { return nil }
        return response
    }

    // MARK: - 内部

    private static func tlv(_ field: UInt8, _ value: Data) -> Data {
        var out = Data([field, UInt8(value.count)])
        out.append(value)
        return out
    }

    private static func u32(_ value: UInt32) -> Data {
        let little = value.littleEndian
        return Data([UInt8(little & 0xFF),
                     UInt8((little >> 8) & 0xFF),
                     UInt8((little >> 16) & 0xFF),
                     UInt8((little >> 24) & 0xFF)])
    }

    private static func apply(field: UInt8, value: Data, to response: inout SynologyResponse) {
        switch field {
        case 0x01: response.packetType = u32Value(value)
        case 0x11: response.serverName = stringValue(value)
        case 0x12: response.ip = ipValue(value)
        case 0x13: response.netmask = ipValue(value)
        case 0x14: response.gateway = ipValue(value)
        case 0x15: response.dns = ipValue(value)
        case 0x18: response.ipAssignment = u32Value(value)
        // MAC 统一成**大写**十六进制：NAS 自报的是小写（`02:00:5e:00:00:88`），
        // ARP 表给的也是小写，而界面上按惯例显示大写。大小写只影响显示——
        // `DeviceMerger.normalizeKey` 比对时会去掉非字母数字并转小写。
        case 0x19: response.mac = stringValue(value).map { Self.canonicalMAC($0) }
        case 0x1E: response.clientIPSeenByNAS = ipValue(value)
        case 0x48: response.state = u32Value(value)
        // 0x49 是 **u32 build 号**，不是字符串：按字符串解会得到乱码
        // （实测 DS1621+ 的 4 字节 f9 4f 01 00 解成 UTF-8 是 "�O "）。
        case 0x49: response.dsmBuild = u32Value(value)
        case 0x70: response.platform = stringValue(value)
        case 0x73: response.shortSerialFragment = stringValue(value)
        case 0x75: response.dsmHTTPPort = u32Value(value).map(Int.init)
        case 0x76: response.dsmHTTPSPort = u32Value(value).map(Int.init)
        case 0x77: response.dsmVersion = stringValue(value)
        case 0x78: response.model = stringValue(value)
        case 0xC0: response.serial = stringValue(value)
        case 0xC1: response.product = stringValue(value)
        default:
            // 0x10/0x50~0x5D/0x71/0x7B/0x80/0x90/0xA3/0xA6/0xA7/0xB0/0xB1/0xB8/0xB9
            // 这些字段要么是服务位图、要么是空串占位，发现场景用不到——不猜。
            break
        }
    }

    /// MAC 规整成大写十六进制。不是 MAC 形状的原样返回，不猜。
    static func canonicalMAC(_ raw: String) -> String {
        let hexOnly = raw.filter { $0.isHexDigit }
        // 只有「12 个十六进制字符」这种常见写法才重排，其它保持原样。
        guard hexOnly.count == 12 else { return raw.uppercased() }
        var pairs: [String] = []
        var index = hexOnly.startIndex
        for _ in 0..<6 {
            let next = hexOnly.index(index, offsetBy: 2)
            pairs.append(String(hexOnly[index..<next]).uppercased())
            index = next
        }
        return pairs.joined(separator: ":")
    }

    /// TLV 里的 u32（小端）。字段实际是 4 或 8 字节（位图），取前 4 字节即可。
    private static func u32Value(_ value: Data) -> UInt32? {
        guard value.count >= 4 else { return nil }
        let bytes = value.prefix(4)
        return bytes.enumerated().reduce(UInt32(0)) { partial, pair in
            partial | (UInt32(pair.element) << (8 * pair.offset))
        }
    }

    /// TLV 里的 IPv4（4 字节 → 点分十进制）。
    private static func ipValue(_ value: Data) -> String? {
        guard value.count == 4 else { return nil }
        return value.map { String($0) }.joined(separator: ".")
    }

    /// TLV 里的字符串。空串/纯空白 → `nil`（「没有」和「空」要分开）。
    private static func stringValue(_ value: Data) -> String? {
        guard let text = String(data: value, encoding: .utf8) else { return nil }
        let trimmed = text
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "\0", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
