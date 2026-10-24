import XCTest
@testable import FlashFindCore

/// 应用搜索的**覆盖面**（2026-10-24 修「搜不到终端、照片」时补的）。
///
/// 原来的 `AppSearchTests` 只锁了「列顶层 `.app`」这条契约，而它恰好对
/// 「只扫三个顶层目录 + 用文件名当显示名」这两处都是绿的——测试和 bug 并不矛盾，
/// 是覆盖面本身漏了。这里补的三组，一一对应三处真实失败：
/// 1. 系统把 `终端`、`活动监视器` 放在 `Utilities` 子目录，整目录没进扫描表；
/// 2. 系统 App 的**显示名是中文**（`照片`、`终端`），用文件名 `Photos` 搜不到；
/// 3. 反过来用户敲英文 `terminal` 也得能命中中文显示名的那一个。
final class AppSearchCoverageTests: XCTestCase {

    private func makeRoot(_ names: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-app-cover-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for name in names {
            try FileManager.default.createDirectory(at: root.appendingPathComponent("\(name).app"),
                                                    withIntermediateDirectories: true)
        }
        return root
    }

    // MARK: - 目录覆盖

    /// ★ 修 bug 的那一行：`Utilities` 不在扫描表里，终端就永远搜不到。
    func testDefaultDirectoriesIncludeTheFoldersSystemAppsLiveIn() {
        let paths = Set(AppCatalog.defaultDirectories.map(\.path))
        XCTAssertTrue(paths.contains("/Applications"), "第三方 App 的主目录")
        XCTAssertTrue(paths.contains("/System/Applications"), "系统 App 的主目录")
        XCTAssertTrue(paths.contains("/System/Applications/Utilities"),
                      "终端、活动监视器、磁盘工具都在这里——少了它用户就搜不到终端")
        XCTAssertTrue(paths.contains("/System/Library/CoreServices/Applications"),
                      "钥匙串访问、目录实用工具在这里")
    }

