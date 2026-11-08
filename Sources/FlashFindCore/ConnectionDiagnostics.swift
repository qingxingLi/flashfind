import Foundation

/// 「运行连接诊断」的结论汇总。
///
/// ## 只报已知事实，不假装探针
///
/// 诊断页曾经长这样：一排维修按钮（用密码重连所有 NAS / 刷新已挂载的 SMB 共享 /
/// 清搜索缓存 / NAS 搜索等待上限）。那是**开发工具**的样子，不是产品。
///
/// 现在收成一个动作「运行连接诊断…」，只把当前真正掌握的状态结构化地说清楚。
///
/// ★ 2026-11-08 补上「设备在不在线」这一层：以前这里只报 `ready`（登录会话），
///   设备掉线后照样写「正常」。现在 `AppModel.runConnectionDiagnostics()` 会先发起
///   一次按需探活（真实 HTTP 往返），证据经 `DeviceReachability` 判定后写进这一行。
///   没有证据时保持原说法，不编造探针结论。
public enum ConnectionDiagnostics {
    public struct Line: Equatable, Sendable {
        public let title: String
        public let value: String
        /// 绿色对勾还是橙色警告。取值只由事实决定。
        public let ok: Bool
        public init(title: String, value: String, ok: Bool) {
            self.title = title; self.value = value; self.ok = ok
        }
    }

    /// 一台来源的诊断结论。
    public static func summary(config: NASSourceConfig,
                              status: NASSourceStatus,
                              ready: Bool,
                              evidence: DeviceReachability.Evidence = .unknown) -> [Line] {
        var lines: [Line] = []

        lines.append(Line(title: "参与搜索", value: config.enabled ? "已开启" : "已关闭", ok: config.enabled))

        // 连接一行必须同时看「会话」与「设备在线证据」，判据只在 Core 一处。
        let display = DeviceReachability.display(ready: ready, evidence: evidence)
        let connection: String
        let connectionOK: Bool
        switch display {
        case .connected:
            connection = "正常"; connectionOK = true
        case .deviceOffline:
            connection = DeviceReachability.offlineDiagnostic; connectionOK = false
        case .notConnected:
            connection = status.health == .connecting ? "正在连接" : "未连接"
            connectionOK = false
        }
        lines.append(Line(title: "连接", value: connection, ok: connectionOK))

        if config.scopes.isEmpty {
            lines.append(Line(title: "搜索位置", value: "未选择", ok: false))
        } else {
            let names = config.scopes.map(NASSourceRowModel.scopeDisplayName).joined(separator: "、")
            lines.append(Line(title: "搜索位置", value: names, ok: true))
        }

        let usable = display == .connected && !config.scopes.isEmpty && config.enabled
        lines.append(Line(title: "搜索", value: usable ? "可用" : "不可用", ok: usable))

        if !status.message.isEmpty {
            lines.append(Line(title: "说明", value: status.message, ok: status.health == .ready))
        }
        return lines
    }
}
