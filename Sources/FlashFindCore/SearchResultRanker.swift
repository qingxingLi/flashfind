import Foundation

/// 搜索结果与查询词的相关度评分。
///
/// 分值越低越靠前。与 `LocalFolderSearch`、`IndexDatabase`、`AppCatalog`
/// 使用同一套约定（整名 0 / 前缀 1 / 全词命中 2 / 路径命中 3 / 其余 4），
/// 这样 NAS、本地、应用三类结果合并排序时不会互相插队。
public enum SearchResultRanker {

    /// 按文件名与路径给结果打相关度分。
    ///
    /// - 0：文件名（忽略大小写/变音符号）与查询完全一致。
    /// - 1：文件名以查询串开头。
    /// - 2：文件名包含查询串拆出的所有词。
    /// - 3：文件名没全命中，但完整路径全命中。
    /// - 4：其它（仍然会显示，只是排在更后面）。
    public static func rank(name: String, path: String, query: String) -> Int {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 3 }

        let foldedName = RelativePath.normalized(name)
        let foldedQuery = RelativePath.normalized(trimmed)

        if foldedName == foldedQuery { return 0 }
        if foldedName.hasPrefix(foldedQuery) { return 1 }

        let terms = foldedQuery.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return 3 }

        if terms.allSatisfy({ foldedName.contains($0) }) { return 2 }

        let foldedPath = RelativePath.normalized(path)
        if terms.allSatisfy({ foldedPath.contains($0) }) { return 3 }

        return 4
    }
}
