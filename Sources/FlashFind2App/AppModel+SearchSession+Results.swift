import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「搜索会话与结果写入」分区。
//
// 2026-10-28 清理：本文件原名 `AppModel+NASConnections.swift`，还装着整套
// 「自研索引服务连接生命周期」（登录 / 同步快照 / 轮询 / 证书信任 / 离线缓存）。
// 那条产品线已随自研服务端一起废弃，且早已没有任何界面入口——整簇移除，
// 只留下仍然服务当前搜索管线的部分：结果写入（唯一入口）、钉住、上限、
// changedQuery 主流程与预览夹具。文件随之改名，历史见当日工作日志。
// ─────────────────────────────────────────────────────────────────────────────

extension AppModel {
    // MARK: - 结果写入（唯一入口）

    /// **唯一**的结果写入点。任何来源的新结果都必须走这里。
    ///
    /// 三件事必须一起做，所以不许在这里拆开写：
    /// 1. 并进窗口（去重 → 重排 → 只留前 200）；
    /// 2. `results` 一次赋值（一次 `objectWillChange`）；
    /// 3. `matchedResultCount` 跟着更新（状态栏写「200 / 1374 项」要它）。
    ///
    /// 绕过它的后果是具体可见的：直接 `results.append(...)` 会让结果突破
    /// 200 条上限，而直接改 `results` 又会让总数停在旧值上——
    /// 两者都不会报错，只是界面开始说假话。
    func integrateResults(_ incoming: [SearchResult]) {
        guard !incoming.isEmpty else { return }
        resultWindow.integrate(incoming)
        results = resultWindow.rows
        matchedResultCount = resultWindow.totalMatched
    }

    /// 候选池里还有没显示的行（「继续搜索」按钮该不该出现）。
    ///
    /// ★ 三个条件缺一不可：这批结果**属于当前限定**（否则按钮会出现在
    ///   一次已经作废的列表下面）、池子里确实还有、且不是夹具。
    var canShowMoreResults: Bool { canUseDisplayedResults && resultWindow.canShowMore }

    /// 「继续搜索」：再放一批（`SearchResultLimit.step`）进列表。
    ///
    /// ★ 只改显示窗口，**不重新搜**：候选早在第一批时就都收下来了，
    ///   再发一次请求既慢又可能拿到不同的集合。
    func showMoreResults() {
        guard resultWindow.showMore() else { return }
        results = resultWindow.rows
    }

    /// 把当前这一批结果做成一份可钉在桌面上的快照。
    ///
    /// 空列表没有钉的意义（钉出来的是一块写着「0 项」的玻璃），返回 nil。
    ///
    /// ★ 2026-10-28 起快照还要带上**此刻的类型与位置限定**：钉住的窗口里那两个
    ///   控件仍然在，而且能改；不带的话窗口一开出来就是「全部 / 全部位置」，
    ///   等于把用户刚做的筛选抹掉（用户原话：「钉住以后保留文件类型和文件位置的筛选」）。
    func currentPinnedResults() -> PinnedResults? {
        guard canUseDisplayedResults, !results.isEmpty else { return nil }
        return PinnedResults(query: query,
                             rows: results,
                             totalMatched: matchedResultCount,
                             locationTitle: limitedLocationTitle,
                             fileType: tokenBar.fileType,
                             location: tokenBar.location)
    }

    /// 点「钉住」：把这一批结果搬到桌面上的独立窗口，搜索框随即空出来。
    ///
    /// ★ 顺序不能反：先取快照再清空。反过来的话 `currentPinnedResults()` 拿到的是
    ///   已经被清掉的空列表，钉出来是一块写着「0 项」的玻璃。
    /// ★ 清空走 `clearSearchSession()`：查询词、结果、选中一起清，
    ///   界面不会出现「输入框空了但下面还挂着上一轮结果」这种自相矛盾的样子。
    /// ★ 最后把键盘交回搜索框：用户是在结果窗里点的图钉，那块窗口马上就要消失，
    ///   不交还的话他接着打字一个字都进不去。
    func pinCurrentResults() {
        guard let snapshot = currentPinnedResults() else { return }
        // 锚点**只能是搜索框那一块**。
        //
        // ★ 2026-10-28 报障「钉住的位置会随机跳一下」，一半原因在这里：
        //   原来回落成 `NSApp.keyWindow?.frame`，而 key window 此刻可能是**结果窗**
        //   （点图钉时焦点在那一块），也可能是**上一块钉住的窗**——同一批结果
        //   从不同的窗口钉出去，落点就不同，看起来就是「随机跳」。
        //   拿不到搜索框时宁可按屏幕居中摆（`present` 里处理 nil），
        //   也不要按一个每次都不一样的东西对齐。
        let anchor = SearchWindowRegistry.shared.fieldFrame
        guard PinnedResultsWindows.shared.present(snapshot, model: self, near: anchor) else { return }
        clearSearchSession()
        NotificationCenter.default.post(name: .focusFlashFindField, object: nil)
    }

