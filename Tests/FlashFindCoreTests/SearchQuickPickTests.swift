import XCTest
@testable import FlashFindCore

/// 命令面板的**顺序**与**数字快捷键**（设置 ▸ 搜索里可调）。
///
/// 这一组守的可以压成两句话：
/// **1. 面板上写「3」的那一行，按 3 必须选中它；**
/// **2. 设置页写「3」的那一行，与面板是同一行 —— 而「3」就是它在第 3 行。**
///
/// ★ 第 2 句是本轮返工的重点（2026-10-26 用户报障）：
/// 上一版允许给单条钉死一个号，于是「此 Mac」排第 1 行却写着 5，
/// 用户拖动之后那个号也不跟着变 —— 数字必须只有一个来源：它在第几行。
final class SearchQuickPickTests: XCTestCase {

    // MARK: - 夹具

    private func source(_ id: String, name: String, roots: [String]) -> SearchCommandCatalog.SourceEntry {
        SearchCommandCatalog.SourceEntry(sourceID: id, displayName: name, roots: roots, ready: true)
    }

    /// 位置面板：全部位置 / 此 Mac / 群晖两个根 / OpenList 两个根 = 六条 + 打开设置。
    private func locationItems() -> [SearchCommandItem] {
        SearchCommandCatalog.items(kind: .location,
                                   sources: [source("syn", name: "群晖", roots: ["/照片", "/文档"]),
                                             source("ol", name: "openlist", roots: ["/A0001", "/A0002"])],
                                   includeLocal: true)
    }

    private func typeItems() -> [SearchCommandItem] {
        SearchCommandCatalog.items(kind: .fileType, sources: [], includeLocal: true)
    }

    private func ids(_ items: [SearchCommandItem]) -> [String] { items.map(\.id) }

    /// 把设置应用到候选上（面板与设置页都走这一条）。
    private func panel(_ items: [SearchCommandItem],
                       _ settings: SearchQuickPickSettings,
                       _ kind: SearchCommandKind) -> [SearchCommandItem] {
        SearchCommandArrangement.arrange(items,
                                         order: settings.order(for: kind),
                                         hidden: settings.hiddenIDs(for: kind))
    }

    /// 存进偏好再读回来 —— 「关掉设置页再打开」看到的必须是同一份。
    private func saved(_ settings: SearchQuickPickSettings) -> SearchQuickPickSettings {
        let preferences = InMemoryClientPreferences()
        settings.save(to: preferences)
        return SearchQuickPickSettings.load(from: preferences)
    }

    // MARK: - 默认值 = 加这个功能之前的行为

    /// ★ 没配过的时候一个字都不该变：1–9 顺排、0 给「打开设置」、顺序照目录给的。
    func testDefaultSettingsChangeNothing() {
        let items = locationItems()
        let settings = SearchQuickPickSettings.empty
        XCTAssertEqual(ids(panel(items, settings, .location)), ids(items), "没排过就必须是自然顺序")
        let numbers = SearchCommandNumbering.keys(in: items)
        XCTAssertEqual(numbers, [1, 2, 3, 4, 5, 6, 0],
                       "六条候选 + 打开设置：1–6 顺排，设置固定 0")
        // 往返：每个号都能回到它自己那一行。
        for (index, number) in numbers.enumerated() {
            guard let number else { continue }
            XCTAssertEqual(SearchCommandNumbering.index(forKey: number, in: items), index)
        }
    }

    /// 打开设置的 0 永远成立，与它在列表里排第几无关（拖动也动不了它）。
    func testSettingsRowStaysLastAndKeepsZero() {
        var settings = SearchQuickPickSettings.empty
        // 把最后一条位置拖到最前。
        settings.move(.location, from: 4, to: 0, among: locationItems())
        let arranged = panel(locationItems(), settings, .location)
        XCTAssertEqual(arranged.last?.id, SearchCommandCatalog.settingsItemID)
        XCTAssertEqual(SearchCommandNumbering.key(for: arranged.count - 1, in: arranged), 0)
    }

    // MARK: - 拖动排序

