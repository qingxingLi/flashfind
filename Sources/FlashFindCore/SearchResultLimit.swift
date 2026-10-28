import Foundation

/// 一次搜索先显示多少条、以及「继续搜索」一次再放多少条。
///
/// 用户 2026-10-28：「一次搜索上限 暂定搜索上限 200」；同一天追加：
/// 「限制 200 结果后，如对结果不满意，可以选择继续搜索」。
/// 于是 200 不再是硬上限，而是**第一批**：状态栏给一个「继续搜索」，
/// 每点一次再放 `step` 条，直到候选池用尽。
///
/// ## 为什么上限在**客户端**而不是让设备少返回
///
/// 设备侧的 `maxResults` 是 2000（`MyNASCore/lib/core.dart`），它是**候选池**。
/// 要挑出「最有可能的那 200 个」，先得看见更多候选：按名字与时间排序需要
/// 全局信息，只取设备给的前 200 条等于「设备怎么排就怎么算」。
/// 所以 2000 保持不动，200 只发生在显示层——这也意味着调大调小都不用重编核心。
public enum SearchResultLimit {

    /// 第一批显示多少条（也是「继续搜索」每次追加的条数）。
    ///
    /// 两个数刻意同值：用户说的是「一次搜索上限 200」，
    /// 「继续搜索」一次再给一屏的量，手感才连续。
    public static let perSearch = 200

    /// 「继续搜索」每次追加的条数。
    public static let step = perSearch

    /// 结果被截断时的说明；没截断返回 nil。
    ///
    /// ★ 必须说清「还有多少没显示」：只说「200 项」会让用户以为
    /// 目录里只有 200 个匹配，从而得出「我的文件丢了」这个结论。
    public static func caption(totalMatched: Int, shown: Int) -> String? {
        guard totalMatched > shown, shown > 0 else { return nil }
        return "共 \(totalMatched) 条匹配，已按匹配度与修改日期排好，先显示前 \(shown) 条"
    }

    /// 状态栏上那个按钮的字。候选还有没显示的就说「继续搜索」。
    public static let continueTitle = "继续搜索"

    /// 悬停说明：写清这一次会多出多少条。
    public static func continueHelp(remaining: Int) -> String {
        remaining > 0 ? "再显示 \(min(remaining, step)) 条（还有 \(remaining) 条没显示）" : continueTitle
    }
}

/// 一次搜索的**结果窗口**：先显示最可能有用的前 N 条，剩余候选留在池子里等「继续搜索」。
///
/// ## 为什么是「有状态的值类型」而不是几个 @Published 变量
///
/// 四件事必须同时成立，拆成几个变量就一定会在某个清空点漏掉一个：
///
/// 1. `all` 是收到的全部候选（已排序、已去重）——「继续搜索」只能从这里取；
/// 2. `rows` 是界面显示的那一批（`all` 的前 `limit` 条，每次变更只赋值一次）；
/// 3. `totalMatched` 是**去重后的真实匹配数**——截断之后从 `rows.count`
///    再也推不出来，必须单独累计；
/// 4. 「同一条结果第二次到达」不能把 `totalMatched` 加两遍（设备会重复发，
///    后台补全元数据还会整批重发），所以要记 `seen`。
///
/// 做成 `mutating` 的值类型之后，「清空」只有 `reset()` 一条路，
/// 而且这四件事是**一起**被清掉的。
///
/// ## 为什么截断不会漏掉「后到的更相关结果」
///
/// 每一批都重新 `apply` + 重排全池：后到的行如果能排进前 `limit` 就会挤掉末尾那条。
/// 前提是「一条结果的分数在它到达时就定了」——事实如此（分数只依赖
/// 名字、路径、修改时间，这三样都不会在到达后改变）。
public struct SearchResultWindow: Equatable {

    /// 收到的全部候选（已按 `SearchResultMerge.precedes` 排好、已去重）。
    public private(set) var all: [SearchResult] = []
    /// 本次搜索**去重后**匹配到的总条数。
    public private(set) var totalMatched = 0
    /// 当前显示前多少条。
    public private(set) var limit: Int
    private var seen: Set<String> = []

    public init(limit: Int = SearchResultLimit.perSearch) {
        self.limit = max(0, limit)
    }

    /// 界面显示的那一批。
    ///
    /// 每次都从 `all` 现取：加进来一条更好的、或者点了「继续搜索」，
    /// 都只有 `all` / `limit` 在变，不存在「两份列表谁先谁后」的问题。
    public var rows: [SearchResult] { Array(all.prefix(limit)) }

    /// 还有没显示的候选（「继续搜索」是否该出现）。
    public var canShowMore: Bool { all.count > limit }

    /// 还没显示的条数。
    public var hiddenCount: Int { max(0, all.count - limit) }

    public var isTruncated: Bool { totalMatched > rows.count }

    /// 给状态栏用的一句话；没截断为 nil。
    public var caption: String? {
        SearchResultLimit.caption(totalMatched: totalMatched, shown: rows.count)
    }

    /// 并入一批结果。
    ///
    /// - 只做一次合并（一次 `objectWillChange`，由调用方赋值 `rows`）；
    /// - 空批次直接返回，连排序都不做。
    public mutating func integrate(_ incoming: [SearchResult]) {
        guard !incoming.isEmpty else { return }
        for row in incoming where seen.insert(row.id).inserted { totalMatched += 1 }
        all = SearchResultMerge.apply(existing: all, incoming: incoming)
    }

    /// 「继续搜索」：再放 `step` 条。
    ///
    /// 返回是否真的多了（候选已经全部显示时返回 false，按钮就该消失）。
    @discardableResult
    public mutating func showMore(step: Int = SearchResultLimit.step) -> Bool {
        guard canShowMore, step > 0 else { return false }
        limit = min(all.count, limit + step)
        return true
    }

    /// 清空（新一次搜索 / 查询词变化 / 断开来源）。
    public mutating func reset() {
        all = []
        totalMatched = 0
        seen.removeAll(keepingCapacity: false)
    }

    /// 预览与夹具用：直接塞一份结果（不走去重集合，`totalMatched` 就是这份的条数）。
    ///
    /// ★ 它**也要截断**：截图里那张「200 / 240 项」必须由同一段代码算出来，
    /// 否则「上限生效时的样子」只能靠手工摆一个假数字。
    public static func fixture(_ rows: [SearchResult], limit: Int = SearchResultLimit.perSearch) -> SearchResultWindow {
        var window = SearchResultWindow(limit: limit)
        window.all = rows.sorted(by: SearchResultMerge.precedes)
        window.totalMatched = rows.count
        return window
    }
}
