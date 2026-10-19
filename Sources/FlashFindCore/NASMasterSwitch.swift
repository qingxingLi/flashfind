import Foundation

/// NAS 总开关的取值判定（审核 R01）。
///
/// ## 错在哪里
///
/// ```swift
/// enabled = defaults.object(forKey: "ff2.multiNAS.enabled") as? Bool
///           ?? defaults.bool(forKey: "ff2.enabled")
/// ```
///
/// 全新安装时两个 key 都不存在：前一个 `object(...)` 是 nil，
/// 而 `bool(forKey:)` 对**不存在**的 key 返回 **false** —— 于是总开关被初始化成关闭。
/// 后果是用户走完向导、来源卡片明明显示「已连接」，搜索却一次都不请求 NAS；
/// 而设置页那个开关只要绑成 `.constant(model.enabled)`，点了也开不了。
///
/// ## 判定规则：**「从未写过」和「显式关过」必须分开**
///
/// `object(forKey:)` 对「写过 false」返回 `NSNumber(false)`（**不是** nil），
/// 只有真正没写过才返回 nil —— 这就是区分两者的依据。
/// 旧版 key 也要用同样的方式读，不能再用 `bool(forKey:)`。
public enum NASMasterSwitch {

    /// 当前总开关的落盘 key。
    public static let storageKey = "ff2.multiNAS.enabled"
    /// 旧版（单 NAS 时代）的总开关 key。
    public static let legacyKey = "ff2.enabled"

    /// 由两个偏好值恢复总开关。
    ///
    /// - Parameters:
    ///   - stored: `object(forKey: storageKey)` 的结果。**nil 表示从未写过**。
    ///   - legacy: `object(forKey: legacyKey)` 的结果。同样，nil 表示从未写过。
    /// - Returns: 总开关取值。两者都没写过 ⇒ 全新安装，默认**开启**。
    public static func resolve(stored: Bool?, legacy: Bool?) -> Bool {
        if let stored { return stored }
        if let legacy { return legacy }
        // 全新安装：默认开启。宁可让用户在设置里关掉，
        // 也不要让他连好了 NAS 却搜不到任何结果、还找不到开关在哪。
        return true
    }
}
