import Foundation

/// 一次搜索限定在哪个「位置」上。
///
/// ★ 这个类型存在的唯一理由：**让「减少检索量」变成真的**。
///
/// 位置限定最终会变成「下发给设备的搜索根集合变小」：
/// 群晖走 `Search.start(folder_path[])`，OpenList 走「每个根各发一次
/// `/api/fs/search`」——少一个根就少一次设备侧扫描。
/// 如果只在界面层过滤结果，检索时间一点都不会变。
public enum SearchTarget: Hashable, Sendable {
    /// 不限定位置：搜哪些来源由界面上的范围（全部/本机/NAS）与各来源开关决定。
    case unrestricted
    /// 只搜本机（此 Mac，含已安装应用）。
    case local
    /// 只搜某个来源下的某个搜索根。
    ///
    /// - `sourceID`: 来源 ID（与 `SearchSource.id` 同域）。
    /// - `root`: 该来源下**已授权**的搜索根（DSM 逻辑共享路径或品牌适配器的根路径）。
    ///
    /// ★ 这个根必须已经是**授权过**的根。核心侧会拿它与已授权范围求交集，
    /// 交集为空即拒绝——所以客户端传一个没授权过的根不会扩大搜索面。
    case sourceRoot(sourceID: String, root: String)

    /// 这次限定涉及哪个来源（不限位置时为 nil）。
    public var sourceID: String? {
        switch self {
        case .unrestricted, .local: return nil
        case .sourceRoot(let id, _): return id
        }
    }

    /// 这次限定是否只搜本机。
    public var isLocalOnly: Bool {
        if case .local = self { return true }
        return false
    }
}

/// 「快捷方式」的两个来源：位置与文件类型。
///
/// ★ 2026-10-28 用户把「输入命令」这套整段取消了（`\` / `/` 不再唤起面板），
///   这个枚举**只剩下一个用途**：设置页里「位置顺序」这份配置按种类分开存
///   （`SearchQuickPickSettings` 的存储键仍用 `rawValue`，老用户的排序不会失效）。
///   面板已经不在了，别再按它去解析输入框。
public enum SearchCommandKind: String, Hashable, Sendable, CaseIterable {
    /// 搜索位置（此 Mac / 各 NAS 的各搜索根）。
    case location
    /// 文件类型（pdf / word / 照片 …）。
    case fileType
}

/// 文件类型清单（`/` 面板的候选）。
///
/// ★ `formatWord` 与 `title` 分开，是因为**显示名不一定是词汇表认的词**：
/// 用户说「word」，而 `FileFormatVocabulary` 认的是 `doc`（连带 docx）。
/// 直接拿显示名去喂解析器，`word` 会掉进关键词里 —— 面板显示选上了，
/// 搜索却完全没有格式限制。
public enum SearchFileTypeCatalog {

    public struct FileType: Hashable, Sendable, Identifiable {
        public let id: String
        /// 面板上显示的名字。
        public let title: String
        /// 交给 `SearchQueryParser` 的格式词。
        public let formatWord: String

        public init(id: String, title: String, formatWord: String) {
            self.id = id
            self.title = title
            self.formatWord = formatWord
        }
    }

    /// 九条：正好占满数字键 1–9（0 留给「打开设置」）。
    ///
    /// ★ 具体格式在前、大类在后，是因为用户举的例子就是
    /// 「1. word  2. pdf  3. 照片」——先想得起来的是具体格式。
    public static let all: [FileType] = [
        FileType(id: "type:pdf", title: "pdf", formatWord: "pdf"),
        FileType(id: "type:word", title: "word", formatWord: "doc"),
        FileType(id: "type:excel", title: "excel", formatWord: "xls"),
        FileType(id: "type:ppt", title: "ppt", formatWord: "ppt"),
        FileType(id: "type:photo", title: "照片", formatWord: "照片"),
        FileType(id: "type:video", title: "视频", formatWord: "视频"),
        FileType(id: "type:music", title: "音乐", formatWord: "音乐"),
        FileType(id: "type:archive", title: "压缩包", formatWord: "压缩包"),
        FileType(id: "type:document", title: "文档", formatWord: "文档"),
    ]
}

