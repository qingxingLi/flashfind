import Foundation

/// 「钉在桌面上」的那一批搜索结果。
///
/// 用户 2026-10-28：搜索结果默认在搜索框下方，但**可以钉在桌面上**并保留这次的结果，
/// 之后搜索框可以继续做下一组搜索，钉住的那批照样留在桌面上、照样能拖。
///
/// ## 为什么是一份快照，而不是「指向 AppModel 的两个下标」
///
/// 钉住之后紧接着就会发生**第二次搜索**：`results` 与 `query` 都会被换掉。
/// 若钉住的窗口还盯着它们，第二批结果一到，第一块窗口里的内容就跟着变了——
/// 「保留此次搜索结果」这句话直接落空。所以钉住那一刻**把行抄下来**。
///
/// ## 为什么快照里还要留 `totalMatched`
///
/// 200 上限之后 `rows.count` 推不出「一共匹配多少」：200 条时到底是「只有 200」
/// 还是「2000 里挑了 200」，只有这个数说得清。钉住的窗口上要写的是同一句话。
///
/// ## 为什么还要留类型与位置限定（2026-10-28 追加）
///
/// 用户：「钉住以后保留文件类型和文件位置的筛选」。于是钉住的窗口里
/// **照旧有顶部类型条与左侧位置侧边栏**，而且能改——改了就在这一批里就地重筛
/// （`SearchResultFilter`），不重新搜。快照因此要记下**钉住那一刻的两个限定**，
/// 否则窗口一开出来就是「全部 / 全部位置」，等于把用户刚做的筛选抹掉。
public struct PinnedResults: Identifiable, Equatable, Sendable {

    public let id: UUID
    /// 这一批结果对应的查询词（窗口题头要写出来，否则几块窗口分不清谁是谁）。
    public let query: String
    /// 钉住那一刻显示的那一批行（已经排好序、已经按上限截断）。
    public let rows: [SearchResult]
    /// 这一批对应的总匹配数（`>= rows.count` 表示当时被截断过）。
    public let totalMatched: Int
    /// 当时限定的位置名（没限定为 nil）。
    ///
    /// ★ 只用于「钉住那一刻」的说明（例如空结果提示）；**题头不再写它**——
    ///   钉住的窗口里位置可以被改，题头那句话会当场变成谎话。
    public let locationTitle: String?
    /// 钉住那一刻的文件类型限定（`nil` = 全部）。
    public let fileType: SearchFileTypeCatalog.FileType?
    /// 钉住那一刻的位置限定。
    public let location: SearchTarget

    public init(id: UUID = UUID(),
                query: String,
                rows: [SearchResult],
                totalMatched: Int,
                locationTitle: String?,
                fileType: SearchFileTypeCatalog.FileType? = nil,
                location: SearchTarget = .unrestricted) {
        self.id = id
        self.query = query
        self.rows = rows
        self.totalMatched = max(totalMatched, rows.count)
        self.locationTitle = locationTitle
        self.fileType = fileType
        self.location = location
    }

    // MARK: - 就地重筛

    /// 按给定的两个限定在**这一批结果里**再筛一遍。
    ///
    /// ★ 不重新搜索：钉住的意义就是「这批不变」。判定全在 Core
    ///   （`SearchResultFilter`），界面只传用户点的那两个限定。
    public func rows(fileType: SearchFileTypeCatalog.FileType?,
                     location: SearchTarget) -> [SearchResult] {
        SearchResultFilter.rows(rows, fileType: fileType, location: location)
    }

    /// 筛完还剩几行（提示与高度都用它）。
    public func visibleCount(fileType: SearchFileTypeCatalog.FileType?,
                             location: SearchTarget) -> Int {
        guard fileType != nil || !isUnrestricted(location) else { return rows.count }
        return rows(fileType: fileType, location: location).count
    }

    private func isUnrestricted(_ location: SearchTarget) -> Bool {
        if case .unrestricted = location { return true }
        return false
    }

    /// 题头左边的标题：查询词；空查询（只按类型筛）时写「搜索结果」。
    public var title: String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "搜索结果" : trimmed
    }

    /// 题头右边的条数，与搜索窗状态栏同一套写法（`200 / 1374 项`）。
    public var countText: String { countText(matching: rows.count) }

    /// 题头右边的条数（筛过之后传筛完的行数）。
    ///
    /// ★ 分母始终是 `totalMatched`：用户要能看出「筛完剩 3 条，而这一批本来有 240 条匹配」。
    ///   两个数都写成 `rows.count` 就分不清「本来就这么少」和「筛掉了」。
    public func countText(matching count: Int) -> String {
        if totalMatched > count, !rows.isEmpty { return "\(count) / \(totalMatched) 项" }
        return "\(count) 项"
    }

    /// 当时限定的位置名；没限定位置时为 nil（此时不占位）。
    public var locationSuffix: String? {
        guard let locationTitle, !locationTitle.isEmpty else { return nil }
        return locationTitle
    }

    /// 这一批是不是空的。空的一批没有钉的意义——按钮会被置灰。
    public var isEmpty: Bool { rows.isEmpty }

    /// 窗口高度：题头 + 类型条 + 行（最多 `SearchModuleLayout.pinnedMaximumRows` 行）+ 上下留白。
    ///
    /// ★ 行高只有一个出处（App 的 `SearchLayout.rowHeight`，56），这里按同一口径算。
    /// 两处各写一个数就会出现「最后一行被切掉半截」——窗口高度是按行数算出来的，
    /// 不是内容撑的。
    /// ★ `rowCount` 由调用方传**筛完之后**的行数：在窗口里改类型/位置会改变行数，
    ///   高度必须跟着变，否则筛出 1 行时窗口还留着 10 行那么高。
    public func windowHeight(rowCount: Int, rowHeight: CGFloat) -> CGFloat {
        let visible = min(max(rowCount, 0), SearchModuleLayout.pinnedMaximumRows)
        let list = CGFloat(max(visible, 1)) * rowHeight + SearchModuleLayout.pinnedListPadding * 2
        return SearchModuleLayout.pinnedHeaderHeight + SearchModuleLayout.typeBarHeight + list
    }
}
