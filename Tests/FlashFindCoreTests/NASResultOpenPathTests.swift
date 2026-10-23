import XCTest
@testable import FlashFindCore

/// 只用于构造 Provider 的空 Bridge：这些用例只测路径解析，不触碰协议。
@MainActor private final class OpenPathNoopBridge: MyNASBridgeTransport {
    func request(_ command: String, sourceID: String, queryID: String,
                 fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        throw FlashFindError.message("noop")
    }
}

/// 锁定真实故障：**能搜到、点不开**（实机反馈）。
///
/// 用户点开 NAS 结果时弹出「无法打开文件 / Unsafe relative path」。
/// 根因不是公网域名、也不是挂载，而是**路径切法**：
///
///   `NASLocator.owningRoot` 返回的授权根**带前导斜杠**（`/示例共享`），
///   而三处调用只做 `path.dropFirst(root.count)`，切完还剩一个前导斜杠
///   （`/示例资料/x.pdf`）；`RelativePath.validate` 第一条就拒绝
///   前导斜杠。于是**每一个** NAS 结果在打开/定位时都抛错——
///   与网络环境、品牌、共享名都无关，是必然失败。
@MainActor
final class NASResultOpenPathTests: XCTestCase {

    private func locator(_ scopes: [String]) -> NASLocator {
        let config = NASSourceConfig(host: "nas.example.com", port: 5001,
                                     username: "u", scopes: scopes)
        return NASSearchProvider(bridge: OpenPathNoopBridge(), config: config, port: 5001).locatorSnapshot
    }

    // MARK: - 切根

    /// 核心回归：切完授权根后不能再带前导斜杠。
    func testRelativePathStripsLeadingSlashAfterRoot() {
        XCTAssertEqual(RelativePath.relative("/示例共享/示例资料/a.pdf", under: "/示例共享"),
                       "示例资料/a.pdf")
        // 含中文与空格的真实文件名
        XCTAssertEqual(RelativePath.relative("/示例共享/质量手册/第 6.2 版.pdf", under: "/示例共享"),
                       "质量手册/第 6.2 版.pdf")
        // 恰好就是根本身 → 空串。validate 会拒，语义正确：共享根不是文件。
        XCTAssertEqual(RelativePath.relative("/示例共享", under: "/示例共享"), "")
    }

    /// 端到端走一遍真实链路：owningRoot → relative → validate。
    /// 这就是修复前必然失败的那条链。
    func testRealisticResultPathPassesValidation() throws {
        let locator = locator(["/示例共享"])
        let path = "/示例共享/示例资料/供应商质量手册.pdf"
        let root = try XCTUnwrap(locator.owningRoot(path: path))
        XCTAssertEqual(root, "/示例共享")

        let inside = RelativePath.relative(path, under: root)
        XCTAssertFalse(inside.hasPrefix("/"), "切完不能再带前导斜杠，否则 validate 必抛")
        XCTAssertNoThrow(try RelativePath.validate(inside))

        // 把修复前的写法钉住：它也**必须**抛。
        // 这条断言的作用不是测它，而是记录「为什么会有这个 bug」——
        // 如果哪天有人把 relative() 改回 dropFirst，上面两条会先红。
        XCTAssertThrowsError(try RelativePath.validate(String(path.dropFirst(root.count))))
    }

    /// 多搜索位置时，相对段要相对**结果实际所属**的那个共享算。
    func testRelativePathUsesOwningRootPerShare() throws {
        let locator = locator(["/示例共享", "/docker"])
        let root = try XCTUnwrap(locator.owningRoot(path: "/docker/compose/nginx.yml"))
        XCTAssertEqual(root, "/docker")
        XCTAssertEqual(RelativePath.relative("/docker/compose/nginx.yml", under: root),
                       "compose/nginx.yml")
    }

    /// 兄弟共享名不能被误切：`/示例共享2` 不归属 `/示例共享`。
    /// relative() 只负责切、不负责判归属，所以归属判断必须靠 owningRoot 的整段比对。
    func testSiblingShareIsNotMistakenForOwningRoot() {
        let locator = locator(["/示例共享"])
        XCTAssertNil(locator.owningRoot(path: "/示例共享2/a.pdf"))
        // 顺带确认切法本身不会把 /示例共享2 切出 "2/a.pdf" 这种错觉结果——
        // 只要调用方走 owningRoot，就到不了 relative()。
        XCTAssertFalse(locator.contains(path: "/示例共享2/a.pdf"))
    }

    // MARK: - 挂载侧解析

    /// 真实目录 + 中文文件名，走一遍挂载侧的解析。
    /// 修复前 mountService.resolve 收到的是 "/示例资料/…"，会被 validate 拒收。
    func testMountResolveAcceptsRelativePathFromLocator() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ff-open-\(UUID().uuidString)", isDirectory: true)
        let share = base.appendingPathComponent("示例共享", isDirectory: true)
        let folder = share.appendingPathComponent("示例资料", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let file = folder.appendingPathComponent("质量手册.pdf")
        try Data("pdf".utf8).write(to: file)

        let locator = locator(["/示例共享"])
        let path = "/示例共享/示例资料/质量手册.pdf"
        let root = try XCTUnwrap(locator.owningRoot(path: path))
        let inside = RelativePath.relative(path, under: root)
        XCTAssertEqual(inside, "示例资料/质量手册.pdf")

        let service = SMBMountService()
        let resolved = try await service.resolve(relativePath: inside, under: share)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().standardizedFileURL.path,
                       file.resolvingSymlinksInPath().standardizedFileURL.path)
    }

    /// 无挂载态的定位入口同样不能因为前导斜杠而失败。
    /// 这里用一个真实临时挂载根来喂 `resolve(_:in:)`，覆盖结果行 canOpen 判定走的路径。
    func testResolveInMountsAcceptsMountedFile() async throws {
        let fm = FileManager.default
        let base = fm.temporaryDirectory
            .appendingPathComponent("ff-mount-\(UUID().uuidString)", isDirectory: true)
        let shareRoot = base.appendingPathComponent("示例共享", isDirectory: true)
        let folder = shareRoot.appendingPathComponent("质量共享", isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: base) }

        let file = folder.appendingPathComponent("手册.pdf")
        try Data("pdf".utf8).write(to: file)

        let config = NASSourceConfig(host: "nas.example.com", port: 5001,
                                     username: "u", scopes: ["/示例共享"])
        let provider = NASSearchProvider(bridge: OpenPathNoopBridge(), config: config, port: 5001)
        // 必须取**同一个实例**的 locator：sourceID 由 config.id 推导，
        // 而 config.id 默认是新建 UUID，两个实例的 sourceID 不会相等。
        let locator = provider.locatorSnapshot
        let row = SearchResult(id: "r1", name: "手册.pdf",
                               relativePath: "/示例共享/质量共享/手册.pdf",
                               sourceID: locator.sourceID, sourceName: "NAS",
                               kind: "file", size: nil, localURL: nil)
        let mount = SMBMountCandidate(id: "m1", host: "nas.example.com", shareName: "示例共享",
                                      mountRoot: shareRoot, username: "u",
                                      safeSMBURL: "smb://nas.example.com/示例共享")
        let resolved = try provider.resolve(row, in: [mount], snapshot: locator)
        XCTAssertEqual(resolved.resolvingSymlinksInPath().standardizedFileURL.path,
                       file.resolvingSymlinksInPath().standardizedFileURL.path)
    }
}
