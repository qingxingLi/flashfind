import Foundation

/// 来源在产品层的可见状态。刻意与底层 phase 解耦：
/// 普通用户只需要知道「正常 / 连接中 / 离线 / 需要处理」。
public enum NASSourceHealth: String, Sendable {
    case unconfigured, connecting, ready, offline, needsAttention
    public var title: String {
        switch self {
        case .unconfigured: return "未配置"
        case .connecting: return "正在连接"
        case .ready: return "正常"
        case .offline: return "离线"
        case .needsAttention: return "需要处理"
        }
    }
    public var symbol: String {
        switch self {
        case .unconfigured: return "circle.dashed"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .offline: return "circle.dashed"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }
}

public struct NASSourceStatus: Sendable {
    public var health: NASSourceHealth = .unconfigured
    public var message = ""
    public var availableShares: [String] = []
    public var selectedScope = ""
    public var discoveredPort: Int?
    public var searching = false
    /// 按钮动作独立于详情文案；nil 表示无需用户处理。
    public var requiredAction: NASSourceRequiredAction?
    /// 重连需要动态码；连接成功后清除。
    public var needsOTP: Bool = false
    /// 区分动态码被拒与尚未输入，以保留重试提示。
    public var otpRejected: Bool = false
    public init() {}
}

/// 区分可静默重连和需要输入密码的原因。
public enum ReconnectRoute: Equatable {
    /// 本机有可用密码：直接静默重连，**不问用户**。
    case storedCredential
    /// 必须输一次密码，附带一句说清为什么。
    case askForPassword(reason: String)
}

public enum ReconnectEntryState {

    /// 只有选择记住密码且本机确有凭据时才静默重连。
    public static func route(rememberPassword: Bool, hasStoredCredential: Bool) -> ReconnectRoute {
        if rememberPassword && hasStoredCredential { return .storedCredential }
        if !rememberPassword { return .askForPassword(reason: notRememberedReason) }
        return .askForPassword(reason: missingStoredReason)
    }

    /// 没勾「记住密码」时的说明。不许暗示「程序忘了」——这是用户的选择。
    public static let notRememberedReason =
        "这台 NAS 没有勾选「记住这台 NAS 的密码」，需要输入一次。"
        + "勾上之后，断开再重连就不用再输了。"

    /// 凭据缺失原因未知时不作确定性推断。
    public static let missingStoredReason =
        "本机凭据文件里没有这台 NAS 的密码（可能上次没存上，或刚被清除）。"
        + "请在这里输入一次；连接成功且勾了「记住密码」，以后重连会直接连上。"

    public static func canReconnectSilently(rememberPassword: Bool, hasStoredCredential: Bool) -> Bool {
        route(rememberPassword: rememberPassword, hasStoredCredential: hasStoredCredential) == .storedCredential
    }
}

/// 断开意图已确定时立即切换动作，不等待 Provider 异步收尾。
public enum NASRowAction: Equatable {
    case disconnect
    case reconnect

    /// markedOffline 优先于尚未完成断开的 ready 状态。
    public static func decide(ready: Bool, markedOffline: Bool) -> NASRowAction {
        if ready && !markedOffline { return .disconnect }
        return .reconnect
    }
}
