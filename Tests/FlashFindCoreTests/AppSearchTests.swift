import XCTest
@testable import FlashFindCore

/// 应用搜索（新增功能）。
///
/// 用户要求「增加搜索 app 功能」。三个可测点分别对应三次真实风险：
/// 1. **列目录**只认顶层 `.app`——递归会把 app 内部的 Helper.app 全翻出来；
/// 2. **匹配与排序**：输入半个名字要能命中，同名/前缀的排前面；
/// 3. **Provider 契约**：必须发 `searching` 再发终态，否则「正在搜索」永远转不完
///    （`SearchCompletionTracker` 的 pendingSources 会一直吊着界面）。
final class AppSearchTests: XCTestCase {

    private func app(_ name: String) -> AppSearchCandidate {
        AppSearchCandidate(name: name, url: URL(fileURLWithPath: "/Applications/\(name).app"))
    }

    // MARK: - 目录枚举

    func testScanListsOnlyTopLevelAppBundles() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-app-catalog-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = FileManager.default
        try manager.createDirectory(at: root.appendingPathComponent("WPS Office.app"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Safari.app"), withIntermediateDirectories: true)
        // 不是 .app 的目录与文件都不该出现。
        try manager.createDirectory(at: root.appendingPathComponent("Utilities.appext"), withIntermediateDirectories: true)
        try manager.createDirectory(at: root.appendingPathComponent("Plain Folder"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("说明.txt"))
        // 嵌套在子目录里的 app 不该被递归翻出来。
        try manager.createDirectory(at: root.appendingPathComponent("Nested/Deep.app"), withIntermediateDirectories: true)

        let found = AppCatalog.scan(directories: [root])
        XCTAssertEqual(Set(found.map(\.name)), ["WPS Office", "Safari"])
        XCTAssertEqual(found.count, 2, "嵌套与 non-.app 条目都不该出现")
    }

    func testScanSkipsDirectoriesThatDoNotExist() {
        // 用户机器上 ~/Applications 常常不存在；读不到的目录直接跳过，不抛错。
        let missing = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-does-not-exist-\(UUID().uuidString)")
        XCTAssertTrue(AppCatalog.scan(directories: [missing]).isEmpty)
    }

    func testScanDropsTheExtensionFromTheDisplayName() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-app-name-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("闪寻.app"), withIntermediateDirectories: true)
        let found = AppCatalog.scan(directories: [root])
        XCTAssertEqual(found.map(\.name), ["闪寻"])
        XCTAssertEqual(found.first?.url.lastPathComponent, "闪寻.app")
    }

    // MARK: - 匹配与排序

    func testEmptyQueryMatchesNothing() {
        let apps = [self.app("Safari"), self.app("Notes")]
        XCTAssertTrue(AppCatalog.matches(apps, query: "").isEmpty)
        XCTAssertTrue(AppCatalog.matches(apps, query: "   ").isEmpty)
    }

    func testSubstringMatchIsCaseAndDiacriticInsensitive() {
        let apps = [self.app("Safari"), self.app("WPS Office")]
        XCTAssertEqual(AppCatalog.matches(apps, query: "saf").map(\.name), ["Safari"])
        XCTAssertEqual(AppCatalog.matches(apps, query: "SAFARI").map(\.name), ["Safari"])
        XCTAssertEqual(AppCatalog.matches(apps, query: "office").map(\.name), ["WPS Office"])
    }

    /// ★ 整名命中排最前，其次前缀，再次包含——与文件夹搜索的 rank 约定一致。
    ///
    /// 查询词用 "note"：`Note` 整名相等（0）、`Notebook` 前缀（1）、
    /// `Quick Notes Pro` 只是包含（2）。三个 rank 各占一个，顺序才钉得住。
    func testExactNameBeatsPrefixBeatsSubstring() {
        let apps = [self.app("Note"), self.app("Notebook"), self.app("Quick Notes Pro")]
        let ranked = AppCatalog.matches(apps, query: "note")
        XCTAssertEqual(ranked.map(\.name), ["Note", "Notebook", "Quick Notes Pro"])
        XCTAssertEqual(AppCatalog.rank(name: "Note", query: "note"), 0)
        XCTAssertEqual(AppCatalog.rank(name: "Notebook", query: "note"), 1)
        XCTAssertEqual(AppCatalog.rank(name: "Quick Notes Pro", query: "note"), 2)
    }

    /// 同一 rank 里短名优先：输入 "note" 时 "Notes" 该在 "Notebook" 前面。
    func testShorterNameWinsWithinTheSameRank() {
        let apps = [self.app("Notebook"), self.app("Notes")]
        XCTAssertEqual(AppCatalog.matches(apps, query: "note").map(\.name), ["Notes", "Notebook"])
    }