    /// ★ 把第 3 条（群晖 /照片）拖到最前：顺序变了，但「打开设置」仍收尾，
    /// 未参与排序的候选不会被吞掉。
    func testDraggingReordersThePanel() {
        var settings = SearchQuickPickSettings.empty
        let items = locationItems()
        XCTAssertEqual(items[2].title, "照片", "夹具前提：第 3 条是群晖的 /照片")

        settings.move(.location, from: 2, to: 0, among: items)
        XCTAssertEqual(settings.order(for: .location).first, items[2].id)

        let arranged = panel(items, settings, .location)
        XCTAssertEqual(arranged.map(\.title), ["照片", "全部位置", "此 Mac", "文档", "A0001", "A0002", "打开设置…"])
        XCTAssertEqual(arranged.count, items.count, "拖动不许丢候选")
    }

    /// ★★ 用户报障的那一条：**拖动之后，数字必须跟着变。**
    ///
    /// 「此 Mac」原先第 2 行（号 2），拖到第 3 行之后它就必须写 3；
    /// 被它挤开的「照片」退到 2。整组里每个号仍然只出现一次。
    func testDraggingChangesTheNumberOnTheMovedRow() throws {
        let items = locationItems()
        XCTAssertEqual(items[1].title, "此 Mac", "夹具前提：第 2 条是此 Mac")
        let mac = items[1]
        var settings = SearchQuickPickSettings.empty

        // 拖到第 3 行（下标 2）。
        settings.move(.location, from: 1, to: 2, among: items)
        let arranged = panel(items, settings, .location)
        let numbers = SearchCommandNumbering.keys(in: arranged)

        XCTAssertEqual(arranged.map(\.title),
                       ["全部位置", "照片", "此 Mac", "文档", "A0001", "A0002", "打开设置…"],
                       "此 Mac 应该排到第 3 行")
        let macIndex = try XCTUnwrap(arranged.firstIndex { $0.id == mac.id })
        XCTAssertEqual(macIndex, 2)
        XCTAssertEqual(numbers[macIndex], 3, "★ 排第 3 行就必须写 3（上一版这里还是 2）")
        XCTAssertEqual(numbers[1], 2, "被挤开的照片退到 2")
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 3, in: arranged), macIndex,
                       "按 3 必须选中此 Mac")
        XCTAssertEqual(Set(numbers.compactMap { $0 }).count, numbers.compactMap { $0 }.count,
                       "同一个号不许出现两次")
    }

    /// ★ 新加的搜索根不在顺序表里 ⇒ 排到末尾，不必写迁移，也不会打乱旧顺序。
    func testNewlyAddedRootAppearsAtTheEndWithoutTouchingTheSavedOrder() {
        var settings = SearchQuickPickSettings.empty
        settings.move(.location, from: 2, to: 0, among: locationItems())
        let saved = settings.order(for: .location)

        // 用户后来给 openlist 加了第三个根。
        let grown = SearchCommandCatalog.items(
            kind: .location,
            sources: [source("syn", name: "群晖", roots: ["/照片", "/文档"]),
                      source("ol", name: "openlist", roots: ["/A0001", "/A0002", "/A0003"])],
            includeLocal: true)
        let arranged = SearchCommandArrangement.arrange(grown, order: saved)
        XCTAssertEqual(arranged.last?.id, SearchCommandCatalog.settingsItemID)
        XCTAssertEqual(arranged.dropLast().last?.title, "A0003", "新根排在末尾（设置之前）")
        XCTAssertEqual(arranged.first?.title, "照片", "旧顺序不受影响")
    }

    /// 拖到原位是空操作，不写脏数据。
    func testDroppingOnItselfDoesNotChangeTheOrder() {
        var settings = SearchQuickPickSettings.empty
        settings.move(.location, from: 1, to: 1, among: locationItems())
        let after = settings.order(for: .location)
        XCTAssertEqual(after.count, locationItems().count - 1, "顺序表里不该有「打开设置」")
        XCTAssertEqual(after.first, locationItems()[0].id, "第一条仍是全部位置")
        XCTAssertEqual(after[1], locationItems()[1].id, "第二条仍是此 Mac")
    }

    // MARK: - 删掉一条

    /// ★ 删掉之后面板里没有它，而且**再刷新一次也不会长回来**。
    ///
    /// 候选是每次从「目录 + 用户配置」现算的：只在界面上跳过这一行的话，
    /// 用户关掉设置页再打开，那条又回来了（删除等于白做）。
    func testHidingRemovesTheRowAndKeepsItGone() throws {
        var settings = SearchQuickPickSettings.empty
        let items = locationItems()
        let photo = try XCTUnwrap(items.first { $0.title == "照片" })
        XCTAssertTrue(settings.hide(photo.id, kind: .location, among: items))
        XCTAssertTrue(settings.hiddenIDs(for: .location).contains(photo.id))
        XCTAssertTrue(settings.hasCustomization(for: .location),
                      "删过也算改过：「恢复默认」必须可点，否则删错了没法回头")

        let arranged = panel(items, settings, .location)
        XCTAssertFalse(arranged.contains { $0.id == photo.id }, "删掉的不能再出现")
        XCTAssertEqual(arranged.count, items.count - 1)
        XCTAssertEqual(arranged.last?.id, SearchCommandCatalog.settingsItemID, "打开设置照样收尾")
        XCTAssertEqual(SearchCommandNumbering.key(for: 2, in: arranged), 3,
                       "删掉第 3 条后，原来第 4 条补上来写 3（号码仍等于行号）")

        XCTAssertFalse(panel(items, saved(settings), .location).contains { $0.id == photo.id },
                       "★ 存回去再读，删掉的仍然不出现")
    }

    /// ★「打开设置」不许删：它是位置都搜不了时的兜底入口。
    func testOpenSettingsCannotBeDeletedAndUnknownIDsAreIgnored() {
        var settings = SearchQuickPickSettings.empty
        XCTAssertFalse(settings.hide(SearchCommandCatalog.settingsItemID,
                                     kind: .location, among: locationItems()))
        XCTAssertFalse(settings.hide("target:没有这一条", kind: .location, among: locationItems()),
                       "目录里没有的 id 不采纳（旧数据/手改过的偏好）")
        XCTAssertTrue(settings.hiddenIDs(for: .location).isEmpty)
        XCTAssertFalse(settings.hasCustomization(for: .location), "没删成就不该留下改动痕迹")
    }

    // MARK: - 换掉一条

    /// ★ 替换是**同一位次上换人**：位次不变 ⇒ 号码不变 ⇒ 用户不会觉得那条被挪走了。
    func testReplacingKeepsTheRowAndTheNumber() throws {
        var settings = SearchQuickPickSettings.empty
        let items = typeItems()
        let word = items[1]
        XCTAssertEqual(word.title, "word", "夹具前提：第 2 条是 word")
        let document = try XCTUnwrap(items.first { $0.title == "文档" })
        XCTAssertTrue(settings.replace(word.id, with: document.id, kind: .fileType, among: items))

        let arranged = panel(items, settings, .fileType)
        XCTAssertEqual(arranged[1].id, document.id, "新条目接替第 2 行")
        XCTAssertEqual(arranged[1].title, "文档")
        XCTAssertFalse(arranged.contains { $0.id == word.id }, "旧条目从面板里消失")
        XCTAssertEqual(arranged.filter { $0.id == document.id }.count, 1,
                       "★ 文档本来在第 9 行：搬过来之后那边必须没有它，否则一页两行")
        XCTAssertEqual(settings.order(for: .fileType).filter { $0 == document.id }.count, 1,
                       "★ 顺序表里不许留两份同一个 id：整份顺序的不变量是「每个候选恰好一次」")
        XCTAssertEqual(SearchCommandNumbering.key(for: 1, in: arranged), 2, "号码不变")
        XCTAssertEqual(arranged.count, items.count - 1, "搬过来不是多一条：总数少一条")
        XCTAssertTrue(settings.hiddenIDs(for: .fileType).contains(word.id),
                      "旧的进隐藏表：否则它下次按自然顺序长回来，同一页出现两条")
    }

    /// ★ 换成一条**已经显示在页面上**的条目：允许，但要把它从原位置搬过来，
    /// 不许留下两行一模一样的候选。
    func testReplacingWithAVisibleItemMovesItInsteadOfDuplicating() throws {
        var settings = SearchQuickPickSettings.empty
        let items = typeItems()
        let pdf = items[0]
        let document = try XCTUnwrap(items.first { $0.title == "文档" })
        XCTAssertEqual(items.firstIndex { $0.title == "文档" }, 8, "夹具前提：文档在第 9 行")

        XCTAssertTrue(settings.replace(pdf.id, with: document.id, kind: .fileType, among: items))
        let arranged = panel(items, settings, .fileType)
        XCTAssertEqual(arranged.first?.id, document.id, "文档接替第 1 行")
        XCTAssertEqual(arranged.filter { $0.id == document.id }.count, 1,
                       "★ 第 9 行那份必须消失：一页两行同样的候选，用户按数字都不知道选哪条")
        XCTAssertFalse(arranged.contains { $0.id == pdf.id })
        XCTAssertEqual(settings.order(for: .fileType).filter { $0 == document.id }.count, 1,
                       "★ 顺序表里不许留两份同一个 id：整份顺序的不变量是「每个候选恰好一次」")
        XCTAssertEqual(arranged.last?.id, SearchCommandCatalog.settingsItemID)
    }

    /// 换成自己、换个不存在的 id、把「打开设置」换进来，都不采纳。
    func testInvalidReplacementsAreRejected() {
        var settings = SearchQuickPickSettings.empty
        let items = typeItems()
        XCTAssertFalse(settings.replace(items[0].id, with: items[0].id,
                                        kind: .fileType, among: items), "换成自己没意义")
        XCTAssertFalse(settings.replace(items[0].id, with: "",
                                        kind: .fileType, among: items))
        XCTAssertFalse(settings.replace(items[0].id, with: SearchCommandCatalog.settingsItemID,
                                        kind: .fileType, among: items), "不许把兜底入口换进来")
        XCTAssertFalse(settings.replace("target:不存在", with: items[3].id,
                                        kind: .fileType, among: items), "要换的那条不在列表里")
        XCTAssertTrue(settings.order(for: .fileType).isEmpty, "不采纳就不该写落盘数据")
        XCTAssertTrue(settings.hiddenIDs(for: .fileType).isEmpty)
    }

    /// ★ 删错了能找回来：替换候选里包含被删掉的条目，换回来之后它重新出现在面板。
    func testDeletedItemComesBackThroughReplacement() throws {
        var settings = SearchQuickPickSettings.empty
        let items = locationItems()
        let photo = try XCTUnwrap(items.first { $0.title == "照片" })
        settings.hide(photo.id, kind: .location, among: items)

        let visible = panel(items, settings, .location)
        let first = try XCTUnwrap(visible.first)
        let candidates = SearchCommandReplacement.candidates(all: items, excluding: first.id)
        XCTAssertTrue(candidates.contains { $0.id == photo.id },
                      "★ 被删的那条必须出现在替换候选里，否则删错了没有回头路")
        XCTAssertFalse(candidates.contains { $0.id == SearchCommandCatalog.settingsItemID },
                       "「打开设置」不能当替换目标")
        XCTAssertFalse(candidates.contains { $0.id == first.id },
                       "候选里不该有自己")

        XCTAssertTrue(settings.replace(first.id, with: photo.id, kind: .location, among: visible))
        let back = panel(items, settings, .location)
        XCTAssertTrue(back.contains { $0.id == photo.id }, "换回来的必须重新出现")
        XCTAssertFalse(back.contains { $0.id == first.id })
        XCTAssertEqual(back.first?.id, photo.id, "接替的是被换掉那一行的位次")
    }

    /// 恢复默认要把删除记录一起清掉（只清顺序的话，删掉的永远回不来了）。
    func testResetAlsoRestoresDeletedRows() throws {
        var settings = SearchQuickPickSettings.empty
        let items = locationItems()
        settings.hide(try XCTUnwrap(items.first { $0.title == "照片" }).id,
                      kind: .location, among: items)
        XCTAssertTrue(settings.hasCustomization(for: .location))

        settings.reset(.location)
        XCTAssertFalse(settings.hasCustomization(for: .location))
        XCTAssertTrue(settings.hiddenIDs(for: .location).isEmpty)
        XCTAssertEqual(panel(items, settings, .location), items)
    }

    // MARK: - 筛选之后仍然「写几按几」

    /// ★ 编号按**当前显示的这组**算：筛完只剩一条时它就是 1 号 ——
    /// 号是行号，不会因为「它在完整列表里排第几」而留下一个按不到的数字。
    func testNumberingAfterFilteringMatchesWhatIsOnScreen() {
        let items = typeItems()
        let filtered = SearchCommandCatalog.filter(items, by: "照片")
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(SearchCommandNumbering.keys(in: filtered), [1])
        XCTAssertEqual(SearchCommandNumbering.index(forKey: 1, in: filtered), 0)
        XCTAssertNil(SearchCommandNumbering.index(forKey: 5, in: filtered),
                     "屏幕上没有 5 号，按 5 就不该选到东西")
    }

    // MARK: - 落盘

    /// ★ 存了再读要一模一样；两次写出的字节也一致（便于排查与比对）。
    func testSettingsSurviveARoundTripThroughPreferences() throws {
        var settings = SearchQuickPickSettings.empty
        settings.move(.location, from: 2, to: 0, among: locationItems())
        settings.move(.fileType, from: 8, to: 1, among: typeItems())
        settings.hide(SearchFileTypeCatalog.all[3].id, kind: .fileType, among: typeItems())

        let preferences = InMemoryClientPreferences()
        settings.save(to: preferences)
        let loaded = SearchQuickPickSettings.load(from: preferences)
        XCTAssertEqual(loaded, settings)
        XCTAssertEqual(loaded.order(for: .location), settings.order(for: .location))
        XCTAssertEqual(loaded.order(for: .fileType).first, SearchFileTypeCatalog.all[0].id,
                       "选了 2 ⇒ 原第 2 行（pdf）退到第 1 行")
        XCTAssertEqual(loaded.order(for: .fileType)[1], SearchFileTypeCatalog.all[8].id,
                       "文档搬到第 2 行")
        XCTAssertEqual(loaded.hiddenIDs(for: .fileType),
                       Set([SearchFileTypeCatalog.all[3].id]),
                       "★ 删掉的条目也要存下来：只存顺序的话，删除会在重启后失效")

        let first = try XCTUnwrap(preferences.data(forKey: SearchQuickPickSettings.storageKey))
        settings.save(to: preferences)
        let second = try XCTUnwrap(preferences.data(forKey: SearchQuickPickSettings.storageKey))
        XCTAssertEqual(first, second, "同一份设置两次写出的字节必须相同")
    }

    /// ★ 读坏了不许崩、不许让设置页打不开：直接回落到默认。
    func testDamagedStorageFallsBackToDefaults() {
        let preferences = InMemoryClientPreferences()
        preferences.set(Data("这不是 JSON".utf8), forKey: SearchQuickPickSettings.storageKey)
        XCTAssertEqual(SearchQuickPickSettings.load(from: preferences), .empty)

        // 版本号对不上：按「没配过」处理（将来改结构时旧数据不硬塞进来）。
        preferences.set(Data(#"{"v":99,"order":{},"keys":{}}"#.utf8),
                        forKey: SearchQuickPickSettings.storageKey)
        XCTAssertEqual(SearchQuickPickSettings.load(from: preferences), .empty)

        // 重复 id、空串被清掉，其余照收。
        let messy = """
        {"v":1,"order":{"location":["a","a","","b"]},
         "keys":{"location":{"a":0,"b":12,"c":3}}}
        """
        preferences.set(Data(messy.utf8), forKey: SearchQuickPickSettings.storageKey)
        let loaded = SearchQuickPickSettings.load(from: preferences)
        XCTAssertEqual(loaded.order(for: .location), ["a", "b"], "去重、去空")
    }

    /// ★ 上一版存过「指定键」的数据还能读：`keys` 字段被忽略，顺序照旧生效。
    ///
    /// 不忽略它的后果是整份设置作废 —— 用户排好的顺序在一次升级里悄悄回到出厂。
    func testStoredKeysFromThePreviousVersionAreIgnoredNotFatal() {
        let preferences = InMemoryClientPreferences()
        let legacy = """
        {"v":1,"order":{"fileType":["type:photo","type:pdf"]},
         "keys":{"fileType":{"type:photo":3}}}
        """
        preferences.set(Data(legacy.utf8), forKey: SearchQuickPickSettings.storageKey)
        let loaded = SearchQuickPickSettings.load(from: preferences)
        XCTAssertEqual(loaded.order(for: .fileType), ["type:photo", "type:pdf"],
                       "顺序必须保住")

        // 读出来之后按新模型编号：照片排第 1 ⇒ 1 号（不再是旧的 3）。
        let items = typeItems()
        let arranged = panel(items, loaded, .fileType)
        XCTAssertEqual(arranged.first?.title, "照片")
        XCTAssertEqual(SearchCommandNumbering.keys(in: arranged).first, 1)
    }

    /// ★ 偏好被人手改过也不能把「打开设置」删掉；隐藏表本身照样去重、去空。
    func testDamagedHiddenListCannotRemoveOpenSettings() {
        let preferences = InMemoryClientPreferences()
        let messy = """
        {"v":1,"order":{},"hidden":{"location":["target:local","target:local","","command:openSettings"]}}
        """
        preferences.set(Data(messy.utf8), forKey: SearchQuickPickSettings.storageKey)
        let loaded = SearchQuickPickSettings.load(from: preferences)
        XCTAssertEqual(loaded.hiddenIDs(for: .location), ["target:local"])
        XCTAssertTrue(panel(locationItems(), loaded, .location)
                        .contains { $0.id == SearchCommandCatalog.settingsItemID },
                      "★ 兜底入口不许被一份坏偏好删掉")
    }

    /// 没存过就是默认。
    func testMissingStorageIsEmpty() {
        XCTAssertEqual(SearchQuickPickSettings.load(from: InMemoryClientPreferences()), .empty)
    }

    // MARK: - 设置页的行

    /// ★ 设置页**不列「打开设置」**：它固定 0，不参与排序。
    /// 每行显示的号必须等于面板上那一行的号，且**等于行号**。
    func testSettingsRowsSkipOpenSettingsAndShareThePanelNumbering() throws {
        var settings = SearchQuickPickSettings.empty
        let items = typeItems()
        settings.move(.fileType, from: 0, to: 5, among: items)

        let arranged = panel(items, settings, .fileType)
        let rows = settings.rows(for: .fileType, in: arranged)
        XCTAssertEqual(rows.count, items.count - 1, "「打开设置」不进设置页")
        XCTAssertFalse(rows.contains { $0.id == SearchCommandCatalog.settingsItemID })
        let numbers = SearchCommandNumbering.keys(in: arranged)
        for (index, row) in rows.enumerated() {
            XCTAssertEqual(row.key, numbers[index], "「\(row.item.title)」两处编号必须相同")
            XCTAssertEqual(row.key, index + 1, "★ 设置页那一行显示的号必须就是它的行号")
        }
        XCTAssertEqual(rows[5].item.title, "pdf", "拖到第 6 行 ⇒ pdf 排第 6 行、写 6")
    }

    /// 恢复默认：顺序清掉，编号回到 1–9 顺排。
    func testResetRestoresNaturalOrder() {
        var settings = SearchQuickPickSettings.empty
        settings.move(.location, from: 3, to: 0, among: locationItems())
        XCTAssertTrue(settings.hasCustomization(for: .location))

        settings.reset(.location)
        XCTAssertFalse(settings.hasCustomization(for: .location))
        XCTAssertEqual(panel(locationItems(), settings, .location), locationItems())
    }

    /// 两类面板的设置互不影响：改了位置，类型面板的顺序不动。
    func testTheTwoKindsDoNotLeakIntoEachOther() {
        var settings = SearchQuickPickSettings.empty
        settings.move(.location, from: 2, to: 0, among: locationItems())
        settings.move(.fileType, from: 4, to: 8, among: typeItems())
        XCTAssertEqual(settings.order(for: .fileType).last, SearchFileTypeCatalog.all[4].id)
        XCTAssertEqual(settings.order(for: .location).count, locationItems().count - 1)
        XCTAssertNotEqual(settings.order(for: .location).first, settings.order(for: .fileType).first)
    }
}
