import Foundation

/// 一次搜索的**发起方**。它同时是取消作用域：
/// 「谁发起的，谁才能取消自己那条」。
///
/// 为什么需要它：`NASSearchProvider` 原来只有「同一来源一个活跃查询」这一条规则，
/// 新查询无条件取代旧查询。那在只有 GUI 一个调用方时是对的（用户改了关键词，
/// 上一条就该丢），但加上 MCP 之后调用方变成三类（GUI / Agent A / Agent B），
/// 复用同一条规则会让三方互相取消——表现为「偶尔搜不到」，重试一次又好了。
public enum SearchOwner: Hashable, Sendable {
    /// 用户手动触发的搜索（搜索框、重新搜索、回车）。
    case ui
    /// 某个 MCP 会话（Agent）。`sessionID` 由 Helper 进程启动时生成。
    case mcp(sessionID: String)

    public var isUserInteractive: Bool { self == .ui }

    /// 诊断用标签。**不是用户文案**，不要显示在界面上。
    public var label: String {
        switch self {
        case .ui: return "ui"
        case .mcp(let sid): return "mcp:\(sid)"
        }
    }
}

/// 按来源排队、按 owner 决定「能不能取消」的调度器。
///
/// ## 每个来源上的四态
///
/// 一条请求在某个来源上只会处于其中之一：
///
/// ```
/// queued  ──►  running  ──►  终态
///   │            │
///   │            └─ cancel 请求 ──► cancelling ──► 终态
///   └─ 被取代 / 被取消 / 排队超时 ──► 终态
/// ```
///
/// 终态是 `completed` / `cancelled` / `timedOut` / `failed` 之一。
///
/// ## 四条硬规则
///
/// 1. **取消只作用于同一 owner。** 跨 owner 永不取消，只排队。
///    这条不是靠注释约束的：`cancel(queryID:requester:)` 必须带发起方，
///    不匹配就拒绝并计数（`rejectedCancelCount`）。
/// 2. **队列键是 `source_id`，不是全局队列。** 做成全局队列会让一个慢 NAS
///    把本机与其它 NAS 一起堵住——用户会看到「搜本机也卡」。
/// 3. **GUI 只插队，不抢占。** 已经在跑的请求（不管 owner 是谁）一定跑完；
///    GUI 的查询只是成为「下一个」。
/// 4. **`cancel()` 不等于 `finished()`。** 请求取消只是请 provider 停下，
///    槽位要等 `search()` 真正返回才释放（见 `cancelling`）。
///
/// ## 终态责任划分（为什么必须这么分）
///
/// - **`queued` 阶段的终态由本类负责**：条目还没交给 provider，provider 永远不会
///   为它发事件。如果这里也不发，调用方就会永远停在 pending——表现为界面转圈不停。
/// - **`running` / `cancelling` 阶段的终态由 provider 负责**：条目已经在 provider
///   手里，本类不知道它内部是正常结束还是失败。这里再补发一次必然产生**双终态**，
///   把「结果数」和「是否还在搜」都算错。
///
/// 所以规则是：**任何进入本类的条目，最终恰好收到一个终态**——排队阶段由这里发，
/// 进入执行后由 provider 发，两边不重叠。
///
/// ## 为什么取消要额外维护 `cancelling`
///
/// `provider.cancel(queryID:)` 的语义只是「请停下」，**不保证同步返回**：
/// 真 provider 可能还要等设备回包、等 socket 收尾。如果在这里直接把槽位清空并
/// 立刻启动下一条，就会出现「旧查询还在退出、新查询已经在跑」——同一来源两个
/// 活跃请求，正是本类存在的前提被破坏。`cancelling` 就是「已请求取消、但还占着
/// 槽位」的那个中间态。
///
/// ★ 由此带来的一个已知行为：用户在慢设备上点「取消」后立刻输入新词，新查询要
/// 等旧查询真正返回才开始。这是正确性的代价，不是缺陷——旧查询的存活时间由
/// provider 的看门狗兜底（`NASSearchProvider` 有 180s 上限）。
@MainActor
public final class SearchScheduler {
    /// 排队等待上限。超过即从队列移除并回一个 `timedOut` 终态。
    ///
    /// 为什么用 deadline 而不是固定队列长度：固定长度在慢 NAS 上会误伤
    /// （队列本来是空的，但一次慢查询就能把长度撑到上限）。
    /// 用户等待时间的上限才是真正要守的东西。
    public var queueWaitMs: Int = 10_000

