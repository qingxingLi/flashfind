import Foundation

/// 右键菜单里的一项。**菜单内容只有这一处定义**。
///
/// ── 为什么要搬到 Core ─────────────────────────────────────────────
/// 2026-10-29 用户报障：飞牛的结果右键有「下载」，群晖、OpenList 的没有；
/// OpenList 的结果连「在 Finder 中显示」都没有。原因是两份菜单各自用
/// `hasWebOpenTarget` 分叉、下载又各自挂在 `supportsDirectDownload` 后面，
/// 三个品牌于是长出三种菜单。
///
/// 判定写在 App 层就是没测（App 是可执行目标，测试依赖不了它），所以
/// 「哪些动作出现在菜单里」这件事放在这里，由测试钉住：**凡是 NAS 结果，
/// 菜单都一样**。App 只负责把每一项画成按钮。
public enum ResultMenuItem: String, CaseIterable, Sendable, Hashable, Identifiable {
    case open
    case reveal
    case quickLook
    case downloadAndOpen
    case downloadToFolder
    case copyPath
    case copyWebLink
    case copyName

    public var id: String { rawValue }

    /// 菜单分组：组与组之间画一条分隔线。
    public enum Section: Int, Sendable, Comparable {
        case action = 0
        case transfer = 1
        case clipboard = 2
        public static func < (lhs: Section, rhs: Section) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var section: Section {
        switch self {
        case .open, .reveal, .quickLook: return .action
        case .downloadAndOpen, .downloadToFolder: return .transfer
        case .copyPath, .copyWebLink, .copyName: return .clipboard
        }
    }
}

public enum ResultMenuPlan {
    /// 这一行的右键菜单有哪几项、按什么顺序。
    ///
    /// - 本机结果：打开 / 在 Finder 中显示 / 快速查看 / 复制路径 / 复制文件名。
    ///   本地文件没有「下载」这回事，菜单里也就不放。
    /// - NAS 结果（**飞牛、群晖、OpenList 一律相同**）：上面这些 +
    ///   下载后打开 / 下载到…；只有**真的有网页地址**的行才多一项「复制网页链接」
    ///   （地址都没有，复制出来只会是空串）。
    ///
    /// ★ 下载项**不按品牌出现**：能不能下载是动作层的事，由
    ///   `ResultDownloadRouting` 决定走设备下载还是本地复制；两条都不通时
    ///   给一句能懂的话，而不是让菜单项凭空消失——用户看不出「消失」
    ///   代表什么，只会以为功能坏了。
    public static func items(for result: SearchResult) -> [ResultMenuItem] {
        guard result.sourceType == .nas else {
            return [.open, .reveal, .quickLook, .copyPath, .copyName]
        }
        var items: [ResultMenuItem] = [.open, .reveal, .quickLook, .downloadAndOpen, .downloadToFolder, .copyPath]
        if result.hasWebOpenTarget { items.append(.copyWebLink) }
        items.append(.copyName)
        return items
    }

    /// 分隔线要画在哪几项之前（第 1 项之前不画）。
    public static func separatorBefore(_ item: ResultMenuItem, in items: [ResultMenuItem]) -> Bool {
        guard let index = items.firstIndex(of: item), index > 0 else { return false }
        return items[index - 1].section != item.section
    }
}

/// 「下载」这条动作该走哪条路。
///
/// 三家 NAS 的下载能力不一样，但**菜单必须一样**（2026-10-29 用户定）。
/// 所以差别收在这里，由它回答「这一行怎么拿到本地副本」：
///
/// - `.deviceDownload`：品牌适配器自己实现了下载（目前只有飞牛 fnOS：
///   `multiple-download` 拿临时 token → 拉 zip → 解包）。这条路**不需要挂载**，
///   SMB 不通也照样能下。
/// - `.localCopy`：从本机路径拷一份（已挂载的共享直接用；没挂载时由打开链
///   先挂上）。群晖、OpenList 走这条。
/// - `.unsupported`：两条都不通，带一句**说清怎么办**的话。
public enum ResultDownloadRoute: Equatable, Sendable {
    case deviceDownload
    case localCopy
    case unsupported(String)
}

public enum ResultDownloadRouting {
    /// - Parameter hasLocalPath: 这一行**此刻**已有可读的本机路径（已挂载）。
    ///   只有它能让「网页来源」落到本地复制那条路上；传 false 时不要假装能下。
    public static func route(for result: SearchResult, vendor: NASSourceConfig.Vendor?,
                             hasLocalPath: Bool = false) -> ResultDownloadRoute {
        guard let vendor else {
            return .unsupported("这个结果的来源已下线，无法下载")
        }
        if vendor == .fnos { return .deviceDownload }
        // 网页来源（OpenList）没有 SMB 共享可挂：它的文件只能在浏览器里到达。
        // 挂上了 WebDAV 时它就有本地路径了，那条路照走「拷一份」。
        if result.hasWebOpenTarget && !hasLocalPath {
            return .unsupported("这个来源的文件在网页上，没有可下载的本机路径；按 Return 用浏览器打开")
        }
        return .localCopy
    }
}
