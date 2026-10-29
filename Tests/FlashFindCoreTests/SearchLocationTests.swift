import XCTest
@testable import FlashFindCore

/// 搜索位置限定：只在一个位置里搜，并且**真的**少扫设备侧。
///
/// ★ 这些断言守的是两件事，缺一不可：
/// 1. 限定位置后只请求那一个来源、那一个根（少扫 = 少检索时间）；
/// 2. 限定位置**不能**绕过总开关与授权范围（少扫不等于能越权）。
final class SearchLocationTests: XCTestCase {

    private let local = "local_mac"
    private let apps = "local_apps"
    private let nasA = "nas-A"
    private let nasB = "nas-B"

    private func plan(target: SearchTarget,
                      includeLocal: Bool = false,
                      includeNAS: Bool = true,
                      includeApps: Bool = false,
                      candidates: [(String, Bool, Bool)]? = nil,
                      authorized: [String: [String]]? = nil)
        -> (ids: Set<String>, limit: SearchRootLimit?) {
        let result = SearchRequestPlan(
            localSourceID: local,
            appSourceID: apps,
            includeLocal: includeLocal,
            includeApps: includeApps,
            includeNAS: includeNAS,
            nasCandidates: (candidates ?? [(nasA, true, true), (nasB, true, true)])
                .map { (sourceID: $0.0, ready: $0.1, enabled: $0.2) },
            target: target,
            authorizedRoots: authorized ?? [nasA: ["/照片", "/文档"], nasB: ["/备份"]])
        return (result.sourceIDs, result.rootLimit)
    }

    // MARK: - 不限定位置

    /// 不限定位置 ⇒ 行为与从前完全一致（不产生任何 rootLimit）。
    func testUnrestrictedKeepsOriginalBehaviour() {
        let result = plan(target: .unrestricted, includeLocal: true)
        XCTAssertEqual(result.ids, [local, nasA, nasB])
        XCTAssertNil(result.limit, "不限定位置时不该产生根限定")
    }

    // MARK: - 限定到本机

    /// 限定到本机 ⇒ NAS 一概不请求。
    func testLocalTargetSkipsNAS() {
        let result = plan(target: .local, includeLocal: true)
        XCTAssertEqual(result.ids, [local])
        XCTAssertFalse(result.ids.contains(nasA))
        XCTAssertFalse(result.ids.contains(nasB))
    }

    /// 限定到本机时应用照旧跟着本机走 —— 少扫的是 NAS，不是本机这一侧。
    func testLocalTargetStillIncludesApps() {
        let result = plan(target: .local, includeLocal: true, includeApps: true)
        XCTAssertEqual(result.ids, [local, apps])
    }

    /// 本机开关关掉 ⇒ 限定到本机也搜不到东西（位置限定不能绕过开关）。
    func testLocalTargetRespectsLocalSwitch() {
        let result = plan(target: .local, includeLocal: false)
        XCTAssertTrue(result.ids.isEmpty)
    }

    // MARK: - 限定到某个来源的某个根

