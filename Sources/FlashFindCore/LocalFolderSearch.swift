import Foundation

public enum LocalSearchMode: String, CaseIterable, Identifiable, Sendable {
    case spotlight, selectedFolders
    public var id: String { rawValue }
    public var title: String { self == .spotlight ? "系统索引（Spotlight）" : "已选文件夹（无需系统索引）" }
}

/// 界面上「本机搜索范围」的三选一，以及它与 `localEnabled` / `LocalSearchMode` 的映射。
///
/// 这个映射原来只是设置页里的一个私有 enum。首次启动引导要用同一套说法，
/// 两处各写一份迟早分叉（改了一边、另一边还是旧行为，而且两边都能编译过），
/// 所以搬进 Core：判定与文案只有一个出处，两个界面共用，也能被测试锁住。
public enum LocalScopeChoice: String, CaseIterable, Identifiable, Sendable {
    case wholeMac
    case selectedFolders
    case off

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .wholeMac: return "整台 Mac"
        case .selectedFolders: return "只搜索指定文件夹"
        case .off: return "不搜索这台 Mac"
        }
    }

    /// 选项下面那行小字。选「不搜索」时不必解释。
    public var detail: String? {
        switch self {
        case .wholeMac: return "使用系统的 Spotlight 索引，不用挑文件夹"
        case .selectedFolders: return "只在你挑的文件夹里找，不动系统索引"
        case .off: return nil
        }
    }

    public var enabled: Bool { self != .off }

    /// 这个选择对应的搜索方式。
    ///
    /// `.off` 也给出一个值（`.spotlight`），只是为了让调用点不必处理可选。
    /// 关闭时调用方**不要**去写 `mode` —— 用户关掉本机搜索并不等于放弃挑好的方式，
    /// 重新打开时该回到他上次选的那一种。
    public var mode: LocalSearchMode { self == .selectedFolders ? .selectedFolders : .spotlight }

    public static func resolve(localEnabled: Bool, mode: LocalSearchMode) -> LocalScopeChoice {
        guard localEnabled else { return .off }
        return mode == .spotlight ? .wholeMac : .selectedFolders
    }
}
public struct LocalFolderSearchReport: Sendable {
    public let results: [SearchResult]
    public let warnings: [String]
    public let visitedCount: Int
}

