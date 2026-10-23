import XCTest
import CryptoKit
@testable import FlashFindCore

/// Phase 6.3b-3：**NAS source root / share-root 语义契约**（fixture 契约，先于真机）。
///
/// ## 复审拍板（2026-10-21，冻结）
///
/// 一个 NAS `source_id` = **一个已配置的 NAS 来源/连接实例**（整台设备），
/// 不是某个单独共享目录。因此**共享名必须保留在 `relative_path` 中**：
///
/// ```text
/// provider 原始：/共享A/供应商/报告.xlsx
/// source_id：    src_nas_work
/// relative_path：共享A/供应商/报告.xlsx
/// ```
///
/// 为什么必须保留（本文件第 ② 条就是这条反例的正面证明）：
/// 同一台 NAS 内 `/共享A/项目/report.pdf` 与 `/共享B/项目/report.pdf`
/// 共享同一个 `source_id`，把 share 剥掉后 FileID 前像完全一样 → 撞成同一个文件。
///
/// 这里的「共享名」指 Provider/backend 给的**真实路径组件**，不是 UI display name。
///
/// ## 六条契约（复审给的清单，顺序一致）
///
/// ① `/共享A/dir/a.pdf` → `共享A/dir/a.pdf`
/// ② `/共享A/a.pdf` 与 `/共享B/a.pdf`，同一 `source_id` → **不同 FileID**
/// ③ 相同 `共享A/a.pdf`，两个不同 `source_id` → **不同 FileID**
/// ④ share 根自身 `/共享A` → `共享A`，不能变空
/// ⑤ `/共享A/../共享B/a.pdf` → 拒绝，不能「修」成另一个 share
/// ⑥ Provider → Executor → LocateResponse 全链路的 `relative_path` 第一段仍是 share
///
/// ## 分层（谁负责哪一刀）
///
/// * **Provider 边界**（`NASSearchProvider.result`）：拒绝含 `.`/`..`/`@eaDir`/`#recycle`
///   的行、拒绝不在授权 scope 里的行。第 ⑤ 条在这里终结——`..` 行整行丢弃，
///   根本不会走到身份层。**身份层不做品牌特判，也不靠 `canonical` 兜底修 share。**
/// * **映射层**（`RelativePath.canonical`，§3.2.1 冻结）：剥前导斜杠、消空段、
///   NFC。注意 `canonical("/共享A/../共享B/x")` 会**收敛**成 `共享B/x`
///   （栈内回退不越根，这是 local_mac 也要的语义）——所以 NAS 的越 share 防线
///   必须在 Provider 边界，而不是指望 `canonical` 拒绝。
/// * **身份层**（`FileID.make`）：只吃规范相对路径，保持严格。
@MainActor
final class NASProviderContractTests: XCTestCase {

    // MARK: - fixture

