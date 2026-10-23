import XCTest
@testable import FlashFindCore

/// 本机「读范围」闸门（build 29 补，来自代码审核 BUG-112-01）。
///
/// 这一组守的是一个**只在收窄范围之后才出现**的缺口：
/// 用户先用「整台 Mac」搜到文件、AI 拿到 `file_id`，随后用户改成
/// 「只搜索指定文件夹」——旧 `file_id` 还能不能问出元数据。
///
/// ★ 判定必须是「不能」。搜索范围是用户当下表达的意思，不是一次性的过滤器：
/// 改了范围之后，AI 手里那些旧引用就该一起失效。
final class LocalReadScopeTests: XCTestCase {

    private let home = "/Users/me"
    private let work = URL(fileURLWithPath: "/Users/me/工作")
    private let archive = URL(fileURLWithPath: "/Users/me/归档")

    // MARK: - 纯判定

    /// 「整台 Mac」时范围不设限：用户选的就是全都在里面。
    func testWholeMacAllowsAnything() {
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/客户资料/合同.pdf",
                                            mode: .spotlight,
                                            folders: [work]))
        // 连一个文件夹都没挑也一样 —— 整台 Mac 的意义就是不靠这个列表。
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/etc/hosts",
                                            mode: .spotlight,
                                            folders: []))
    }

    func testPathInsideSelectedFolderIsAllowed() {
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/工作/2026/报告.pdf",
                                            mode: .selectedFolders,
                                            folders: [work]))
    }

    /// 文件夹自身也算范围内：用户选中的那一层目录本来就该能查。
    func testSelectedFolderItselfIsAllowed() {
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/工作",
                                            mode: .selectedFolders,
                                            folders: [work]))
    }

    func testPathOutsideSelectedFoldersIsRejected() {
        XCTAssertFalse(LocalReadScope.allows(absolutePath: "/Users/me/客户资料/合同.pdf",
                                             mode: .selectedFolders,
                                             folders: [work]))
        // 只有一个文件夹命中就够了：它在 `archive` 里。
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/归档/2025/x.pdf",
                                            mode: .selectedFolders,
                                            folders: [work, archive]))
        XCTAssertFalse(LocalReadScope.allows(absolutePath: "/Users/me/桌面/x.pdf",
                                             mode: .selectedFolders,
                                             folders: [work, archive]))
    }

    /// ★ 前缀相同但是兄弟目录：`工作备份` 不是 `工作` 里的东西。
    ///
    /// 只写 `hasPrefix(folder)` 的判定会把这一条放过去，而它看起来完全正常。
    func testSiblingSharingThePrefixIsRejected() {
        XCTAssertFalse(LocalReadScope.allows(absolutePath: "/Users/me/工作备份/旧报告.pdf",
                                             mode: .selectedFolders,
                                             folders: [work]))
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/工作备份/旧报告.pdf",
                                            mode: .selectedFolders,
                                            folders: [URL(fileURLWithPath: "/Users/me/工作备份")]))
    }

    /// 选了「只搜指定文件夹」却一个都没选：范围是空的，不是「全部」。
    ///
    /// ★ 这一条反过来的代价最大：用户清空列表的那一刻等于把 AI 的范围放大成全盘。
    func testEmptyFolderListRejectsEverything() {
        XCTAssertFalse(LocalReadScope.allows(absolutePath: "\(home)/工作/x.pdf",
                                             mode: .selectedFolders,
                                             folders: []))
    }

    /// 带 `..` 的路径先归一化再比：不能靠「字面不以文件夹开头」骗过判定。
    func testDotDotIsNormalisedBeforeComparison() {
        XCTAssertFalse(LocalReadScope.allows(absolutePath: "/Users/me/工作/../客户资料/a.pdf",
                                             mode: .selectedFolders,
                                             folders: [work]))
        XCTAssertTrue(LocalReadScope.allows(absolutePath: "/Users/me/归档/../工作/a.pdf",
                                            mode: .selectedFolders,
                                            folders: [work]))
    }

    /// ★ 选中的文件夹里放一个指向外面的软链，不能借此读到范围外。
    ///
    /// 只比字符串前缀的判定在这里会被绕过：字面上它确实「在文件夹下面」。
    func testSymbolicLinkEscapingTheFolderIsRejected() throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let target = outside.appendingPathComponent("secret.txt")
        try "x".write(to: target, atomically: true, encoding: .utf8)

        // 软链写在选中的文件夹内部，指向外面那个文件。
        let link = inside.appendingPathComponent("escape")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)

        XCTAssertFalse(LocalReadScope.allows(absolutePath: link.appendingPathComponent("secret.txt").path,
                                             mode: .selectedFolders,
                                             folders: [inside]))
    }

    // MARK: - 真 provider：闸门接上了没有

    /// 收窄范围之后，旧引用必须查不出来。
    ///
    /// 这条用真的 `LocalSearchProvider` 与真的文件系统，比结构断言硬：
    /// 断言的是「拿到的结论是 notFound」，不是「源码里出现了某个调用」。
    @MainActor
    func testProviderHidesMetadataOfFileOutsideCurrentFolders() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside")
        let outside = root.appendingPathComponent("outside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let file = outside.appendingPathComponent("旧报告.pdf")
        try "0123456789".write(to: file, atomically: true, encoding: .utf8)

        let provider = LocalSearchProvider()
        provider.mode = .selectedFolders
        provider.folders = [inside]

        let outcome = await provider.metadata(
            canonicalRelativePath: try RelativePath.canonical(file.path))

        // ★ 必须是 notFound 而不是 unavailable：
        //   报「这次问不出来」会让 Agent 让用户去检查一台其实好好的 Mac，
        //   而报「这个文件不在了」才是对的——它在当前范围里确实不存在。
        XCTAssertEqual(outcome, .notFound)
    }

    /// 范围内的文件照常给元数据：闸门不能顺手把正常查询也关掉。
    @MainActor
    func testProviderStillAnswersInsideCurrentFolders() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let inside = root.appendingPathComponent("inside")
        try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        let file = inside.appendingPathComponent("报告.pdf")
        try "0123456789".write(to: file, atomically: true, encoding: .utf8)

        let provider = LocalSearchProvider()
        provider.mode = .selectedFolders
        provider.folders = [inside]

        let outcome = await provider.metadata(
            canonicalRelativePath: try RelativePath.canonical(file.path))

        guard case .found(let metadata) = outcome else {
            return XCTFail("范围内的文件必须能查出元数据，实际是 \(outcome)")
        }
        XCTAssertEqual(metadata.name, "报告.pdf")
        XCTAssertEqual(metadata.sizeBytes, 10)
    }

    /// 「整台 Mac」时不做任何限制。
    @MainActor
    func testProviderAnswersAnythingUnderWholeMacMode() async throws {
        let root = try makeScratch()
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("随便一个.pdf")
        try "abc".write(to: file, atomically: true, encoding: .utf8)

        let provider = LocalSearchProvider()
        provider.mode = .spotlight
        // 故意留着一个完全无关的文件夹：整台 Mac 模式下它不该起作用。
        provider.folders = [URL(fileURLWithPath: "/Users/me/工作")]

        let outcome = await provider.metadata(
            canonicalRelativePath: try RelativePath.canonical(file.path))
        guard case .found = outcome else {
            return XCTFail("整台 Mac 模式下不该有任何范围限制，实际是 \(outcome)")
        }
    }

    // MARK: - 工具

    private func makeScratch() throws -> URL {
        // ★ 用 `resolvingSymlinksInPath` 之后的路径：macOS 的临时目录本身
        //   就在 `/var → /private/var` 这条软链下面，不先解开的话，
        //   判定用的规范化路径与建文件用的路径会是两串不同的字面量。
        let raw = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff-scope-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: raw, withIntermediateDirectories: true)
        return raw.resolvingSymlinksInPath()
    }
}
