import Foundation

/// DSM Web 入口的端口探测。
///
/// 为什么需要：真实设备上 `.96` 在 5001，另一台 `.88` 的 5001 是关闭的、
/// 实际入口在 5003。让用户知道「5001」是不合理的（见 UI 规划书 Step 2），
/// 因此这里按优先级依次探测，并用 API.Info 判断响应是否真的是 DSM 入口。
public enum EndpointProbe {
    /// 候选端口。5001/5000 是 DSM 默认，5003/5005 是群晖近年的随机端口，443 是纯 HTTPS 入口。
    public static let candidatePorts = [5001, 5000, 5003, 5005, 443]

    public struct Candidate: Sendable {
        public let port: Int
        public let endpoint: String
        public let hasFileStation: Bool
    }

    /// 从用户输入里取出裸主机名。支持 `192.168.1.96`、`nas.local`、`[::1]` 之外的常见写法。
    public static func host(of input: String) -> String? {
        var text = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count)); break
        }
        if let slash = text.firstIndex(of: "/") { text = String(text[..<slash]) }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        if let colon = text.lastIndex(of: ":"), text[text.index(after: colon)...].allSatisfy({ $0.isNumber }) {
            text = String(text[..<colon])
        }
        guard !text.isEmpty, text.count <= 253, !text.contains("..") else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789.-")
        guard text.allSatisfy({ allowed.contains($0) }) else { return nil }
        // 既接受 IPv4（192.168.1.96），也接受 DNS 名（nas.local、disk-station.local）。
        // 每一段允许字母数字与连字符——`nas-home` / `disk-station` 都是合法主机名，
        // 只允许字母数字会把它们误判为非法。
        // 仍拒绝：空段（`a..b`）、首尾连字符（`-a` / `a-`）、纯符号。
        let labels = text.split(separator: ".", omittingEmptySubsequences: false)
        guard text.first != ".", text.last != "." else { return nil }
        for label in labels {
            guard !label.isEmpty,
                  let first = label.first, let last = label.last,
                  first != "-", last != "-",
                  label.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" }) else { return nil }
        }
        return text
    }


    /// 依次探测候选端口，返回第一个能通过 API.Info 判定为 DSM 入口的结果。
    ///
    /// `check` 由调用方注入（真机走 TrustHTTP / URLSession），本类型不直接建连接，
    /// 以便单元测试可以在不触碰网络的情况下覆盖端口优先级逻辑。
    public static func firstWorking(
        host: String,
        ports: [Int] = candidatePorts,
        timeout: TimeInterval = 3,
        check: (Int) async -> Candidate?
    ) async -> Candidate? {
        for port in ports {
            if let candidate = await check(port) { return candidate }
        }
        return nil
    }

    /// 解析 API.Info 的响应，判断它是否声明了 FileStation 能力。
    ///
    /// 只看「HTTP 200 且 JSON 里有 SYNO.API.Auth 与 SYNO.FileStation.Info」；
    /// 登录门户、重定向页、其他设备的管理界面都不会同时满足这两个键。
    public static func parseAPIInfo(_ data: Data?) -> Bool {
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = root["data"] as? [String: Any] else { return false }
        return payload["SYNO.API.Auth"] != nil && payload["SYNO.FileStation.Info"] != nil
    }
}