    /// 清空结果。**`results = []` 出现的每一处都必须走这里**（窗口的
    /// rows / 总数 / 去重集合三者只能一起清掉，漏一个就会「上一轮的
    /// 匹配数」渗进这一次的界面）。
    func clearResults() {
        resultWindow.reset()
        results = []
        matchedResultCount = 0
    }

    /// 预览 / 夹具专用：直接给一份结果，不参与上限计算、不冒充匹配总数。
    func setFixtureResults(_ rows: [SearchResult]) {
        resultWindow = .fixture(rows)
        results = resultWindow.rows
        matchedResultCount = resultWindow.totalMatched
    }

    func invalidate() {        providerCoordinator?.cancel()
        contextRevision &+= 1; resultsAreCurrent = false; displayedRevision = nil
        searchTask?.cancel(); spotlight?.cancel(); queryID = UUID()
        clearResults(); selected = nil; searching = false
    }
    func changedQuery() {
        // 一开始输入就把首次使用的键位提示收起——它只在「还没动手」时有用。
        dismissSearchHints()
        searchTask?.cancel(); spotlight?.cancel(); let id = UUID(); queryID = id
        resultsAreCurrent = false; displayedRevision = nil; searchFailure = nil; searchWarnings = []
        // 打开失败的提示条讲的是「刚才点的那一条结果」。查询一换（或清空）
        // 那条结果就不在列表里了，留着它会对着空列表继续喊「无法打开文件」。
        openFailure = nil
        let text = query, revision = contextRevision, searchScope = scope
        // ★ 真正发给设备的是「关键词 + 类型词」，不一定是输入框里的原文。
        //
        // 类型限定（`SearchTokenBar`）不走新的过滤机制，而是拼成一个格式词
        // 交给既有的 `SearchQueryParser` —— 用户在框里打「pdf」走的是同一条路，
        // 所以行为一致。只选了类型没打关键词时，就只发类型词（看某类型的全部文件）。
        let searchText = tokenBar.searchText(keyword: query)
        if searchText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { clearResults(); selected = nil; searching = false; return }
        if AppEnvironment.isPreview {
            setFixtureResults(AppEnvironment.fixtures(for: query))
            selected = results.first?.id
            publishCurrent(text, searchScope, revision); searching = false
            if query == "error" { searchFailure = "NAS 暂时不可用，请检查网络连接。" }
            return
        }
        ensureProviderCoordinator();providerCoordinator?.cancel()
        clearResults();selected=nil
        // 本机范围只有一处出处（MCP 执行侧也要套，见 `AppModel+AIAccess`）。
        applyLocalScopeToProvider()
        for provider in nativeProviders.values { provider.queryBudgetMs = max(1, min(120, nativeSearchTimeoutSeconds)) * 1000 }
        // 请求哪些来源完全由当前配置决定：不再写死任何设备标识。
        // ★ 判定搬到 Core 的 `SearchRequestPlan`：这台机器到底有没有请求 NAS，
        // 原来只能在界面上点出来，现在可以直接断言（R01 的验证面）。
        //
        // 应用搜索跟着「本机」作用域走（`includeApps` 与 `includeLocal` 同源），
        // 但**不受「指定文件夹」限制**：那种模式刻意不扫全盘，而应用不在用户的
        // 数据文件夹里，本就不该被那条限制挡住——否则用户设了文件夹就搜不到 app，
        // 而这个功能在他看来是坏的。
        let includeLocalSide = localEnabled && scope != .nas
        // ★ 位置限定（`/` 命令面板选的那个位置）参与请求计划。
        //
        // 三层防护的第一层在这里：根必须在本来源**已授权**的搜索根之内，
        // 不在就不请求那个来源。第二层在 `NASSearchProvider`（与授权根求交集），
        // 第三层在 Dart 核心（与已授权 scope 求交集）。
        let plan = SearchRequestPlan(
            localSourceID: SearchSource.local.id,
            appSourceID: SearchSource.apps.id,
            includeLocal: includeLocalSide,
            includeApps: includeLocalSide,
            includeNAS: enabled && scope != .local,
            nasCandidates: nativeProviders.map { id, provider in
                (sourceID: id,
                 ready: provider.ready,
                 enabled: nasSources.first(where: { $0.id == id })?.enabled == true)
            },
            target: tokenBar.location,
            authorizedRoots: nasSources.reduce(into: [String: [String]]()) { map, config in
                map[config.sourceID] = config.scopes
            })
        let rootLimit = plan.rootLimit
        // ★ 「还在搜吗」的判据搬到 Core 的 `SearchCompletionTracker`。
        // 原来是一行内联的 `!requested.isSubset(of: terminal)`：断开一台正在搜的 NAS
        // 之后，如果那个来源永远不发终态，这条判据就永远为真 —— 结果行都出来了，
        // 状态栏却一直显示「正在搜索」。搬到 Core 之后这条判据才可能被断言。
        //
        // ★ 名字仍是 `requested`：它就是「本次请求了哪些来源」这个集合。
        // （位置限定让它可能只有一两个来源，但判据的形式不变。）
        let requested = plan.sourceIDs
        var completion = SearchCompletionTracker(requested: requested)
        searchTask=Task {
            // 本机立即出结果；NAS 走 Coordinator 的 600ms 防抖，
            // 避免用户输入过程中产生多次无谓的远端请求。
            // 依据： 间隔对照实验，四档间隔均为 100%，
            // debounce 不是为规避设备退化，而是节流请求数。
            guard queryID==id,contextRevision==revision else { return }
            searching = !requested.isEmpty
            // ★ queryID 由这里生成并一路传到底（P1-01）：
            // 不传的话 Coordinator 会另造一个，于是界面与协调层各持一个 ID，
            // 取消、旧结果迟到、并发返回时根本对不上谁是谁。
            //
            // ★ `rootLimit` 一路带到底：它会让**设备侧**只扫那一个根，
            // 所以「减少检索时间」是真的，不是界面层过滤。
            providerCoordinator?.searchDebounced(searchText,sources:requested,rootLimit:rootLimit,queryID:id) { [weak self] event in
                guard let self,self.queryID==id,self.contextRevision==revision else { return }
                self.recordProviderEvent(event)
                // ★ 合并与排序搬到 Core 的 `SearchResultMerge`：顺序、去重、
                //   「什么时候才需要重排」这三条判据都收在那边。
                //   这里只做一次赋值 —— 一整批发一次 `objectWillChange`，
                //   逐条 append 是每行发一次（结果上千条时界面就开始发涩）。
                //
                // ★ 上限 200 与「总共匹配了多少」也在 Core 的 `SearchResultWindow`：
                //   它同时管 rows / totalMatched / 去重集合，三者只能一起清空。
                if !event.results.isEmpty {
                    integrateResults(event.results)
                }
                if !self.results.contains(where:{$0.id==self.selected}) { self.selected=self.results.first?.id }
                completion.note(event)
                if let message=event.message,!self.searchWarnings.contains(message) { self.searchWarnings.append(message) }
                self.searching = completion.isSearching
                // A source error never hides successful results from another source.
                self.searchFailure=nil
                self.publishCurrent(text,searchScope,revision)
            }
        }
    }
    func publishCurrent(_ text: String, _ searchScope: SearchScope, _ revision: UInt64) {
        displayedQuery = text; displayedScope = searchScope; displayedRevision = revision
        displayedTokenBar = tokenBar; resultsAreCurrent = true
    }
    func moveResultSelection(_ delta: Int) {
        guard canUseDisplayedResults, !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == selected }) ?? (delta > 0 ? -1 : results.count)
        selected = results[max(0, min(results.count - 1, current + delta))].id
    }
    /// 连上 NAS 之后把总开关打开（R01）。
    ///
    /// 只在这种前提下动手：总开关当前是关的，**且**用户从来没有显式设置过它。
    /// 用户主动关掉的场景（例如只想搜本机）必须原样保留，不能反过来替他打开。
    func ensureNASSearchEnabled() {
        guard !enabled, !masterSwitchIsExplicit, (!AppEnvironment.isPreview || fixtureMode) else { return }
        enabled = true
        masterSwitchIsExplicit = true
        preferences.set(true, forKey: NASMasterSwitch.storageKey)
        invalidate()
        changedQuery()
    }

    func toggleNetwork() {
        guard !AppEnvironment.isPreview || fixtureMode else { return }
        // 用户动过开关，从这一刻起它就是显式的，不再允许自动改写。
        masterSwitchIsExplicit = true
        preferences.set(enabled, forKey: NASMasterSwitch.storageKey)
        if enabled && !hasSelectedNASSource { status = nasSearchAvailabilityMessage }
        invalidate(); changedQuery()
    }
}
