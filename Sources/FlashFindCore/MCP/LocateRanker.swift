import Foundation

/// `locate` 的排序：**每条结果自己的函数**（方案 §7.1 / §7.3）。
///
/// ## 它在 `SearchResultRanker` **之上**组合，而不是另写一套名字匹配
///
/// ```text
///               SearchResultRanker          ← lexical（名字/路径）唯一事实来源
///                      ↑
///                 LocateRanker              ← 在这里加上 locate 独有的信号
///                （本类型）
/// ```
///
/// 三个 Tool 的分工（§15 #29，v0.27 拍板）：
///
/// | Tool | 用什么排 | 为什么 |
/// | --- | --- | --- |
/// | `locate` | `LocateRanker`（lexical + 修改时间） | 强排序、少量，要给 Agent `score` 与 `reasons` |
/// | `search` | `SearchResultRanker.rank` 原始档位 | 宽口径、多结果、**不做历史加权**，也不编一个 composite 分 |
/// | `locate_many` | 每条子查询各自走 `locate` | 它本来就是「N 次 locate」 |
///
/// ★ 不要写成 `SearchResultRanker(mode: .locate)` / `(mode: .search)`：
/// 一个类里堆 mode 分支，等于把三种产品语义重新揉成一个东西，
/// 而它们恰恰是**故意**不同的（方案 §4.3）。
///
/// ## 这一版只使用当前真实可获得的两个信号
///
/// | 信号 | 权重 | 这一版的状态 |
/// | --- | ---: | --- |
/// | `name-match` | 0.65 | ✅ 用现有 `SearchResultRanker` 的 0…4 档 |
/// | `recently-modified` | 0.15 | ✅ 结果自带修改时间时可用 |
/// | `metadata-access` | 0.15 | ⛔ **恒 0，且不生成 reason**（1.1.2 还没有 History） |
/// | `located-recently` | 0.05 | ⛔ 同上 |
///
/// ★ 后两个**不许伪造**：没有历史数据时既不给分，也不往 `reasons` 里写一个看起来
/// 很懂的名字。`reasons` 是给 Agent 的因果说明，编一个理由比少一个理由坏得多——
/// 它会照着这个理由去推断「闪寻记得我用过这个文件」。
///
/// ★ 缺 `modifiedDate` 的来源（部分 WebDAV）在这一项上拿 0。这是**已知偏差**：
/// 它让同一批结果里「没给时间的来源」系统性低 0.15。等 §15 #24 一起决定要不要
/// 改成「按可用信号归一化」——那是评分口径的改变，不能顺手做。
public enum LocateRanker {

    /// §7.1 的权重。**只在测试与这里出现**，不在别处抄一份。
    public static let nameMatchWeight = 0.65
    public static let recentlyModifiedWeight = 0.15

    /// `recently-modified` 的衰减半衰期：30 天。
    ///
    /// 方案只给了「文件本身近期修改过」这一句话，没给曲线。取指数衰减而不是阈值，
    /// 是为了让「上周改的」与「三年前改的」不在同一个档上——阈值会让边界两侧
    /// 差出整整 0.15，排序在边界附近抖。
    public static let modifiedHalfLifeDays = 30.0

    /// 超过这个年龄就不再声称「近期修改过」。一个月是「近期」的口语含义。
    public static let reasonMaxAge: TimeInterval = 30 * 86_400

    /// `SearchResultRanker` 的 0…4 档 → `[0,1]` 的强度。
    ///
    /// ```text
    /// 0 整名相同      1.00
    /// 1 文件名前缀    0.75
    /// 2 文件名全词    0.50
    /// 3 仅路径命中    0.25
    /// 4 其它          0.00   ← 连路径都没命中：我们说不出它为什么在这，
    ///                          所以不给分，也不给 name-match 这个理由
    /// ```
    ///
    /// ## 档距是 0.25，不是「看着顺眼」
    ///
    /// 档距 × 权重 = `0.25 × 0.65 = 0.1625`，而 `recently-modified` 的**最大**贡献
    /// 是 0.15。也就是说：**任何一档名字差距都压得过「更新一些」**，§7.1 那条
    /// 「不能让不像的翻上来」由算术保证，不靠调参运气。
    ///
    /// ★ 第一版取的是 0.2 档距（1.0/0.8/0.6/0.4），算出来 `0.65 × 0.2 = 0.13 < 0.15`
    /// ——一个刚改过 1 分钟的文件会把「名字完全一致」挤到第二。
    /// `testASharperNameMatchOutranksAFresherFile` 就是被这条打红之后补的。
    public static func nameMatchStrength(rank: Int) -> Double {
        switch rank {
        case 0: return 1.0
        case 1: return 0.75
        case 2: return 0.5
        case 3: return 0.25
        default: return 0.0
        }
    }

    /// 修改时间的新近度 `[0,1]`。没有时间 → 0（不猜）。
    public static func recencyStrength(modified: Date?, now: Date) -> Double {
        guard let modified else { return 0 }
        let age = now.timeIntervalSince(modified)
        // 未来时间（时钟偏移 / 设备时区错）按「刚刚」处理，不要让 exp 变成 >1。
        guard age > 0 else { return 1 }
        return exp(-age / (modifiedHalfLifeDays * 86_400))
    }

    /// 一条结果的分数与理由。
    public static func score(name: String,
                             path: String,
                             modified: Date?,
                             query: String,
                             now: Date) -> (score: Double, reasons: [LocateReason]) {
        let rank = SearchResultRanker.rank(name: name, path: path, query: query)
        let nameStrength = nameMatchStrength(rank: rank)

        var score = nameMatchWeight * nameStrength
        var reasons: [LocateReason] = []
        if nameStrength > 0 { reasons.append(.nameMatch) }

        let recency = recencyStrength(modified: modified, now: now)
        if recency > 0 {
            score += recentlyModifiedWeight * recency
            // 分数永远按连续曲线算，理由只在「一个月内」时才给：
            // 「三年前改过」加上 0.0001 分不代表它近期动过。
            if let modified, abs(now.timeIntervalSince(modified)) <= reasonMaxAge {
                reasons.append(.recentlyModified)
            }
        }

        // 浮点尾巴（0.80000000000000004）会原样进 Agent 的上下文，
        // 也会让「同一输入两次跑出同一串」的断言在别的机器上抖。收成 6 位小数。
        let rounded = (score * 1_000_000).rounded() / 1_000_000
        return (min(max(rounded, 0), 1), reasons)
    }
}
