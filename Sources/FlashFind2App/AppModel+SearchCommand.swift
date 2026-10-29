import Foundation
import FlashFindCore

/// 位置 / 文件类型这两组「限定」在 App 层的入口。
///
/// ★ 2026-10-28：用户把「输入命令」整套取消了（`\` / `/` 不再唤起面板，
///   `SearchCommandMode` / `SearchCommandParser` 与命令面板视图一并删除）。
///   这个文件因此只剩**没有命令 UI 也照样要用的那一半**：
///   - 侧边栏的候选与顺序；
///   - 位置 / 类型的限定动作（类型条与侧边栏都走这里）；
///   - 删除键撤回最近一个限定。
///
/// ★ 2026-10-28 再减一次：设置页那一行「搜索工具 ▸ 命令快捷键」（位置顺序）也删了——
///   用户原话「没有用了」。至此 `quickPick` 只剩**读**：
///   `commandItems(for:)` 仍按用户以前排过的顺序与删掉的项来排侧边栏，
///   但已经没有任何界面能改它（所以 `applyQuickPick` 也一并删掉）。
///
/// 判定仍然全在 Core（`SearchCommandCatalog` / `SearchSidebar` / `SearchQuickPickSettings` /
/// `SearchTokenBar`），App 层只转发——它是 executableTarget，不可单测。
extension AppModel {

    // MARK: - 候选

