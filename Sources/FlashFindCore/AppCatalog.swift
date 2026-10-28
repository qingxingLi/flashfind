import CoreServices
import Foundation

/// 一台已安装的应用程序。
public struct AppSearchCandidate: Sendable, Equatable {
    /// 显示名：访达里看到的那个名字（`/System/Applications/Photos.app` → `照片`）。
    public let name: String
    /// app 本体的位置（`/Applications/WPS Office.app`）。
    public let url: URL
    /// 除显示名之外还能用来匹配的名字，通常是**文件名主干**。
    ///
    /// 系统自带 App 的中文显示名和文件名常常对不上（`终端` / `Terminal`、
    /// `照片` / `Photos`），只认一个就会出现「中文搜不到英文名、英文搜不到中文名」。
    public let aliases: [String]

    public init(name: String, url: URL) {
        self.init(name: name, url: url, aliases: [])
    }

    public init(name: String, url: URL, aliases: [String]) {
        self.name = name
        self.url = url
        self.aliases = aliases
    }

    /// 参与匹配的名字：显示名在前，别名按顺序补上（去重、丢空串）。
    public var matchKeys: [String] {
        var keys = [name]
        for alias in aliases where !alias.isEmpty && !keys.contains(alias) {
            keys.append(alias)
        }
        return keys
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
/// ## 不递归，但也不是只认三个顶层目录
///
/// `.app` 是目录，里面常常还有 `Contents/Helpers/XXX.app`。递归会把它们全翻
/// 出来，用户看到一堆不认识的名字。所以只列**白名单目录**的直接子项。
///
/// 2026-10-24 修：早先的目录表只有 `/Applications`、`/System/Applications`、
/// `~/Applications` 三个顶层，于是系统把它自带的 `终端`、`活动监视器`、
/// `钥匙串访问` 放在 `Utilities` 子目录里就全被漏掉——用户报「搜不到终端」。
/// 现在把系统放 App 的四个标准位置都列进去，仍然不做递归。
///
/// ## 名字取访达显示的那个
///
/// 文件名是 `Photos.app`，用户脑子里是「照片」。`Bundle` 的
/// `CFBundleDisplayName` 在多数系统 App 上是空的（实测 `邮件`、`系统设置`、
/// `活动监视器` 都读不到），只有 Spotlight 元数据的 `kMDItemDisplayName`
/// 给出和访达完全一致的名字（实测 136 个 App 全部读得到，一轮 47ms）。
/// 代价是这层依赖——读不到时退回文件名主干，功能不受影响，只是变成英文名。
public enum AppCatalog {

    /// 标准应用目录，按优先级排列（顺序即同名 app 的取舍优先级）。
    ///
    /// 后四个是系统放 App 的地方，其中 `Utilities` 是「搜不到终端」的根因所在。
    /// `~/Applications` 在多数机器上不存在，`/Applications/Utilities` 在新系统上
    /// 也常常是空的——读不到的目录直接跳过（见 `scan`）。
    public static let defaultDirectories: [URL] = [
        URL(fileURLWithPath: "/Applications"),
        URL(fileURLWithPath: "/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Applications"),
        URL(fileURLWithPath: "/System/Applications/Utilities"),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications"),
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications"),
    ]

    /// 枚举给定目录下的 `.app`（只列直接子项）。
    ///
    /// 读不到的目录跳过而不抛错：用户机器上少一个应用目录是常态，
    /// 为此让整次搜索失败没有道理。
    ///
    /// - Parameter displayName: 显示名解析，默认走 Spotlight；测试注入假实现，
    ///   免得断言被「这台机器装没装那个 App」左右。
    public static func scan(directories: [URL] = defaultDirectories,
                            displayName: (URL) -> String? = { spotlightDisplayName(url: $0) })
        -> [AppSearchCandidate] {
        let manager = FileManager.default
        var found: [AppSearchCandidate] = []
        var seen = Set<String>()
        for directory in directories {
            guard let entries = try? manager.contentsOfDirectory(atPath: directory.path) else { continue }
            for entry in entries where entry.hasSuffix(".app") {
                let url = directory.appendingPathComponent(entry)
                // 同名 app 出现在多个目录时保留先找到的那个（顺序即优先级）：
                // `/Applications/Safari.app` 与 `/System/Applications/Safari.app` 只留一条。
                guard seen.insert(entry).inserted else { continue }
                let stem = String(entry.dropLast(".app".count))
                guard !stem.isEmpty else { continue }
                let localized = displayName(url)
                found.append(AppSearchCandidate(name: localized ?? stem,
                                                url: url,
                                                // 本地化名丢掉时 name 就是 stem，别名没有意义。
                                                aliases: localized == nil ? [] : [stem]))
            }
        }
        return found
    }

    /// 访达里显示的名字：`/System/Applications/Photos.app` → `照片`。
    ///
    /// 读不到（没索引、卷被排除）返回 nil，由调用方退回文件名。
    public static func spotlightDisplayName(url: URL) -> String? {
        guard let item = MDItemCreateWithURL(nil, url as CFURL),
              let raw = MDItemCopyAttribute(item, kMDItemDisplayName) as? String else { return nil }
        return normalizeDisplayName(raw)
    }

    /// 元数据里的值带 `.app` 后缀（`照片.app`），显示名不要它。
    /// 空串或只剩后缀都算读不到——显示成空白行比显示英文名更糟。
    static func normalizeDisplayName(_ raw: String?) -> String? {
        guard let raw else { return nil }
        // 先剥空白再判后缀：元数据里偶尔带首尾空格，`"照片.app "` 直接判后缀会漏。
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let name = trimmed.hasSuffix(".app") ? String(trimmed.dropLast(".app".count)) : trimmed
        return name.isEmpty ? nil : name
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

    /// 候选与查询词的相关度；完全不匹配返回 nil。
    ///
    /// 显示名与别名都参与，名次取**最好的那个**：搜 `safari` 时
    /// `Safari浏览器` 靠别名整名命中拿 0，不能因为显示名多了三个字就掉到 1。
    /// 排序用它、结果行的 rank 也用它——两处各算一套就会出现
    /// 「排第一的那行 rank 写 1」这种自相矛盾。
    ///
    /// ★ 2026-10-28：多了**模糊**一档。原来要求 `fold(key).contains(folded)`，
    /// 于是 `xcode` 找不到 `Xcode-beta`（子序列 `xcd` 之类）、打错一个字母
    /// 就一条都没有。现在交给 `SearchMatch` 判等级：0/1/2 的口径一个字没变，
    /// 子序列与容错归到 **3**（原来根本不返回的候选现在能搜到，但排在
    /// 整名/前缀/包含之后）。
    public static func rank(for candidate: AppSearchCandidate, query: String) -> Int? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        var best: Int?
        for key in candidate.matchKeys {
            let grade = SearchMatch.evaluate(name: key, query: trimmed).grade
            guard grade != .none else { continue }
            // 旧口径的 0/1/2 原样保留；模糊一档统一记 3。
            let value = grade.legacyRank == 4 ? 3 : grade.legacyRank
            if best.map({ value < $0 }) ?? true { best = value }
        }
        return best
    }

    /// 名字包含查询词的应用，按相关度排序。
    ///
    /// 排序规则：先按 `rank`，同 rank 里**短名优先**（输入 "note" 时
    /// "Notes" 该在 "Notebook" 前面），再按名字字母序——保证结果稳定，
    /// 同样的输入永远得到同样的顺序。
    public static func matches(_ candidates: [AppSearchCandidate], query: String,
                               limit: Int = 20) -> [AppSearchCandidate] {
        guard limit > 0 else { return [] }
        var hits: [(candidate: AppSearchCandidate, rank: Int)] = []
        for candidate in candidates {
            guard let value = rank(for: candidate, query: query) else { continue }
            hits.append((candidate, value))
        }
        hits.sort { a, b in
            a.rank != b.rank ? a.rank < b.rank
                : a.candidate.name.count != b.candidate.name.count ? a.candidate.name.count < b.candidate.name.count
                : a.candidate.name < b.candidate.name
        }
        return Array(hits.prefix(limit).map(\.candidate))
    }

    /// 大小写与变音符号不敏感比较（与 `RelativePath.normalized` 同一套折叠）。
    private static func fold(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive],
                     locale: Locale(identifier: "en_US_POSIX"))
    }
}