    /// 真机验收：修复前 `Terminal.app` 一条都不会出现。
    ///
    /// 用**英文名**做断言：中文系统上它的显示名是「终端」，但别名仍是 `Terminal`，
    /// 所以这条在任意语言环境下都成立。
    func testRealCatalogFindsTerminalWhichLivesUnderUtilities() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: "/System/Applications/Utilities/Terminal.app"),
                          "这台机器没有系统自带终端")
        let hits = AppCatalog.matches(AppCatalog.scan(), query: "terminal")
        XCTAssertEqual(hits.first?.url.lastPathComponent, "Terminal.app",
                       "搜 terminal 必须命中 /System/Applications/Utilities/Terminal.app")
    }

    /// 子目录进了扫描表，但**仍然不递归**：App 内部的 `Helper.app` 不许冒出来。
    func testAddingSubdirectoriesDidNotTurnScanIntoARecursiveWalk() throws {
        let root = try makeRoot(["Safari"])
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("Safari.app/Contents/Helpers/Updater.app")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let found = AppCatalog.scan(directories: [root], displayName: { _ in nil })
        XCTAssertEqual(found.map(\.name), ["Safari"], "Helper.app 不该被翻出来")
    }

    // MARK: - 显示名

    /// ★ 显示名取访达那个（`照片.app` → `照片`），文件名主干留作别名。
    func testScanUsesTheSpotlightNameAndKeepsTheFileStemAsAlias() throws {
        let root = try makeRoot(["Photos"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AppCatalog.scan(directories: [root], displayName: { _ in "照片" })
        XCTAssertEqual(found.map(\.name), ["照片"], "显示名必须是本地化名，不是文件名")
        XCTAssertEqual(found.first?.aliases, ["Photos"], "文件名主干要留下来当别名")
        XCTAssertEqual(found.first?.matchKeys, ["照片", "Photos"])
    }

    /// 读不到元数据（没索引 / 卷被排除）时退回文件名主干——只是变回英文名，不许空白。
    func testScanFallsBackToTheFileStemWhenThereIsNoSpotlightName() throws {
        let root = try makeRoot(["Photos"])
        defer { try? FileManager.default.removeItem(at: root) }
        let found = AppCatalog.scan(directories: [root], displayName: { _ in nil })
        XCTAssertEqual(found.map(\.name), ["Photos"])
        XCTAssertEqual(found.first?.aliases, [], "名字就是文件名时，别名列没有意义")
    }

    func testNormalizeDisplayNameStripsTheBundleSuffix() {
        XCTAssertEqual(AppCatalog.normalizeDisplayName("照片.app"), "照片")
        XCTAssertEqual(AppCatalog.normalizeDisplayName("Safari浏览器.app"), "Safari浏览器")
        XCTAssertEqual(AppCatalog.normalizeDisplayName("Terminal"), "Terminal")
        XCTAssertEqual(AppCatalog.normalizeDisplayName("  终端.app "), "终端", "首尾空白先剥掉再判后缀")
    }

    /// 空串、只剩后缀、纯空白都算读不到——否则结果列表里出现一行空白标题。
    func testNormalizeDisplayNameRejectsValuesThatWouldRenderBlank() {
        XCTAssertNil(AppCatalog.normalizeDisplayName(""))
        XCTAssertNil(AppCatalog.normalizeDisplayName(".app"))
        XCTAssertNil(AppCatalog.normalizeDisplayName("   "))
        XCTAssertNil(AppCatalog.normalizeDisplayName(nil))
    }

    // MARK: - 中英文都能搜

    func testLocalizedNameAndFileStemAreBothSearchable() {
        let photos = AppSearchCandidate(name: "照片",
                                        url: URL(fileURLWithPath: "/System/Applications/Photos.app"),
                                        aliases: ["Photos"])
        XCTAssertEqual(AppCatalog.matches([photos], query: "照片").map(\.name), ["照片"])
        XCTAssertEqual(AppCatalog.matches([photos], query: "photos").map(\.name), ["照片"])
        XCTAssertEqual(AppCatalog.matches([photos], query: "pho").map(\.name), ["照片"])
        XCTAssertTrue(AppCatalog.matches([photos], query: "outlook").isEmpty)
    }

    /// 名次取最好的那个：`Safari浏览器` 靠别名 `Safari` 整名命中该是 0，
    /// 不能因为显示名多了三个字就掉成前缀（1）——那会让它排到别的 App 后面。
    func testAliasExactMatchRanksZeroInsteadOfPrefix() {
        let safari = AppSearchCandidate(name: "Safari浏览器",
                                        url: URL(fileURLWithPath: "/Applications/Safari.app"),
                                        aliases: ["Safari"])
        XCTAssertEqual(AppCatalog.rank(for: safari, query: "Safari"), 0)
        XCTAssertEqual(AppCatalog.rank(for: safari, query: "safari浏览器"), 0)
        XCTAssertEqual(AppCatalog.rank(for: safari, query: "safar"), 1)
        XCTAssertNil(AppCatalog.rank(for: safari, query: "chrome"))
        XCTAssertNil(AppCatalog.rank(for: safari, query: "   "), "空查询不匹配任何东西")
    }

    /// ★ 结果行里的 rank 必须和排序用的是同一个值。
    ///
    /// 两处各算一套时，别名命中的那行会「排在第一位、rank 却写着 1」——
    /// 界面按 rank 显示「弱匹配」，而列表第一位就是它。
    @MainActor
    func testResultRowRankComesFromTheMatchedNameNotTheDisplayName() async {
        let safari = AppSearchCandidate(name: "Safari浏览器",
                                        url: URL(fileURLWithPath: "/Applications/Safari.app"),
                                        aliases: ["Safari"])
        let provider = AppSearchProvider(scan: { [safari] })
        var events: [ProviderEvent] = []
        await provider.search("safari", queryID: UUID()) { events.append($0) }
        XCTAssertEqual(events.last?.results.first?.name, "Safari浏览器", "显示名照旧用中文那个")
        XCTAssertEqual(events.last?.results.first?.rank, 0, "靠别名整名命中，rank 必须是 0")
    }

    // MARK: - 缓存

    /// 名字要走 Spotlight 元数据 ⇒ 一次全扫约 50ms，落在主线程上就是打字发黏。
    /// 连续敲字符必须复用上一次的清单。
    @MainActor
    func testProviderReusesTheCatalogAcrossKeystrokes() async {
        let counter = ScanCounter()
        let provider = AppSearchProvider(scan: {
            counter.bump()
            return [AppSearchCandidate(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))]
        })
        for text in ["s", "sa", "saf", "safa"] {
            await provider.search(text, queryID: UUID()) { _ in }
        }
        XCTAssertEqual(counter.count, 1, "4 次输入只该扫 1 次目录")
    }

    /// 但缓存必须真的会过期：新装的 App 不能永远不出现。
    @MainActor
    func testProviderRescansAfterTheCacheLifetime() async {
        let counter = ScanCounter()
        let provider = AppSearchProvider(cacheLifetime: 0, scan: {
            counter.bump()
            return [AppSearchCandidate(name: "Safari", url: URL(fileURLWithPath: "/Applications/Safari.app"))]
        })
        for text in ["s", "sa"] {
            await provider.search(text, queryID: UUID()) { _ in }
        }
        XCTAssertEqual(counter.count, 2, "寿命为 0 时每次都该重扫")
    }
}

/// 数扫描次数。`scan` 是 `@Sendable`，用引用型计数器；实际调用都发生在主 actor 上。
private final class ScanCounter: @unchecked Sendable {
    private(set) var count = 0
    func bump() { count += 1 }
}
