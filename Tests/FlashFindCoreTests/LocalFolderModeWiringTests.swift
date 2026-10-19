import XCTest
@testable import FlashFindCore

/// 「已选文件夹」模式有没有真的接上目录遍历（OSS-08）。
///
/// ## 这个缺陷长什么样
///
/// 界面上写死着两种承诺：`LocalSearchMode.selectedFolders.title`
/// 是「已选文件夹（**无需系统索引**）」，选项小字是「只在你挑的文件夹里找，
/// **不动系统索引**」；`SpotlightAvailability` 在系统索引关着时还**主动引导**
/// 用户切到这个模式。而 `LocalFolderSearch` 那 123 行遍历实现——符号链接不跟随、
/// 越界路径跳过、时间/数量双上限、只匹配文件名——产品代码里一个调用点都没有，
/// 只有测试在调它。
///
/// 于是用户按我们的提示切到「已选文件夹」，设置页显示没问题，一搜就失败。
///
/// ## 为什么这里的目录要真建
///
/// 同目录的 `PMCLI003Tests` 要求显式给 `FF_CLI003_FIXTURE_ROOT`，拿不到就 skip。
/// 这里**不能**沿用那个约定：被 skip 的测试在红证里不算数（变异改了源码它也
/// 不会变红），等于没锁住。所以在系统临时目录下真建真删。
@MainActor
final class LocalFolderModeWiringTests: XCTestCase {

    // MARK: - 脚手架

