import Foundation

/// 一条结果的**匹配质量**：等级 + 0…1 的分值。
///
/// ## 为什么要有「等级」和「分值」两样
///
/// 等级是**可断言的语义**（整名命中 / 前缀 / 词命中 / 子序列 / 容错 / 路径 /
/// 不命中），既有 `rank` 的 0…4 就是它的投影；分值是给排序和「取前 200」
/// 用的连续量——两件事混成一个数就会出现「改了权重，测试全绿但其实
/// 前缀命中掉到了词命中后面」这种看不出来的退化。
///
/// ## 与旧 `SearchResultRanker` 的关系
///
/// 那套 0…4 的口径**原样保留**（`rank` 字段、MCP 的 `ranking score` 都在用），
/// 这里只是把它细化：`rank` 说「哪一档」，`grade` 说「这一档里是不是靠
/// 模糊才命中」，`value` 说「具体多像」。
///
/// 性能：这个函数在 `NASSearchProvider.result` 里是**一行一次**调用的
/// （2000 行 / 次搜索，跑在主线程上）。所以归一化只做一次，
/// 子序列与编辑距离**只在前面几档都没命中时**才跑——设备返回的结果
/// 绝大多数在「词命中」那档就结束了。
/// ## 用户 2026-10-28 定的四层优先级（`rawValue` 就是这四层的顺序）
///
/// 「同名优先 → 关键词在前边的优先 → 匹配字符多的优先 → 可能相关的」，
/// 每层之内比时间（时间项在 `SearchRanking`，占 0.28）。
///
/// ★ `rawValue` 只是**排序序号**，不对外、不落盘；对外口径永远是 `legacyRank`
/// 的 0…4。2026-10-28 之前 `pathOnly` 的序号大于 `subsequence`，而它的分值
/// 更低——顺序与分值不同向，这次一并理顺（分值区间也改成互不重叠）。
public enum SearchMatchGrade: Int, Comparable, Sendable, CaseIterable {
    /// 一点都不像（仍然会显示，只是排在最后、最容易被上限挤掉）。
    case none = 0
    /// 文件名里没全命中，但完整路径里都出现了。
    case pathOnly = 1
    /// 打错字了，但编辑距离在容忍范围内（`flshfind` → `nasuser`）。
    case typo = 2
    /// 按顺序命中，但**缺字符**（4 个字里中 3 个）——第 3 层「匹配字符多」的
    /// 下沿：命中率越高越靠前。
    case partial = 3
    /// 字符按顺序全部出现，但不连续（`bsr` → `best_seller_report`）。
    case subsequence = 4
    /// 查询拆开的每个词都在文件名里（顺序不限）。
    case terms = 5
    /// 文件名以查询串开头。
    case prefix = 6
    /// 文件名（**去掉扩展名**）与查询串完全一致：「报告.pdf」搜「报告」。
    case exact = 7

    public static func < (lhs: SearchMatchGrade, rhs: SearchMatchGrade) -> Bool {
        lhs.rawValue < rhs.rawValue
    }

    /// 这一档对应的**旧 rank 值**（0 最好，4 最差）。
    ///
    /// ★ 子序列与容错都归到 4：它们的语义就是旧注释里的「其它，
    /// 仍然会显示，只是排在更后面」。让它们各自占一个 rank 会改掉
    /// `rank` 这个对外字段的取值范围，MCP 的排序说明与既有断言都要跟着变，
    /// 而真正需要区分它们的是 `score`，不是 `rank`。
    public var legacyRank: Int {
        switch self {
        case .exact: return 0
        case .prefix: return 1
        case .terms: return 2
        case .pathOnly: return 3
        case .subsequence, .partial, .typo, .none: return 4
        }
    }
}

public struct SearchMatchScore: Equatable, Sendable {
    public let grade: SearchMatchGrade
    /// 0…1，越大越像。`none` 是 0。
    public let value: Double

