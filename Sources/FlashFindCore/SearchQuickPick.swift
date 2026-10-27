import Foundation

/// 命令面板的**候选顺序**，以及由顺序直接决定的**数字快捷键**（「设置 ▸ 搜索」里可改）。
///
/// ## 只有一条规则：第几行就是几号
///
/// 面板上排第 1 行写 1、第 3 行写 3；`0` 永远归「打开设置」。
/// 于是「数字」不是另一份配置，而是**顺序的另一种写法**：
/// 拖动排序 ⇒ 数字跟着变（「此 Mac」从第 1 位拖到第 3 位，它旁边的数字就是 3）。
///
/// ★ 为什么不给每条单独「指定一个固定键」：那样同一屏里会出现
/// 「排第 1 但写着 5」——用户看不出这个 5 是从哪来的，拖动之后它还不跟着变。
/// 一份数据、一种表现，才不会出现「界面上写几」与「按下去选中谁」分叉。
///
/// ## 删掉与换掉
///
/// 用户能对某一条做的事只有三件：**挪位置**（拖动）、**删掉**（`hide`）、
/// **换成别的位置/格式**（`replace`）。三者共用同一份「整份 id 顺序」：
///
/// * `hide` 把 id 从顺序里摘掉，并记进 `hiddenTable` —— 否则它下次会因为
///   「目录里还有这一条」而按自然顺序悄悄长回来；
/// * `replace` 是「在同一位次上换人」：新 id 接替旧 id 的位置，旧 id 进隐藏表。
///   这样换完之后数字不变，用户不会觉得自己那条被挪走了。
///
/// ## 默认值就是「什么都不存」
///
/// 没配过的时候顺序 = 目录给的自然顺序（位置：全部位置 → 此 Mac → 各搜索根；
/// 类型：九条固定顺序），编号 = 1–9 顺排、0 给「打开设置」。
/// 也就是说：**这个类型为空时，行为与加它之前一字不差**。
public struct SearchQuickPickSettings: Equatable, Sendable {

    /// 偏好键。沿用 `ff2.` 前缀。
    public static let storageKey = "ff2.searchQuickPick.v1"
    /// 存储格式版本。将来改结构就换版本号，旧数据读不出来按「默认」处理。
    public static let version = 1
    /// 一份顺序最多记多少条 id。
    ///
    /// 防御损坏/被手改过的偏好：顺序表只增不减地累积已删除来源的 id，
    /// 没有上限的话它会一直长下去。
    static let orderLimit = 200

    private var orderTable: [SearchCommandKind: [String]]
    /// 被用户删掉的候选 id。
    ///
    /// ★ 必须有这一份：候选是从「目录 + 用户配置」现算出来的，
    /// 不做删除记录的话，删掉的搜索根下一次刷新就又出现在面板里。
    private var hiddenTable: [SearchCommandKind: Set<String>]

    public init(order: [SearchCommandKind: [String]] = [:],
                hidden: [SearchCommandKind: Set<String>] = [:]) {
        orderTable = order
        hiddenTable = hidden
    }

    /// 完全没配过。行为等同加这个功能之前。
    public static let empty = SearchQuickPickSettings()

    // MARK: - 读

    /// 用户排过的 id 顺序（没排过就是空数组）。
    public func order(for kind: SearchCommandKind) -> [String] { orderTable[kind] ?? [] }

    /// 用户删掉的候选 id（没删过就是空集合）。
    public func hiddenIDs(for kind: SearchCommandKind) -> Set<String> {
        hiddenTable[kind] ?? []
    }

    /// 这一页有没有被改过。界面据此决定「恢复默认」能不能点。
    public func hasCustomization(for kind: SearchCommandKind) -> Bool {
        !order(for: kind).isEmpty || !hiddenIDs(for: kind).isEmpty
    }

    // MARK: - 写

