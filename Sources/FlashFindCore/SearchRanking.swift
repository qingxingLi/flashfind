import Foundation

/// 一条搜索结果「有多值得排在前面」的**唯一算法**。
///
/// 用户 2026-10-28 的要求原话：「搜索上限能否根据最后修改日期和模糊搜索
/// 匹配度进行优先展示最有可能的 200 个文件」。所以分数只有两个输入：
///
/// ```text
/// score = 0.72 × 匹配度 + 0.28 × 新近度
/// ```
///
/// ## 为什么匹配度权重明显更大
///
/// 搜索的第一诉求是「找对」，其次才是「找新」。反过来配权重的话，
/// 搜 `报告` 时一堆名字里根本没有「报告」、只是昨天刚改过的文件会挤到前面——
/// 那不是搜索，是「最近文件」。
///
/// ## 为什么要留 0.28 给时间而不是 0
///
/// 同一个名字系列（`月报-2026-01` … `月报-2026-09`）的匹配度完全一样，
/// 没有时间项时排序只能退化成「按文件名」，用户拿到的是最旧的那份。
///
/// ## 数值都是产品行为，测试逐条锁着
///
/// 改任何一个常量都会让 `SearchRankingTests` 里对应的断言红——
/// 这是故意的：这些数字调起来「感觉都行」，不锁就会在某次重构里被悄悄改掉。
public enum SearchRanking {

    /// 匹配度权重。
    public static let matchWeight = 0.72

    /// 新近度权重。
    public static let recencyWeight = 0.28

    /// 新近度的半衰期：改动距今 180 天，新近度掉到 0.5。
    ///
    /// 半年是个折中：文件管理里「最近半年」几乎等于「最近在用的」，
    /// 而一年以上的归档件本来就不该压过上周改过的东西。
    public static let recencyHalfLife: TimeInterval = 180 * 24 * 60 * 60

    /// 没有修改时间时的新近度。
    ///
    /// 既不是 1（不许无日期的东西冒充最新），也不是 0（设备没给时间
    /// 不等于文件老——SMB 与网页来源都可能不给）。取一个「略低于中位」的值，
    /// 让它在匹配度相同时排在有日期的旧文件之后、明显旧文件之前。
    public static let undatedRecency = 0.25

    /// 新近度：0…1，越新越大；无日期取 `undatedRecency`。
    public static func recency(modified: Date?, now: Date) -> Double {
        guard let modified else { return undatedRecency }
        let age = now.timeIntervalSince(modified)
        // 设备时间比本机快（时钟漂移、时区写错）时 age 为负：
        // 当成「刚刚改过」处理，不能算出 > 1 的分数去压过一切。
        guard age > 0 else { return 1 }
        return pow(0.5, age / recencyHalfLife)
    }

    /// 综合分：匹配度与时间的加权和。
    public static func score(match: Double, modified: Date?, now: Date) -> Double {
        let clamped = min(max(match, 0), 1)
        return matchWeight * clamped + recencyWeight * recency(modified: modified, now: now)
    }

    /// 便利入口：从名字/路径/查询词直接算综合分。
    public static func score(name: String, path: String = "", query: String,
                             modified: Date?, now: Date) -> (rank: Int, match: SearchMatchGrade, score: Double) {
        let evaluation = SearchMatch.evaluate(name: name, path: path, query: query)
        return (evaluation.grade.legacyRank, evaluation.grade,
                score(match: evaluation.value, modified: modified, now: now))
    }
}