    private struct Entry {
        let queryID: UUID
        let text: String
        let owner: SearchOwner
        let sourceID: String
        let provider: any SearchProvider
        let emit: @MainActor (ProviderEvent) -> Void
        let deadline: Date
    }

    private let providers: [any SearchProvider]
    private let now: () -> Date

    /// 每个来源当前在跑的项（最多一个）。
    private var running: [String: Entry] = [:]

    /// 每个来源上「已请求取消、provider 还没返回」的项。
    ///
    /// 与 `running` **互斥**：同一个来源任一时刻最多一个，两者都非空是不可能的
    /// （`start` 只在两者都为 nil 时发生）。它存在的唯一理由是把
    /// 「请求取消」和「真的结束了」分开，见类型注释最后一段。
    private var cancelling: [String: Entry] = [:]

    /// 每个来源的等待队列。**键是 source_id**，见类型注释规则 2。
    private var queues: [String: [Entry]] = [:]

    /// 跨 owner 的取消请求被拒绝的次数。**诊断用**，不是用户文案。
    ///
    /// 为什么要有计数器而不是静默忽略：owner 隔离是这套机制最重要的不变量，
    /// 静默拒绝会让「谁取消了谁」在日志里彻底不可见，出问题只能靠猜。
    public private(set) var rejectedCancelCount: Int = 0

    /// 最近一次被拒绝的跨 owner 取消请求（诊断用）。
    public private(set) var lastRejectedCancel: (requester: SearchOwner,
                                                 targetOwner: SearchOwner,
                                                 queryID: UUID,
                                                 sourceID: String)?

    public init(providers: [any SearchProvider], now: @escaping () -> Date = Date.init) {
        self.providers = providers
        self.now = now
    }

    // MARK: - 提交

    /// 提交一次搜索到**指定 provider 对象**（MCP 的授权快照路径，Phase 6.3b-1）。
    ///
    /// ★ 与上面那个入口的唯一区别是「provider 从哪来」：这里由调用方给，
    /// 不再从本类持有的列表里按 id 过滤。原因见 `SourceExecutionHandle`：
    /// 执行侧若按 id 回去查一次，就会出现「判权时是 A、执行时是 A′」的窗口。
    ///
    /// ★ 但**槽位与队列完全共用**：`enqueue` 仍然按 `provider.source.id` 落到
    /// `running` / `cancelling` / `queues` 这三张同源的表里。所以「同一来源同时只跑一个」
    /// 与「取消只作用于同 owner」这两条不变量对 MCP 与 GUI 一样成立——这正是
    /// 不能用「MCP 自己造一个调度器」解决的原因。
    ///
    /// - Parameter supersedePrevious: **必须由调用方显式给**。MCP 侧恒为 `false`
    ///   （方案 §4.7：一次 wire 请求展开的子查询不能被自己人互相取消）。
    public func submit(text: String,
                       queryID: UUID,
                       owner: SearchOwner,
                       provider: any SearchProvider,
                       supersedePrevious: Bool,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) {
        reapExpired()
        if supersedePrevious {
            supersedeAll(owner: owner, keeping: queryID)
        }
        enqueue(text: text, queryID: queryID, owner: owner, provider: provider, emit: emit)
    }

