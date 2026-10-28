import Foundation

/// 把**新到的一批**搜索结果并进已有列表。
///
/// 这个函数的唯一理由：设备是**按批**回结果的，而界面上那一份 `results`
/// 是滚动累积的。合并必须一次算完、一次写回，理由有三条：
///
/// 1. **一次赋值只发一次 `objectWillChange`。** 逐条 `append` 是每行发一次：
///    2000 行就是 2000 次「界面要重算」，而真正需要重算的只有最后那一次。
/// 2. **没有新增行就不重排。** 后台补全元数据（挂载路径、能否打开）会把
///    同一批行走第二遍，这时 `(rank, name)` 一个都没变 —— 重排 2000 行
///    纯属白干。判据用「排序键变没变」，不是调用方口头保证的 `isMetadataUpdate`。
/// 3. **顺序要能被断言。** 原来直接 `sort { rank == rank ? name < name : … }`
///    在同 rank 同名时是**不稳定**的：同一份数据两次跑出两种顺序，测试只能
///    绕着走。这里补了 `id` 作为最后的比较键，排序从此是全序。
///
/// 判定放在 Core 而不是界面里：`FlashFind2App` 是 executableTarget，
/// 测试依赖不上 —— 写在界面里的规则等于没测。
public enum SearchResultMerge {

    /// 显示顺序：综合分降序 → 相关度 rank 升序 → 文件名升序 → id 升序。
    ///
    /// ## 为什么综合分排在 rank 前面（2026-10-28）
    ///
    /// 用户要求「按最后修改日期和模糊搜索匹配度优先展示最有可能的文件」。
    /// `rank` 只有 0…4 五档，同档里几千条结果只能按文件名排——搜 `报告`
    /// 时拿到的是 `报告-A` 到 `报告-Z`，而不是最近改过的那几份。
    ///
    /// ## 为什么「两侧都是 0 时退回旧口径」不是妥协
    ///
    /// `score == 0` 的含义是「这一行没被评分」（见 `SearchResult.score` 的说明）。
    /// 预览夹具、手工构造的结果、既有测试都停在这个状态上；让它们继续走
    /// 旧口径，等于**没有评分的地方行为一个字都没变**。真实搜索路径一定评分，
    /// 所以界面上的顺序全部由综合分决定。
    ///
    /// 判据写成 `a.score != b.score` 而不是「都非 0 才比」：一侧评了分、
    /// 一侧没评时（同一批里混进预览行）也要有个确定顺序，0 分自然排最后——
    /// 这与「没评分 = 最不可信」一致。
    public static func precedes(_ a: SearchResult, _ b: SearchResult) -> Bool {
        if a.score != b.score { return a.score > b.score }
        if a.rank != b.rank { return a.rank < b.rank }
        if a.name != b.name { return a.name < b.name }
        return a.id < b.id
    }

    /// 返回合并后的新数组；**输入数组一个字节都不改**。
    ///
    /// - 同 id 的行原地替换（设备重复发同一行、或元数据补全回填）；
    /// - 新 id 追加；
    /// - 只有「新增了行」或「替换改变了排序键（rank/name）」才重排。
    public static func apply(existing: [SearchResult], incoming: [SearchResult]) -> [SearchResult] {
        guard !incoming.isEmpty else { return existing }
        var merged = existing
        var index = [String: Int](minimumCapacity: existing.count)
        for (offset, row) in existing.enumerated() where index[row.id] == nil {
            index[row.id] = offset
        }
        var needsSort = false
        for row in incoming {
            if let offset = index[row.id] {
                let previous = merged[offset]
                // 完全相同的行：连写回都不必要（省掉一次无意义的界面刷新）。
                guard previous != row else { continue }
                if previous.rank != row.rank || previous.name != row.name
                    || previous.score != row.score { needsSort = true }
                merged[offset] = row
            } else {
                index[row.id] = merged.count
                merged.append(row)
                needsSort = true
            }
        }
        if needsSort { merged.sort(by: precedes) }
        return merged
    }
}