    /// ★ 核心断言：限定到某来源的一个根 ⇒ 只请求那一个来源，且根集合只剩那一个。
    ///
    /// 这是「减少检索时间」的全部依据。少了 `roots == ["/照片"]` 这一半，
    /// 界面看起来限制了位置，设备侧却仍在扫全部共享 —— 检索时间一点没降。
    func testSourceRootTargetRequestsOnlyThatSourceAndRoot() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"))
        XCTAssertEqual(result.ids, [nasA])
        XCTAssertFalse(result.ids.contains(nasB))
        XCTAssertEqual(result.limit?.sourceID, nasA)
        XCTAssertEqual(result.limit?.roots, ["/照片"], "根集合必须只剩选中的那一个")
    }

    /// 位置限定不能绕过 NAS 总开关。
    func testSourceRootTargetRespectsMasterSwitch() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"), includeNAS: false)
        XCTAssertTrue(result.ids.isEmpty)
        XCTAssertNil(result.limit)
    }

    /// 位置限定不能绕过逐来源开关。
    func testSourceRootTargetRespectsPerSourceSwitch() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"),
                          candidates: [(nasA, true, false), (nasB, true, true)])
        XCTAssertTrue(result.ids.isEmpty, "被关掉的来源不能因为位置限定而复活")
    }

    /// 未就绪（没登录）的来源同样不请求。
    func testSourceRootTargetRespectsReadiness() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"),
                          candidates: [(nasA, false, true)])
        XCTAssertTrue(result.ids.isEmpty)
    }

    /// ★ 没授权过的根 ⇒ 不请求。宁可搜不到，也不能搜一个没授权的目录。
    func testUnAuthorizedRootIsRejected() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/别人的秘密"))
        XCTAssertTrue(result.ids.isEmpty)
        XCTAssertNil(result.limit)
    }

    /// 授权范围为空（来源压根没选过搜索位置）⇒ 不请求。
    func testSourceWithoutAuthorizedRootsIsRejected() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"),
                          authorized: [:])
        XCTAssertTrue(result.ids.isEmpty)
    }

    /// 限定位置时本机一概不参与（用户明确说了「在哪儿搜」）。
    func testSourceRootTargetSkipsLocal() {
        let result = plan(target: .sourceRoot(sourceID: nasA, root: "/照片"), includeLocal: true)
        XCTAssertEqual(result.ids, [nasA])
        XCTAssertFalse(result.ids.contains(local))
    }
}

// MARK: - 候选列表与筛选

/// 命令目录：候选列表长什么样、怎么筛。
final class SearchCommandCatalogTests: XCTestCase {

    private func source(id: String,
                        name: String,
                        roots: [String],
                        ready: Bool = true) -> SearchCommandCatalog.SourceEntry {
        SearchCommandCatalog.SourceEntry(sourceID: id, displayName: name, roots: roots, ready: ready)
    }

    private func locationItems(sources: [SearchCommandCatalog.SourceEntry],
                               includeLocal: Bool = true,
                               includeSettings: Bool = true) -> [SearchCommandItem] {
        SearchCommandCatalog.items(kind: .location, sources: sources,
                                   includeLocal: includeLocal, includeSettings: includeSettings)
    }

    /// ★ 位置面板顺序：全部位置 → 此 Mac → 各来源的各根 → 打开设置。
    func testLocationItemsOrder() {
        let items = locationItems(sources: [source(id: "nas-A", name: "群晖 NAS", roots: ["/照片", "/文档"])])
        XCTAssertEqual(items.map(\.id), [
            SearchCommandCatalog.allItemID,
            SearchCommandCatalog.localItemID,
            "target:nas-A:/照片",
            "target:nas-A:/文档",
            SearchCommandCatalog.settingsItemID,
        ])
    }

    /// ★ 未连接的来源**仍要列出来**，副标题标「未连接」。
    ///
    /// 2026-10-26 真实报障：「位置没有生效，只能检测到本机的」——
    /// 面板里只剩「全部位置 / 此 Mac」。根因是本文件原来那条
    /// `for source in sources where source.ready`：App 重启后**不会自动连 NAS**
    /// （刻意设计，避免开机就去动钥匙串），于是刚开机时用户配好的来源集体消失。
    ///
    /// 判据：位置是「用户配过的地方」，不是「此刻在线的机器」。
    /// 配过就该能选；选中后由 App 层先连再搜（`applySearchTarget`）。
    func testOfflineSourceIsStillListedWithAStatusSubtitle() {
        let items = locationItems(sources: [source(id: "nas-A", name: "群晖 NAS",
                                                   roots: ["/照片"], ready: false)],
                                  includeLocal: false)
        let root = items.first { $0.id == "target:nas-A:/照片" }
        XCTAssertNotNil(root, "未连接的来源也必须出现在位置面板里")
        XCTAssertEqual(root?.subtitle, "群晖 NAS · 未连接")
        // 位置限定照旧下发：连上之后就是靠它把设备侧搜索压到这一个根。
        XCTAssertEqual(root?.action, .search(.sourceRoot(sourceID: "nas-A", root: "/照片")))
    }

