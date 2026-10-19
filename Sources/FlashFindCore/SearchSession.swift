import Foundation

/// 一次搜索在整条链路上的**唯一身份**。
///
/// 背景（BUG-006）：此前一次搜索同时存在好几套身份 ——
/// `AppModel.queryID`、`SearchCoordinator` 自己又生成的一个 `queryID`、
/// `NASSearchProvider.active`、Dart 侧的 `queryID` / `requestID`。
/// 它们只在「恰好都相等」的时候才对得上；一旦发生取消、旧结果迟到、
/// 并发返回，就只能靠猜哪个 ID 是哪一次搜索。
///
/// 现在的规则只有一条：**queryID 由最外层调用方（AppModel）生成，
/// 一路传到底，中途任何一层都不许再造一个。**
/// `SearchCoordinator` 保留「不传就自己造」的入口，只给测试与直接调用用；
/// App 的正常路径必须传。
public struct SearchSession: Sendable, Equatable, Identifiable {
    public let queryID: UUID
    public let sourceID: String
    /// 同一个 queryID 下的第几次尝试。自动重连后重跑会 +1，
    /// 这样日志里能区分「同一次查询的两次设备交互」。
    public let attempt: Int
    public let startedAt: Date

    /// 设备侧搜索任务标识。
    ///
    /// **目前恒为 nil，这是刻意的**：DSM 的 taskid 是设备内部的不透明句柄，
    /// Dart 核心明确规定它不离开核心进程（不进日志、不落盘、不外发）。
    /// 可观测性不能靠把设备内部句柄掏出来换。
    /// 字段保留，将来协议若提供脱敏的任务引用（例如 `taskRef`）再填。
    public var remoteTaskID: String?

    public var id: UUID { queryID }

    public init(queryID: UUID, sourceID: String, attempt: Int = 1,
                startedAt: Date = Date(), remoteTaskID: String? = nil) {
        self.queryID = queryID; self.sourceID = sourceID; self.attempt = attempt
        self.startedAt = startedAt; self.remoteTaskID = remoteTaskID
    }

}

// MARK: - 搜索状态机

/// 一次搜索的完整生命周期。
///
/// 背景（P1-02）：此前判断「这次搜索到哪一步了」靠的是
/// `active` / `terminalState` / `terminalComplete` / `retryInFlight` / `malformedSeen`
/// 好几个 Bool 与 Optional 的组合。组合状态的问题不是难读，
/// 而是**合法组合与非法组合在类型上长得一样** —— 于是
/// 「已终结却又收到一批结果」「还没开始就进入了清理」这类状态根本无法被发现。
///
/// 现在用显式状态 + 转移表：非法转移会被记进 `rejected`，测试可以直接断言
/// 「整条跑完没有一条非法转移」。
public enum SearchSessionState: String, Sendable, CaseIterable {
    case idle, starting, polling, fetching, stopping, cleaning, finished
    case cancelled, failed, orphaned

    /// 已终结：此后不得再回到进行中，也不应再接收结果。
    public var isTerminal: Bool {
        switch self {
        case .finished, .cancelled, .failed, .orphaned: return true
        case .idle, .starting, .polling, .fetching, .stopping, .cleaning: return false
        }
    }

    /// 是否处在「设备侧任务已经存在」的窗口内。
    ///
    /// 这个窗口里异常退出意味着**可能有任务留在设备上没清掉**，
    /// 终结态应该是 `orphaned` 而不是 `finished` —— 两者的处置完全不同。
    public var holdsRemoteTask: Bool {
        switch self {
        case .starting, .polling, .fetching, .stopping: return true
        case .idle, .cleaning, .finished, .cancelled, .failed, .orphaned: return false
        }
    }

    public var allowedNext: Set<SearchSessionState> {
        switch self {
        case .idle:      return [.starting, .cancelled]
        case .starting:  return [.polling, .fetching, .stopping, .cleaning, .finished, .cancelled, .failed, .orphaned]
        case .polling:   return [.polling, .fetching, .stopping, .cleaning, .finished, .cancelled, .failed, .orphaned]
        case .fetching:  return [.polling, .fetching, .stopping, .cleaning, .finished, .cancelled, .failed, .orphaned]
        case .stopping:  return [.cleaning, .finished, .cancelled, .failed, .orphaned]
        case .cleaning:  return [.finished, .cancelled, .failed, .orphaned]
        case .finished, .cancelled, .failed, .orphaned: return []
        }
    }

    /// 由界面状态 + 设备侧清理结果推导出终结态。
    ///
    /// 关键在于 `orphaned`：**搜索本身成功了，但设备上的任务没清掉**。
    /// 这种情况不能记成 `finished`，否则「成功」会掩盖一次真实的资源泄漏
    /// ——而泄漏正是「搜几次就搜不到」的成因（BUG-001）。
    public static func terminal(providerState: ProviderSearchState, cleanupState: String?) -> SearchSessionState {
        switch providerState {
        case .cancelled: return .cancelled
        case .failed: return .failed
        case .searching: return .failed   // 卡在进行中却走到了收尾 = 异常
        default: break
        }
        if let cleanupState, (cleanupState == "pending" || cleanupState == "orphaned") { return .orphaned }
        return .finished
    }
}

/// 一条被拒绝的转移。留着用于测试与诊断——非法转移本身就是缺陷的证据。
public struct RejectedTransition: Sendable, Equatable {
    public let from: String
    public let to: String
    public init(from: String, to: String) { self.from = from; self.to = to }
}

/// 驱动一次搜索走完生命周期。
///
/// 刻意做成普通 class（不是 actor）：调用方 `NASSearchProvider` 已在
/// `@MainActor` 上，这里不需要第二层隔离，也避免测试里到处写 await。
public final class SearchSessionMachine {
    public let session: SearchSession
    public private(set) var state: SearchSessionState = .idle
    public private(set) var trail: [String] = []
    public private(set) var rejected: [RejectedTransition] = []

    public init(session: SearchSession) { self.session = session }

    /// 走一步。**非法转移不会改变状态**，只记进 `rejected`。
    /// 这样「状态错乱」变成可断言的事实，而不是悄悄发生。
    @discardableResult
    public func transition(to next: SearchSessionState) -> Bool {
        guard state.allowedNext.contains(next) else {
            rejected.append(RejectedTransition(from: state.rawValue, to: next.rawValue))
            return false
        }
        state = next
        trail.append(next.rawValue)
        return true
    }

    public var isTerminal: Bool { state.isTerminal }

    /// 外部事实导致的强制终结（核心进程没了、连接被踢掉等）。
    /// 只允许进终结态；传进行中的状态视为调用方写错。
    @discardableResult
    public func forceTerminal(_ next: SearchSessionState) -> Bool {
        guard next.isTerminal else {
            rejected.append(RejectedTransition(from: state.rawValue, to: next.rawValue))
            return false
        }
        // 已终结就不重复覆盖：第一次终结的原因才是有用的那个。
        guard !state.isTerminal else { return false }
        state = next
        trail.append(next.rawValue)
        return true
    }

    /// 终结态名称，供诊断落盘。
    public var terminalState: String? { state.isTerminal ? state.rawValue : nil }
}
