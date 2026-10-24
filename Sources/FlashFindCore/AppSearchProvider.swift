import Foundation

/// 应用搜索来源：在标准应用目录里找已安装的 app（新增功能）。
///
/// 与 `LocalSearchProvider` 并列，同属「本机」一侧（`source.type == .local`），
/// 因此由 `SearchCoordinator` **立即执行、不走 600ms 防抖**——防抖是为 NAS
/// 请求节流用的，应用搜索只是一次目录列举，没有理由让用户多等半秒。
///
/// 扫描入口是构造注入的（`@Sendable () -> [AppSearchCandidate]`）：
/// 测试里喂固定列表，真机上用 `AppCatalog.scan()`。漏装配也能编译通过，
/// 所以这里没有给默认值以外的可选路径——默认值就是真机路径。
@MainActor
public final class AppSearchProvider: SearchProvider {
    public let source = SearchSource.apps

    /// 结果上限。应用命中通常很集中，20 条足够铺满一屏。
    public var limit: Int

    /// 目录枚举结果的缓存寿命（秒）。
    ///
    /// 名字要取访达显示的那个，就得逐个 App 读 Spotlight 元数据——136 个 App 约 47ms。
    /// 这条来源不走 600ms 防抖（本机来源立即执行），所以每敲一个字符都要在主线程上
    /// 花掉这 47ms，打字会发黏。缓存 30 秒把它摊平：新装的 App 最迟半分钟内出现，
    /// 换来的是每个字符只做一次纯内存比对。
    public var cacheLifetime: TimeInterval

    private let scan: @Sendable () -> [AppSearchCandidate]
    private var cached: [AppSearchCandidate]?
    private var cachedAt: Date?

    public init(limit: Int = 20, cacheLifetime: TimeInterval = 30,
                scan: @escaping @Sendable () -> [AppSearchCandidate] = { AppCatalog.scan() }) {
        self.limit = limit
        self.cacheLifetime = cacheLifetime
        self.scan = scan
    }

    /// 取消是空操作：搜索在同一次调用里同步跑完，没有可取消的中间态。
    /// 迟到事件的拦截在 `SearchCoordinator`（它只转发 queryID 对得上的事件）。
    public func cancel(queryID: UUID) {}

    /// 取应用清单：缓存没到期就用上次的，到期或第一次才真扫。
    private func candidates() -> [AppSearchCandidate] {
        if let cached, let cachedAt, Date().timeIntervalSince(cachedAt) < cacheLifetime {
            return cached
        }
        let fresh = scan()
        cached = fresh
        cachedAt = Date()
        return fresh
    }

    public func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
        // 应用没有扩展名可言：一旦查询带了格式限制（`报告 ppt`），
        // 应用侧就该保持安静——否则「ppt」会被当成应用名去匹配。
        let parsed = SearchQueryParser.parse(text)
        guard !parsed.hasFormatFilter, !parsed.keywords.isEmpty else {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, results: [],
                               state: .completed, reportedTotal: 0))
            return
        }
        let hits = AppCatalog.matches(candidates(), query: parsed.keywords, limit: limit)
        // 就绪判据是拿到 total，不是收到 finished：空结果也要带 0 一起落终态，
        // 否则 SearchCompletionTracker 会一直把这一条记在 pending 里，
        // 状态栏永远显示「正在搜索」。
        emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                           results: hits.map { candidate in
                               SearchResult(id: "app:" + candidate.url.path,
                                            name: candidate.name,
                                            relativePath: candidate.url.path,
                                            sourceID: source.id,
                                            sourceName: source.displayName,
                                            kind: "app",
                                            size: nil,
                                            localURL: candidate.url,
                                            // 名次与排序同源：`matches` 已经筛过一遍，
                                            // 这里若按显示名单算，别名命中的那行会被写成 1。
                                            rank: AppCatalog.rank(for: candidate, query: parsed.keywords) ?? 2)
                           },
                           state: .completed,
                           reportedTotal: hits.count))
    }
}