    /// ★ 已连接的来源不带「未连接」字样，副标题就是来源名。
    ///
    /// 与上一条成对：只断言「能列出来」的话，把副标题写成常量
    /// 「未连接」也能骗过测试 —— 那样用户会以为连上的那台也没连。
    func testOnlineSourceSubtitleCarriesNoStatusSuffix() {
        let items = locationItems(sources: [source(id: "nas-A", name: "群晖 NAS",
                                                   roots: ["/照片"], ready: true)],
                                  includeLocal: false, includeSettings: false)
        XCTAssertEqual(items.first { $0.id == "target:nas-A:/照片" }?.subtitle, "群晖 NAS")
    }

    /// 「全部位置」永远在：位置限定生效后必须有办法退回去。
    func testAllItemAlwaysPresent() {
        let items = locationItems(sources: [], includeLocal: false, includeSettings: false)
        XCTAssertEqual(items.map(\.id), [SearchCommandCatalog.allItemID])
    }

    /// 候选的标题取根的最后一段，副标题是来源名。
    func testItemTitleAndSubtitle() {
        let items = locationItems(sources: [source(id: "nas-A", name: "群晖 NAS", roots: ["/照片"])],
                                  includeLocal: false, includeSettings: false)
        let root = items.first { $0.id == "target:nas-A:/照片" }
        XCTAssertEqual(root?.title, "照片")
        XCTAssertEqual(root?.subtitle, "群晖 NAS")
        XCTAssertEqual(root?.action, .search(.sourceRoot(sourceID: "nas-A", root: "/照片")))
    }

    /// ★ 类型面板：九条类型 + 打开设置收尾。
    func testFileTypeItems() {
        let items = SearchCommandCatalog.items(kind: .fileType, sources: [], includeLocal: true)
        XCTAssertEqual(items.count, 10, "九条类型 + 打开设置")
        XCTAssertEqual(items.map(\.title),
                       ["pdf", "word", "excel", "ppt", "照片", "视频", "音乐", "压缩包", "文档", "打开设置…"])
        XCTAssertEqual(items.last?.id, SearchCommandCatalog.settingsItemID)
    }

    /// ★ 一个来源里勾了多个文件夹 ⇒ **每一条**都要进候选。
    ///
    /// 2026-10-26 真实报障：「路径下 openlist 选中好几个文件夹的搜索位置时，
    /// 只显示第一个的文件夹」。配置里 `scopes` 明明是 `/A0001…/A0004` 四条，
    /// 面板里只有 A0001 —— 界面按行数上限裁掉了其余三条
    /// （见 `SearchCommandCatalog.maximumVisibleRows`）。
    ///
    /// 这条守的是「Core 把每一条都交出来」，裁切在界面层，不许再回来。
    func testEveryRootOfOneSourceIsListed() {
        let items = locationItems(sources: [source(id: "ol", name: "openlist",
                                                   roots: ["/A0001", "/A0002", "/A0003", "/A0004"])])
        let roots = items.filter {
            if case .search(.sourceRoot) = $0.action { return true }
            return false
        }
        XCTAssertEqual(roots.map(\.title), ["A0001", "A0002", "A0003", "A0004"],
                       "同一个来源的四个搜索根必须全在候选里，不能只留第一个")
        XCTAssertEqual(roots.map(\.subtitle), Array(repeating: "openlist", count: 4))
    }

