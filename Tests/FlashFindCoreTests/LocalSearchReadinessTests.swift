import XCTest
@testable import FlashFindCore

/// 本机侧的搜索就绪：Spotlight 可用性、已选文件夹遍历、SMB 挂载解析、来源配置判定。
final class LocalSearchReadinessTests: XCTestCase {
    private func root() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-local-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testDisabledSpotlightIsNotEmptySuccess() {
        let result = SpotlightAvailability.parse("Spotlight server is disabled.", exitCode: 0)
        XCTAssertEqual(result.state, .disabled)
        XCTAssertTrue(result.message.contains("已关闭"))
        XCTAssertEqual(SpotlightAvailability.parse("/:\n Indexing disabled.", exitCode: 0).state, .disabled)
        XCTAssertEqual(SpotlightAvailability.parse("/:\n Indexing enabled.", exitCode: 0).state, .available)
        XCTAssertEqual(SpotlightAvailability.parse("error: unavailable", exitCode: 1).state, .unavailable)
    }

    /// ★ 索引正常时设置页不该出现这一行（`message` 仍要留着给搜索失败当原因）。
    ///
    /// 把「索引已启用」也摆进设置页，等于每一台正常 Mac 的搜索页上都挂着
    /// 一行永远不变的灰字——提醒只有在真的有问题时才值得占这个位置。
    func testOnlyProblemStatesDeserveASettingsNote() {
        let enabled = SpotlightAvailability.parse("/:\n Indexing enabled.", exitCode: 0)
        XCTAssertNil(enabled.attentionMessage, "索引正常不需要提醒")
        XCTAssertFalse(enabled.message.isEmpty, "message 要留给搜索失败当原因，不能一起删掉")

        XCTAssertEqual(SpotlightAvailability.parse("Spotlight server is disabled.", exitCode: 0).attentionMessage,
                       SpotlightAvailability.parse("Spotlight server is disabled.", exitCode: 0).message)
        XCTAssertNotNil(SpotlightAvailability.parse("error: unavailable", exitCode: 1).attentionMessage,
                        "连不上/认不出的索引状态必须让用户知道")
    }
    func testSelectedDirectoryRequiresOptInAndRejectsRoot() {
        XCTAssertThrowsError(try LocalFolderSearch.search("知识库", folders: []))
        XCTAssertThrowsError(try LocalFolderSearch.search("知识库", folders: [URL(fileURLWithPath: "/")]))
    }
    func testFilenameUnicodeANDAndLiteralPunctuation() throws {
        let directory = try root()
        for name in ["知识库 文档.md", "知识库资料.md", "literal%_知识库.txt", "其他.txt"] {
            try Data("fixture".utf8).write(to: directory.appendingPathComponent(name))
        }
        let result = try LocalFolderSearch.search("知识库 文档", folders: [directory])
        XCTAssertEqual(result.results.map(\.name), ["知识库 文档.md"])
        XCTAssertTrue(result.warnings.isEmpty)
        XCTAssertEqual(try LocalFolderSearch.search("%_", folders: [directory]).results.map(\.name), ["literal%_知识库.txt"])
        XCTAssertTrue(try LocalFolderSearch.search("不存在", folders: [directory]).results.isEmpty)
    }
    func testSymlinkCannotEscapeSelectedFolder() throws {
        let base = try root(), selected = base.appendingPathComponent("selected"), outside = base.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: selected, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data().write(to: outside.appendingPathComponent("知识库禁入.txt"))
        try FileManager.default.createSymbolicLink(at: selected.appendingPathComponent("知识库link"), withDestinationURL: outside)
        XCTAssertTrue(try LocalFolderSearch.search("知识库", folders: [selected]).results.isEmpty)
        XCTAssertThrowsError(try LocalFolderSearch.search("知识库", folders: [selected.appendingPathComponent("知识库link")]))
    }
    func testBudgetIsExplicitAndOverlappingScopesDoNotDuplicate() throws {
        let directory = try root()
        try Data("知识库".utf8).write(to: directory.appendingPathComponent("知识库.txt"))
        let truncated = try LocalFolderSearch.search("知识库", folders: [directory], maximumEntries: 0)
        XCTAssertFalse(truncated.warnings.isEmpty)
        XCTAssertEqual(truncated.visitedCount, 0)
        XCTAssertEqual(try LocalFolderSearch.search("知识库", folders: [directory, directory]).results.count, 1)
    }
    func testCancelledTraversalStopsBeforeReadingEntries() async throws {
        let directory = try root()
        try Data("知识库".utf8).write(to: directory.appendingPathComponent("知识库.txt"))
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try LocalFolderSearch.search("知识库", folders: [directory])
        }
        do { _ = try await task.value; XCTFail("Cancelled search succeeded") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
    func testMountParsingDoesNotRetainPasswordOrInferHTTPS() throws {
        let candidate = try XCTUnwrap(SMBMountCandidate.parse(origin: "//alice:do-not-retain@nas.example/Team%20Share", mountPath: "/Volumes/Team Share"))
        XCTAssertEqual(candidate.host, "nas.example")
        XCTAssertEqual(candidate.shareName, "Team Share")
        XCTAssertEqual(candidate.username, "alice")
        XCTAssertFalse(candidate.safeSMBURL.contains("alice"))
        XCTAssertFalse(candidate.safeSMBURL.contains("do-not-retain"))
        XCTAssertEqual(URL(string: candidate.safeSMBURL)?.scheme, "smb")
        XCTAssertNil(SMBMountCandidate.parse(origin: "//alice@nas/share/subfolder", mountPath: "/Volumes/x"))
    }
    func testBlankNASIsNotConfiguredOrEnabled() {
        let blank = NASConnectionProfile()
        XCTAssertFalse(blank.enabled)
        XCTAssertFalse(blank.isConfigured)
        XCTAssertFalse(NASConnectionProfile(address: "https://nas.example", username: "").isConfigured)
        XCTAssertTrue(NASConnectionProfile(address: "https://nas.example:9543", username: "alice").isConfigured)
    }
}
