import Foundation
import FlashFindCore

/// 读本机 ARP 表，拿到**真正在线**的主机与它们的 MAC。
///
/// ## 为什么它排在 TCP 扫描前面
///
/// 实测一个 `/24` 网段：
///
/// * 整网 253 个地址逐个试 4 个端口 ≈ **33.5 秒**——不存在的地址每个端口都
///   耗到超时（同网段 ARP 无响应，**不是 RST**）；
/// * 先读 ARP 表拿到 128 台在线主机，只对它们探测 ≈ **12.2 秒**；
/// * 而读 ARP 表本身只花 **0.01 秒**。
///
/// 所以顺序是：**ARP 先给出「谁在线」，TCP 端口探测只作为确认身份的 fallback**。
/// 端口命中本身不产生默认显示资格（一台开了 445 的机器可能是任何东西），
/// 它只是给已经在列表里的设备补一个能用的端口。
///
/// ## 为什么不自己发 ARP 请求
///
/// 自己造 ARP 包要原始套接字（root）。`arp -an` 是系统已经维护好的结果，
/// 而且**必须带 `-n`**：不带 `-n` 会做反向 DNS，一个网段能卡住几十秒。
enum ARPTableReader {

    /// ARP 表里的一条：地址 + MAC。
    struct Entry: Equatable, Sendable {
        var address: String
        var mac: String
    }

    /// 读一次 ARP 表，只保留与本机同网段的私有地址。
    ///
    /// `(incomplete)` 的行说明内核发过 ARP 但没人答——那种地址**不算在线**，丢掉。
    static func read() async -> [Entry] {
        await Task.detached(priority: .utility) {
            Self.entries()
        }.value
    }

    /// 转成发现证据：只有「在线」和 MAC 这两条事实。
    static func evidence(from entries: [Entry]) -> [DeviceEvidence] {
        entries.map { entry in
            var item = DeviceEvidence(host: entry.address, sources: [.arp])
            item.mac = entry.mac
            return item
        }
    }

    // MARK: - 内部

    private static func entries() -> [Entry] {
        guard let output = runARP() else { return [] }
        var results: [Entry] = []
        var seen: Set<String> = []
        for line in output.split(separator: "\n") {
            // 形如：? (192.168.1.96) at 0:2:0:5e:0:0:96 on en0 ifscope [ethernet]
            guard let open = line.firstIndex(of: "("),
                  let close = line[open...].firstIndex(of: ")") else { continue }
            let address = String(line[line.index(after: open)..<close])
            guard let range = line.range(of: " at ") else { continue }
            let afterMAC = line[range.upperBound...]
            let mac = String(afterMAC.split(separator: " ").first ?? "")
            guard !address.isEmpty, !mac.isEmpty,
                  mac != "(incomplete)",
                  NetworkDiscovery.isPrivateIPv4(address),
                  !seen.contains(address) else { continue }
            seen.insert(address)
            results.append(Entry(address: address, mac: canonicalMAC(mac)))
        }
        return results.sorted { lhs, rhs in
            let l = NetworkDiscovery.ipv4Value(lhs.address) ?? 0
            let r = NetworkDiscovery.ipv4Value(rhs.address) ?? 0
            if l != r { return l < r }
            return lhs.address < rhs.address
        }
    }

    private static func runARP() -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/arp")
        // ★ -n 不能少：不带它 arp 会对每个地址做反向 DNS，一个网段能卡几十秒。
        process.arguments = ["-an"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }

    /// `arp` 给的 MAC 前导零是省掉的（`0:2:0:5e:0:0:96`），补成规整形式。
    ///
    /// 补零不只是好看：`DeviceMerger` 用归一化后的 MAC 做归并键，
    /// 而 DSM 的 SSDP `serialNumber` 是**补了零的**去冒号 MAC（`02005e000096`）。
    /// 两边形状不一致就对不上，多网卡归并会失效。
    static func canonicalMAC(_ raw: String) -> String {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.allSatisfy({ $0.count <= 2 && !$0.isEmpty }) else { return raw.uppercased() }
        return parts.map { $0.count == 1 ? "0\($0)" : $0 }.joined(separator: ":").uppercased()
    }
}