    /// ★ 面板画得下的行数 = 数字键 1–9 加「打开设置」这一条 0，共十条。
    ///
    /// 「能按到哪」与「能看见哪」必须是同一个数：上限比带编号的候选少，
    /// 按下去的数字就指向屏幕外（用户按 7 选中了 A0002，面板上却什么都没变）。
    /// 这条在 Core 里锁死，App 层只能引用，不许另写一个数。
    func testVisibleRowsCoverEveryNumberedCandidate() {
        XCTAssertGreaterThanOrEqual(SearchCommandCatalog.maximumVisibleRows,
                                    SearchCommandNumbering.numberedLimit + 1,
                                    "行数上限至少覆盖 1–9 与 0")
        // 两条基础项 + 七个搜索根 = 九条带编号的候选，再加「打开设置」正好十条。
        let items = locationItems(sources: [
            source(id: "ol", name: "openlist", roots: ["/A0001", "/A0002", "/A0003", "/A0004"]),
            source(id: "syn", name: "群晖", roots: ["/照片", "/文档", "/备份"]),
        ])
        XCTAssertEqual(items.count, SearchCommandCatalog.maximumVisibleRows)
        var keys: [Int?] = []
        for index in items.indices { keys.append(SearchCommandNumbering.key(for: index, in: items)) }
        XCTAssertEqual(keys, [1, 2, 3, 4, 5, 6, 7, 8, 9, 0],
                       "前九条按顺序 1–9，「打开设置」固定 0")
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 0, in: items), items.count - 1)
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 9, in: items),
                       items.count - 2, "数字 9 是第九个带编号的候选（这里正是第三个搜索根「备份」）")
    }

    /// 候选多到画不下时，编号规则照样成立 —— 界面负责滚动，不负责删。
    func testNumberingStaysCorrectBeyondOneScreen() {
        let items = locationItems(sources: [
            source(id: "ol", name: "openlist",
                   roots: ["/A0001", "/A0002", "/A0003", "/A0004", "/A0005"]),
            source(id: "syn", name: "群晖", roots: ["/照片", "/文档", "/备份", "/归档"]),
        ])
        XCTAssertGreaterThan(items.count, SearchCommandCatalog.maximumVisibleRows,
                             "这个用例的前提就是候选超过一屏")
        XCTAssertEqual(SearchCommandNumbering.key(for: items.count - 1, in: items), 0,
                       "「打开设置」无论排第几都是 0")
        XCTAssertNil(SearchCommandNumbering.key(for: SearchCommandCatalog.maximumVisibleRows - 1, in: items),
                     "第十条带编号的候选之后不再给数字（只能滚动或用方向键）")
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 0, in: items), items.count - 1,
                       "0 必须仍能选中排在最末尾的「打开设置」")
    }

    /// ★ 类型面板的每一条都带一个**词汇表认得**的格式词。
    ///
    /// 少了这条，「word」这种显示名会被当成关键词 —— 面板显示选上了，
    /// 搜索却完全没有格式限制（格式词表里只有 `doc`）。
    func testEveryFileTypeCarriesAFormatWordTheVocabularyKnows() {
        for type in SearchFileTypeCatalog.all {
            guard let extensions = FileFormatVocabulary.extensions(for: type.formatWord) else {
                return XCTFail("「\(type.title)」的格式词 \(type.formatWord) 不在词汇表里")
            }
            XCTAssertFalse(extensions.isEmpty, "\(type.title) 解析不出任何扩展名")
        }
    }

    /// ★ 两个面板都以「打开设置」收尾（用户明确要求）。
    func testBothPalettesEndWithSettings() {
        let location = locationItems(sources: [source(id: "nas-A", name: "NAS", roots: ["/照片"])])
        let fileType = SearchCommandCatalog.items(kind: .fileType, sources: [], includeLocal: true)
        XCTAssertEqual(location.last?.action, .openSettings)
        XCTAssertEqual(fileType.last?.action, .openSettings)
    }

    /// 「打开设置」是候选之一，动作是打开设置。
    func testSettingsItemAction() {
        let items = locationItems(sources: [])
        let settings = items.first { $0.id == SearchCommandCatalog.settingsItemID }
        XCTAssertEqual(settings?.action, .openSettings)
    }

    /// 空筛选词 ⇒ 原样返回全部候选（输入斜杠就该看到全部）。
    func testEmptyFilterReturnsAll() {
        let items = locationItems(sources: [source(id: "nas-A", name: "群晖 NAS", roots: ["/照片"])])
        XCTAssertEqual(SearchCommandCatalog.filter(items, by: "").count, items.count)
        XCTAssertEqual(SearchCommandCatalog.filter(items, by: "   ").count, items.count)
    }

    /// 筛选匹配标题或副标题，**不区分大小写**。
    func testFilterMatchesTitleOrSubtitleIgnoringCase() {
        let items = locationItems(sources: [source(id: "nas-A", name: "Synology NAS", roots: ["/Photos"])],
                                  includeLocal: false)
        XCTAssertEqual(SearchCommandCatalog.filter(items, by: "photo").map(\.id), ["target:nas-A:/Photos"])
        XCTAssertEqual(SearchCommandCatalog.filter(items, by: "synology").map(\.id), ["target:nas-A:/Photos"])
    }

    /// 没有匹配 ⇒ 空列表（界面据此显示「没有匹配的选项」而不是保留旧候选）。
    func testNoMatchReturnsEmpty() {
        let items = locationItems(sources: [])
        XCTAssertTrue(SearchCommandCatalog.filter(items, by: "不存在的名字").isEmpty)
    }

    /// 筛选只做子串匹配，不做模糊匹配。
    ///
    /// ★ 反例要用「子串不成立、但 subsequence 成立」的词：
    /// 「照引」是「照片索引」的 subsequence，却不是它的子串。
    func testFilterIsSubstringNotFuzzy() {
        let items = locationItems(sources: [source(id: "nas-A", name: "NAS", roots: ["/照片", "/影片", "/照片索引"])],
                                  includeLocal: false, includeSettings: false)
        XCTAssertEqual(SearchCommandCatalog.filter(items, by: "照片").map(\.id),
                       ["target:nas-A:/照片", "target:nas-A:/照片索引"])
        XCTAssertTrue(SearchCommandCatalog.filter(items, by: "照引").isEmpty,
                      "subsequence 匹配会把「照片索引」也算进来")
    }

    /// 搜索根的显示名取最后一段；取不到就退回整条路径。
    func testRootName() {
        XCTAssertEqual(SearchTargetLabel.rootName("/照片"), "照片")
        XCTAssertEqual(SearchTargetLabel.rootName("照片"), "照片")
        XCTAssertEqual(SearchTargetLabel.rootName("/"), "/")
        XCTAssertEqual(SearchTargetLabel.rootName(""), "")
    }

    /// 飞牛卷根**不许取末段**：`/vol1/1000` 与 `/vol2/1000` 的末段都是 uid。
    ///
    /// 真实截图（2026-10-29）：侧边栏里两行都写「1000」，用户分不出点哪个；
    /// 设置行更直接，写着 `vol1/1000、vol2/1000`。
    func testFnOSVolumeRootsGetDistinctNames() {
        XCTAssertEqual(SearchTargetLabel.rootName("/vol1/1000"), "存储空间 1")
        XCTAssertEqual(SearchTargetLabel.rootName("/vol2/1000"), "存储空间 2")
        XCTAssertEqual(NASScopeLabel.text(for: "/vol1/1000"), "存储空间 1")
        XCTAssertEqual(NASSourceRowModel.scopeDisplayName("/vol2/1000"), "存储空间 2")
        // 不是这个形状的照旧：末段 / 去前导斜杠。
        XCTAssertEqual(NASScopeLabel.text(for: "/vol1/1000/照片"), "vol1/1000/照片")
        XCTAssertEqual(SearchTargetLabel.rootName("/vol1/1000/照片"), "照片")
        XCTAssertEqual(NASScopeLabel.text(for: "/示例共享"), "示例共享")
    }

    /// 位置限定的显示名：不限定时不显示任何东西。
    func testTargetLabel() {
        XCTAssertNil(SearchTargetLabel.label(for: .unrestricted))
        XCTAssertEqual(SearchTargetLabel.label(for: .local), "此 Mac")
        XCTAssertEqual(SearchTargetLabel.label(for: .sourceRoot(sourceID: "nas-A", root: "/照片")), "照片")
    }
}

