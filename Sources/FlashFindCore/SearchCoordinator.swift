import Foundation

@MainActor public final class SearchCoordinator {
    public private(set) var queryID: UUID?
    private var providers: [any SearchProvider]

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

    public init(providers: [any SearchProvider]) { self.providers=providers }

    public func cancel() {
        debounceTask?.cancel(); debounceTask=nil
        localTask?.cancel(); localTask=nil
        remoteTask?.cancel(); remoteTask=nil
        if let queryID { for provider in providers { provider.cancel(queryID: queryID) } }
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
    private func supersede(with id: UUID) {
        if let previous = queryID, previous != id {
            for provider in providers { provider.cancel(queryID: previous) }
        }
        localTask?.cancel(); localTask=nil
        remoteTask?.cancel(); remoteTask=nil
    }

    private func run(_ selected: [any SearchProvider], text: String, emit: @escaping @MainActor (ProviderEvent)->Void, id: UUID) -> Task<Void,Never> {
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for provider in selected {
                    group.addTask { @MainActor [weak self] in
                        guard let self, self.queryID==id, !Task.isCancelled else { return }
                        await provider.search(text, queryID:id) { [weak self] event in
                            guard let self, self.queryID==id, event.queryID==id else { return }
                            emit(event)
                        }
                    }
                }
            }
        }
    }
}