    func testLimitCapsTheResultCount() {
        let apps = (0..<50).map { self.app("App \($0)") }
        XCTAssertEqual(AppCatalog.matches(apps, query: "app", limit: 5).count, 5)
    }

    // MARK: - Provider 契约

    /// ★ 必须先发 `searching`、再发终态，且带上 `total`。
    ///
    /// 界面「还在搜吗」看的是 `SearchCompletionTracker`：缺终态会让状态栏
    /// 永远显示「正在搜索」——结果都出来了还在转。
    @MainActor
    func testProviderEmitsSearchingThenCompletedWithTotal() async {
        let provider = AppSearchProvider(scan: { [self.app("Safari"), self.app("Notes")] })
        var events: [ProviderEvent] = []
        await provider.search("saf", queryID: UUID()) { events.append($0) }
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].state, .searching)
        XCTAssertEqual(events[1].state, .completed)
        XCTAssertTrue(events[1].isComplete)
        XCTAssertEqual(events[1].reportedTotal, 1)
    }

    /// 结果行要能被打开：localURL 指向 app 本体，kind 标记为 app。
    @MainActor
    func testProviderMapsCandidatesToOpenableRows() async {
        let provider = AppSearchProvider(scan: { [self.app("Safari")] })
        var events: [ProviderEvent] = []
        await provider.search("safari", queryID: UUID()) { events.append($0) }
        let rows = events.last?.results ?? []
        XCTAssertEqual(rows.count, 1)
        let row = rows[0]
        XCTAssertEqual(row.name, "Safari")
        XCTAssertEqual(row.kind, "app")
        XCTAssertEqual(row.sourceID, SearchSource.apps.id)
        XCTAssertEqual(row.sourceType, .local)
        XCTAssertEqual(row.localURL?.lastPathComponent, "Safari.app")
        XCTAssertEqual(row.rank, 0, "整名命中必须是 rank 0，排在本机文件前面")
        XCTAssertTrue(row.id.hasPrefix("app:"), "结果 id 要有自己的前缀，不能和文件行撞")
    }

    /// 空查询也要落终态，否则一样会吊住「正在搜索」。
    @MainActor
    func testProviderTerminatesOnEmptyQuery() async {
        let provider = AppSearchProvider(scan: { [self.app("Safari")] })
        var events: [ProviderEvent] = []
        await provider.search("", queryID: UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.state, .completed)
        XCTAssertEqual(events.last?.reportedTotal, 0)
    }

    /// ★ 每个事件都要带**调用方的** queryID 与自己的 sourceID。
    ///
    /// 应用搜索在同一次调用里同步跑完（没有中途挂起点），所以 provider 自己
    /// 不需要取消机制；迟到/过期事件的拦截在 `SearchCoordinator`——
    /// 它只转发 `queryID` 与 sourceID 都对得上的事件。这里锁的是「对得上」的前提。
    @MainActor
    func testProviderTagsEveryEventWithTheCallersQueryID() async {
        let provider = AppSearchProvider(scan: { [self.app("Safari")] })
        let id = UUID()
        var events: [ProviderEvent] = []
        await provider.search("saf", queryID: id) { events.append($0) }
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.allSatisfy { $0.queryID == id }, "事件必须带调用方的 queryID")
        XCTAssertTrue(events.allSatisfy { $0.sourceID == SearchSource.apps.id }, "事件必须带来源 ID")
    }

    /// 取消对应用搜索是空操作：它在一次调用内同步完成，没有可取消的中间态。
    /// 这条锁住「别为它加一套假装能取消的状态机」。
    @MainActor
    func testCancelIsANoOpBecauseTheSearchRunsToCompletion() async {
        let provider = AppSearchProvider(scan: { [self.app("Safari")] })
        let id = UUID()
        provider.cancel(queryID: id)
        var events: [ProviderEvent] = []
        await provider.search("saf", queryID: id) { events.append($0) }
        XCTAssertEqual(events.last?.state, .completed, "取消不该让一次完整搜索发不出终态")
    }

    // MARK: - 来源标识

    /// 应用来源的标识要稳定，且属于「本机」一侧（立即出结果，不走防抖）。
    func testAppsSourceIsStableAndLocal() {
        XCTAssertEqual(SearchSource.apps.id, "local_apps")
        XCTAssertEqual(SearchSource.apps.displayName, "应用程序")
        XCTAssertEqual(SearchSource.apps.type, .local)
        XCTAssertNotEqual(SearchSource.apps.id, SearchSource.local.id, "不能和本机文件来源共用 id")
    }
}