/// Explicit directory opt-in, filename-only, read-only and bounded. Never follows symlinks.
public enum LocalFolderSearch {
    /// - Parameters:
    ///   - text: 名字关键词。与 Spotlight 那条路一样，**格式词已经由
    ///     `SearchQueryParser` 剥出去了**，这里不该再收到 `ppt`。
    ///   - extensions: 格式限制。留空表示不限格式。
    ///
    /// ★ 格式匹配的口径复用 `ParsedSearchQuery.matches`，不在这里另写一份
    /// `contains(extensionOf(name))`：两处各写一遍的话，改了连带的族
    /// （`ppt` 要带上 `pptx`）只会改一处，另一处照样漏。
    public static func search(_ text: String, folders: [URL], extensions: [String] = [], limit: Int = 200,
                              maximumEntries: Int = 30_000, timeBudget: TimeInterval = 3) throws -> LocalFolderSearchReport {
        let terms = RelativePath.normalized(text).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let parsed = ParsedSearchQuery(raw: text, terms: terms, extensions: extensions)
        guard !folders.isEmpty else { throw FlashFindError.message("请选择要搜索的本机文件夹；不会自动扫描全盘") }
        // 只有格式词（搜「ppt」）也算有东西可查：找出该格式的文件。
        guard !terms.isEmpty || parsed.hasFormatFilter else { return LocalFolderSearchReport(results: [], warnings: [], visitedCount: 0) }
        let manager = FileManager.default
        let deadline = ProcessInfo.processInfo.systemUptime + timeBudget
        var results: [SearchResult] = [], warnings: [String] = [], visited = 0, identities = Set<String>()
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey,
                                      .volumeIsLocalKey, .volumeURLKey, .contentModificationDateKey]
        // ★ 一次遍历用同一个 `now`：否则同一批结果的时间新近度会随着
        //   扫描进度缓慢漂移，排序里出现「早扫到的略占便宜」这种莫名现象。
        let now = Date()
        for chosen in folders {
            try Task.checkCancellation()
            let root = chosen.standardizedFileURL
            guard root.isFileURL, root.path != "/" else { throw FlashFindError.message("不能将文件系统根目录用作降级搜索范围，请选择具体文件夹") }
            let metadata = try root.resourceValues(forKeys: Set(keys))
            guard metadata.isDirectory == true, metadata.isSymbolicLink != true else { throw FlashFindError.message("请选择真实文件夹，不使用符号链接作为搜索根") }
            guard metadata.volumeIsLocal == true else { throw FlashFindError.message("已选文件夹搜索仅支持本机卷；已挂载NAS请通过NAS设置导入") }
            let canonicalRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
            guard canonicalRoot != "/", canonicalRoot != "/System/Volumes/Data",
                  metadata.volume?.resolvingSymlinksInPath().standardizedFileURL.path != canonicalRoot else { throw FlashFindError.message("不能扫描文件系统或整卷根目录，请选择具体文件夹") }
            let rootName = RelativePath.normalized(root.lastPathComponent)
            // ★ 命中判定走 `SearchMatch`：原来这里是「每个词都得是名字的子串」，
            //   输入 `bsr` 就找不到 `best_seller_report.xlsx`。模糊之后
            //   子序列与容错也算命中，与 NAS 那条路同一个口径。
            let rootEvaluation = SearchMatch.evaluate(name: root.lastPathComponent, path: root.path, query: text)
            if (terms.isEmpty || rootEvaluation.grade != .none), parsed.matches(rootName), identities.insert(root.path).inserted {
                var row = SearchResult(id: "local:" + root.path, name: root.lastPathComponent, relativePath: root.path,
                    sourceID: nil, sourceName: "本机·已选文件夹", kind: "directory", size: 0, localURL: root)
                row.rank = rootEvaluation.grade.legacyRank
                row.score = SearchRanking.score(match: rootEvaluation.value, modified: metadata.contentModificationDate, now: now)
                results.append(row)
                if results.count >= limit {
                    warnings.append("已选文件夹搜索达到结果上限，结果可能不完整")
                    return LocalFolderSearchReport(results: results, warnings: warnings, visitedCount: visited)
                }
            }
            let enumerator = manager.enumerator(at: root, includingPropertiesForKeys: keys,
                options: [.skipsPackageDescendants], errorHandler: { url, _ in
                    if warnings.count < 8 { warnings.append("部分目录无法读取：" + url.lastPathComponent) }
                    return true
                })
            guard let enumerator else { warnings.append("文件夹无法读取：" + root.lastPathComponent); continue }
            while let value = enumerator.nextObject() as? URL {
                try Task.checkCancellation()
                if visited >= maximumEntries || ProcessInfo.processInfo.systemUptime >= deadline || results.count >= limit {
                    warnings.append("已选文件夹搜索达到时间或数量上限，结果可能不完整，请缩小目录范围")
                    return LocalFolderSearchReport(results: results.sorted(by: SearchResultMerge.precedes), warnings: warnings, visitedCount: visited)
                }
                visited += 1
                do {
                    let attributes = try value.resourceValues(forKeys: Set(keys))
                    if attributes.isSymbolicLink == true { enumerator.skipDescendants(); continue }
                    // Lexical ancestry plus non-following enumeration protects selected scope.
                    guard value.standardizedFileURL.path.hasPrefix(root.path + "/"),
                          value.resolvingSymlinksInPath().standardizedFileURL.path.hasPrefix(canonicalRoot + "/") else {
                        enumerator.skipDescendants(); warnings.append("已跳过越界路径"); continue
                    }
                    if attributes.isDirectory == true, attributes.volumeIsLocal != true { enumerator.skipDescendants(); continue }
                    let name = RelativePath.normalized(value.lastPathComponent)
                    let evaluation = SearchMatch.evaluate(name: value.lastPathComponent, path: value.path, query: text)
                    guard (terms.isEmpty || evaluation.grade != .none), parsed.matches(name),
                          identities.insert(value.path).inserted else { continue }
                    var row = SearchResult(id: "local:" + value.path, name: value.lastPathComponent, relativePath: value.path,
                        sourceID: nil, sourceName: "本机·已选文件夹", kind: attributes.isDirectory == true ? "directory" : "file",
                        size: Int64(attributes.fileSize ?? 0), localURL: value,
                        rank: evaluation.grade.legacyRank)
                    row.modifiedDate = attributes.contentModificationDate
                    row.score = SearchRanking.score(match: evaluation.value, modified: attributes.contentModificationDate, now: now)
                    results.append(row)
                } catch {
                    if warnings.count < 8 { warnings.append("部分条目无法读取：" + value.lastPathComponent) }
                }
            }
        }
        return LocalFolderSearchReport(results: results.sorted(by: SearchResultMerge.precedes), warnings: warnings, visitedCount: visited)
    }
}