/// 搜索命令面板（斜杠唤起）里的一条候选。
///
/// 命令面板是**指令入口**，不是搜索框的过滤器：候选里的每一条都对应
/// 一个可以立刻执行的动作，而不是「换个词再搜一次」。
public struct SearchCommandItem: Identifiable, Hashable, Sendable {
    /// 候选被选中之后要做什么。
    public enum Action: Hashable, Sendable {
        /// 限定到某个位置，随后在该位置搜索。
        case search(SearchTarget)
        /// 限定到某个文件类型。
        case filterFileType(SearchFileTypeCatalog.FileType)
        /// 打开设置。
        case openSettings
    }

    public let id: String
    /// 主标题（位置或类型的名称）。
    public let title: String
    /// 副标题（来源名等）。没有就为 nil——界面不编造说明文字。
    public let subtitle: String?
    public let action: Action

    public init(id: String, title: String, subtitle: String? = nil, action: Action) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.action = action
    }
}

/// 命令目录：把「有哪些位置/类型可搜」变成候选列表，并按输入过滤。
///
/// ★ 放在 Core 是因为它有判定：哪些位置**此刻**可选（来源就绪与否）、
/// 以及过滤规则是什么。这两件事以前只可能写在界面里，于是没法断言。
public enum SearchCommandCatalog {

    /// 命令面板里用到的来源信息。
    ///
    /// 只带命令面板需要的三件事，不带凭据、不带主机地址。
    public struct SourceEntry: Hashable, Sendable {
        public let sourceID: String
        /// 用户看到的来源名。
        public let displayName: String
        /// 该来源下**已授权**的搜索根（用户勾选过的那些）。
        public let roots: [String]
        /// 来源是否就绪（已连接、已选好搜索位置）。
        ///
        /// ★ 它**只影响副标题怎么写**，不决定这一条进不进候选（见 `items`）。
        /// 早先这里拿它过滤候选，直接导致一次真实报障（见 `items` 的说明）。
        public let ready: Bool

        public init(sourceID: String, displayName: String, roots: [String], ready: Bool) {
            self.sourceID = sourceID
            self.displayName = displayName
            self.roots = roots
            self.ready = ready
        }

        /// 位置候选的副标题：来源名，未连接时加一句状态。
        ///
        /// ★ 「未连接」是**状态**不是解释性备注：用户点了这一条会先连上再搜，
        /// 不告诉他的话，这段时间里界面看起来像什么都没发生。
        public var locationSubtitle: String {
            ready ? displayName : displayName + " · 未连接"
        }
    }

    /// 候选列表里「本机」这一条的命令 ID。
    public static let localItemID = "target:local"
    /// 候选列表里「全部位置」这一条的命令 ID（取消位置限定）。
    public static let allItemID = "target:all"
    /// 候选列表里「打开设置」这一条的命令 ID。
    public static let settingsItemID = "command:openSettings"

    /// 某个来源下某个搜索根的候选 id。
    ///
    /// ★ 拼 id 只许有这一处：侧边栏要把「当前位置限定」反查成「该高亮哪一行」，
    /// 两处各拼一遍的话，中间改一个分隔符就会出现「位置生效了、侧边栏没有高亮」。
    public static func locationItemID(sourceID: String, root: String) -> String {
        "target:\(sourceID):\(root)"
    }

    /// 面板一次画得下多少行候选。
    ///
    /// ★ 这个数由编号规则反推出来，不能随便定：数字键 1–9 给前九条候选，
    /// 0 固定给「打开设置」⇒ **最多有十条候选带着看得见的编号**。
    /// 画得比这少，按下去的数字就指向屏幕外的条目：用户按 7 选中了 A0002，
    /// 面板上却根本看不到哪一条被选中（2026-10-26 真实报障：OpenList 选了
    /// 四个文件夹，面板只画出第一个，剩下的三个既看不见也点不到）。
    ///
    /// 候选超过这个数时不截断，改为滚动（见 `SearchCommandPaletteView`）：
    /// 截断等于把超出的位置彻底藏起来，而用户明明配过它们。
    public static let maximumVisibleRows = SearchCommandNumbering.numberedLimit + 1