    public init(grade: SearchMatchGrade, value: Double) {
        self.grade = grade
        self.value = value
    }

    public static let none = SearchMatchScore(grade: .none, value: 0)
}

public enum SearchMatch {

    // MARK: - 阈值（改这里就是改产品行为，测试逐条锁着）

    /// 子序列匹配要求的最小紧凑度：查询长度 / 首末字符跨度。
    ///
    /// `0.34` 意味着「3 个字符最多摊开在 9 个字符里」。不设这条，
    /// `abc` 会命中任何含 a、b、c 的长文件名，搜什么都是满屏。
    public static let minimumCompactness = 0.34

    /// 只有这么长的查询才做子序列匹配。两个字符的子序列几乎等于
    /// 「任意位置含这两个字母」，噪声远大于价值。
    public static let minimumSubsequenceQueryLength = 3

    /// 容错匹配（编辑距离）要求的最小查询长度。太短的词改一个字母
    /// 就变成另一个词了（`cat` → `car`），那不是纠错是乱猜。
    public static let minimumTypoQueryLength = 4

    /// 编辑距离容忍上限：`max(1, 查询长度 / 5)`。
    ///
    /// 4 个字符容 1 个错，10 个字符容 2 个。再宽就会把不相干的名字拉进来。
    public static func typoTolerance(queryLength: Int) -> Int {
        max(1, queryLength / 5)
    }

    /// 半命中（`partial`）至少要命中这么多个查询字符。
    ///
    /// 用户 2026-10-28 的原话：「一个文件七个字，我搜四个字这个文件都有，
    /// 另一个文件只有三个字符合，四个字的排前边」。3 是这条需求给出的下界，
    /// 也刚好挡住「两个字符凑上」这类噪声（2 个字符命中在长名字里满地都是）。
    public static let minimumPartialCharacters = 3

    /// 半命中的最低命中率（命中的查询字符数 / 查询字数）。
    ///
    /// 0.6 是**新增档的准入线，不是把原有四条阈值放宽**：子序列仍然要求
    /// 全字符命中且紧凑度 ≥ 0.34。半命中只排在第 3 层下沿（分值 0.46…0.52，
    /// 低于子序列 0.61、高于容错 0.45），且**只对单词查询生效**——
    /// 多词查询由 `terms` 档负责，按字数算覆盖率会把它算出奇怪的数。
    public static let minimumPartialCoverage = 0.6

    // MARK: - 入口

