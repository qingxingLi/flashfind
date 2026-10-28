import Foundation

/// 搜索结果与查询词的相关度评分。
///
/// 分值越低越靠前。与 `LocalFolderSearch`、`IndexDatabase`、`AppCatalog`
/// 使用同一套约定（整名 0 / 前缀 1 / 全词命中 2 / 路径命中 3 / 其余 4），
/// 这样 NAS、本地、应用三类结果合并排序时不会互相插队。
///
/// ★ 2026-10-28：具体判定搬进了 `SearchMatch`（多了子序列与容错两档）。
/// 这里只保留**对外口径**——`rank` 的 0…4 没有变，MCP 的 `ranking score`
/// 与既有断言因此都不受影响。新代码请用 `evaluate`，一次拿等级 + 分值 + rank。
public enum SearchResultRanker {

    /// 按文件名与路径给结果打相关度分。
    ///
    /// - 0：文件名（忽略大小写/变音符号）与查询完全一致。
    /// - 1：文件名以查询串开头。
    /// - 2：文件名包含查询串拆出的所有词。
    /// - 3：文件名没全命中，但完整路径全命中。
    /// - 4：其它（仍然会显示，只是排在更后面）。
    public static func rank(name: String, path: String, query: String) -> Int {
        // ★ 空查询返回 3 是 1.1.x 的既有口径（那时是 `return 3`），
        //   不是 4 —— 空查询意味着「没有关键词可比」，不该被判成「最不相关」。
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 3 }
        return SearchMatch.evaluate(name: name, path: path, query: trimmed).grade.legacyRank
    }

    /// 等级 + 匹配分值 + 旧 rank 一次算完。
    public static func evaluate(name: String, path: String = "", query: String) -> SearchMatchScore {
        SearchMatch.evaluate(name: name, path: path, query: query)
    }
}
