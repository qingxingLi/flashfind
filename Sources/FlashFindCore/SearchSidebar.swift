import Foundation

/// 结果模块左侧的**位置侧边栏**（用户 2026-10-27 要求）。
///
/// 用户原话：「到了搜索界面模块 搜索界面模块新增侧边栏功能 从侧边栏可以选择搜索位置
/// 默认是全部 依次往下排列 做成抽屉式的感觉 点击切换有页面切换动画 切换后显示该位置的文件
/// 无搜索结果有提示 … 侧边栏不要突出搜索框左右宽度 宽度保持一致」。
///
/// ## 与 `\` 命令面板是同一份位置清单
///
/// 侧边栏吃的是 `SearchCommandCatalog.items(kind: .location, …)` 那份候选
/// （App 层已经按「设置 ▸ 搜索」里排过的顺序、并滤掉被删的候选排好了）。
/// 于是「面板里第 3 个位置」与「侧边栏里第 3 行」永远是同一处，
/// 用户在哪边选都一样——两处各列一遍，迟早会有一边少了某个根。
///
/// ## 一条都不许藏（与面板同一条铁律）
///
/// ★ 2026-10-26 的真实报障：「位置没生效，只能搜到本机的」——根因是候选按
/// 「此刻已连接」过滤，而 App **重启后不会自动连 NAS**，于是刚开机时所有 NAS
/// 都被藏掉。侧边栏同样不许按 `ready` 过滤：位置是**用户配过的地方**，
/// 不是此刻在线的机器。状态差异走副标题（「未连接」），不靠藏条目表达。
public enum SearchSidebar {

    /// 侧边栏的一行。
    public struct Entry: Identifiable, Hashable, Sendable {
        public let id: String
        /// 主标题：根名（「全部位置」「此 Mac」或某个共享/文件夹名）。
        public let title: String
        /// 副标题：来源名（未连接的会带「· 未连接」）。
        public let subtitle: String?
        /// 点这一行要应用的位置限定。
        public let target: SearchTarget

        public init(id: String, title: String, subtitle: String? = nil,
                    target: SearchTarget) {
            self.id = id
            self.title = title
            self.subtitle = subtitle
            self.target = target
        }
    }

    /// 把位置候选转成侧边栏的行。
    ///
    /// ★ 只收 `.search` 动作的候选：那份清单里还可能有「打开设置…」，
    /// 它不是位置，出现在侧边栏里会变成一条点了跳走的怪东西。
    /// 这里按动作过滤，而不是按 id 排除某个字符串——动作才是它「是什么」。
    public static func entries(from items: [SearchCommandItem]) -> [Entry] {
        items.compactMap { item in
            guard case .search(let target) = item.action else { return nil }
            return Entry(id: item.id, title: item.title, subtitle: item.subtitle,
                         target: target)
        }
    }

    /// 每一行要不要写副标题。
    ///
    /// ★★ **每一行都写**（2026-10-29 真实报障：「飞牛位置侧边栏的存储空间 2 不显示设备名称」）。
    ///
    /// 上一版按「同一个来源只在组首行写一次」处理，理由是「一台 NAS 勾五个共享
    /// 就是五行，每行都写一遍来源名是噪音」。真实后果是：一台飞牛挂两个存储空间时，
    /// 第二行下面**整片空白**——用户看到的是一行没有出处的位置名，
    /// 既不知道它属于哪台设备，也看不到「未连接」这个状态。
    ///
    /// 副标题不是装饰，是**身份 + 状态**（「飞牛 fnOS」「群晖 Synology · 未连接」）：
    /// 一旦允许省略，省略的就不只是重复的设备名，还包括那一行自己的连接状态。
    /// 重复可以忍，缺信息不行。
    ///
    /// 判定留在 Core（不是视图里 `if subtitle != nil` + 别处的分组表）：
    /// 「这行画不画第二行字」是语义，用例直接钉住。
    public static func subtitleRows(_ entries: [Entry]) -> [Bool] {
        entries.map { !($0.subtitle ?? "").isEmpty }
    }

    /// 当前位置限定应该在侧边栏里高亮哪一行。
    ///
    /// - `.unrestricted` ⇒ 「全部位置」那一行。
    /// - `.local` ⇒ 「此 Mac」那一行（本机搜索关掉时它不在列表里 ⇒ 返回 nil）。
    /// - `.sourceRoot` ⇒ 那个根那一行。
    ///
    /// ★ 找不到就返回 `nil`，**不要**回落到「全部位置」：当前位置指向一个
    /// 已经被删掉的搜索根时，把「全部」点亮是在撒谎（用户会以为自己搜的是全部，
    /// 实际限定还挂在那个消失的根上）。界面在 nil 时不高亮任何一行，
    /// 与真实状态一致。
    public static func selectedID(for location: SearchTarget, in entries: [Entry]) -> String? {
        let candidateID: String
        switch location {
        case .unrestricted: candidateID = SearchCommandCatalog.allItemID
        case .local: candidateID = SearchCommandCatalog.localItemID
        case .sourceRoot(let sourceID, let root):
            candidateID = SearchCommandCatalog.locationItemID(sourceID: sourceID, root: root)
        }
        return entries.contains { $0.id == candidateID } ? candidateID : nil
    }

    /// 当前高亮那一行的标题（用于空结果提示里的「在哪没找到」）。
    public static func selectedTitle(for location: SearchTarget, in entries: [Entry]) -> String? {
        guard let id = selectedID(for: location, in: entries) else { return nil }
        return entries.first { $0.id == id }?.title
    }

    /// 当前**限定**的位置名（没限定 ⇒ `nil`）。
    ///
    /// ★ 这一条是从一个真实的自相矛盾里长出来的：`.unrestricted` 时侧边栏高亮的
    /// 是「全部位置」，但那是「不限定」的名字，不是限定名。直接拿它当位置名，
    /// 空结果提示会写成「“全部位置”里没有匹配的文件……或换回“全部”」——
    /// 一句话里既说在全部里没找到、又劝你换回全部。截图当场就露馅了。
    public static func limitedLocationTitle(for location: SearchTarget,
                                            in entries: [Entry]) -> String? {
        if case .unrestricted = location { return nil }
        return selectedTitle(for: location, in: entries)
    }
}

/// 没有搜索结果时说的那两句话。
///
/// ★ 为什么在 Core：位置一换，话就得换。「在「公司 nas」里没有匹配的文件」
/// 与「整个都没有」是两件事，用户据此决定「换个位置」还是「换个词」。
/// 这类文案以前散在视图里，改一处忘一处；收进来之后可以逐条断言。
public enum SearchEmptyHint {

    /// 标题：任何位置下都是「没有找到“关键词”」。
    public static func title(query: String) -> String {
        "没有找到“\(query)”"
    }

    /// 正文：**说清是在哪个位置没找到**，再给一条能马上做的事。
    ///
    /// - 没限定位置：建议换位置（现在就有侧边栏，这是最省事的下一步）。
    /// - 限定了位置：点明位置名，并给「换回全部位置」这条出路——
    ///   否则用户会以为整个搜索坏了，而不是「这个位置里没有」。
    public static func detail(locationTitle: String?) -> String {
        guard let locationTitle, !locationTitle.isEmpty else {
            return "试试更短的关键词，或换个位置再找"
        }
        return "“\(locationTitle)”里没有匹配的文件。试试更短的关键词，或换回“全部位置”"
    }
}