    /// 把第 `from` 条挪到第 `to` 条（`to` 是**移动后在列表里的下标**）。
    ///
    /// - Parameter items: 当前**已排好序**的候选（含「打开设置」也无妨，它会被跳过）。
    ///
    /// ★ 存的是**整份 id 顺序**，不是「谁在谁前面」的一堆相对关系：
    /// 相对关系没法表达「A 和 B 之间插进来一个新来源」，而整份顺序里
    /// 新来源不在表内、自然排到末尾，不必写迁移代码。
    public mutating func move(_ kind: SearchCommandKind, from: Int, to: Int,
                              among items: [SearchCommandItem]) {
        var ids = baseOrder(kind, among: items)
        guard ids.indices.contains(from) else { return }
        let moved = ids.remove(at: from)
        let target = min(max(to, 0), ids.count)
        ids.insert(moved, at: target)
        orderTable[kind] = ids
    }

    /// 删掉一条：从面板里彻底拿掉，不会因为「目录里还有」再长回来。
    ///
    /// - Returns: 是否采纳。`items` 里没有它就是没删（例如 id 抄错的旧数据）。
    ///   「打开设置」不能被删：它是位置都搜不了时的兜底入口。
    @discardableResult
    public mutating func hide(_ id: String, kind: SearchCommandKind,
                              among items: [SearchCommandItem]) -> Bool {
        guard id != SearchCommandCatalog.settingsItemID,
              items.contains(where: { $0.id == id }) else { return false }
        var ids = baseOrder(kind, among: items)
        guard let index = ids.firstIndex(of: id) else { return false }
        ids.remove(at: index)
        orderTable[kind] = ids
        var hidden = hiddenIDs(for: kind)
        hidden.insert(id)
        setHidden(hidden, for: kind)
        return true
    }

    /// 把某一行的**位置/格式换掉**：新 id 接替旧 id 的那一行。
    ///
    /// ★ 这是「换人」不是「删一个再拖一个」：位次不变，所以换完之后
    /// 这一行旁边的数字还是原来那个，用户不会觉得自己那条被挪到别处去了。
    ///
    /// ★ 新条目**本来就在列表里**时，要从它原来的位置摘掉（它是搬过来，
    /// 不是多出一条）。界面上不会因此看到两行（`arrange` 是拿目录全集重排），
    /// 但顺序表会留下两份同一个 id —— 那张表的约定是「每个候选恰好一次」，
    /// 破了之后 `move` 的 from/to 下标会一天天对不上。
    ///
    /// - Parameter items: 当前**可见的**候选（含「打开设置」无妨）。
    ///   `newID` 应当来自目录候选（`SearchCommandReplacement.candidates`）。
    /// - Returns: 是否采纳。`id` 不在当前列表里、或 `newID` 就是它自己时不采纳。
    @discardableResult
    public mutating func replace(_ id: String, with newID: String, kind: SearchCommandKind,
                                 among items: [SearchCommandItem]) -> Bool {
        guard id != newID, !newID.isEmpty,
              id != SearchCommandCatalog.settingsItemID,
              newID != SearchCommandCatalog.settingsItemID else { return false }
        var ids = baseOrder(kind, among: items)
        guard ids.contains(id) else { return false }
        // 先摘掉新条目在原位的出现，再定位旧条目：先替换后摘会让下标错位。
        // 界面上不会因此看到两行（`arrange` 是拿目录全集重排，同一 id 只出现一次），
        // 但顺序表本身会留下两份同一个 id —— 那份表的约定是「每个候选恰好一次」，
        // 破了之后 `move` 的 from/to 下标会一天天对不上。
        ids.removeAll { $0 == newID }
        guard let index = ids.firstIndex(of: id) else { return false }
        ids[index] = newID
        orderTable[kind] = ids
        var hidden = hiddenIDs(for: kind)
        hidden.insert(id)
        hidden.remove(newID)
        setHidden(hidden, for: kind)
        return true
    }

    /// 把某一页恢复成自然顺序（编号随之回到 1–9 顺排，删掉的也全部回来）。
    public mutating func reset(_ kind: SearchCommandKind) {
        orderTable[kind] = nil
        hiddenTable[kind] = nil
    }

    // MARK: - 内部

