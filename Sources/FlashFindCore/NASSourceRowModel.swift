import Foundation

/// 来源出问题时，行上该给哪个按钮。
///
/// ## 为什么按钮是「三选一」而不是「一排」
///
/// 来源卡片上要是同时挂着「参与搜索 / 重新连接 / 管理… / 断开 / 详细信息」，
/// 正常连接的 NAS 也照样显示「断开」「重新连接」——用户看到的是
/// 一个 NAS 管理器，而不是一个搜索工具。
///
/// 所以改成：**只有发生问题时才出现操作**，而且只出现
/// 一个、且与问题对应的那一个。
public enum NASSourceRequiredAction: String, Sendable {
    /// 连不上 → [重试]。
    case retry
    /// 本机没有可用密码 → [登录]。
    case login
    /// 配置不完整 / 需要选搜索位置 / 证书要重新确认 → [继续设置]。
    case continueSetup

    public var buttonTitle: String {
        switch self {
        case .retry: return "重试"
        case .login: return "登录"
        case .continueSetup: return "继续设置"
        }
    }
}

/// 「搜索来源」列表里一行的呈现。
///
/// 一行最多四类信息：图标、名称、状态/描述、启用状态（外加异常时的一个按钮）。
/// 所有判定都收在这个纯函数里——App 层只负责画出来，不再自己拼状态文案。
public struct NASSourceRowModel: Equatable, Sendable {
    public let title: String
    /// 状态行：正常时是「群晖 · 已连接」，异常时是「无法连接」这类短句。
    public let detail: String
    /// 搜索位置，如「公司共享文档、部门文档」。空表示没选。
    public let locations: String
    /// 需要用户处理时给按钮；正常行是 `nil`（界面据此**不画**按钮）。
    public let action: NASSourceRequiredAction?
    /// 是否参与搜索（右侧开关）。
    public let enabled: Bool
    /// 供状态着色。绿色=明确正常，橙色=需要处理，灰色=未连接/关闭。
    public let health: NASSourceHealth

    public init(title: String, detail: String, locations: String,
                action: NASSourceRequiredAction?, enabled: Bool, health: NASSourceHealth) {
        self.title = title
        self.detail = detail
        self.locations = locations
        self.action = action
        self.enabled = enabled
        self.health = health
    }

    /// `/公司共享文档` → `公司共享文档`。
    ///
    /// 搜索位置在界面上一律不带前导斜杠：用户配的是 NAS 上的共享名，
    /// 那是产品概念；`/xxx` 是 DSM 的表示法，属于实现细节。
    public static func scopeDisplayName(_ scope: String) -> String {
        scope.hasPrefix("/") ? String(scope.dropFirst()) : scope
    }

    /// 从真实状态推出这一行该长什么样。
    ///
    /// - Parameters:
    ///   - config: 来源配置。
    ///   - status: 该来源的界面状态（含 `requiredAction`）。
    ///   - ready: Provider 是否已连接。
    public static func make(config: NASSourceConfig, status: NASSourceStatus, ready: Bool) -> NASSourceRowModel {
        let title = config.displayName
        let locations = config.scopes.map(scopeDisplayName).joined(separator: "、")

        // ① 用户主动关掉：不搜索、不删除、不注销账号。不给按钮。
        if !config.enabled {
            return NASSourceRowModel(title: title, detail: "已关闭", locations: locations,
                                     action: nil, enabled: false, health: .unconfigured)
        }

        // ② 配置都不全：先去把地址账号填上。
        if !config.isConnectConfigured {
            return NASSourceRowModel(title: title, detail: "需要填写地址与账号", locations: locations,
                                     action: .continueSetup, enabled: true, health: .unconfigured)
        }

        // ③ 已连上：正常情况下**一个按钮都不给**。
        if ready {
            if config.scopes.isEmpty {
                // 连上了却没选目录 = 搜不到东西，必须让用户去补。
                return NASSourceRowModel(title: title, detail: "需要选择搜索位置", locations: "",
                                         action: .continueSetup, enabled: true, health: .needsAttention)
            }
            return NASSourceRowModel(title: title, detail: config.vendor.shortTitle + " · 已连接",
                                     locations: locations, action: nil, enabled: true, health: .ready)
        }

        // ④ 未连上且状态里明确写了要做什么 → 只给那一个按钮。
        if let required = status.requiredAction {
            return NASSourceRowModel(title: title, detail: shortDetail(required, config: config),
                                     locations: locations, action: required, enabled: true,
                                     health: status.health == .unconfigured ? .offline : status.health)
        }

        // ⑤ 正在连接：等它自己走完，不给按钮。
        if status.health == .connecting {
            return NASSourceRowModel(title: title, detail: "正在连接…", locations: locations,
                                     action: nil, enabled: true, health: .connecting)
        }

        // ⑥ 其余（已保存但尚未连接）→ 给一个「重试」把连接发起起来。
        return NASSourceRowModel(title: title, detail: "未连接", locations: locations,
                                 action: .retry, enabled: true, health: .offline)
    }

    /// 列表行上的**短**状态语。完整原因（可能很长）留在详情页，不塞进列表。
    static func shortDetail(_ action: NASSourceRequiredAction,
                            config: NASSourceConfig) -> String {
        switch action {
        case .retry:
            return "无法连接"
        case .login:
            return "需要重新登录"
        case .continueSetup:
            return config.scopes.isEmpty ? "需要选择搜索位置" : "需要继续设置"
        }
    }
}
