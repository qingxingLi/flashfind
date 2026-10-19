import Foundation

/// SSDP `description.xml` 的解析。
///
/// ## 为什么要有它
///
/// SSDP 的 `M-SEARCH` 响应只有 `SERVER` / `LOCATION` / `ST` 三个头，
/// 设备真正的身份在 LOCATION 指向的 `description.xml` 里。实测
/// 群晖 DSM 自带 minissapd，那份 XML 明写：
///
/// ```
/// <friendlyName>demo-synology (DS124)</friendlyName>
/// <manufacturer>Synology</manufacturer>
/// <modelDescription>Synology NAS</modelDescription>
/// <modelName>DS124</modelName>
/// <serialNumber>02005e000096</serialNumber>
/// ```
///
/// 这是**不依赖 mDNS、也不依赖 DSM 端口**的第三条识别通道——
/// 实测有不广播 mDNS 的 DS1621+，只有这条通道能认出它。
///
/// ## 解析策略
///
/// 这份 XML 很小（几百字节）、结构固定，用一个**只认已知标签**的轻量扫描器，
/// 不引第三方、不建完整 DOM。遇到同名标签取**第一个**（UPnP 允许嵌套
/// `deviceList`，外层是根设备；取第一个即根设备的字段）。
/// 解析不出来就留 `nil`——「没有」和「有但读不懂」都按没有处理，不猜。
public enum SSDPDescriptionParser {

    /// 从 `description.xml` 里取根设备的身份。
    ///
    /// - Parameter xml: 原始 XML 文本；传空串或格式不对时返回全空身份。
    /// - Returns: 解析出的字段；任何一个字段读不到就是 `nil`。
    public static func parse(_ xml: String) -> SSDPIdentity {
        var identity = SSDPIdentity()
        identity.deviceType = firstTag("deviceType", in: xml)
        identity.friendlyName = firstTag("friendlyName", in: xml)
        identity.manufacturer = firstTag("manufacturer", in: xml)
        identity.modelName = firstTag("modelName", in: xml)
        identity.modelDescription = firstTag("modelDescription", in: xml)
        identity.serialNumber = firstTag("serialNumber", in: xml)
        return identity
    }

    /// 从 SSDP 响应的 `SERVER` 头里认厂商。
    ///
    /// ★ 这条不是可选项，是**必需品**：实测 DS1621+ 的 SSDP LOCATION 指向
    /// `http://<另一块网卡的地址>:5002/ssdp/desc-DSM-eth2.xml`——那是它的第三块
    /// 网卡，从本机根本连不上（实测超时）。**XML 拉不到的时候，
    /// `SERVER: Synology/DSM/<地址>` 这行本身就已经说明了它是群晖。**
    public static func vendorHint(fromServerHeader server: String?) -> NASSourceConfig.Vendor? {
        guard let server, !server.isEmpty else { return nil }
        let lower = server.lowercased()
        if lower.contains("synology") { return .synology }
        if lower.contains("qnap") { return .qnap }
        return nil
    }

    // MARK: - 内部

    /// 取 `<tag>值</tag>` 的第一个值。
    ///
    /// 值里的 XML 实体（`&amp;` 等）只做最小替换——设备名里出现 `&` 时
    /// 显示成 `&amp;` 比显示成空更难看，也比拉一个完整 XML 解析器便宜。
    static func firstTag(_ tag: String, in xml: String) -> String? {
        let open = "<" + tag + ">"
        guard let startRange = xml.range(of: open) else { return nil }
        let close = "</" + tag + ">"
        let searchFrom = startRange.upperBound
        guard let endRange = xml.range(of: close, range: searchFrom..<xml.endIndex) else { return nil }
        let raw = String(xml[searchFrom..<endRange.lowerBound])
        let decoded = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return decoded.isEmpty ? nil : decoded
    }
}