    /// 一次算完「等级 + 分值 + 旧 rank」，**只归一化一次**。
    ///
    /// 判定顺序就是用户定的优先级：同名 → 前缀 → 词命中 → 全字符子序列
    /// → 半命中（匹配字符多）→ 容错 → 仅路径。分值区间互不重叠，
    /// 见每个分支上的注释。
    public static func evaluate(name: String, path: String = "", query: String) -> SearchMatchScore {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let foldedName = RelativePath.normalized(name)
        let foldedQuery = RelativePath.normalized(trimmed)
        guard !foldedQuery.isEmpty else { return .none }

        if foldedName == foldedQuery { return SearchMatchScore(grade: .exact, value: 1.0) }
        // ★ 用户 2026-10-28 定：「同名」= **去掉扩展名之后完全相等**。
        //   「报告.pdf」搜「报告」是第 1 层，不是第 2 层；「年度报告.pdf」不算
        //   （它含查询词但基名不等），落到后面的层级。
        if sameNameIgnoringExtension(foldedName, foldedQuery) {
            return SearchMatchScore(grade: .exact, value: 1.0)
        }
        if foldedName.hasPrefix(foldedQuery) { return SearchMatchScore(grade: .prefix, value: 0.90) }

        let terms = foldedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !terms.isEmpty, terms.allSatisfy({ foldedName.contains($0) }) {
            return SearchMatchScore(grade: .terms, value: 0.76)
        }

        // ★ 下面三档是「模糊」：子序列 → 半命中 → 容错 → 路径。
        //   子序列是「确实都打对了只是不连续」，比「打错一个字」更可信；
        //   半命中是「大部分字对上了」，排在子序列之后、打错字之前。
        let nameCharacters = Array(foldedName)
        let queryCharacters = Array(foldedQuery)
        if queryCharacters.count >= minimumSubsequenceQueryLength {
            let run = orderedRun(nameCharacters, queryCharacters)
            if run.matched == queryCharacters.count {
                // 词首缩写（`bsr` → `best_seller_report`）先单独扫一遍：单遍贪婪
                // 会让 `s` 被 `best` 里的 s 吃掉，跨度 11、紧凑度 0.27 → 判不命中。
                // 命中即满分（紧凑度按 1 计）。
                let compactness = matchesAtWordStarts(nameCharacters, queryCharacters)
                    ? 1 : Double(run.matched) / Double(run.span)
                // 0.61…0.74：上限压在 `terms`（0.76）之下。
                // 理由：同一个查询里「每个词都是子串」比「字符都能凑出来」更可信。
                if compactness >= minimumCompactness {
                    return SearchMatchScore(grade: .subsequence, value: 0.54 + 0.20 * compactness)
                }
                // ★ 全命中但摊得太开 = **不命中**（`minimumCompactness` 那条阈值
                //   是刻意留的），不许退化成 half match 混进来。
            } else if run.matched >= minimumPartialCharacters, terms.count == 1 {
                // 第 3 层下沿：命中率高的在前，命中率相同再比紧凑度。
                // 0.46…0.52：**高于 `typo`（0.45）、低于 `subsequence`（0.61）**。
                let coverage = Double(run.matched) / Double(queryCharacters.count)
                if coverage >= minimumPartialCoverage {
                    let compactness = Double(run.matched) / Double(run.span)
                    let room = (coverage - minimumPartialCoverage) / (1 - minimumPartialCoverage)
                    return SearchMatchScore(grade: .partial, value: 0.46 + 0.05 * room + 0.01 * compactness)
                }
            }
        }

        if let distance = typoDistance(name: foldedName, query: foldedQuery) {
            let tolerance = typoTolerance(queryLength: foldedQuery.count)
            let closeness = 1.0 - Double(distance) / Double(tolerance + 1)
            // 0.42…0.45：**高于 `pathOnly`（0.40）**——「名字打错一个字」
            // 比「名字一点都不像但放在了对的目录里」更可信；又低于
            // `partial` 的 0.46，保证「大部分字对上了」永远压过「打错了」。
            return SearchMatchScore(grade: .typo, value: 0.42 + 0.03 * closeness)
        }

        if !path.isEmpty {
            let foldedPath = RelativePath.normalized(path)
            if !terms.isEmpty, terms.allSatisfy({ foldedPath.contains($0) }) {
                return SearchMatchScore(grade: .pathOnly, value: 0.40)
            }
        }

        return .none
    }

    /// 「同名」的第二条路：**去掉扩展名之后**与查询串完全相等。
    ///
    /// 只剥**文件名**的扩展名，不剥查询串的：`report.2026` 里的 `.2026`
    /// 是名字的一部分而不是扩展名，剥掉它会造出「搜 `report.2026`
    /// 命中 `report.pdf`」这种假同名。
    static func sameNameIgnoringExtension(_ name: String, _ query: String) -> Bool {
        let base = (name as NSString).deletingPathExtension
        guard base != name else { return false }   // 本来就没扩展名，上一条已比过
        return base == query
    }

    // MARK: - 子序列 / 半命中

    /// 一遍贪婪扫描的结果：按顺序命中了几个查询字符、首末命中落在哪。
    ///
    /// 同一个扫描同时供两档用：全命中看**紧凑度**，缺字符看**命中率**
    /// （用户 2026-10-28：「匹配字符多的优先」）。分开扫两遍既慢又会
    /// 让两档对「命中到哪儿了」有不同答案。
    struct OrderedRun {
        let matched: Int
        let first: Int
        let last: Int

