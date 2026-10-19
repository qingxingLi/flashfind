import Foundation

/// 「运行连接诊断」的结论汇总。
///
/// ## 只报已知事实，不假装探针
///
/// 诊断页曾经长这样：一排维修按钮（用密码重连所有 NAS / 刷新已挂载的 SMB 共享 /
/// 清搜索缓存 / NAS 搜索等待上限）。那是**开发工具**的样子，不是产品。
///
/// 现在收成一个动作「运行连接诊断…」。但要如实：产品侧并没有独立的
/// 「网络探针 / Finder 打开探针」，所以这里**不编造**那几行，
/// 只把当前真正掌握的状态结构化地说清楚——连接、搜索位置、可用性、说明。
///
/// 真正的连接尝试由调用方负责发起（`AppModel.refreshStatuses` +
/// 已保存密码的静默重连），这里只做汇总。
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
                              ready: Bool) -> [Line] {
        var lines: [Line] = []

        lines.append(Line(title: "参与搜索", value: config.enabled ? "已开启" : "已关闭", ok: config.enabled))

        let connection: String
        if ready { connection = "正常" }
        else if status.health == .connecting { connection = "正在连接" }
        else { connection = "未连接" }
        lines.append(Line(title: "连接", value: connection, ok: ready))

        if config.scopes.isEmpty {
            lines.append(Line(title: "搜索位置", value: "未选择", ok: false))
        } else {
            let names = config.scopes.map(NASSourceRowModel.scopeDisplayName).joined(separator: "、")
            lines.append(Line(title: "搜索位置", value: names, ok: true))
        }

        let usable = ready && !config.scopes.isEmpty && config.enabled
        lines.append(Line(title: "搜索", value: usable ? "可用" : "不可用", ok: usable))

        if !status.message.isEmpty {
            lines.append(Line(title: "说明", value: status.message, ok: status.health == .ready))
        }
        return lines
    }
}