    /// 提交一次搜索。`sources` 为 nil 表示「这台机器上注册的全部来源」。
    ///
    /// 同一个 `queryID` 跨多个来源各排一次队——与 `SearchCoordinator` 的语义一致
    /// （一次查询打多个 provider，结果按来源分别回）。
    ///
    /// - Parameter supersedePrevious: 是否「用这次替换同 owner 的旧请求」。
    ///   `nil`（默认）按 owner 推断：`.ui` 为 `true`，`.mcp` 为 `false`。
    ///
    ///   ★ **这不是 owner 的固有属性，而是调用方的意图**，所以留了显式覆盖：
    ///   GUI 打字天然是「最新输入优先」（用户改了关键词，上一条就该丢）；
    ///   而 MCP 的一次 `locate_many` 会展开成 5 条同 session 的子查询，
    ///   如果同 owner 自动取代，第 2 条就会把第 1 条取消——**5 条只剩 1 条结果**。
    ///   Agent 要取消自己的旧请求，应当显式走 `cancel(queryID:requester:)` /
    ///   `cancelAll(owner:)`。
    public func submit(text: String,
                       queryID: UUID,
                       owner: SearchOwner,
                       sources: Set<String>? = nil,
                       supersedePrevious: Bool? = nil,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) {
        reapExpired()
        let supersede = supersedePrevious ?? owner.isUserInteractive
        if supersede {
            // 取代是**跨来源**的：上一轮 GUI 查询可能打过 NAS B，这一轮用户改成了
            // 「只搜本机」。若不扫全来源，NAS B 上那条旧查询会继续跑完再回来
            // 污染界面（这正是删掉 `lastQuery` 之后仍然成立的原因——真实状态在
            // running / cancelling / queues 里，不必另存一份可能过期的「最后 Query」）。
            supersedeAll(owner: owner, keeping: queryID)
        }
        for provider in providers where sources == nil || sources!.contains(provider.source.id) {
            enqueue(text: text, queryID: queryID, owner: owner, provider: provider, emit: emit)
        }
    }

    private func enqueue(text: String,
                         queryID: UUID,
                         owner: SearchOwner,
                         provider: any SearchProvider,
                         emit: @escaping @MainActor (ProviderEvent) -> Void) {
        let sid = provider.source.id
        let entry = Entry(queryID: queryID,
                          text: text,
                          owner: owner,
                          sourceID: sid,
                          provider: provider,
                          emit: emit,
                          deadline: now().addingTimeInterval(Double(queueWaitMs) / 1000))

        // 「能不能立刻跑」要同时看三个容器：槽位可能被正在跑的占着，
        // 也可能被**正在退出的**占着（cancelling）。只看 running 会让新旧两个
        // 查询同时压在同一个 provider 上。
        if running[sid] == nil, cancelling[sid] == nil, queues[sid] == nil {
            start(entry)
            return
        }
        if owner.isUserInteractive {
            // GUI 插到队首，但**不动**正在跑的那个。
            queues[sid, default: []].insert(entry, at: 0)
        } else {
            queues[sid, default: []].append(entry)
        }
    }

    private func start(_ entry: Entry) {
        running[entry.sourceID] = entry
        Task { @MainActor [weak self] in
            await entry.provider.search(entry.text, queryID: entry.queryID, owner: entry.owner) { event in
                entry.emit(event)
            }
            self?.finished(sourceID: entry.sourceID, queryID: entry.queryID)
        }
    }

    /// provider 的 `search()` 真正返回（无论成功、失败、被取消）后推进队列。
    ///
    /// ★ 这是**唯一**释放槽位的地方。`cancel` / `supersede` / `cancelAll` 都只把
    /// 条目移进 `cancelling`，不直接清空槽位——见类型注释规则 4。
    private func finished(sourceID: String, queryID: UUID) {
        if running[sourceID]?.queryID == queryID {
            running[sourceID] = nil
        } else if cancelling[sourceID]?.queryID == queryID {
            cancelling[sourceID] = nil
        } else {
            // 槽位早已让给别人（重复回调，或 provider 违约多调了一次）。
            // 这里绝不能 drain：会把别人的排队项提前放出来。
            return
        }
        drain(sourceID)
    }