    /// 位置面板的候选来源（只用得到位置面板）。
    ///
    /// 数据源是**已授权的搜索根**（用户自己勾选过的那些），不是设备上
    /// 全部可见的目录 —— 侧边栏里的每一条都必须能立刻执行。
    ///
    /// ★ **不按「已连接」过滤**（2026-10-26 报障）：App 重启后不会自动连 NAS，
    /// 按 `ready` 过滤会让用户配好的 NAS 在侧边栏里集体消失，只剩「全部位置 / 此 Mac」。
    /// 未连上的来源照样列出来，选中时由 `applySearchTarget` 先连再搜。
    /// ★ 字典键用 `config.id`（`nativeProviders` 就是这么建的），不是 `sourceID`：
    /// `sourceID` 是过滤非法字符后的**协议标识**，两者只有在 id 本身合法时才相等。
    var commandSources: [SearchCommandCatalog.SourceEntry] {
        nasSources.filter(\.enabled).map { config in
            SearchCommandCatalog.SourceEntry(
                sourceID: config.sourceID,
                displayName: config.displayName,
                roots: config.scopes,
                // 仅预览 demo：来源按已就绪画，别让截图里出现「有它的结果却说未连接」。
                ready: AppEnvironment.demoSourcesActive || nativeProviders[config.id]?.ready == true)
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

    /// 某一种候选（按用户排过的顺序，已滤掉删掉的）。
    ///
    /// ★ 顺序来自 Core：`SearchCommandArrangement.arrange` 只认 id，
    /// 表里没有的候选（新加的来源/搜索根）自然排到末尾，因此这一层
    /// 不需要任何「新增来源要不要插队」的判断。
    func commandItems(for kind: SearchCommandKind) -> [SearchCommandItem] {
        let natural = SearchCommandCatalog.items(kind: kind,
                                                 sources: commandSources,
                                                 includeLocal: localEnabled)
        return SearchCommandArrangement.arrange(natural,
                                                order: quickPick.order(for: kind),
                                                // ★ 删掉的候选必须在这里滤掉，而不是在界面里
                                                //   藏一行：设置页与侧边栏读的是同一个入口，
                                                //   只在一处藏，另一处就会把删掉的又画出来。
                                                hidden: quickPick.hiddenIDs(for: kind))
    }

    /// 当前位置限定的名字（不限定时为 nil）。
    var locationLabel: String? { SearchTargetLabel.label(for: tokenBar.location) }

    /// 有没有已选定的限定（决定删除键归谁）。
    var hasSearchToken: Bool { !tokenBar.isEmpty }

    /// 输入框里除限定外还有没有关键词。
    var keywordIsEmpty: Bool { query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    // MARK: - 动作

    /// 应用位置限定（侧边栏点一下走这里）。
    ///
    /// ★ 输入框**一个字都不动**：2026-10-27 起「限定位置」有两个可见入口
    ///   （侧边栏、设置里的位置顺序），都不是在输入框里敲前缀，
    ///   所以这里没有任何「把命令前缀抹掉」的事可做——早先那句
    ///   `query = keyword` 在非命令模式下会把用户的字清空，是一条真实报障。
    func applySearchTarget(_ target: SearchTarget) {
        tokenBar.setLocation(target)
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
    ///
    /// ★ 与 `applySearchTarget` 同一条：**不动输入框**。类型条点一下走这里，
    ///   用户的字必须原样留着。
    func applyFileType(_ type: SearchFileTypeCatalog.FileType) {
        tokenBar.setFileType(type)
        changedQuery()
    }

    // MARK: - 侧边栏与类型条（同一份限定的两种手势）

    /// 侧边栏的行。
    ///
    /// ★ 直接吃 `commandItems(for: .location)`：与 `\` 面板**同一份**候选，
    /// 连用户在设置里排过的顺序、删掉的候选都是同一套。两处各列一遍，
    /// 迟早会有一边少了某个搜索根。
    var sidebarEntries: [SearchSidebar.Entry] {
        SearchSidebar.entries(from: commandItems(for: .location))
    }

    /// 当前位置限定在侧边栏里高亮哪一行（找不到为 nil —— 不假装选中「全部」）。
    var sidebarSelectionID: String? {
        SearchSidebar.selectedID(for: tokenBar.location, in: sidebarEntries)
    }

    /// 当前**限定**位置的显示名（没限定就是 nil）。
    ///
    /// ★ 必须用 `limitedLocationTitle`：`.unrestricted` 时侧边栏高亮的那一行叫
    /// 「全部位置」，但那是「不限定」的名字。拿它当位置名，空结果提示会写成
    /// 「“全部位置”里没有匹配的文件……或换回“全部”」（截图里真出现过）。
    var limitedLocationTitle: String? {
        SearchSidebar.limitedLocationTitle(for: tokenBar.location, in: sidebarEntries)
    }

    /// 点侧边栏第 `index` 行。
    ///
    /// ★ 点已经在用的那一行**什么都不做**：`applySearchTarget` 会重搜一次，
    /// 而用户只是点了一下当前位置，重搜只会让列表白闪一下。
    func selectSidebarEntry(at index: Int) {
        let entries = sidebarEntries
        guard entries.indices.contains(index) else { return }
        guard entries[index].id != sidebarSelectionID else { return }
        applySearchTarget(entries[index].target)
    }

    /// 类型条当前选中的段。
    var typeBarSelectionID: String { SearchTypeBar.selectedID(for: tokenBar.fileType) }

    /// 点类型条某一段（「全部」= 清掉类型限定）。
    ///
    /// ★ 「选中的那段是哪一段」与「这一段对应什么限定」两件换算都在 Core
    /// （`SearchTypeBar`），这里只做分流——视图里不许出现 `if id == "type:all"`。
    func selectTypeBarSegment(_ id: String) {
        guard id != typeBarSelectionID else { return }
        if let type = SearchTypeBar.fileType(for: id) {
            applyFileType(type)
        } else {
            clearFileType()
        }
    }

    /// 清掉类型限定，回到「全部」。
    func clearFileType() {
        guard tokenBar.hasFileType else { return }
        tokenBar.clear(.fileType)
        changedQuery()
    }

    /// ★ 删除键：撤回最近设的那个限定。
    ///
    /// 删哪个由 Core 的 `SearchTokenBar` 判定（关键词还在时就归文本编辑）。
    ///
    /// ★ 2026-10-27 输入行里那排蓝色标签删掉之后，这是**唯一**还能「一键撤限定」
    ///   的入口：位置与类型各自有可见入口（侧边栏 / 类型条），但都需要点两下
    ///   （挪到「全部位置」/「全部」）。所以键盘这一条**留着**——
    ///   它撤的是真的限定，效果马上能从侧边栏高亮与结果看出来。
    ///   ★ 判定仍在 Core：`keywordEmpty` 不成立时删除键不抢，字才删得动。
    func deleteSearchToken() {
        guard let slot = tokenBar.slotToRemoveOnBackspace(keywordEmpty: keywordIsEmpty) else { return }
        tokenBar.clear(slot)
        changedQuery()
    }
}
