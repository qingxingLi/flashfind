import Foundation

@MainActor public final class SearchCoordinator {
    public private(set) var queryID: UUID?
    private var providers: [any SearchProvider]
    /// 调度器：GUI 与 MCP 共用同一份「按来源排队」的事实（P3）。
    ///
    /// 为什么 GUI 也必须有它：provider 的「同一来源只有一个活跃查询」是设备约束，
    /// 不是 GUI 专属逻辑。GUI 与 Agent 各自直接调 provider 时，那个槽位就成了
    /// 双方争抢的共享状态——谁后到谁取消谁，与调用方的意图无关。
    /// 排队与「谁能取消谁」必须收在一处，否则两边的规则永远对不齐。
    private let scheduler: SearchScheduler
    /// 排队超时的驱动器。GUI 也可能排在 Agent 后面，不能只靠 submit 时顺带清理。
    private var reapTicker: Task<Void, Never>?

    /// 本地与远端各自独立的任务槽：防抖只推迟远端，本地必须立即执行，
    /// 因此两者不能共用一个 Task，否则晚到的远端查询会取消本地查询。
    private var localTask: Task<Void,Never>?
    private var remoteTask: Task<Void,Never>?
    private var debounceTask: Task<Void,Never>?

    /// 防抖窗口。连续输入时只为稳定后的文本发起一次远端查询。
    ///
    /// 这**不是**为规避设备退化： 的间隔对照实验（210 次搜索，
    /// 0.5s/1s/2s/5s 四档间隔全部 100%）证明任务间隔不影响成功率。
    /// 此处的 debounce 只是避免用户输入 `odoo` 过程中产生 4 次无谓的远端请求。
    public static let debounceInterval: Duration = .milliseconds(600)

    public init(providers: [any SearchProvider]) {
        self.providers = providers
        self.scheduler = SearchScheduler(providers: providers)
    }

    /// 给 MCP 用的同一个调度器实例（Phase 6.3b-1）。
    ///
    /// ★ 必须是**同一个对象**，不能另造一个：`SearchScheduler` 的队列与槽位就是
    /// 「同一来源同时只跑一个查询」这条设备约束的唯一落点。MCP 若自己 new 一个，
    /// GUI 与 Agent 就会各排一条队，同时压到同一台 NAS 上——P3 修掉的正是这个。
    public var searchScheduler: SearchScheduler { scheduler }