    /// 这一页「现在这份顺序」的完整 id 列表（不含「打开设置」）。
    ///
    /// 三个写操作（移动/删除/替换）都先取这一份再改：只改一处，
    /// 「表里还没有的候选排末尾」这条规则就不会在某个操作里被忘掉。
    private func baseOrder(_ kind: SearchCommandKind, among items: [SearchCommandItem]) -> [String] {
        let body = items.map(\.id).filter { $0 != SearchCommandCatalog.settingsItemID }
        let existing = order(for: kind)
        guard !existing.isEmpty else { return body }
        let present = Set(body)
        var out = existing.filter { present.contains($0) }
        let known = Set(out)
        for id in body where !known.contains(id) { out.append(id) }
        return out
    }

    /// 写隐藏表。空集合存成 nil：两份内容相同的设置必须 `==` 相等，
    /// 否则「存了再读要一模一样」那条断言会因为一个空字典而假红。
    private mutating func setHidden(_ ids: Set<String>, for kind: SearchCommandKind) {
        if ids.isEmpty { hiddenTable[kind] = nil } else { hiddenTable[kind] = ids }
    }

    // MARK: - 落盘

    /// 存储形态。
    ///
    /// 字典键用 `SearchCommandKind.rawValue` 而不是把枚举直接当键：
    /// 枚举当 JSON 键要靠 `CodingKey` 的隐式规则，写出去长什么样取决于编译器的
    /// 推导顺序 —— 那是我们没法用一条断言钉住的东西。
    ///
    /// ★ `keys` 是**上一版留下的字段**：那一版允许给单条指定固定键。
    /// 现在数字由顺序决定，这个字段不再读、也不再写；保留在解码结构里
    /// 只是为了让那一版存下的顺序**不因为多一个字段而整份作废**。
    /// ★ `hidden` 是本版新增的可选字段：旧数据里没有它 ⇒ 解码为 nil ⇒
    /// 「什么都没删」，顺序照旧生效。
    private struct Stored: Codable {
        var v: Int
        var order: [String: [String]]
        var keys: [String: [String: Int]]?
        var hidden: [String: [String]]?
    }

    /// 从偏好里读。
    ///
    /// ★ 读坏了**不抛错、不崩**：直接回落到默认。顺序读不出来只该
    /// 表现为「回到出厂顺序」，不该让设置页打不开。
    public static func load(from preferences: ClientPreferences) -> SearchQuickPickSettings {
        guard let data = preferences.data(forKey: storageKey),
              let stored = try? JSONDecoder().decode(Stored.self, from: data),
              stored.v == version else { return .empty }
        var result = SearchQuickPickSettings()
        for (raw, ids) in stored.order {
            guard let kind = SearchCommandKind(rawValue: raw) else { continue }
            let cleaned = sanitize(order: ids)
            if !cleaned.isEmpty { result.orderTable[kind] = cleaned }
        }
        for (raw, ids) in stored.hidden ?? [:] {
            guard let kind = SearchCommandKind(rawValue: raw) else { continue }
            // 「打开设置」不许进隐藏表：手改过的偏好也不该把兜底入口删掉。
            let cleaned = sanitize(order: ids).filter { $0 != SearchCommandCatalog.settingsItemID }
            if !cleaned.isEmpty { result.hiddenTable[kind] = Set(cleaned) }
        }
        return result
    }

    /// 写回偏好。
    public func save(to preferences: ClientPreferences) {
        var orderByKind: [String: [String]] = [:]
        for kind in SearchCommandKind.allCases {
            let ids = order(for: kind)
            if !ids.isEmpty { orderByKind[kind.rawValue] = ids }
        }
        var hiddenByKind: [String: [String]] = [:]
        for kind in SearchCommandKind.allCases {
            let ids = hiddenIDs(for: kind)
            // 排序只为「同一份设置写出的字节固定」，便于比对与排查。
            if !ids.isEmpty { hiddenByKind[kind.rawValue] = ids.sorted() }
        }
        let stored = Stored(v: Self.version,
                            order: orderByKind,
                            keys: nil,
                            hidden: hiddenByKind.isEmpty ? nil : hiddenByKind)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(stored) else { return }
        preferences.set(data, forKey: Self.storageKey)
    }

