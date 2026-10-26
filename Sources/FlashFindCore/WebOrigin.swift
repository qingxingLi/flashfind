import Foundation

/// 一个来源的**网页 origin**：协议 + 主机 + 有效端口。
///
/// ## 为什么单独存在
///
/// 网页打开目标会被 `NSWorkspace.open` **直接交给系统**，因此「这条地址是不是
/// 本来源的」是整个打开链路唯一的边界判断。判断写在 `result(_:)` 里就只能靠
/// 走完整个 Provider 生命周期去测，边界情形（同主机异端口、https 降 http）
/// 根本造不出来 —— 而它们恰恰是「点一条搜索结果被送到别处」的入口。
///
/// ## 为什么只比 host 不够
///
/// 同一台主机上不同端口是完全不同的服务（DSM 5001 管理口 / 别的站点 8443）；
/// 协议不同则连信任模型都不同（HTTPS 有证书固定，HTTP 谁都能中间人）。
/// 只比主机等于承认「随便哪个端口、随便哪个协议都算同源」。
///
/// ## 省略端口
///
/// `URL(string: "https://nas/a")` 的 `port` 是 `nil`，语义上等于 443。
/// 因此比较时把 `nil` 折成默认端口 —— 否则每个不写端口的正常地址都会被拒，
/// 而这种「全拒」看起来像安全，实际只会逼着以后的人把校验删掉。
public struct WebOrigin: Equatable, Sendable {
    public let scheme: String
    /// 已规范化为小写；IPv6 不带方括号（与 `URL.host` 一致）。
    public let host: String
    public let port: Int

    /// 失败即「这个来源根本不该有网页目标」（主机为空、端口非法）。
    public init?(scheme: String, host: String, port: Int) {
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "https" || normalizedScheme == "http" else { return nil }
        let normalizedHost = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalizedHost.isEmpty else { return nil }
        let effective = port > 0 ? port : Self.defaultPort(for: normalizedScheme)
        guard (1...65535).contains(effective) else { return nil }
        self.scheme = normalizedScheme
        self.host = normalizedHost
        self.port = effective
    }

    /// 协议对应的默认端口。只认这两个 scheme —— 调用方已在上游筛过。
    public static func defaultPort(for scheme: String) -> Int {
        scheme.lowercased() == "https" ? 443 : 80
    }

    /// 这条地址是否属于本 origin。
    ///
    /// 三项全等才算：协议、主机（大小写不敏感）、有效端口（省略按默认端口折算）。
    public func admits(_ url: URL) -> Bool {
        guard let scheme = url.scheme?.lowercased(), scheme == self.scheme,
              let host = url.host, host.lowercased() == self.host else { return false }
        return (url.port ?? Self.defaultPort(for: scheme)) == port
    }
}