    private func drain(_ sourceID: String) {
        guard running[sourceID] == nil, cancelling[sourceID] == nil else { return }
        guard var queued = queues[sourceID], !queued.isEmpty else {
            queues[sourceID] = nil
            return
        }
        let next = queued.removeFirst()
        queues[sourceID] = queued.isEmpty ? nil : queued
        start(next)
    }

    /// 用 `queryID` 取代 `owner` 的全部旧请求（跨来源）。
    ///
    /// 顺序固定为「先清排队、再请求取消在跑的」：
    /// 反过来会先用 `drain` 放出下一个，而那个下一个可能正是同类旧项。
    private func supersedeAll(owner: SearchOwner, keeping queryID: UUID) {
        // ① 排队项：从未交给 provider，终态必须由这里发，否则调用方永远 pending。
        for sid in Array(queues.keys) {
            guard let queued = queues[sid] else { continue }
            var kept: [Entry] = []
            for entry in queued {
                guard entry.owner == owner, entry.queryID != queryID else {
                    kept.append(entry); continue
                }
                emitTerminal(entry, state: .cancelled)
            }
            queues[sid] = kept.isEmpty ? nil : kept
        }

        // ② 在跑的项：只请求取消，槽位留到 provider 返回再放。
        for sid in Array(running.keys) {
            guard let entry = running[sid],
                  entry.owner == owner,
                  entry.queryID != queryID else { continue }
            running[sid] = nil
            cancelling[sid] = entry
            entry.provider.cancel(queryID: entry.queryID)
        }
    }

    // MARK: - 取消

    /// 按 `queryID` 取消**自己发起的**那一条。
    ///
    /// `requester` 不是可选的：`queryID` 本身是「一次具体请求」的身份，但调度器
    /// 只凭它无法知道**谁在调用**。不带发起方的取消 API 等于把 owner 不变量写成
    /// 一句注释——任何拿到别人 queryID 的调用方都能取消别人的查询。
    ///
    /// 跨 owner → 拒绝（不改状态、不碰 provider），并计入 `rejectedCancelCount`。
    public func cancel(queryID: UUID, requester: SearchOwner) {
        // ① 排队项：从未交给 provider，终态由这里发。
        for sid in Array(queues.keys) {
            guard let queued = queues[sid] else { continue }
            var kept: [Entry] = []
            for entry in queued {
                guard entry.queryID == queryID else { kept.append(entry); continue }
                guard entry.owner == requester else {
                    reject(requester: requester, target: entry)
                    kept.append(entry)          // 跨 owner 的项原样留在队列里
                    continue
                }
                emitTerminal(entry, state: .cancelled)
            }
            queues[sid] = kept.isEmpty ? nil : kept
        }

        // ② 在跑的项：移进 cancelling，等 provider 真正返回才放槽位。
        for sid in Array(running.keys) {
            guard let entry = running[sid], entry.queryID == queryID else { continue }
            guard entry.owner == requester else {
                reject(requester: requester, target: entry)
                continue
            }
            running[sid] = nil
            cancelling[sid] = entry
            entry.provider.cancel(queryID: queryID)
        }

        // ③ 已经在 cancelling 里的：重复取消是 **no-op**。
        //    `provider.cancel` 不保证幂等，再调一次会让「取消了一次」的诊断计数变成两次。
        //    但 owner 不匹配仍然要拒绝——它不是重复取消，是越权。
        for sid in Array(cancelling.keys) {
            guard let entry = cancelling[sid], entry.queryID == queryID else { continue }
            if entry.owner != requester { reject(requester: requester, target: entry) }
        }
    }