    /// 构建候选列表。
    ///
    /// 位置面板：全部位置 → 本机 → 按来源顺序列出各来源下的每个搜索根 → 打开设置。
    /// 类型面板：九种类型 → 打开设置。
    ///
    /// ★ 「全部位置」排在最前：位置限定一旦生效就必须有办法退回去，
    /// 否则用户被卡在某个位置里出不来。
    /// ★ 两个面板**都以「打开设置」收尾**：它是兜底动作——
    /// 前面的位置都搜不了、类型都不对时才需要它。
    /// ★★ **位置候选不看来源是否已连接**（2026-10-26 真实报障）。
    ///
    /// 原先这里是 `for source in sources where source.ready`，注释还写着
    /// 「未就绪的来源不进候选」。看起来合理，实际把功能废掉了：
    /// App **重启后不会自动连 NAS**（这是刻意设计，避免开机就去动钥匙串），
    /// 于是刚开机那会儿所有 NAS 都是未就绪 ⇒ 面板里只剩「全部位置 / 此 Mac」，
    /// 用户配好的 NAS 一个都看不见，现象是「位置没生效，只能搜本机」。
    ///
    /// 根子上的错在于把「位置」当成了「此刻在线的机器」。位置是**用户配过的地方**：
    /// 配过就该在列表里，选中时先连上再搜（App 层 `applySearchTarget` 负责）。
    /// 状态差异走副标题（`SourceEntry.locationSubtitle`），不靠把条目藏起来表达。
    public static func items(kind: SearchCommandKind,
                             sources: [SourceEntry],
                             includeLocal: Bool,
                             includeSettings: Bool = true) -> [SearchCommandItem] {
        var out: [SearchCommandItem] = []
        switch kind {
        case .location:
            out.append(SearchCommandItem(id: allItemID, title: "全部位置",
                                          action: .search(.unrestricted)))
            if includeLocal {
                out.append(SearchCommandItem(id: localItemID, title: "此 Mac",
                                              action: .search(.local)))
            }
            for source in sources {
                for root in source.roots {
                    out.append(SearchCommandItem(id: locationItemID(sourceID: source.sourceID, root: root),
                                                  title: SearchTargetLabel.rootName(root),
                                                  subtitle: source.locationSubtitle,
                                                  action: .search(.sourceRoot(sourceID: source.sourceID, root: root))))
                }
            }
        case .fileType:
            for type in SearchFileTypeCatalog.all {
                out.append(SearchCommandItem(id: type.id, title: type.title,
                                              action: .filterFileType(type)))
            }
        }
        if includeSettings {
            out.append(SearchCommandItem(id: settingsItemID, title: "打开设置…",
                                          action: .openSettings))
        }
        return out
    }

    /// 按输入过滤候选。
    ///
    /// - 空输入 ⇒ 原样返回（输入斜杠就该看到全部候选）。
    /// - 匹配范围：主标题与副标题，**不区分大小写**的子串匹配。
    ///
    /// ★ 不做模糊匹配（ subsequence / 拼音首字母）：命令面板的候选数量很小，
    /// 子串匹配已经够用；而模糊匹配一旦猜错，用户看到的是「我明明输了
    /// 「照片」却匹配到「影片」」这种无法解释的结果。
    public static func filter(_ items: [SearchCommandItem], by text: String) -> [SearchCommandItem] {
        let needle = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty else { return items }
        return items.filter { item in
            if item.title.range(of: needle, options: [.caseInsensitive]) != nil { return true }
            if let subtitle = item.subtitle,
               subtitle.range(of: needle, options: [.caseInsensitive]) != nil { return true }
            return false
        }
    }
}