// MARK: - 数字编号

/// ★ 数字编号规则：1–9 按顺序，**0 固定给「打开设置」**。
final class SearchCommandNumberingTests: XCTestCase {

    private func palette(count: Int) -> [SearchCommandItem] {
        var items: [SearchCommandItem] = (0..<count).map {
            SearchCommandItem(id: "item-\($0)", title: "项\($0)", action: .search(.local))
        }
        items.append(SearchCommandItem(id: SearchCommandCatalog.settingsItemID,
                                        title: "打开设置…", action: .openSettings))
        return items
    }

    /// 九条以内：1…9 按顺序，设置拿 0。
    func testNumberingIsSequentialWithZeroForSettings() {
        let items = palette(count: 4)
        XCTAssertEqual((0..<4).map { SearchCommandNumbering.key(for: $0, in: items) }, [1, 2, 3, 4])
        XCTAssertEqual(SearchCommandNumbering.key(for: 4, in: items), 0, "打开设置固定是 0")
    }

    /// ★ 反查：按 0 一定是打开设置，与它在列表里的位置无关。
    func testZeroAlwaysResolvesToSettings() {
        let items = palette(count: 4)
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 0, in: items), 4)
        XCTAssertEqual(items[SearchCommandNumbering.index(forKey: 0, in: items)!].id,
                       SearchCommandCatalog.settingsItemID)
    }

    /// 数字与下标一一对应（往返一致）。
    func testKeyAndIndexRoundTrip() {
        let items = palette(count: 6)
        for index in items.indices {
            guard let key = SearchCommandNumbering.key(for: index, in: items) else { continue }
            XCTAssertEqual(SearchCommandNumbering.index(forKey: key, in: items), index)
        }
    }

    /// ★ 第十条及以后没有数字：那时该继续打字筛选，不是塞一个要数着按的键。
    func testBeyondNineHasNoNumber() {
        let items = palette(count: 12)
        XCTAssertEqual(SearchCommandNumbering.key(for: 8, in: items), 9)
        XCTAssertNil(SearchCommandNumbering.key(for: 9, in: items), "第十条不该再有数字")
        XCTAssertEqual(SearchCommandNumbering.key(for: 12, in: items), 0, "设置仍然是 0")
        XCTAssertNil(SearchCommandNumbering.index(forKey: 9, in: palette(count: 2)))
    }

    /// 按下没有对应项的数字 ⇒ 什么都不做（不是越界崩溃、也不是退而求其次）。
    func testOutOfRangeKeyResolvesToNil() {
        let items = palette(count: 2)
        XCTAssertNil(SearchCommandNumbering.index(forKey: 7, in: items))
        XCTAssertNil(SearchCommandNumbering.index(forKey: -1, in: items))
    }

    /// ★ 筛选之后编号重排：筛完剩下的第一条就是 1。
    ///
    /// 用户的要求原话：筛完「符合数字键盘选择的要求也可以支持数字选择」。
    /// 若编号还按筛选前的列表算，按 1 会选到一条根本没显示出来的项。
    func testNumberingIsRecomputedAfterFiltering() {
        let items = palette(count: 9)
        let filtered = SearchCommandCatalog.filter(items, by: "项1")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(SearchCommandNumbering.key(for: 0, in: filtered), 1)
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 1, in: filtered), 0)
    }
}

