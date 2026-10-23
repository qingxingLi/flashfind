import Foundation

/// 统一搜索「还在搜吗」的判据。
///
/// AppModel 里原来是一行内联的 `searching = !requested.isSubset(of: terminal)`。
/// 单独搬到 Core 有两个理由：
///
/// 1. 它是**界面永久转圈**的直接机制。断开一台正在搜的 NAS 之后，
///    如果那个来源永远不发终态，`requested` 里就永远缺一个来源，
///    这个判据永远为真 —— 结果行出完了、状态栏却一直显示「正在搜索」。
///    `AppModel` 属 executableTarget、测试依赖不了，这条判据因此从没被断言过。
/// 2. 「什么算终态」需要一个唯一定义：`searching` 只是「还在跑」，
///    元数据补发（`isMetadataUpdate`）更不是终态。
///
/// ★ 现在那个定义只有一处：`ProviderEvent.isTerminal`。这里不再自己拼条件——
/// 拼两份就会分叉，而分叉的表现正是「界面永久转圈」。
public struct SearchCompletionTracker {

    /// 这次查询请求了哪些来源。
    public let requested: Set<String>
    private var terminated: Set<String> = []

    public init(requested: Set<String>) { self.requested = requested }

    /// 记一个来源事件。`isTerminal` 由 `ProviderEvent` 唯一定义。
    public mutating func note(_ event: ProviderEvent) {
        guard event.isTerminal else { return }
        terminated.insert(event.sourceID)
    }

    /// 只要还有一个被请求的来源没落终态，就仍在搜索。
    public var isSearching: Bool { !requested.isSubset(of: terminated) }

    /// 还没落终态、因而会一直吊住「正在搜索」的来源。空集 = 正常收尾。
    public var pendingSources: Set<String> { requested.subtracting(terminated) }
}
