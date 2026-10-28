import Foundation

/// 在**已经拿到的结果**里按「文件类型 / 位置」再筛一遍。
///
/// ## 为什么需要它（2026-10-28）
///
/// 正常搜索时这两个限定是**下发给设备/索引**的（`SearchRequestPlan` → Dart 的
/// `Scope.narrowTo`），客户端从不自己筛。但「钉在桌面上的那一批结果」没有设备在手边：
/// 用户要求钉住之后**保留文件类型与位置的筛选，并且还能改**，改完就地重筛。
/// 那就必须有一条纯客户端的判定——否则只能悄悄重新搜一次，而钉住的意义恰恰是「这批不变」。
///
/// ## 与设备侧口径的关系
///
/// 这里只做「同一件事的客户端近似」，不追求与设备逐字节一致：
/// - 类型走 `FileFormatVocabulary`——它已经是 `SearchQueryParser` 认的那张表，
///   设备侧收到的也是同一批扩展名；
/// - 位置按「来源 + 根前缀」判定，与 `NASLocator.owningRoot` 同一套整段比较。
public enum SearchResultFilter {

    // MARK: - 文件类型

    /// 这条结果是否符合类型限定。`nil`（「全部」）一律放行。
    ///
    /// ★ **文件夹不算任何一种文件类型**：选了 pdf 时文件夹必须消失。
    ///   设备侧按扩展名筛本来也不会有文件夹（它没有扩展名），
    ///   客户端要显式写这一条，不然「钉住里选 pdf 却冒出三个文件夹」会显得像坏了。
    public static func matches(fileType: SearchFileTypeCatalog.FileType?,
                               name: String,
                               kind: String) -> Bool {
        guard let fileType else { return true }
        if kind == "directory" { return false }
        // 认不出的格式词就**放行**（宁可多显示，也不要因为一张表漏了一项就整片空白）。
        guard let extensions = FileFormatVocabulary.extensions(for: fileType.formatWord) else { return true }
        return extensions.contains(ParsedSearchQuery.extensionOf(name))
    }

    // MARK: - 位置

    /// 这条结果是否落在位置限定里。
    public static func matches(location: SearchTarget, result: SearchResult) -> Bool {
        switch location {
        case .unrestricted:
            return true
        case .local:
            // 本机结果的 `sourceID` 恒为 nil（`LocalFolderSearch` / `AppCatalog` 都是这么造的）。
            return result.sourceID == nil
        case .sourceRoot(let sourceID, let root):
            guard let raw = result.sourceID,
                  NASSourceConfig.protocolIdentifier(for: raw)
                    == NASSourceConfig.protocolIdentifier(for: sourceID) else { return false }
            return path(result.relativePath, isUnder: root)
        }
    }

    /// `path` 是否在 `root` 之下（含 `root` 本身）。
    ///
    /// ★★ 按**整段**比较，不按字符串前缀：
    ///   1. `/示例共享` 不能吃掉 `/示例共享2/x` 里的东西（前缀比较会）；
    ///   2. `root == "/"`（整根）必须成立。用 `split` 之后段数是 0，天然匹配一切——
    ///      而按字符串拼前缀时 `"/"。hasPrefix("/" + "/")` 恒假，症状是
    ///      **「钉住里选那个整根共享，一行都不剩」**（同一条坑 `NASLocator.owningRoot`
    ///      与 Dart 侧各踩过一次）；
    ///   3. 前导斜杠的有无**不影响**判定：NAS 结果行的 `relativePath` 带前导 `/`
    ///      （`/团队文档/x.pdf`），而本机与夹具的行不带。按字符串比较就得先统一口径，
    ///      统一漏一处就是「某类来源永远筛不出来」。
    public static func path(_ path: String, isUnder root: String) -> Bool {
        let rootSegments = root.split(separator: "/", omittingEmptySubsequences: true)
        // 整根（`/`、`""`、`///`）：一切都是它的子孙。
        if rootSegments.isEmpty { return true }
        let pathSegments = path.split(separator: "/", omittingEmptySubsequences: true)
        guard pathSegments.count >= rootSegments.count else { return false }
        return Array(pathSegments.prefix(rootSegments.count)) == rootSegments
    }

    // MARK: - 一起筛

    /// 保序筛出同时满足两个限定的行。
    public static func rows(_ rows: [SearchResult],
                            fileType: SearchFileTypeCatalog.FileType?,
                            location: SearchTarget) -> [SearchResult] {
        guard fileType != nil || !isUnrestricted(location) else { return rows }
        return rows.filter {
            matches(fileType: fileType, name: $0.name, kind: $0.kind)
                && matches(location: location, result: $0)
        }
    }

    private static func isUnrestricted(_ location: SearchTarget) -> Bool {
        if case .unrestricted = location { return true }
        return false
    }
}
