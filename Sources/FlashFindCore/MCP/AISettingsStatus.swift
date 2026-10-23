import Foundation

/// 「AI」设置页上「MCP 助手」那一段的事实与文案。
///
/// 这一层只做一件事：把 `AuthorityListener.StartResult`（启动那一刻的事实）
/// 翻译成用户能读的一行。判定、启动、失败重试全在 `MCPAuthorityController`，
/// 这里不持有任何状态。
///
/// ## 为什么标题写「正常运行」而不是「已连接」
///
/// 闪寻这一侧能确定的只有一件事：**权威端 socket 正在监听**。真正连上来的是
/// AI 客户端拉起的 `flashfind-mcp`，它什么时候来、来几次，闪寻并不知道，也不该
/// 假装知道。写成「已连接」会变成一句没人能验证的话（`detail` 里把这一点说明）。
///
/// ## 四种取值都要有话说
///
/// `ownedByAnotherInstance` 不是故障：同一台 Mac 上开了两份闪寻时就该是这个样子
/// （§1.3.3.1）。但它也**不能**显示成「正常运行」——那份运行的是别人，
/// 用户在设置里改的授权对这一份不生效。
public enum MCPHelperStatus: Equatable, Sendable {

    /// 本实例拿到 socket，正在等待 AI 客户端连接。
    case running
    /// 还没走到启动那一步（预览构建、或启动前就被问到）。
    case notStarted
    /// 另一份闪寻占着这个 socket，本实例没有监听。
    case ownedByAnotherInstance
    /// 启动失败。参数是底层给的原因，原样转述，不加工。
    case failed(String)

    public init(start: AuthorityListener.StartResult?) {
        switch start {
        case .listening: self = .running
        case .ownedByAnotherInstance: self = .ownedByAnotherInstance
        case .failed(let reason): self = .failed(reason)
        case nil: self = .notStarted
        }
    }

    public var title: String {
        switch self {
        case .running: return "正常运行"
        case .notStarted: return "未启动"
        case .ownedByAnotherInstance: return "被另一份闪寻占用"
        case .failed: return "启动失败"
        }
    }

    public var detail: String {
        switch self {
        case .running:
            return "闪寻正在等待 AI 客户端连接。客户端由你在 Claude、Codex 这类工具里自行启动。"
        case .notStarted:
            return "本次启动还没有开始监听，AI 现在连不上闪寻。"
        case .ownedByAnotherInstance:
            return "这个服务由另一份闪寻提供。同一台 Mac 上只运行一份，设置里的授权才对得上。"
        case .failed(let reason):
            return "监听没有起来：\(reason)"
        }
    }

    /// 只有 `running` 算健康。`ownedByAnotherInstance` 虽然不算故障，
    /// 但对**这一份**闪寻来说服务确实不在这里，所以不健康。
    public var isHealthy: Bool { self == .running }
}

/// 「AI 历史」那一段的事实。
///
/// 两个入参就是全部事实：总开关开没开、库里现有多少条。**不预估、不四舍五入**，
/// 也不去推断「大概记录了多少天」——那是用户没要的统计。
///
/// ★ `eventCount == nil` 只有一个含义：历史库打不开（`HistoryStore` 构造失败）。
/// 这时 `recent` 会一直返回空列表 + `recent_unavailable`（方案 §4.13.5），
/// 所以这一行必须如实说「不可用」，不能显示成「0 条」——「0 条」是可清空的正常态，
/// 「打不开」是故障，两者的下一步动作完全不同。
public struct AIHistorySummary: Equatable, Sendable {

    /// AI 访问总开关（已保存的值，不是草稿）。
    public let isRecording: Bool
    /// 现有事件条数；`nil` 表示历史库不可用。
    public let eventCount: Int?

    public init(isRecording: Bool, eventCount: Int?) {
        self.isRecording = isRecording
        self.eventCount = eventCount
    }

    /// 历史库打不开。
    public var isUnavailable: Bool { eventCount == nil }

    public var title: String {
        guard !isUnavailable else { return "不可用" }
        return isRecording ? "已开启" : "已关闭"
    }

    public var detail: String {
        guard let count = eventCount else {
            return "历史库打不开，AI 查不到以前看过哪些文件（recent 只会返回空）。"
        }
        if isRecording {
            return "AI 每次成功找到文件都会记一条，目前 \(count) 条。"
        }
        return "AI 访问关着，不再记录；已有的 \(count) 条仍保留。"
    }

    /// 没有记录可清时按钮置灰——点了也不会发生任何事，不如不给点。
    public var canClear: Bool { (eventCount ?? 0) > 0 }
}

/// 「清空历史」这一次操作的结果。
///
/// 三种结局必须分得开，因为下一步动作完全不同：`cleared` 是成功（说清空了多少条），
/// `unavailable` 是本来就没有库（按钮本该是灰的），`failed` 是库在、但删不掉
/// （磁盘满了、文件被占用）。把它们折成一个 `Bool` 会让「删失败」显示成
/// 「已清空」，那是这一类功能最不能犯的错。
public enum AIHistoryClearOutcome: Equatable, Sendable {
    case cleared(Int)
    case unavailable
    case failed
}

/// 「AI 历史」那一段的按钮与结果文案。
public enum AIHistoryText {

    public static let clearButton = "清空历史…"

    /// 二次确认。清空不可恢复，所以必须问一句，且把**清的是什么、不清什么**写清楚。
    public static let clearTitle = "清空 AI 历史？"
    public static let clearDetail = "这会删掉全部访问记录，清空后不可恢复。AI 已经拿到的文件编号仍然有效，不影响它继续查同一个文件。"

    public static func cleared(_ count: Int) -> String {
        "已清空 \(count) 条历史。"
    }

    public static let clearFailed = "清空没有成功，历史库现在写不进去。"
    public static let clearUnavailable = "历史库不可用，没有可清空的记录。"
}
