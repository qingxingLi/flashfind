import XCTest
@testable import FlashFindCore

/// 结果模块左侧的位置侧边栏（用户 2026-10-27）。
///
/// 要求原文：「新增侧边栏功能 从侧边栏可以选择搜索位置 默认是全部 依次往下排列
/// 做成抽屉式的感觉 点击切换有页面切换动画 切换后显示该位置的文件 无搜索结果有提示」。
///
/// 侧边栏画什么、高亮哪一行、空结果说什么 —— 三件事都在这里断言，
/// 视图只负责摆位置与动画。
final class SearchSidebarTests: XCTestCase {

    private func items(includeLocal: Bool = true,
                       sources: [SearchCommandCatalog.SourceEntry] = []) -> [SearchCommandItem] {
        SearchCommandCatalog.items(kind: .location, sources: sources, includeLocal: includeLocal)
    }

    private let nas = SearchCommandCatalog.SourceEntry(sourceID: "nas-a",
                                                       displayName: "公司 NAS",
                                                       roots: ["/Book", "/Photo"],
                                                       ready: true)
    private let offline = SearchCommandCatalog.SourceEntry(sourceID: "nas-b",
                                                           displayName: "家里的 NAS",
                                                           roots: ["/Share"],
                                                           ready: false)

    /// 侧边栏只收「位置」候选：「打开设置…」不在里面。
    ///
    /// ★ 按**动作**过滤而不是按某个 id 字符串排除：动作才是「它是什么」。
    func testEntriesOnlyCarryLocationItems() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas]))
        XCTAssertEqual(entries.map(\.title), ["全部位置", "此 Mac", "Book", "Photo"])
        XCTAssertFalse(entries.contains { $0.title.contains("设置") },
                       "「打开设置…」不是位置，出现在侧边栏里会变成一条点了跳走的怪东西")
        XCTAssertEqual(entries.count, 4, "全部 + 本机 + 两个根")
    }

    /// ★ 未连接的来源照样在列表里，状态写在副标题上。
    ///
    /// 这是 2026-10-26 那条报障的同一条铁律：位置是**用户配过的地方**，
    /// 不是此刻在线的机器。按 `ready` 过滤会让重启后的 NAS 集体消失。
    func testOfflineSourcesStayVisibleWithAStatusSubtitle() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas, offline]))
        let home = entries.first { $0.title == "Share" }
        XCTAssertNotNil(home, "★ 未连接的来源被藏掉了：重启后用户会以为位置没了")
        XCTAssertEqual(home?.subtitle, "家里的 NAS · 未连接")
        XCTAssertEqual(entries.first { $0.title == "Book" }?.subtitle, "公司 NAS",
                       "已连接的来源副标题只写名字，不写状态")
    }

    /// 本机搜索关掉时没有「此 Mac」这一行——默认值由调用方（`includeLocal`）给。
    func testLocalRowOnlyWhenLocalSearchIsOn() {
        let entries = SearchSidebar.entries(from: items(includeLocal: false, sources: []))
        XCTAssertEqual(entries.map(\.title), ["全部位置"])
    }

    /// 高亮哪一行：三种位置各自对应一行。
    func testSelectedIDMapsEveryTarget() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas]))
        XCTAssertEqual(SearchSidebar.selectedID(for: .unrestricted, in: entries),
                       SearchCommandCatalog.allItemID)
        XCTAssertEqual(SearchSidebar.selectedID(for: .local, in: entries),
                       SearchCommandCatalog.localItemID)
        XCTAssertEqual(SearchSidebar.selectedID(for: .sourceRoot(sourceID: "nas-a", root: "/Book"),
                                                in: entries),
                       SearchCommandCatalog.locationItemID(sourceID: "nas-a", root: "/Book"))
    }

    /// ★ 当前位置指向一个**已经不在列表里**的根 ⇒ 不点亮任何一行。
    ///
    /// 回落到「全部位置」是在撒谎：限定还挂在那个消失的根上，
    /// 用户看到「全部」被点亮，会以为自己在搜全部。
    func testVanishedRootHighlightsNothing() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas]))
        XCTAssertNil(SearchSidebar.selectedID(for: .sourceRoot(sourceID: "nas-a", root: "/Gone"),
                                              in: entries),
                     "★ 找不到就必须返回 nil，不许假装选中了「全部」")
        XCTAssertNil(SearchSidebar.selectedID(for: .local,
                                              in: SearchSidebar.entries(from: items(includeLocal: false))),
                     "本机搜索关掉后，「此 Mac」那一行不存在，也不该高亮")
    }

    /// ★★ **每个位置行都要写自己的来源名**（2026-10-29 真实报障）。
    ///
    /// 用户原话：「飞牛位置侧边栏的存储空间 2 不显示设备名称」，截图里
    /// 「存储空间 1」下面写着「飞牛 fnOS」，「存储空间 2」下面整片空白。
    ///
    /// 上一版按「同一个来源只在组首行写一次」处理，理由是去重——真实后果是
    /// 第二个根看不出属于哪台设备，而且**连「未连接」这个状态也一起丢了**。
    /// 这条用例钉的是「同源多根，每根都有副标题」，不是「某一行恰好有字」。
    func testEveryLocationRowShowsItsSourceName() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas, offline]))
        XCTAssertEqual(entries.map(\.title), ["全部位置", "此 Mac", "Book", "Photo", "Share"])

        let twoRoots = entries.filter { $0.title == "Book" || $0.title == "Photo" }
        XCTAssertEqual(twoRoots.map(\.subtitle), ["公司 NAS", "公司 NAS"],
                       "★ 同一台 NAS 的两个根，第二行也必须写着来源名（否则就是用户报的那片空白）")
        XCTAssertEqual(SearchSidebar.subtitleRows(entries), [false, false, true, true, true],
                       "★ 只有真正没有副标题的行（「全部位置」「此 Mac」）才不画第二行字")

        // 同源的第二个根在离线时也要能看出它没连上——这正是「组内省略」丢掉的另一件事。
        let offlineTwoRoots = SearchCommandCatalog.SourceEntry(sourceID: "nas-c",
                                                              displayName: "书房的 NAS",
                                                              roots: ["/A0001", "/A0002"],
                                                              ready: false)
        let offlineEntries = SearchSidebar.entries(from: items(includeLocal: true,
                                                              sources: [offlineTwoRoots]))
        XCTAssertEqual(offlineEntries.filter { $0.subtitle != nil }.map(\.subtitle),
                       ["书房的 NAS · 未连接", "书房的 NAS · 未连接"],
                       "★ 状态跟着每一行走：第二行看不出「未连接」＝ 用户点了没反应也不知道为什么")
    }

    /// 顺序跟着传进来的候选走（用户在设置里排过序就按排过的来）。
    func testOrderFollowsTheGivenItems() {
        let reversed = items(includeLocal: true, sources: [nas]).reversed().filter {
            if case .search = $0.action { return true } else { return false }
        }
        let entries = SearchSidebar.entries(from: Array(reversed))
        XCTAssertEqual(entries.map(\.title), ["Photo", "Book", "此 Mac", "全部位置"],
                       "侧边栏不许自己再排一遍：顺序只有一份（命令面板那份）")
    }

    /// 空结果的提示要说清「是在哪个位置没找到」。
    func testEmptyHintNamesTheLocation() {
        let plain = SearchEmptyHint.detail(locationTitle: nil)
        XCTAssertFalse(plain.contains("“”"), "没限定位置时不该出现一对空引号：\(plain)")
        XCTAssertTrue(plain.contains("换个位置"), "给了侧边栏，就该提示「换个位置」这条出路：\(plain)")
        XCTAssertTrue(plain.contains("试试更短的关键词"),
                      "「换短关键词」这条可操作建议必须留着：\(plain)")

        let limited = SearchEmptyHint.detail(locationTitle: "Book")
        XCTAssertTrue(limited.contains("“Book”"), "★ 必须点明是哪个位置没找到：\(limited)")
        XCTAssertTrue(limited.contains("换回“全部位置”"),
                      "限定了位置就要给「换回全部位置」这条出路（写成「全部」会与类型条那段撞名）：\(limited)")
        XCTAssertNotEqual(plain, limited, "有没有限定位置，说的不是同一句话")
    }

    func testEmptyHintTitleCarriesTheQuery() {
        XCTAssertEqual(SearchEmptyHint.title(query: "报告"), "没有找到“报告”")
    }

    /// ★「全部位置」不是「限定名」——这一条是从一张截图里的自相矛盾长出来的。
    ///
    /// 空结果提示写成「“全部位置”里没有匹配的文件……或换回“全部”」：
    /// 一句话里既说在全部里没找到、又劝用户换回全部。
    /// 根因是拿侧边栏**高亮那一行的标题**当「限定位置名」用了。
    func testUnrestrictedHasNoLimitTitle() {
        let entries = SearchSidebar.entries(from: items(includeLocal: true, sources: [nas]))
        XCTAssertNil(SearchSidebar.limitedLocationTitle(for: .unrestricted, in: entries),
                     "★ 没限定位置时不许有「限定名」，「全部位置」只是那一行的名字")
        XCTAssertEqual(SearchSidebar.limitedLocationTitle(for: .sourceRoot(sourceID: "nas-a", root: "/Book"),
                                                           in: entries),
                       "Book")
        XCTAssertEqual(SearchSidebar.limitedLocationTitle(for: .local, in: entries), "此 Mac")
    }

    /// 侧边栏宽度必须**明显窄于**搜索框宽度：它是模块内部的一列，
    /// 不许把窗口撑宽（用户原话「侧边栏不要突出搜索框左右宽度」）。
    func testSidebarStaysInsideTheModuleWidth() {
        XCTAssertGreaterThan(SearchModuleLayout.sidebarWidth, 80, "太窄放不下「全部位置」")
        XCTAssertLessThan(SearchModuleLayout.sidebarWidth, 200, "太宽会把结果区挤成一条")
        XCTAssertLessThan(SearchModuleLayout.sidebarRowHeight, SearchModuleLayout.typeBarHeight + 1,
                          "侧边栏行高不该比类型条还高，否则一屏放不下几个位置")
    }
}
