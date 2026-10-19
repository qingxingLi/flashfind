import Foundation

/// 一台已安装的应用程序。
public struct AppSearchCandidate: Sendable, Equatable {
    /// 显示名：`WPS Office.app` → `WPS Office`。
    public let name: String
    /// app 本体的位置（`/Applications/WPS Office.app`）。
    public let url: URL
    public init(name: String, url: URL) {
        self.name = name
        self.url = url
    }
}

/// 本机已安装应用的枚举与匹配（新增「搜索 app」功能）。
///
/// ## 为什么不用 Spotlight 一把搜
///
/// Spotlight（`NSMetadataQuery`）在「整台 Mac」模式下本来就会返回 `.app`，
/// 但返回的是**文件行**：通用图标、路径一长串、和文档混在一起。
/// 用户要的是「输入名字 → 第一个就是那个 app → 回车打开」。
/// 单独一条来源还能让应用搜索在**指定文件夹模式**下也可用——那种模式刻意
/// 不扫全盘，但应用不在用户的数据文件夹里，本就不该被那条限制挡住。
///
/// ## 只列顶层
///
/// `.app` 是目录，里面常常还有 `Contents/Helpers/XXX.app`。递归会把它们全翻
/// 出来，用户看到一堆不认识的名字。所以只列应用目录的**直接子项**。
public enum AppCatalog {

    /// 标准应用目录，按优先级排列。
    ///
    /// `~/Applications` 在多数机器上不存在——读不到的目录直接跳过（见 `scan`）。
    public static let defaultDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/System/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// 枚举给定目录下的 `.app`（只列直接子项）。
    ///
    /// 读不到的目录跳过而不抛错：用户机器上少一个应用目录是常态，
    /// 为此让整次搜索失败没有道理。
    public static func scan(directories: [URL] = defaultDirectories) -> [AppSearchCandidate] {
        let manager = FileManager.default
        var found: [AppSearchCandidate] = []
        var seen = Set<String>()
        for directory in directories {
            guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = directory.appendingPathComponent(entry)
                // 同名 app 出现在多个目录时保留先找到的那个（顺序即优先级）。
                guard seen.insert(entry).inserted else { continue }
                let name = String(entry.dropLast(".app".count))
                guard !name.isEmpty else { continue }
                found.append(AppSearchCandidate(name: name, url: url))
            }
        }
        return found
    }

    /// 名字与查询词的相关度：整名 0 < 前缀 1 < 包含 2。
    ///
    /// 与文件夹搜索（`LocalFolderSearch`）的 rank 约定一致——两处排名口径不同，
    /// 合并排序时会出现「同名文件排在应用后面」这种说不通的结果。
    public static func rank(name: String, query: String) -> Int {
        let foldedName = fold(name)
        let foldedQuery = fold(query)
        if foldedName == foldedQuery { return 0 }
        if foldedName.hasPrefix(foldedQuery) { return 1 }
        return 2
    }

    /// 名字包含查询词的应用，按相关度排序。
    ///
    /// 排序规则：先按 `rank`，同 rank 里**短名优先**（输入 "note" 时
    /// "Notes" 该在 "Notebook" 前面），再按名字字母序——保证结果稳定，
    /// 同样的输入永远得到同样的顺序。
    public static func matches(_ candidates: [AppSearchCandidate], query: String,
                               limit: Int = 20) -> [AppSearchCandidate] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let folded = fold(trimmed)
        var hits: [(candidate: AppSearchCandidate, rank: Int)] = []
        for candidate in candidates where fold(candidate.name).contains(folded) {
            hits.append((candidate, rank(name: candidate.name, query: trimmed)))
        }
        hits.sort { a, b in
            a.rank != b.rank ? a.rank < b.rank
                : a.candidate.name.count != b.candidate.name.count ? a.candidate.name.count < b.candidate.name.count
                : a.candidate.name < b.candidate.name
        }
        guard limit > 0 else { return [] }
        return Array(hits.prefix(limit).map(\.candidate))
    }

    /// 大小写与变音符号不敏感比较（与 `RelativePath.normalized` 同一套折叠）。
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
