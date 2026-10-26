import Foundation
import FlashFindCore

/// 命令面板（斜杠唤起）的 App 层状态与动作。
///
/// ★ 这里只做「转发」：**判定全在 Core**
/// （`SearchCommandParser` / `SearchCommandCatalog` / `SearchCommandNumbering` /
/// `SearchTokenBar`）。App 层不可单测（它是 executableTarget），所以
/// 「什么算命令模式」「面板里该列哪些候选」「编号是多少」「删除键删哪个」
/// 都不许写在这里。
extension AppModel {

    // MARK: - 判定

    /// 当前是否命令模式、是哪一种面板、筛选词与关键词分别是什么。
    var commandMode: SearchCommandMode { SearchCommandParser.parse(query) }

    /// 命令模式是否激活（面板该显示了）。
    var isCommandModeActive: Bool {
        if case .command = commandMode { return true }
        return false
    }

    /// 面板的种类（非命令模式为 nil）。
    var commandKind: SearchCommandKind? { commandMode.kind }

    /// 命令面板的候选来源（只用得到位置面板）。
    ///
    /// 数据源是**已授权的搜索根**（用户自己勾选过的那些），不是设备上
    /// 全部可见的目录 —— 面板里的每一条都必须能立刻执行。
    ///
    /// ★ **不按「已连接」过滤**（2026-10-26 报障）：App 重启后不会自动连 NAS，
    /// 按 `ready` 过滤会让用户配好的 NAS 在面板里集体消失，只剩「全部位置 / 此 Mac」。
    /// 未连上的来源照样列出来，选中时由 `applySearchTarget` 先连再搜。
    /// ★ 字典键用 `config.id`（`nativeProviders` 就是这么建的），不是 `sourceID`：
    /// `sourceID` 是过滤非法字符后的**协议标识**，两者只有在 id 本身合法时才相等。
    var commandSources: [SearchCommandCatalog.SourceEntry] {
        nasSources.filter(\.enabled).map { config in
            SearchCommandCatalog.SourceEntry(
                sourceID: config.sourceID,
                displayName: config.displayName,
                roots: config.scopes,
                ready: nativeProviders[config.id]?.ready == true)
        }
    }

    /// 某个协议 sourceID 对应的来源此刻是否已就绪。
    ///
    /// 位置候选里带的是 `sourceID`（要下发给核心），而 Provider 字典按 `id` 建 ——
    /// 这一层换算只能有一处，否则又是「两个键各写各的」。
    func isSourceReady(_ sourceID: String) -> Bool {
        guard let config = nasSources.first(where: { $0.sourceID == sourceID }) else { return false }
        return nativeProviders[config.id]?.ready == true
    }

    /// 命令面板的全部候选（未过滤）。
    var commandItems: [SearchCommandItem] {
        guard let kind = commandKind else { return [] }
        return SearchCommandCatalog.items(kind: kind,
                                          sources: commandSources,
                                          includeLocal: localEnabled)
    }

    /// 按当前筛选词过滤后的候选。
    var filteredCommandItems: [SearchCommandItem] {
        SearchCommandCatalog.filter(commandItems, by: commandMode.filter)
    }

    /// 当前选中的候选（默认第一条 —— 回车就是它）。
    var selectedCommandItem: SearchCommandItem? {
        let items = filteredCommandItems
        guard !items.isEmpty else { return nil }
        return items[min(max(0, commandSelection), items.count - 1)]
    }

    /// 面板最多显示多少条候选。
    ///
    /// ★ 类型面板必须能显示满十条：它的九条类型 + 打开设置**全都有数字**，
    /// 只画出前六条的话，按 7/8/9/0 选中的是列表外的项。
    /// 位置面板保持六条 —— 位置可能有很多个，超出就该继续打字筛。
    var commandMaximumVisible: Int {
        commandKind == .fileType ? 10 : 6
    }

    /// 每条候选在面板上显示的数字编号（没有则 nil）。
    var commandNumbers: [Int?] {
        let items = filteredCommandItems
        return items.indices.map { SearchCommandNumbering.key(for: $0, in: items) }
    }

    // MARK: - 前置限定

    /// 搜索框最前面那排限定（带槽位——点哪一枚就删哪一枚）。
    var searchTokens: [SearchTokenBar.Token] { tokenBar.tokens }

    /// 当前位置限定的名字（不限定时为 nil）。
    var locationLabel: String? { SearchTargetLabel.label(for: tokenBar.location) }

    /// 有没有已选定的限定（决定删除键归谁）。
    var hasSearchToken: Bool { !tokenBar.isEmpty }

    /// 输入框里除限定外还有没有关键词。
    var keywordIsEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 动作

    /// 移动命令面板的候选选择。
    func moveCommandSelection(_ delta: Int) {
        let count = filteredCommandItems.count
        guard count > 0 else { commandSelection = 0; return }
        let next = commandSelection + delta
        // 上下环绕：列表比屏幕高时，停在两端会让人以为面板卡住了。
        commandSelection = ((next % count) + count) % count
    }

