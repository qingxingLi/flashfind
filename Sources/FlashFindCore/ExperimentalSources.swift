import Foundation

/// 「显示实验性搜索来源」开关。
///
/// ## 为什么需要它
///
/// 正式开放的只有群晖与 OpenList（两者都已在真机上跑通完整链路），
/// 其余品牌（威联通 / 绿联 / WebDAV / 飞牛）的适配器与模型**原样留在代码里**：
/// 旧配置要能解码，以后也要能再开放。但它们当中还有没在真机上验证过的，
/// 摆给普通用户选等于把「可能连不上」当成一个正常选项。
///
/// 于是把「要不要看到这些来源」做成一个显式开关，默认**关**：
/// 关着的时候向导只给正式开放的类型；打开以后才把自己承担风险的人放进去。
///
/// 判定放在 Core：App 层是 `executableTarget`，测试目标 import 不到，
/// 而「默认关、关着时只给正式开放的类型」这条契约必须能被测试锁住。
public enum ExperimentalSources {
    /// 偏好键。沿用 `ff2.` 前缀。
    public static let storageKey = "ff2.experimentalSources"

    /// 解析开关的当前取值。**默认关**——没设过就是关。
    public static func resolve(stored: Bool?) -> Bool { stored ?? false }

    /// 向导里当前可选（也就是可展示）的类型。
    ///
    /// - Parameter includingExperimental: `ExperimentalSources.resolve` 的结果。
    ///
    /// 基线永远是 `NASSourceConfig.Vendor.selectableVendors`（群晖 + OpenList）——
    /// 这两个不归开关管，正式版就该看得见。
    ///
    /// 打开开关后的追加条件只有一个 —— **有可用适配器**。它同时挡掉两类：
    /// * 从来没接入的（`smb` / `generic`）；
    /// * 接入过、但已下线（`NASSourceConfig.AdapterStatus.retired`，如飞牛）。
    ///
    /// 这里刻意**不按品牌名写死**：核心的 `retiredVendors` 以后再添一个，
    /// 界面应当跟着一起消失，而不是等着有人想起来回来改这一行。
    public static func vendors(includingExperimental: Bool) -> [NASSourceConfig.Vendor] {
        let standard = NASSourceConfig.Vendor.selectableVendors
        guard includingExperimental else { return standard }
        var result = standard
        for vendor in NASSourceConfig.Vendor.allCases
        where vendor.hasAdapter && !result.contains(vendor) {
            result.append(vendor)
        }
        return result
    }
}