    private var scratchRoot: URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-foldermode", isDirectory: true)
    }

    /// 建一个**名字里不含任何测试关键词**的空目录。
    ///
    /// 目录名用 UUID 是刻意的：`LocalFolderSearch` 会先判断搜索根自身的名字
    /// 是否命中，名字里带「知识库」的话根目录会作为 directory 结果进来，
    /// 断言就分不清「找到了文件」和「匹配到了根目录」。
    private func scratch() throws -> URL {
        let root = scratchRoot.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func cleanUpScratch() { try? FileManager.default.removeItem(at: scratchRoot) }

    private func write(_ name: String, in directory: URL) throws {
        try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
    }

    private func events(of provider: LocalSearchProvider, _ text: String) async -> [ProviderEvent] {
        var collected: [ProviderEvent] = []
        await provider.search(text, queryID: UUID()) { collected.append($0) }
        return collected
    }

    private func provider(mode: LocalSearchMode, folders: [URL]) -> LocalSearchProvider {
        let provider = LocalSearchProvider()
        provider.mode = mode
        provider.folders = folders
        return provider
    }

    // MARK: - 文件夹模式必须真的遍历

    func testSelectedFoldersModeTraversesTheChosenDirectory() async throws {
        let directory = try scratch()
        defer { cleanUpScratch() }
        try write("知识库.txt", in: directory)

        let result = await events(of: provider(mode: .selectedFolders, folders: [directory]), "知识库").last

        XCTAssertEqual(result?.state, .completed, "文件夹模式不该失败——它根本不依赖系统索引")
        XCTAssertEqual(result?.results.map(\.name), ["知识库.txt"],
                      "临时目录不在 Spotlight 索引里，只有真遍历才找得到")
    }

    /// ★ 结果的来源名必须标明「已选文件夹」。
    ///
    /// 这条断言的作用是**指认代码走了哪条路**：`LocalFolderSearch` 产出
    /// `本机·已选文件夹`，Spotlight 那侧是「本机」。未接上时无论 Spotlight
    /// 是成功还是失败，都不会出现这个来源名——所以它比「有结果」更能钉死缺陷。
    func testSelectedFoldersResultsAreMarkedAsFolderScope() async throws {
        let directory = try scratch()
        defer { cleanUpScratch() }
        try write("知识库.txt", in: directory)

        let result = await events(of: provider(mode: .selectedFolders, folders: [directory]), "知识库").last

        XCTAssertEqual(result?.results.first?.sourceName, "本机·已选文件夹")
    }

    /// 文件夹模式的范围校验要透出来，不能因为「反正没接」而静默走全盘。
    func testSelectedFoldersModeRejectsFileSystemRoot() async throws {
        defer { cleanUpScratch() }
        let result = await events(of: provider(mode: .selectedFolders, folders: [URL(fileURLWithPath: "/")]),
                                  "知识库").last

        XCTAssertEqual(result?.state, .failed)
        XCTAssertTrue(result?.message?.contains("文件系统根目录") == true,
                      "拿到的却是：\(result?.message ?? "无")")
    }

    /// 一个文件夹都没选时，必须说清楚「不会自动扫描全盘」。
    ///
    /// 只说「请选择」会让人以为不选也能搜，于是永远搜不到东西。
    func testSelectedFoldersWithoutAnyFolderSaysSo() async throws {
        defer { cleanUpScratch() }
        let result = await events(of: provider(mode: .selectedFolders, folders: []), "知识库").last

        XCTAssertEqual(result?.state, .failed)
        XCTAssertTrue(result?.message?.contains("不会自动扫描全盘") == true,
                      "拿到的却是：\(result?.message ?? "无")")
    }

    // MARK: - 格式过滤

    /// 「名称 + 格式」是主打功能，文件夹模式下不能只剩名字那一半。
    ///
    /// 格式词由 `SearchQueryParser` 剥出去（keywords 里没有 `ppt`），
    /// 所以漏掉 extensions 不会误伤——它表现为**格式限制静默失效**：
    /// 搜「报告 ppt」会把 .docx 一起端上来。
    func testFolderModeHonorsFormatFilter() async throws {
        let directory = try scratch()
        defer { cleanUpScratch() }
        try write("报告.pptx", in: directory)
        try write("报告.docx", in: directory)
        try write("报告.md", in: directory)

        let result = await events(of: provider(mode: .selectedFolders, folders: [directory]), "报告 ppt").last

        XCTAssertEqual(result?.results.map(\.name), ["报告.pptx"])
    }

    /// 只给格式词（搜「ppt」）也要能用，不该因为关键词为空就返回空。
    func testFolderModeAcceptsFormatOnlyQuery() async throws {
        let directory = try scratch()
        defer { cleanUpScratch() }
        try write("季度报告.pptx", in: directory)
        try write("季度报告.docx", in: directory)

        let result = await events(of: provider(mode: .selectedFolders, folders: [directory]), "ppt").last

        XCTAssertEqual(result?.results.map(\.name), ["季度报告.pptx"])
    }

    // MARK: - 哨兵：另一条路不受影响

    /// Spotlight 模式不许被这批改动带偏。
    ///
    /// 这条在修复前后**都应该是绿的**——它守的是「别把整台 Mac 那条路也改坏」。
    /// 之所以不断言 Spotlight 一定成功（那取决于机器索引状态，测试里控不住），
    /// 只断言它绝不冒充文件夹模式的结果。
    func testSpotlightModeDoesNotPretendToBeFolderScope() async throws {
        let directory = try scratch()
        defer { cleanUpScratch() }
        try write("知识库.txt", in: directory)

        let result = await events(of: provider(mode: .spotlight, folders: [directory]), "知识库").last

        XCTAssertNotEqual(result?.results.first?.sourceName, "本机·已选文件夹",
                         "整台 Mac 模式不该产出文件夹遍历的结果")
    }

    // MARK: - 取消

    /// 取消必须能传到后台那次遍历。
    ///
    /// ★ `Task.detached` **不继承**调用方的取消，所以 provider 必须自己握住句柄；
    /// 否则输入框一改就作废的那次搜索仍会在后台跑满 3 秒预算，而界面早已切到新查询。
    ///
    /// 这条扫源码而不是测时序：异步取消的时序在测试里控不住，能稳定断言的只有
    /// 「`cancel` 里有这一句」。扫之前先去掉整行注释，免得谁在注释里提一句就算通过。
    func testCancellationReachesTheBackgroundTraversal() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/LocalSearchProvider.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        XCTAssertTrue(code.contains("final class LocalSearchProvider"),
                      "没读到 LocalSearchProvider.swift，下面的断言会假绿")
        XCTAssertTrue(code.contains("folderTask?.cancel()"),
                      "取消必须传到后台遍历，否则作废的那次搜索会继续跑满预算")
    }

    // MARK: - 整台 Mac 不许被残留的旧文件夹框住

    /// 从「已选文件夹」切回「整台 Mac」之后，全盘搜索不能被那几个旧目录限制。
    ///
    /// `mode` 只决定**走哪条路**，`folders` 却是 provider 上的**状态**：
    /// 切回全盘时它并不清空（用户切回去还要用），于是只要 `searchWithSpotlight`
    /// 顺手把 `folders` 转发给 `SpotlightProvider`，
    /// `NSMetadataQuery.searchScopes` 就从「本机全盘」缩成那几个旧目录 ——
    /// 界面写着「整台 Mac」，实际只在旧文件夹里找，用户搜全盘必然空手而归。
    ///
    /// 为什么这条只能扫源码：真正的差别要一台开着索引的 Mac 才看得出来
    /// （把 `searchScopes` 缩到临时目录后结果就空了），单元测试里控不住。
    /// 能稳定钉住的是「这一分支根本不读 `folders`」这条结构事实。
    func testWholeMacSearchDoesNotForwardResidualFolders() throws {
        let source = try String(contentsOf: sourceRoot
            .appendingPathComponent("Sources/FlashFindCore/LocalSearchProvider.swift"), encoding: .utf8)
        let code = codeOnly(source)
        XCTAssertTrue(code.contains("final class LocalSearchProvider"),
                      "没读到 LocalSearchProvider.swift，下面的断言会假绿")
        guard let block = braceBlock(after: "private func searchWithSpotlight(", in: code) else {
            return XCTFail("找不到 searchWithSpotlight，下面的断言会假绿")
        }
        XCTAssertTrue(block.contains("provider.search(parsed.keywords, extensions: parsed.extensions)"),
                      "整台 Mac 那一路要按「只给关键词与格式」调 Spotlight")
        XCTAssertFalse(block.contains("folders"),
                       "★ 整台 Mac 分支不许读 folders：残留的旧文件夹会把 searchScopes 缩小，界面写着全盘却只搜几个目录")
    }

    // MARK: - 源码结构小工具

    private var sourceRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    }

    /// 去掉整行注释，免得谁在注释里提一句就算通过。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 取 marker 之后第一个花括号块（括号配平），把断言限定在目标函数体内 ——
    /// 整文件 `contains` 会被文件里同名的另一处满足。
    private func braceBlock(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text.range(of: "{", range: markerRange.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open.lowerBound...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }
}