        var span: Int { first < 0 ? 0 : last - first + 1 }
    }

    /// 按顺序能命中多少查询字符（`matched` 可能小于查询长度）。
    ///
    /// 用 `Character` 而不是 UTF-8 字节：中文一个字是一个 `Character`，
    /// 按字节比会把「报告」拆成六个字节去凑，既慢又会命中半个汉字。
    static func orderedRun(_ name: [Character], _ query: [Character]) -> OrderedRun {
        var queryIndex = 0
        var first = -1
        var last = -1
        for (offset, character) in name.enumerated() {
            guard queryIndex < query.count else { break }
            guard character == query[queryIndex] else { continue }
            if first < 0 { first = offset }
            last = offset
            queryIndex += 1
        }
        return OrderedRun(matched: queryIndex, first: first, last: last)
    }

    /// 「每个查询字符都命中的是某个词的首字符」。
    ///
    /// `bsr` → `best_seller_report.xlsx` 是最常用的模糊写法（每个词打首字母），
    /// 但**单遍贪婪扫描会取错位置**：`s` 会被 `best` 里的那个 s（第 2 个字符）
    /// 吃掉，于是 `r` 要跑到第 10 个字符，跨度 11、紧凑度 0.27 —— 被判不命中。
    /// 所以全命中时先做一遍「每个字符都必须落在词首」的严格扫描，
    /// 命中就按紧凑度 1 计。
    static func matchesAtWordStarts(_ name: [Character], _ query: [Character]) -> Bool {
        var queryIndex = 0
        for (offset, character) in name.enumerated() {
            guard queryIndex < query.count else { break }
            guard character == query[queryIndex] else { continue }
            let startsWord = offset == 0 || !isWordCharacter(name[offset - 1])
            guard startsWord else { continue }
            queryIndex += 1
        }
        return queryIndex == query.count
    }

    /// 字母或数字算「词内」；其余（空格、`_`、`-`、`.`、`/`）算词边界。
    static func isWordCharacter(_ character: Character) -> Bool {
        character.isLetter || character.isNumber
    }

    // MARK: - 容错（编辑距离）

    /// 文件名里某个「词」与查询串的编辑距离在容忍范围内时，返回那个距离。
    ///
    /// 只跟**词**比，不跟整个文件名比：`quarterly-report.pdf` 与
    /// `quarterly-report-v2.pdf` 的整串距离是 3，按词比就只差 1 个后缀。
    /// 词按非字母数字（含下划线、连字符、空格）切，中文串整体算一个词。
    static func typoDistance(name: String, query: String) -> Int? {
        guard query.count >= minimumTypoQueryLength, !query.contains(" ") else { return nil }
        let tolerance = typoTolerance(queryLength: query.count)
        var best: Int?
        for word in words(of: name) {
            // 长度差超过容忍上限就不用算了——编辑距离不可能小于长度差。
            guard abs(word.count - query.count) <= tolerance else { continue }
            let distance = editDistance(word, query, limit: tolerance)
            guard distance <= tolerance else { continue }
            if best.map({ distance < $0 }) ?? true { best = distance }
        }
        return best
    }

    static func words(of text: String) -> [String] {
        text.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
    }

    /// 带上限的 Levenshtein 距离：一旦整行都超过 `limit` 就提前返回 `limit + 1`。
    ///
    /// 这里不需要「精确距离」，只需要「在不在容忍范围内」，所以提前退出
    /// 既正确又便宜——这是它敢在 2000 行的循环里出现的理由。
    static func editDistance(_ lhs: String, _ rhs: String, limit: Int) -> Int {
        let a = Array(lhs), b = Array(rhs)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            var rowMinimum = current[0]
            for j in 1...b.count {
                let cost = a[i - 1] == b[j - 1] ? 0 : 1
                current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
                rowMinimum = min(rowMinimum, current[j])
            }
            if rowMinimum > limit { return limit + 1 }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