    /// 可脚本化的假核心：discover/login 成功；search 原样回放预置的批次文件。
    ///
    /// 被测的是**真 `NASSearchProvider`**——路径解析、scope 判定、`..` 拒绝
    /// 全部走产品代码；假的只有「结果从哪来」（批次内容是我们写的 fixture）。
    @MainActor private final class ContractBridge: MyNASBridgeTransport {
        var files: [[String: Any]] = []

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            switch command {
            case "discover":
                return ["event": "capabilities"]
            case "login":
                return ["event": "authState", "state": "scopeReady"]
            case "search":
                event?(["event": "batch", "sourceID": sourceID, "queryID": queryID, "files": files])
                return ["resultState": "completed", "isComplete": true]
            default:
                return ["event": "controlAck"]
            }
        }
    }

    /// 核心批次里的一个文件行（设备根路径形态，与 Dart `row()` 同形）。
    private func row(sourceID: String, path: String, name: String? = nil,
                     fileType: String = "file") -> [String: Any] {
        ["id": "\(sourceID):\(path)", "name": name ?? (path as NSString).lastPathComponent,
         "path": path, "fileType": fileType, "size": 1024, "sourceID": sourceID,
         "sourceName": "NAS", "sourceType": "nas", "isOnline": true, "canOpen": false]
    }

    private var root = ""
    private var path = ""
    private var listeners: [AuthorityListener] = []

    override func setUpWithError() throws {
        root = "/tmp/ff-nas-contract-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
        path = root + "/authority.sock"
    }

    override func tearDown() {
        for listener in listeners { listener.stop() }
        listeners = []
        try? FileManager.default.removeItem(atPath: root)
    }

    /// 一套完整装配：每个来源一个**真 `NASSearchProvider`**（假核心喂批次），
    /// 真 `SearchScheduler` + 真权威端 + 真 socket。来源先 discover + login
    /// （与产品连接流程一致，`ready` 才会是 true）。
    private func assemble(sources: [(id: String, files: [[String: Any]])]) async throws
        -> (providers: [NASSearchProvider], link: UnixSocketAuthorityLink) {
        var providers: [NASSearchProvider] = []
        for source in sources {
            let bridge = ContractBridge()
            bridge.files = source.files
            let config = NASSourceConfig(id: source.id, name: "NAS \(source.id)", vendor: .synology,
                                         host: "nas-\(source.id).example", port: 5001, username: "u",
                                         scopes: ["/共享A", "/共享B"])
            providers.append(NASSearchProvider(bridge: bridge, config: config, port: 5001))
        }
        // ★ 连接流程与产品一致：discover + login 之后 `ready` 才是 true。
        //   漏掉就会得到「provider 发 .failed → 执行层 source_unavailable」，
        //   那是 bug 在 tataki 自己装配上，不是 NAS 路径语义的问题。
        for provider in providers {
            try await provider.discover()
            try await provider.login(account: "u", password: "p")
            XCTAssertTrue(provider.ready, "装配完必须处于就绪态，否则搜索会直接失败")
        }
        let scheduler = SearchScheduler(providers: providers)
        // 执行句柄在**这一次**读数里冻结（§15 #23）：side table 先在 MainActor 上建好，
        // `sources` 闭包是非隔离的，不能在这里读 `provider.source`。
        let registry = providers.map { provider in
            AuthoritySource(id: provider.source.id, name: provider.source.name,
                            execution: SourceExecutionHandle(provider: provider, scheduler: scheduler))
        }
        let service = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: Set(sources.map(\.id))) },
            sources: { registry })
        let listener = AuthorityListener(path: path, service: service, log: { _ in })
        XCTAssertTrue(listener.start().isListening, "监听没起来")
        listeners.append(listener)
        return (providers, UnixSocketAuthorityLink(path: path))
    }

    private func located(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw NotSuccess()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private struct NotSuccess: Error {}

    /// ★ **独立的 golden 计算**：不调 `FileID.make`，按方案 §4.6 前像公式直接算。
    /// 前像：`utf8(source_id) + 0x1F + "path:" + utf8(NFC(相对路径))`，取前 128 位。
    /// NAS 的相对路径根 = **设备搜索根**（共享名是第一段，复审拍板）。
    private func goldenFileID(sourceID: String, relativePath: String) -> String {
        let rel = relativePath.precomposedStringWithCanonicalMapping
        var preimage = Data(sourceID.utf8)
        preimage.append(0x1F)
        preimage.append(contentsOf: Data("path:".utf8))
        preimage.append(contentsOf: Data(rel.utf8))
        let digest = SHA256.hash(data: preimage).map { String(format: "%02x", $0) }.joined()
        return "ff1_" + String(digest.prefix(32))
    }

    // MARK: - ①⑥ 全链路：共享名保留 + golden 身份

    /// 设备根路径 `/共享A/供应商/报告.xlsx` 穿过整条链路
    /// （真 NASSearchProvider → 真 SearchScheduler → 真 LocateExecutor
    /// → LocateResponse → wire），返回的 `relative_path` 是
    /// `共享A/供应商/报告.xlsx`：前导斜杠剥掉、**共享名保留**、第一段就是 share；
    /// `file_id` 与独立计算的 golden 一致。
    func testASharePathKeepsItsShareSegmentThroughTheWholeChain() async throws {
        let sourceID = "src_nas_work"
        let (providers, link) = try await assemble(sources: [(sourceID,
            [row(sourceID: sourceID, path: "/共享A/供应商/报告.xlsx")])])
        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("报告")])))
        XCTAssertEqual(body["truncated"] as? Bool, false)
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1, "fixture 里只有一个名字含「报告」的文件：\(hits)")

        // ★ 用 XCTUnwrap 而不是 hits[0]：上一行断言失败时 hits 是空的，
        // 直接下标会以 `Fatal error: Index out of range` 打死进程（实测 signal 5），
        // 整轮测试连「哪条用例红了」都打不出来——变异就归因不到具体用例上。
        let hit = try XCTUnwrap(hits.first)
        let relative = try XCTUnwrap(hit["relative_path"] as? String)
        XCTAssertEqual(relative, "共享A/供应商/报告.xlsx",
                       "① 前导斜杠剥掉、共享名保留在相对路径里")
        XCTAssertEqual(relative.split(separator: "/").first.map(String.init), "共享A",
                       "⑥ 全链路返回的 relative_path 第一段仍是 share")
        XCTAssertEqual(hit["source_id"] as? String, sourceID)
        XCTAssertEqual(hit["file_id"] as? String,
                       goldenFileID(sourceID: sourceID, relativePath: "共享A/供应商/报告.xlsx"),
                       "① 与独立计算的 golden 一致（source_id = 整台来源 + share 保留）")
    }

    // MARK: - ② 为什么共享名不能剥（同一来源两个 share）

    /// 同一个 `source_id` 下，`/共享A/年报.pdf` 与 `/共享B/年报.pdf` 必须**身份不同**。
    /// 这条就是「share 不能剥」的正面证明：剥掉后两条的前像完全一样，
    /// 会撞成同一个文件——本用例在现有实现下绿，在任何「顺手剥 share」的
    /// 实现下第一段断言先红。
    func testTwoSharesUnderTheSameSourceKeepDistinctFileIDs() async throws {
        let sourceID = "src_nas_work"
        let (_, link) = try await assemble(sources: [(sourceID,
            [row(sourceID: sourceID, path: "/共享A/年报.pdf"),
             row(sourceID: sourceID, path: "/共享B/年报.pdf")])])

        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("年报")])))
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 2, "两个 share 里各有一个「年报」：\(hits)")

        let relatives = hits.compactMap { $0["relative_path"] as? String }
        XCTAssertEqual(relatives.sorted(), ["共享A/年报.pdf", "共享B/年报.pdf"],
                       "两个 share 的同名文件各保留自己的 share 段")
        let ids = hits.compactMap { $0["file_id"] as? String }
        XCTAssertEqual(Set(ids).count, 2,
                       "② 同一 source_id 下，不同 share 的同名文件必须不同 FileID")
    }

    // MARK: - ③ 相同 share 路径、不同 source_id

    /// `共享A/年报.pdf` 在两台已配置来源上各出现一次：`source_id` 参与前像，
    /// 两条身份必须不同。这也是「一个来源一个身份空间」的直接体现。
    func testTheSameSharePathUnderDifferentSourceIDsKeepsDistinctFileIDs() async throws {
        let (_, link) = try await assemble(sources: [
            ("src_nas_work", [row(sourceID: "src_nas_work", path: "/共享A/年报.pdf")]),
            ("src_nas_home", [row(sourceID: "src_nas_home", path: "/共享A/年报.pdf")]),
        ])

        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("年报")])))
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 2, "两台来源各返回一条：\(hits)")

        let ids = hits.compactMap { $0["file_id"] as? String }
        XCTAssertEqual(Set(ids).count, 2,
                       "③ 相对路径相同、source_id 不同 → 必须不同 FileID")
        XCTAssertEqual(Set(hits.compactMap { $0["source_id"] as? String }),
                       ["src_nas_work", "src_nas_home"])
        // 两台的 relative_path 相同——share 段不掺来源信息，来源由 source_id 表达。
        XCTAssertEqual(Set(hits.compactMap { $0["relative_path"] as? String }), ["共享A/年报.pdf"])
    }

    // MARK: - ④ share 根自身

    /// share 根（`/共享A`，目录）是合法结果：`relative_path` = `共享A`，
    /// 不能规约成空串。空串不是任何文件的身份。
    func testTheShareRootItselfIsAValidRelativePath() async throws {
        let sourceID = "src_nas_work"
        let (_, link) = try await assemble(sources: [(sourceID,
            [row(sourceID: sourceID, path: "/共享A", name: "共享A", fileType: "folder")])])

        let body = try located(await link.call(
            tool: "locate",
            arguments: ToolArguments(["query": .string("共享A"), "kind": .string("folder")])))
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertEqual(hits.count, 1, "share 根目录本身应作为 folder 返回：\(hits)")

        // ★ 同上：hits 可能是空的，必须 XCTUnwrap 而不是下标（否则进程被打死、
        // 变异归因不到这条用例）。
        let hit = try XCTUnwrap(hits.first)
        let relative = try XCTUnwrap(hit["relative_path"] as? String)
        XCTAssertEqual(relative, "共享A", "④ share 根 → 共享A，不能变空")
        XCTAssertFalse(relative.isEmpty)
        XCTAssertEqual(hit["kind"] as? String, "folder")
    }

    // MARK: - ⑤ 越出 share 的 `..` 必须拒绝

    /// `/共享A/../共享B/年报.pdf` 在 **Provider 边界**整行丢弃（`result` 返回 nil）：
    /// 它不能被「修」成 `共享B/年报.pdf`——那是另一个 share 里的身份。
    /// 走到执行层也不会凭空出现：locate 返回空结果（搜过了，没有），
    /// 而**不是**一条 `共享B/年报.pdf`。
    ///
    /// ★ 分层说明：`RelativePath.canonical` 对「栈内 `..`」是收敛语义
    /// （`/a/../b` → `b`，local_mac 也依赖它）；越 **share** 的拒绝因此必须、
    /// 也只能发生在 NAS Provider 边界——`result()` 对任何含 `..` 的行直接丢弃。
    /// 身份层与执行层不做品牌特判。
    func testADotDotRowCrossingSharesIsRejectedNotRepaired() async throws {
        let sourceID = "src_nas_work"
        let (providers, link) = try await assemble(sources: [(sourceID,
            [row(sourceID: sourceID, path: "/共享A/../共享B/年报.pdf")])])

        // Provider 边界：整行丢弃，nil。
        let provider = try XCTUnwrap(providers.first)
        XCTAssertNil(provider.result(row(sourceID: sourceID, path: "/共享A/../共享B/年报.pdf"),
                                     query: "年报"),
                     "⑤ 含 `..` 的行在 Provider 边界就必须丢弃，不进身份层")

        // 全链路：空结果，且不存在「修出来的另一个 share 身份」。
        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("年报")])))
        let hits = try XCTUnwrap(body["results"] as? [[String: Any]])
        XCTAssertTrue(hits.isEmpty,
                      "不能把 /共享A/../共享B/年报.pdf 修成 共享B/年报.pdf：\(hits)")

        // 越根的 `..`（栈已空）在 canonical 层也是拒绝——两道防线各守各的。
        XCTAssertThrowsError(try RelativePath.canonical("/../共享B/年报.pdf"),
                             "越出设备根的 `..` 必须拒绝（escapesSourceRoot）")
    }

    // MARK: - 补充：授权 scope 之外的结果不进身份层

    /// scope 之外的 `/共享C/年报.pdf`（来源只授权了 共享A/共享B）在 Provider
    /// 边界丢弃——「来源的搜索空间」由授权 scope 定义，越界行连身份都不该有。
    /// 这条守的是 source root 语义的另一半：**设备根 ≠ 全部可见**。
    func testAPathOutsideTheAuthorizedScopesIsDropped() async throws {
        let sourceID = "src_nas_work"
        let (providers, link) = try await assemble(sources: [(sourceID,
            [row(sourceID: sourceID, path: "/共享C/年报.pdf")])])

        let provider = try XCTUnwrap(providers.first)
        XCTAssertNil(provider.result(row(sourceID: sourceID, path: "/共享C/年报.pdf"), query: "年报"),
                     "scope 之外的行必须丢弃")

        let body = try located(await link.call(tool: "locate",
                                               arguments: ToolArguments(["query": .string("年报")])))
        XCTAssertTrue(((body["results"] as? [[String: Any]]) ?? []).isEmpty,
                      "未授权共享的结果不能出现在 locate 返回里")
    }
}