/// 候选的**数字键编号**。
///
/// ★ 规则是用户定的：数字 1–9 按顺序给前九条候选，**0 固定给「打开设置」**——
/// 因为 0 在键盘上排在 9 后面，手指不用挪位置。
/// 于是「打开设置」永远是按 0，与它在列表里的位置无关。
///
/// ★ 第十条及以后没有数字：那时就该继续打字筛选，而不是塞一个要数着按的键。
///
/// ## 编号 = 位置，没有第二种来源（1.1.18）
///
/// 面板排第几行，这一行就写几。用户拖动排序之后数字**立刻跟着变**
/// （「此 Mac」从第 1 位拖到第 3 位 ⇒ 它写 3，别的行依次让位），
/// 因为数字根本不是另一份配置，只是顺序的影子。
///
/// 上一版允许给单条「指定固定键」，结果是同一屏里出现「排第 1 却写着 5」：
/// 用户看不出那个 5 从哪来，拖动之后它也不跟着变。那一版已删掉。
///
/// ★ 编号永远按**当前显示的这组候选**算（筛选之后也一样）：面板上写几，
/// 按下去就选中几。若拿筛选前的表算，用户按 1 会选到一条根本没显示的项。
public enum SearchCommandNumbering {

    /// 数字键能给到几条候选（1–9）。
    ///
    /// ★ 面板一次画得下多少行由它推出来（见 `SearchCommandCatalog.maximumVisibleRows`）：
    /// 「能按到哪」与「能看见哪」必须是同一件事。
    public static let numberedLimit = 9

    /// 可供用户选择的数字键。`0` 不在其中 —— 它固定归「打开设置」，
    /// 让用户把 0 指给某个位置，就等于把兜底入口占掉。
    public static var availableKeys: [Int] { Array(1...numberedLimit) }

    /// 候选用得着的全部编号（与 `items` 一一对应，没有编号的为 nil）。
    ///
    /// 只由**显示顺序**决定：第 1 行是 1 …… 第 9 行是 9，第 10 行起 nil，
    /// 「打开设置」是 0。
    /// 一次算出整组而不是「按单个下标算」：编号是整屏的事，
    /// 少算一个空位就会让后面所有行错位。
    public static func keys(in items: [SearchCommandItem]) -> [Int?] {
        var out = [Int?](repeating: nil, count: items.count)
        var next = 1
        for index in items.indices {
            if items[index].id == SearchCommandCatalog.settingsItemID {
                out[index] = 0
                continue
            }
            guard next <= numberedLimit else { continue }
            out[index] = next
            next += 1
        }
        return out
    }

    /// 第 `index` 条候选对应哪个数字键。`nil` = 这条没有数字键。
    public static func key(for index: Int, in items: [SearchCommandItem]) -> Int? {
        guard items.indices.contains(index) else { return nil }
        return keys(in: items)[index]
    }

    /// 数字键对应第几条候选。`nil` = 这个数字当前没有对应项（按了不做事）。
    public static func index(forKey key: Int, in items: [SearchCommandItem]) -> Int? {
        guard (0...numberedLimit).contains(key) else { return nil }
        if key == 0 {
            return items.lastIndex { $0.id == SearchCommandCatalog.settingsItemID }
        }
        return keys(in: items).firstIndex { $0 == key }
    }
}

/// 搜索框最前面那排**已选定的限定**（位置 + 类型）。
///
/// ★ 它是「状态」不是历史：界面上显示成蓝色小字放在关键词前面，
/// 让用户一眼看见这次搜索被限成了什么样。
///
/// ★ 两个限定**可叠加**：`\照片` + `/pdf` = 在照片里找 PDF。
public struct SearchTokenBar: Hashable, Sendable {

    /// 哪一个限定。
    public enum Slot: Hashable, Sendable {
        case location
        case fileType
    }

    /// 位置限定。`.unrestricted` = 没限定。
    public var location: SearchTarget
    /// 类型限定。`nil` = 没限定。
    public var fileType: SearchFileTypeCatalog.FileType?
    /// 最近一次设置的是哪一个——决定删除键先删谁。
    private var lastSet: Slot?

    public init(location: SearchTarget = .unrestricted,
                fileType: SearchFileTypeCatalog.FileType? = nil,
                lastSet: Slot? = nil) {
        self.location = location
        self.fileType = fileType
        self.lastSet = lastSet
    }

    public static let empty = SearchTokenBar()

