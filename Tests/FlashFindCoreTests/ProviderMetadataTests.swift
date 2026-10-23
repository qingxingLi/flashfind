import XCTest
@testable import FlashFindCore

/// Phase 6.4b-1：两个 provider 的**直查实现本身**（不是执行链）。
///
/// 执行链那一层在 `GetMetadataExecutionTests`；这一组盯的是适配器边界上
/// 真正会出错的那三件事：
///
/// ```text
/// ① 匹配必须是「整段、精确、大小写敏感」—— 不是 contains / hasPrefix / 忽略大小写
/// ② Unicode 按 FileID 的规则比（NFC），不是按设备给的原始字节硬比
/// ③ 设备没给的字段是 nil，不是 0
/// ```
///
/// ★ 本机那条用**真文件**（真 `stat`），NAS 那条用**真 `NASSearchProvider`**
/// + 假核心（报文形状与 Dart `row()` 一致）。被测的是产品代码，假的只有
/// 「字节从哪来」。
@MainActor
final class ProviderMetadataTests: XCTestCase {

    // MARK: - 本机

    private var sandbox: URL!

    override func setUpWithError() throws {
        sandbox = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-prov-meta-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: sandbox, withIntermediateDirectories: true)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: sandbox)
    }

    /// 真文件：大小、时间、类型都来自一次 `stat`。
    func testLocalMetadataComesFromTheRealFile() async throws {
        let file = sandbox.appendingPathComponent("预算 2026.xlsx")
        try Data(count: 4096).write(to: file)
        let provider = LocalSearchProvider()
        let path = String(file.path.dropFirst())   // 剥掉前导 `/`，与 canonical 一致

        guard case .found(let metadata) = await provider.metadata(canonicalRelativePath: path) else {
            return XCTFail("真文件必须是 found")
        }
        XCTAssertEqual(metadata.kind, .file)
        XCTAssertEqual(metadata.sizeBytes, 4096)
        XCTAssertNotNil(metadata.modified)
        XCTAssertEqual(metadata.name, "预算 2026.xlsx")
    }

    /// 0 字节文件必须是 `0`，不是 `nil`。
    ///
    /// ★ 与「未知大小 → nil」是**两件**事，两条用例都得在。
    func testAnEmptyLocalFileReportsZero() async throws {
        let file = sandbox.appendingPathComponent("空.txt")
        try Data().write(to: file)
        let provider = LocalSearchProvider()

        guard case .found(let metadata) = await provider.metadata(
            canonicalRelativePath: String(file.path.dropFirst())) else {
            return XCTFail("空文件也是存在的")
        }
        XCTAssertEqual(metadata.sizeBytes, 0)
        XCTAssertEqual(metadata.kind, .file)
    }

    /// 真文件夹：`size_bytes` 是 nil（目录项大小不是文件大小）。
    func testALocalFolderHasNoSize() async throws {
        let folder = sandbox.appendingPathComponent("项目")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let provider = LocalSearchProvider()

        guard case .found(let metadata) = await provider.metadata(
            canonicalRelativePath: String(folder.path.dropFirst())) else {
            return XCTFail("目录也是存在的")
        }
        XCTAssertEqual(metadata.kind, .folder)
        XCTAssertNil(metadata.sizeBytes, "目录不该给一个看着像文件大小的数字")
        XCTAssertNotNil(metadata.modified)
    }

    /// 被删掉的文件 → `notFound`，**不是** `unavailable`。
    ///
    /// ★ 合成 `.unavailable` 的话，用户会以为这台 Mac 不能搜了，
    /// 而其实只是那个文件没了。
    func testAMissingLocalFileIsNotFound() async throws {
        let provider = LocalSearchProvider()
        let outcome = await provider.metadata(canonicalRelativePath: "不存在/没有这个文件.pdf")
        XCTAssertEqual(outcome, .notFound)
    }

    // MARK: - NAS

    /// 假核心：按路径回放一个目录批次（形状与 Dart `row()` 一致）。
    @MainActor private final class MetadataBridge: MyNASBridgeTransport {
        var files: [[String: Any]] = []
        private(set) var listed: [String] = []

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            switch command {
            case "discover":
                return ["event": "capabilities"]
            case "login":
                return ["event": "authState", "state": "scopeReady"]
            case "list":
                listed.append((fields["path"] as? String) ?? "")
                return ["event": "batch", "files": files]
            default:
                return ["event": "controlAck"]
            }
        }
    }

    private func nasProvider(files: [[String: Any]],
                             bridgeOut: MetadataBridge) -> NASSearchProvider {
        let config = NASSourceConfig(id: "src_nas_work", name: "Work NAS", vendor: .synology,
                                     host: "nas-work.example", port: 5001, username: "u",
                                     scopes: ["/共享A"])
        bridgeOut.files = files
        return NASSearchProvider(bridge: bridgeOut, config: config, port: 5001)
    }

    private func row(name: String, path: String, fileType: String = "file",
                     size: Int? = 1024, modified: String? = nil) -> [String: Any] {
        var entry: [String: Any] = ["id": "src_nas_work:" + path, "name": name, "path": path,
                                    "fileType": fileType, "sourceID": "src_nas_work",
                                    "sourceName": "Work NAS", "sourceType": "nas"]
        if let size { entry["size"] = size } else { entry["size"] = NSNull() }
        if let modified { entry["modifiedDate"] = modified }
        return entry
    }

    /// 列父目录 → 精确命中。
    func testNasMetadataPicksTheExactEntry() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [
            row(name: "预算.xlsx", path: "/共享A/预算.xlsx"),
            row(name: "旧预算.xlsx", path: "/共享A/旧预算.xlsx"),
            row(name: "目录", path: "/共享A/目录", fileType: "folder", size: nil),
        ], bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        guard case .found(let metadata) = await provider.metadata(
            canonicalRelativePath: "共享A/预算.xlsx") else {
            return XCTFail("目录里明明有这一条")
        }
        XCTAssertEqual(metadata.name, "预算.xlsx")
        XCTAssertEqual(metadata.kind, .file)
        XCTAssertEqual(metadata.sizeBytes, 1024)
        // ★ 问的是**父目录**，不是目标自己：没有来源有 stat。
        XCTAssertEqual(bridge.listed, ["/共享A"])
    }

    /// 根下第一层时父目录就是 `/`。
    func testTheRootListingUsesSlash() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: "共享A", path: "/共享A", fileType: "folder")],
                                   bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        _ = await provider.metadata(canonicalRelativePath: "共享A")
        XCTAssertEqual(bridge.listed, ["/"])
    }

    /// 目录里没有那一条 → `notFound`（来源本身是好的）。
    func testAMissingEntryIsNotFound() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: "别的文件.pdf", path: "/共享A/别的文件.pdf")],
                                   bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let outcome = await provider.metadata(canonicalRelativePath: "共享A/没有这个.pdf")
        XCTAssertEqual(outcome, .notFound, "父目录列出来了、里面没有 = 这个文件不在了")
    }

    /// 大小写不同就是**另一个文件**，不许含糊匹配。
    ///
    /// ★ 这是「把 == 换成 caseInsensitiveCompare」那个变异的直接抓手：
    /// `Report.pdf` 与 `report.pdf` 是两个文件、两个 id。
    func testCaseIsSignificantSoThereIsNoFuzzyMatch() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: "Report.pdf", path: "/共享A/Report.pdf")],
                                   bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let outcome = await provider.metadata(canonicalRelativePath: "共享A/report.pdf")
        XCTAssertEqual(outcome, .notFound, "大小写不同的名字不许匹配上")
    }

    /// 前缀相同也不算命中（`预算.xlsx` 不许被 `预算.xlsx.bak` 顶替，反之亦然）。
    func testAPrefixIsNotAMatch() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: "预算.xlsx.bak", path: "/共享A/预算.xlsx.bak")],
                                   bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        let outcome = await provider.metadata(canonicalRelativePath: "共享A/预算.xlsx")
        XCTAssertEqual(outcome, .notFound, "前缀相同的名字不许匹配上")
    }

    /// 设备给 NFD、库里存 NFC：仍然要命中（按 FileID 的规则比）。
    ///
    /// ★ 少了这条，某台给 NFD 的 SMB 设备会让它的文件全部变成假
    /// `file_not_found`——文件明明在，就是匹配不上。
    func testTheDeviceMayReturnEitherUnicodeForm() async throws {
        let nfc = "café.txt"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(nfc.utf8.count, nfd.utf8.count, "这个用例依赖两种形态真的不同")

        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: nfd, path: "/共享A/" + nfd)], bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        // 库里存的是 NFC（canonical 归一过），设备回的是 NFD。
        guard case .found(let metadata) = await provider.metadata(
            canonicalRelativePath: "共享A/" + nfc) else {
            return XCTFail("NFD 与 NFC 是同一个文件，必须命中")
        }
        XCTAssertEqual(metadata.name, nfd)
    }

    /// 设备没给大小 → `nil`，不是 0（WebDAV 的 `sizeKnown` 如实带出来）。
    func testADeviceThatGivesNoSizeYieldsNil() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [row(name: "空.txt", path: "/共享A/空.txt", size: nil)],
                                   bridgeOut: bridge)
        try await provider.discover()
        try await provider.login(account: "u", password: "p")

        guard case .found(let metadata) = await provider.metadata(
            canonicalRelativePath: "共享A/空.txt") else {
            return XCTFail("文件在")
        }
        XCTAssertNil(metadata.sizeBytes, "设备没给大小必须是 nil，不能折成 0")
    }

    /// 没连上就是 `unavailable`，不许先去问设备。
    func testADisconnectedSourceIsUnavailableNotNotFound() async throws {
        let bridge = MetadataBridge()
        let provider = nasProvider(files: [], bridgeOut: bridge)
        // 刻意**不** discover/login：`ready` 保持 false。
        let outcome = await provider.metadata(canonicalRelativePath: "共享A/预算.xlsx")
        XCTAssertEqual(outcome, .unavailable)
        XCTAssertTrue(bridge.listed.isEmpty, "没连上就不该发请求：\(bridge.listed)")
    }
}