    /// 去重、去空、截断。
    private static func sanitize(order ids: [String]) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        for id in ids where !id.isEmpty {
            guard seen.insert(id).inserted else { continue }
            out.append(id)
            if out.count >= orderLimit { break }
        }
        return out
    }
}

/// 设置页要画的一行：候选 + 它**此刻生效**的编号。
///
/// ★ 设置页**不列「打开设置」**：它的号固定是 0，既不能被拖动，也不该被
/// 改成别的数字 —— 兜底入口不参与排序。所以这里由 Core 统一过滤，
/// 界面层不必记得「最后一行要跳过」。
public struct SearchQuickPickRow: Identifiable, Hashable, Sendable {
    public let item: SearchCommandItem
    /// 面板上这一条现在写的数字（没有就是 nil —— 超过九条时排进去的那些）。
    public let key: Int?
    public var id: String { item.id }

    public init(item: SearchCommandItem, key: Int?) {
        self.item = item
        self.key = key
    }
}

extension SearchQuickPickSettings {
    /// 设置页某一面板的行（顺序已由调用方排好，这里只算编号并滤掉「打开设置」）。
    public func rows(for kind: SearchCommandKind,
                     in items: [SearchCommandItem]) -> [SearchQuickPickRow] {
        let numbers = SearchCommandNumbering.keys(in: items)
        return zip(items, numbers).compactMap { item, number in
            guard item.id != SearchCommandCatalog.settingsItemID else { return nil }
            return SearchQuickPickRow(item: item, key: number)
        }
    }
}

/// 「把这一行换成别的位置/格式」时，能换成什么。
///
/// ★ 候选是**目录里的其它全部条目**（去掉自己、去掉「打开设置」），
/// 包括此刻已经显示在列表里的那些：「把第 1 行的 pdf 换成第 9 行的文档」
/// 是替换的正常用法，`replace` 会把文档从第 9 行搬过来、不会留下两行。
/// 被删过的条目也在里面 —— 那正好是「删错了怎么找回来」的唯一入口。
public enum SearchCommandReplacement {
    public static func candidates(all: [SearchCommandItem], excluding id: String) -> [SearchCommandItem] {
        all.filter { $0.id != id && $0.id != SearchCommandCatalog.settingsItemID }
    }
}

/// 把「自然顺序」换成「用户排的顺序」。
///
/// ★ 只做两件事：按用户记下的 id 顺序重排、把删掉的滤掉。表里没有的候选
/// （新加的来源、新加的搜索根）**排在末尾并保持自然相对顺序** —— 于是加一台
/// NAS 之后它照样出现在面板里，不需要迁移，也不会把用户的旧顺序打乱。
/// 「打开设置」永远收尾：它是兜底动作，位置由编号规则（0）决定，不该被拖动，
/// 也不该被删掉。
public enum SearchCommandArrangement {

    public static func arrange(_ items: [SearchCommandItem],
                               order: [String],
                               hidden: Set<String> = []) -> [SearchCommandItem] {
        // 打开设置不参与隐藏：哪怕偏好被人手改成把它也删了，兜底入口必须还在。
        let kept = hidden.isEmpty ? items
            : items.filter { $0.id == SearchCommandCatalog.settingsItemID || !hidden.contains($0.id) }
        guard !order.isEmpty else { return kept }
        var rank: [String: Int] = [:]
        for (index, id) in order.enumerated() where rank[id] == nil { rank[id] = index }
        let settings = kept.filter { $0.id == SearchCommandCatalog.settingsItemID }
        let body = kept.filter { $0.id != SearchCommandCatalog.settingsItemID }
        let sorted = body.enumerated().sorted { lhs, rhs in
            let left = rank[lhs.element.id] ?? Int.max
            let right = rank[rhs.element.id] ?? Int.max
            // 同 rank（都没排过）时保持自然顺序：用原始下标兜底，
            // 否则 `sorted` 不保证稳定，面板顺序会随运行次数变。
            return left == right ? lhs.offset < rhs.offset : left < right
        }.map(\.element)
        return sorted + settings
    }
}