    /// 退出命令模式：把斜杠前缀与筛选词去掉，回到普通搜索。
    func cancelCommandMode() {
        if case .command = commandMode {
            query = ""
        }
        commandSelection = 0
    }

    /// 执行当前选中的命令。
    ///
    /// - `.search(target)`：设好位置限定，把关键词留给用户继续输入。
    /// - `.filterFileType(type)`：设好类型限定，同上。
    /// - `.openSettings`：打开设置，命令模式结束。
    ///
    /// ★ 前两种**不**保留斜杠文本：用户选的是「在哪儿搜 / 搜什么格式」，
    /// 那个词已经变成前面那枚蓝色小字了，再留在输入框里只会又被搜一遍。
    func executeSelectedCommand() {
        guard let item = selectedCommandItem else { return }
        commandSelection = 0
        switch item.action {
        case .search(let target):
            applySearchTarget(target)
        case .filterFileType(let type):
            applyFileType(type)
        case .openSettings:
            cancelCommandMode()
            NotificationCenter.default.post(name: .openFlashFindSettings, object: nil)
        }
    }

    /// ★ 数字键直接选中对应候选。
    ///
    /// 手指就在数字键上，面板把编号写在脸上了 —— 没有理由要求用户
    /// 先用方向键挪过去再回车。
    func pickCommand(_ number: Int) {
        guard let index = SearchCommandNumbering.index(forKey: number, in: filteredCommandItems)
        else { return }
        commandSelection = index
        executeSelectedCommand()
    }

    /// 应用位置限定。
    ///
    /// 关键词部分（`\照片 报告` 里的「报告」）保留在输入框里，
    /// 用户接着补字即可；筛选词（位置名）随命令一起丢掉。
    func applySearchTarget(_ target: SearchTarget) {
        let keyword: String
        if case .command(_, _, let k) = commandMode { keyword = k } else { keyword = "" }
        tokenBar.setLocation(target)
        query = keyword
        commandSelection = 0
        // 位置变了 ⇒ 立刻重搜一次：用户已经明确说了「在哪儿搜」，
        // 等他再敲一个字才搜是白等。
        changedQuery()
        // ★ 选中的来源此刻没连上 ⇒ **当场连**，别让用户自己去设置页点登录。
        //
        // 位置面板不再按「已连接」过滤候选（否则重启后一台 NAS 都看不见），
        // 所以「选了但没连」是常态而不是异常：这一下点击本身就是「我要在这台上搜」
        // 的明确意图，接上去是这一条候选的份内事。
        if let sourceID = target.sourceID, !isSourceReady(sourceID) {
            connectSourceForSearch(sourceID)
        }
    }

    /// 为一个还没连上的位置来源发起连接，并在搜索面板上留一句状态。
    ///
    /// ★ 走用户主动的路径（`interactiveOTP: true`）：设备要动态码就**当场**弹框。
    /// 这条与 2026-10-26 的 OTP 报障同源 —— 把「要码」推给用户下一次点击
    /// 等于让他重走一遍刚走完的路。
    /// ★ 连上之后由 `quietConnectSteps` 成功路径里的 `changedQuery()` 自动重搜。
    private func connectSourceForSearch(_ sourceID: String) {
        guard let config = nasSources.first(where: { $0.sourceID == sourceID }),
              config.enabled else { return }
        if reconnectUsingStoredCredential(config.id, interactiveOTP: true) {
            searchWarnings.append("正在连接 \(config.displayName)…")
        } else {
            // 没存密码 / 钥匙串里读不到：连接不会自己起来，必须说清为什么。
            // 不写这句的话，界面表现就是「选了位置，列表空着，什么都不说」。
            searchWarnings.append("\(config.displayName) 未连接，请先在设置里登录")
        }
    }

    /// 应用类型限定（与位置限定可叠加）。
    func applyFileType(_ type: SearchFileTypeCatalog.FileType) {
        let keyword: String
        if case .command(_, _, let k) = commandMode { keyword = k } else { keyword = "" }
        tokenBar.setFileType(type)
        query = keyword
        commandSelection = 0
        changedQuery()
    }

    /// ★ 删除键：删掉最前面那排限定里的一个。
    ///
    /// 删哪个由 Core 的 `SearchTokenBar` 判定（关键词还在时就归文本编辑）。
    func deleteSearchToken() {
        guard let slot = tokenBar.slotToRemoveOnBackspace(keywordEmpty: keywordIsEmpty) else { return }
        deleteSearchToken(slot)
    }

    /// ★ 点某一枚限定：删的就是**被点的那一枚**。
    ///
    /// 与删除键是两条不同的规则，不能共用：
    ///   · 删除键归「撤销最近一步」——还受「关键词为空」这个前提约束
    ///     （输入框里有字时，删除键必须留给文本编辑，否则字删不动）；
    ///   · 点标签是**直接指着它**说「去掉这个」——没有歧义，也不该被
    ///     「输入框里还有字」挡住（1.1.16 里点了没反应就是共用了一条规则）。
    func deleteSearchToken(_ slot: SearchTokenBar.Slot) {
        tokenBar.clear(slot)
        commandSelection = 0
        changedQuery()
    }
}