// MARK: - 前置限定（位置 + 类型可叠加）

/// ★ 叠加与删除：两个限定同时在，删除键先删最近设的那个。
final class SearchTokenBarTests: XCTestCase {

    private let pdf = SearchFileTypeCatalog.all[0]
    private let photo = SearchFileTypeCatalog.all[4]

    /// 空条：什么都没限定。
    func testEmptyBar() {
        let bar = SearchTokenBar.empty
        XCTAssertTrue(bar.isEmpty)
        XCTAssertTrue(bar.labels.isEmpty)
        XCTAssertEqual(bar.searchText(keyword: "报告"), "报告")
    }

    /// ★ 位置与类型可叠加，界面上两个名字都在（位置在前）。
    func testLocationAndFileTypeStack() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        bar.setFileType(pdf)
        XCTAssertEqual(bar.labels, ["照片", "pdf"])
        XCTAssertFalse(bar.isEmpty)
    }

    /// ★ 发给搜索的文本 = 关键词 + 类型词（走既有的格式解析）。
    func testSearchTextAppendsFormatWord() {
        var bar = SearchTokenBar.empty
        bar.setFileType(pdf)
        XCTAssertEqual(bar.searchText(keyword: "报告"), "报告 pdf")
    }

    /// 只选了类型、没打关键词 ⇒ 只发类型词（看这一类的全部文件）。
    func testSearchTextWithOnlyFileType() {
        var bar = SearchTokenBar.empty
        bar.setFileType(pdf)
        XCTAssertEqual(bar.searchText(keyword: ""), "pdf")
        XCTAssertEqual(bar.searchText(keyword: "   "), "pdf")
    }

    /// ★ 拼出来的文本必须真的被解析成格式限制，而不是掉进关键词。
    func testSearchTextIsParsedAsFormatFilter() {
        var bar = SearchTokenBar.empty
        bar.setFileType(pdf)
        let parsed = SearchQueryParser.parse(bar.searchText(keyword: "年报"))
        XCTAssertEqual(parsed.terms, ["年报"], "关键词不该被类型词污染")
        XCTAssertTrue(parsed.hasFormatFilter)
        XCTAssertTrue(parsed.extensions.contains("pdf"))
    }

    /// ★ 删除键：关键词还在时不许抢（那是文本编辑的键）。
    func testBackspaceDoesNotStealKeyWhenKeywordPresent() {
        var bar = SearchTokenBar.empty
        bar.setFileType(pdf)
        XCTAssertNil(bar.slotToRemoveOnBackspace(keywordEmpty: false))
    }

    /// 关键词为空 ⇒ 删最近设的那一个（LIFO）。
    func testBackspaceRemovesLastSetFirst() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        bar.setFileType(pdf)
        XCTAssertEqual(bar.slotToRemoveOnBackspace(keywordEmpty: true), .fileType)
        bar.clear(.fileType)
        XCTAssertEqual(bar.slotToRemoveOnBackspace(keywordEmpty: true), .location)
        bar.clear(.location)
        XCTAssertNil(bar.slotToRemoveOnBackspace(keywordEmpty: true))
    }

    /// 位置限定不影响发给搜索的文本（它走的是 rootLimit 那条路）。
    func testLocationDoesNotChangeSearchText() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        XCTAssertEqual(bar.searchText(keyword: "报告"), "报告")
    }

    // MARK: - 点标签（与删除键是两条规则）

    /// ★ 每一枚限定都要带上自己的槽位 —— 点的就是被点的那一枚。
    ///
    /// 只给一串字符串的话，界面只能「删最近设的那个」：位置与类型都在时
    /// 点位置，删掉的却是类型（1.1.16 的实际表现）。
    func testTokensCarryTheirOwnSlot() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        bar.setFileType(pdf)
        XCTAssertEqual(bar.tokens.map(\.slot), [.location, .fileType])
        XCTAssertEqual(bar.tokens.map(\.label), ["照片", "pdf"])
    }

    /// ★ 点位置标签删的是位置，类型**不受影响**。
    ///
    /// 变异：界面把点击也接到 `slotToRemoveOnBackspace` 上，本条立刻红
    /// （删掉的会是「最近设的」= 类型）。
    func testTappingLocationTokenClearsOnlyLocation() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        bar.setFileType(pdf)
        bar.clear(.location)
        XCTAssertNil(bar.locationLabelText, "位置应被清掉")
        XCTAssertEqual(bar.fileType?.id, pdf.id, "类型必须还在")
    }

    /// ★ 点类型标签删的是类型，位置**不受影响**。
    func testTappingFileTypeTokenClearsOnlyFileType() {
        var bar = SearchTokenBar.empty
        bar.setLocation(.sourceRoot(sourceID: "nas-A", root: "/照片"))
        bar.setFileType(pdf)
        bar.clear(.fileType)
        XCTAssertNil(bar.fileType)
        XCTAssertEqual(bar.tokens.map(\.slot), [.location], "位置必须还在")
    }

    /// ★ 点击不受「关键词必须为空」的限制 —— 那是删除键的前提，不是点击的。
    ///
    /// 这两条规则被合并的后果就是：输入框里有字时点标签毫无反应。
    func testTapClearIsNotGatedByKeyword() {
        var bar = SearchTokenBar.empty
        bar.setFileType(pdf)
        // 关键词非空时删除键要让路给文本编辑……
        XCTAssertNil(bar.slotToRemoveOnBackspace(keywordEmpty: false))
        // ……但点标签是直接指着它，不该被这个前提挡住。
        bar.clear(.fileType)
        XCTAssertTrue(bar.isEmpty, "点了就该删掉，与输入框里有没有字无关")
    }

    /// 只有类型限定时的槽位清单（回归：别多给一个空的「位置」）。
    func testTokensWithOnlyFileType() {
        var bar = SearchTokenBar.empty
        bar.setFileType(photo)
        XCTAssertEqual(bar.tokens.map(\.slot), [.fileType])
    }
}

private extension SearchTokenBar {
    /// 位置限定的显示名（测试里读它比判枚举更直观）。
    var locationLabelText: String? { SearchTargetLabel.label(for: location) }
}