    public var hasLocation: Bool {
        if case .unrestricted = location { return false }
        return true
    }
    public var hasFileType: Bool { fileType != nil }
    public var isEmpty: Bool { !hasLocation && !hasFileType }

    public mutating func setLocation(_ target: SearchTarget) {
        location = target
        lastSet = .location
    }

    public mutating func setFileType(_ type: SearchFileTypeCatalog.FileType) {
        fileType = type
        lastSet = .fileType
    }

    public mutating func clear(_ slot: Slot) {
        switch slot {
        case .location: location = .unrestricted
        case .fileType: fileType = nil
        }
        if lastSet == slot { lastSet = nil }
    }

    /// ★ 关键词为空时按删除键，该删哪一个限定。
    ///
    /// 关键词**不为空**时一律返回 nil —— 那时删除键属于文本编辑
    /// （删的是用户刚打的字），抢过来会变成「输入框删不动字」。
    ///
    /// 都为空时按 LIFO（最后设的先删）：符合「撤销最近一步」的直觉。
    public func slotToRemoveOnBackspace(keywordEmpty: Bool) -> Slot? {
        guard keywordEmpty else { return nil }
        if lastSet == .fileType, hasFileType { return .fileType }
        if lastSet == .location, hasLocation { return .location }
        if hasFileType { return .fileType }
        if hasLocation { return .location }
        return nil
    }

    /// 界面上要显示的一枚限定：标签 + 它属于哪个槽位。
    ///
    /// ★ 必须带上 `slot`，而不是只给一串字符串：
    /// 鼠标点某一枚时，要删的**就是被点的那一枚**；
    /// 只有槽位能表达这件事，标签名不能（两个位置的显示名可能一样）。
    public struct Token: Hashable, Sendable, Identifiable {
        public let slot: Slot
        public let label: String
        public init(slot: Slot, label: String) {
            self.slot = slot
            self.label = label
        }
        /// 同一时刻每个槽位最多一枚，槽位即可当 id。
        public var id: Slot { slot }
    }

    /// 界面上要显示的那排限定（位置在前，类型在后）。
    public var tokens: [Token] {
        var out: [Token] = []
        if let label = SearchTargetLabel.label(for: location) { out.append(Token(slot: .location, label: label)) }
        if let type = fileType { out.append(Token(slot: .fileType, label: type.title)) }
        return out
    }

    /// 界面上要显示的那排限定名（位置在前，类型在后）。
    public var labels: [String] {
        var out: [String] = []
        if let label = SearchTargetLabel.label(for: location) { out.append(label) }
        if let type = fileType { out.append(type.title) }
        return out
    }

    /// ★ 真正发给搜索的文本：把类型词拼在关键词后面。
    ///
    /// 走的是**既有的** `SearchQueryParser` —— 用户在框里打「pdf」走的也是这条路，
    /// 所以行为一致，不需要新的过滤机制。只给类型没给关键词时（想看某类型
    /// 的全部文件）就只发类型词。
    public func searchText(keyword: String) -> String {
        let word = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let type = fileType else { return word }
        guard !word.isEmpty else { return type.formatWord }
        return word + " " + type.formatWord
    }
}

/// 搜索根的显示名。
///
/// 搜索根在协议里是路径（DSM 的 `/示例共享`、品牌的 `/存储A`），
/// 但列表里显示整条路径既长又难读——只取最后一段。
/// 取不到最后一段时退回整条路径，不显示空白。
public enum SearchTargetLabel {
    public static func rootName(_ root: String) -> String {
        let trimmed = root.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        let segments = trimmed.split(separator: "/", omittingEmptySubsequences: true)
        return segments.last.map(String.init) ?? trimmed
    }

    /// 当前限定的位置在界面上叫什么。
    ///
    /// 不限定位置时不显示任何东西（`nil`）——界面上不该常驻一句
    /// 「搜索范围：全部」，那是废话。
    public static func label(for target: SearchTarget) -> String? {
        switch target {
        case .unrestricted: return nil
        case .local: return "此 Mac"
        case .sourceRoot(_, let root): return rootName(root)
        }
    }
}