    /// 取消某个 owner 的全部请求（MCP 会话结束、Helper 退出、GUI 清空时用）。
    ///
    /// ★ **顺序不能反**：先清排队项、再请求取消在跑的。
    /// 如果先取消 running 再 `drain`，队首那条很可能就是这个 owner 的排队项
    /// ——于是「要求全部取消」反而把它启动了。这条顺序有专门的测试守着。
    public func cancelAll(owner: SearchOwner) {
        // ① 先清排队项，逐条发终态。
        for sid in Array(queues.keys) {
            guard let queued = queues[sid] else { continue }
            var kept: [Entry] = []
            for entry in queued {
                guard entry.owner == owner else { kept.append(entry); continue }
                emitTerminal(entry, state: .cancelled)
            }
            queues[sid] = kept.isEmpty ? nil : kept
        }

        // ② 再请求取消在跑的。
        for sid in Array(running.keys) {
            guard let entry = running[sid], entry.owner == owner else { continue }
            running[sid] = nil
            cancelling[sid] = entry
            entry.provider.cancel(queryID: entry.queryID)
        }

        // ③ 这里**不 drain**：槽位仍被 cancelling 占着，推进只能由 `finished` 触发。
    }

    private func reject(requester: SearchOwner, target: Entry) {
        rejectedCancelCount += 1
        lastRejectedCancel = (requester, target.owner, target.queryID, target.sourceID)
    }

    /// 给排队阶段的条目发终态。
    ///
    /// ★ `message` 默认 `nil`，且**取消类终态必须保持 `nil`**：App 层把非空 `message`
    /// 当作**用户可见警告**收进 `searchWarnings`。「被新输入取代」是最正常的路径，
    /// 弹警告是噪音。只有 `timedOut` 值得配文案（「排队超上限」对 Agent 是有用信息）。
    @discardableResult
    private func emitTerminal(_ entry: Entry,
                              state: ProviderSearchState,
                              message: String? = nil) -> ProviderEvent {
        let event = ProviderEvent(queryID: entry.queryID,
                                  sourceID: entry.sourceID,
                                  state: state,
                                  message: message)
        entry.emit(event)
        return event
    }

    // MARK: - deadline

    /// 把排队超时的项移除并回 `timedOut` 终态。
    ///
    /// 为什么做成「可主动调用」而不是内部起定时器：
    /// ① 测试能确定地推进时间，不用 sleep 赌调度；
    /// ② 生产侧由 App 的一个 tick 驱动，避免每条队列一个 Timer。
    ///
    /// 返回被移除的事件，便于断言（事件同时也已 emit 给调用方）。
    @discardableResult
    public func reapExpired() -> [ProviderEvent] {
        let t = now()
        var expired: [ProviderEvent] = []
        for sid in Array(queues.keys) {
            guard let queued = queues[sid] else { continue }
            var kept: [Entry] = []
            for entry in queued {
                guard entry.deadline <= t else { kept.append(entry); continue }
                expired.append(emitTerminal(entry,
                                            state: .timedOut,
                                            message: "排队等待超过上限，本次搜索没有执行"))
            }
            queues[sid] = kept.isEmpty ? nil : kept
        }
        return expired
    }

    // MARK: - 观测（测试与诊断）

    /// 某个来源当前在跑的 queryID。
    public func runningQuery(sourceID: String) -> UUID? { running[sourceID]?.queryID }

    /// 某个来源上「已请求取消、provider 还没返回」的 queryID。
    public func cancellingQuery(sourceID: String) -> UUID? { cancelling[sourceID]?.queryID }

    /// 某个来源的排队长度。
    public func queuedCount(sourceID: String) -> Int { queues[sourceID]?.count ?? 0 }

    /// 全部来源的排队长度之和。
    public var queuedTotal: Int { queues.values.reduce(0) { $0 + $1.count } }

    /// 正在跑的来源集合。
    public var runningSources: Set<String> { Set(running.keys) }

    /// 正在退出（cancelling）的来源集合。
    public var cancellingSources: Set<String> { Set(cancelling.keys) }

    /// 某个来源排队中各项的 owner（按队列顺序）。
    public func queuedOwners(sourceID: String) -> [SearchOwner] {
        (queues[sourceID] ?? []).map(\.owner)
    }

    /// 某个来源在跑的 queryID 集合（0 或 1 个）。诊断用，断言「同来源不并发」。
    public func activeQueryIDs(sourceID: String) -> [UUID] {
        [running[sourceID]?.queryID, cancelling[sourceID]?.queryID].compactMap { $0 }
    }
}