    /// 排队超时的节拍器。懒启动：没有排队时它只是每秒空转一次 `reapExpired()`。
    ///
    /// `guard let self else { return }` 是必须的：coordinator 被释放后
    /// 这个 Task 不能继续持着旧实例空转（测试里每个用例都会新建一个）。
    private func ensureReapTicker() {
        guard reapTicker == nil else { return }
        reapTicker = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(1))
                guard let self else { return }
                self.scheduler.reapExpired()
            }
        }
    }

    public func cancel() {
        debounceTask?.cancel(); debounceTask=nil
        localTask?.cancel(); localTask=nil
        remoteTask?.cancel(); remoteTask=nil
        // 取消统一走调度器：它知道 GUI 这一轮打过哪些来源（可能比当前 sources 多）。
        // ★ 不要再额外 `for provider in providers { provider.cancel(queryID:) }`：
        // provider 的 cancel 不保证幂等，两边都调会让诊断计数翻倍，
        // 也会把「取消了一次」的断言变成「取消了两次」。
        scheduler.cancelAll(owner: .ui)
        queryID=nil
    }

    /// 防抖入口：**本地立即执行，远端在静默窗口后只发一次。**
    @discardableResult
    public func searchDebounced(_ text: String, sources: Set<String>? = nil, emit: @escaping @MainActor (ProviderEvent)->Void) -> UUID? {
        searchDebounced(text, sources: sources, queryID: UUID(), emit: emit)
    }

    /// 由调用方指定 queryID 的防抖入口（P1-01）。
    ///
    /// **App 的正常路径必须走这个**：不传的话这里会另造一个 UUID，
    /// 于是 AppModel 与 Coordinator 各持一个 ID，日志里永远对不上谁是谁
    /// （BUG-006）。不传的重载只给测试与直接调用保留。
    @discardableResult
    public func searchDebounced(_ text: String, sources: Set<String>? = nil, queryID external: UUID, emit: @escaping @MainActor (ProviderEvent)->Void) -> UUID? {
        let id = external
        debounceTask?.cancel()
        supersede(with: id)
        let selected = providers.filter { sources == nil || sources!.contains($0.source.id) }
        let local = selected.filter { $0.source.type == .local }
        let remote = selected.filter { $0.source.type != .local }
        queryID = id
        if !local.isEmpty { localTask = run(local, text: text, emit: emit, id: id) }
        if !remote.isEmpty {
            debounceTask = Task { [weak self] in
                try? await Task.sleep(for: Self.debounceInterval)
                guard let self, !Task.isCancelled, self.queryID == id else { return }
                self.remoteTask = self.run(self.remoteProviders(sources: sources),
                                           text: text, emit: emit, id: id)
            }
        }
        return id
    }

    /// 立即发起搜索（不防抖）。用于回车提交等明确意图。
    @discardableResult
    public func search(_ text: String, sources: Set<String>? = nil, emit: @escaping @MainActor (ProviderEvent)->Void) -> UUID {
        search(text, sources: sources, queryID: UUID(), emit: emit)
    }

    /// 由调用方指定 queryID 的立即入口（P1-01）。见 `searchDebounced` 的说明。
    @discardableResult
    public func search(_ text: String, sources: Set<String>? = nil, queryID external: UUID, emit: @escaping @MainActor (ProviderEvent)->Void) -> UUID {
        debounceTask?.cancel(); debounceTask=nil
        let id = external
        supersede(with: id)
        queryID = id
        localTask = run(providers.filter { $0.source.type == .local && (sources == nil || sources!.contains($0.source.id)) },
                        text: text, emit: emit, id: id)
        remoteTask = run(providers.filter { $0.source.type != .local && (sources == nil || sources!.contains($0.source.id)) },
                         text: text, emit: emit, id: id)
        return id
    }

    private func remoteProviders(sources: Set<String>?) -> [any SearchProvider] {
        providers.filter { $0.source.type != .local && (sources == nil || sources!.contains($0.source.id)) }
    }

    /// 新查询作废旧查询：旧 query 不得污染新 query 的结果。
    /// 这是既定行为（testNewQueryRejectsDeliberatelyLateOldEvents）。
    ///
    /// 「取消 provider 上的旧请求」这一步交给调度器做（见 `SearchScheduler.submit`
    /// 的 `supersedePrevious`）：它按 owner 扫 running / cancelling / queues，
    /// 天然覆盖「上一轮打过、这一轮没打」的来源（例如用户从「全都搜」改成「只搜本机」）。
    /// 这里重复调一次只会让同一个 queryID 被取消两次，而 provider 的 cancel 不幂等。
    private func supersede(with id: UUID) {
        localTask?.cancel(); localTask=nil
        remoteTask?.cancel(); remoteTask=nil
    }

    private func run(_ selected: [any SearchProvider], text: String, emit: @escaping @MainActor (ProviderEvent)->Void, id: UUID) -> Task<Void,Never> {
        Task { @MainActor [weak self] in
            guard let self, self.queryID == id, !Task.isCancelled else { return }
            self.ensureReapTicker()
            // 交给调度器：按来源排队，按 owner 决定谁能取消谁。
            // 跨来源并行是调度器的固有性质（每个 source 独立一条队列），
            // 因此这里不再需要 task group —— 原实现每个 provider 起一个 Task，
            // 只是把「并行」写在了调用侧，反而让「同一来源只能有一个」无处安放。
            self.scheduler.submit(text: text,
                                  queryID: id,
                                  owner: .ui,
                                  sources: Set(selected.map(\.source.id)),
                                  supersedePrevious: true) { [weak self] event in
                // 门禁留在这一层：迟到的旧查询事件不得污染当前查询的界面。
                guard let self, self.queryID == id, event.queryID == id else { return }
                emit(event)
            }
        }
    }
}