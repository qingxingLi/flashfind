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
public enum SearchMatchGrade: Int, Comparable, Sendable, CaseIterable {
    /// 一点都不像（仍然会显示，只是排在最后、最容易被上限挤掉）。
    case none = 0
    /// 打错字了，但编辑距离在容忍范围内（`flshfind` → `nasuser`）。
    case typo = 1
    /// 字符按顺序都出现了，但不连续（`bsr` → `best_seller_report`）。
    case subsequence = 2
    /// 文件名里没全命中，但完整路径里都出现了。
    case pathOnly = 3
    /// 查询拆开的每个词都在文件名里（顺序不限）。
    case terms = 4
    /// 文件名以查询串开头。
    case prefix = 5
    /// 文件名与查询串完全一致。
    case exact = 6

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
        case .subsequence, .typo, .none: return 4
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

    // MARK: - 入口

    /// 一次算完「等级 + 分值 + 旧 rank」，**只归一化一次**。
    public static func evaluate(name: String, path: String = "", query: String) -> SearchMatchScore {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .none }

        let foldedName = RelativePath.normalized(name)
        let foldedQuery = RelativePath.normalized(trimmed)
        guard !foldedQuery.isEmpty else { return .none }

        if foldedName == foldedQuery { return SearchMatchScore(grade: .exact, value: 1.0) }
        if foldedName.hasPrefix(foldedQuery) { return SearchMatchScore(grade: .prefix, value: 0.90) }

        let terms = foldedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        if !terms.isEmpty, terms.allSatisfy({ foldedName.contains($0) }) {
            return SearchMatchScore(grade: .terms, value: 0.76)
        }

        // ★ 下面三档是这次新增的「模糊」：子序列 → 容错 → 路径。
        //   顺序不能反：子序列是「确实都打对了只是不连续」，比「打错一个字」
        //   更可信；路径命中则是「名字不像但文件放在对的目录里」，最弱的一档。
        if let compactness = subsequence(name: foldedName, query: foldedQuery) {
            // 0.48…0.74：上限压在 `terms`（0.76）之下。
            //
            // 理由：同一个查询里「每个词都是子串」比「字符都能凑出来」更可信，
            // 所以词首缩写（`bsr` → `best_seller_report`）虽然很强，也只能
            // 拿 0.74 这一档的最高分，不能越到词命中前面去。
            return SearchMatchScore(grade: .subsequence, value: 0.48 + 0.26 * compactness)
        }

        if let distance = typoDistance(name: foldedName, query: foldedQuery) {
            let tolerance = typoTolerance(queryLength: foldedQuery.count)
            let closeness = 1.0 - Double(distance) / Double(tolerance + 1)
            // 0.42…0.50：**高于 `pathOnly`（0.40）**——「名字打错一个字」
            // 比「名字一点都不像但放在了对的目录里」更可信；又低于
            // `subsequence` 的 0.52，保证「打对了只是不连续」永远压过「打错了」。
            return SearchMatchScore(grade: .typo, value: 0.42 + 0.08 * closeness)
        }

        if !path.isEmpty {
            let foldedPath = RelativePath.normalized(path)
            if !terms.isEmpty, terms.allSatisfy({ foldedPath.contains($0) }) {
                return SearchMatchScore(grade: .pathOnly, value: 0.40)
            }
        }

        return .none
    }

    // MARK: - 子序列

    /// 字符按顺序全部出现时返回紧凑度（0…1），否则 nil。
    ///
    /// ## 两遍扫描：先试「词首缩写」，再试普通子序列
    ///
    /// `bsr` → `best_seller_report.xlsx` 是最常用的模糊写法（每个词打首字母），
    /// 但**单遍贪婪扫描会取错位置**：`s` 会被 `best` 里的那个 s（第 2 个字符）
    /// 吃掉，于是 `r` 要跑到第 10 个字符，跨度 11、紧凑度 0.27 —— 被判不命中。
    /// 所以先做一遍「每个字符都必须落在词首」的严格扫描，成功就直接满分，
    /// 失败再退回普通子序列（`ace` → `abcdefghij` 这种连续但不词首的写法）。
    ///
    /// 判定顺序上仍归 `subsequence` 档（0.78），永远不会压过前缀命中。
    ///
    /// 用 `Character` 而不是 UTF-8 字节：中文一个字是一个 `Character`，
    /// 按字节比会把「报告」拆成六个字节去凑，既慢又会命中半个汉字。
    static func subsequence(name: String, query: String) -> Double? {
        let queryCharacters = Array(query)
        guard queryCharacters.count >= minimumSubsequenceQueryLength else { return nil }
        let nameCharacters = Array(name)
        guard nameCharacters.count >= queryCharacters.count else { return nil }

        if matchesAtWordStarts(nameCharacters, queryCharacters) { return 1 }

        var queryIndex = 0
        var first = -1
        var last = -1
        for (offset, character) in nameCharacters.enumerated() {
            guard queryIndex < queryCharacters.count else { break }
            guard character == queryCharacters[queryIndex] else { continue }
            if first < 0 { first = offset }
            last = offset
            queryIndex += 1
        }
        guard queryIndex == queryCharacters.count, first >= 0 else { return nil }
        let span = last - first + 1
        let compactness = Double(queryCharacters.count) / Double(span)
        return compactness >= minimumCompactness ? compactness : nil
    }

    /// 「每个查询字符都命中的是某个词的首字符」。
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
