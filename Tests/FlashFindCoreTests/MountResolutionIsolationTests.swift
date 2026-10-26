import XCTest
@testable import FlashFindCore

/// 网页目标不许被后台 SMB 元数据补全改写（首轮审核 必须修改 #1）。
///
/// ## 这条用例在防什么
///
/// `search` 的结果批次到手后，会起一个后台任务去「挂载表里找这条结果的本地文件」，
/// 找到就把行改成 `.mountedFile` 并写 `localURL`。对群晖这是必要的——
/// `canOpen` 要如实说「此刻能不能定位」。
///
/// 但 OpenList 可以部署在**任何**主机上，包括一台同时也开着 SMB 的 NAS：
/// 那时挂载表里会有一条 host + 共享名都匹配的候选，`resolve` 会**真的**
/// 解析出一个同路径文件，于是网页目标被悄悄换成本地文件——用户点开的是
/// 另一份内容。本地回环 fixture 永远造不出这个场景（那里没有任何共享挂载），
/// 所以这组用例必须自己造一条「能解析成功」的挂载候选。
///
/// ## 为什么用临时目录假装挂载根
///
/// `SMBMountCandidate.parse` 只要求 `mountPath` 是绝对路径且非根，`resolve`
/// 之后只做 `FileManager.fileExists` 与路径前缀校验。因此临时目录就是一条
/// **对 `resolve` 完全合法**的候选——这样断言「网页行没被改写」时，
/// 不能说成「反正它也解析不出来」。
@MainActor
final class MountResolutionIsolationTests: XCTestCase {

    // MARK: - 夹层

    private final class StubBridge: MyNASBridgeTransport {
        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            switch command {
            case "discover": return ["event": "capabilities"]
            case "login": return ["event": "authState", "state": "scopeReady", "isManager": false]
            case "selectScope": return ["event": "scopeState", "state": "scopeReady", "scopes": ["/A0002"]]
            default: return [:]
            }
        }
    }

    private var tempRoot: URL!

    override func setUp() {
        super.setUp()
        // 目录名故意带中文与空格：实时路径里这两样最常见，
        // 顺带证明「临时根」不会因为非 ASCII 让 `resolve` 的路径比较失效。
        tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-mount-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("共享 挂载点", isDirectory: true)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
    }

    override func tearDown() {
        if let tempRoot { try? FileManager.default.removeItem(at: tempRoot) }
        tempRoot = nil
        super.tearDown()
    }

    private func provider(vendor: NASSourceConfig.Vendor = .openlist,
                          host: String = "openlist.example.invalid",
                          port: Int = 443) async throws -> NASSearchProvider {
        let subject = NASSearchProvider(
            bridge: StubBridge(),
            config: NASSourceConfig(vendor: vendor, host: host, port: port,
                                    username: "tester", scopes: ["/A0002"]),
            port: port)
        try await subject.login(account: "tester", password: "p")
        _ = try await subject.selectScopes(["/A0002"])
        return subject
    }

    /// 一条真的能解析成功的挂载候选（主机、共享名都与来源对齐）。
    private func matchingMount(host: String = "openlist.example.invalid") throws -> SMBMountCandidate {
        // 让 `resolve` 找得到目标：挂载根下必须真有一个同名文件。
        let target = tempRoot.appendingPathComponent("体系审核", isDirectory: true)
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        return try XCTUnwrap(SMBMountCandidate.parse(origin: "//\(host)/A0002", mountPath: tempRoot.path),
                             "前置：临时目录应当能构成一条合法挂载候选")
    }

    private func payload(sourceID: String, path: String, kind: String = "folder",
                         target: [String: Any]? = nil) -> [String: Any] {
        var m: [String: Any] = ["id": "1:" + path, "name": (path as NSString).lastPathComponent,
                                "path": path, "fileType": kind, "sourceID": sourceID]
        if let target { m["openTarget"] = target }
        return m
    }

    private let webPath = "/A0002/体系审核"
    private var webURLText: String { "https://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8" }

    // MARK: - 用例

    /// ★ 核心回归：**挂着一条能解析成功的同名 SMB 候选**时，网页目标依然不许被改写。
    func testWebRowIsNeverRewrittenByMatchingSMBMount() async throws {
        let p = try await provider()
        let mount = try matchingMount()
        let webRow = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id, path: webPath,
            target: ["kind": "webLocation", "url": webURLText])))
        XCTAssertEqual(webRow.openTarget, .webURL(URL(string: webURLText)!), "前置：网页目标应当已写入")

        // 先证明这条候选**真的能解析成功**——否则下面「没被改写」可能是假的。
        XCTAssertNoThrow(try p.resolve(webRow, in: [mount]),
                         "前置：这条挂载候选对同一路径确实能解析出文件，排除「解析不出来所以没改写」")

        let localized = NASSearchProvider.localizedRows([webRow], mounts: [mount],
                                                        exposesSMBShares: true,
                                                        resolve: { try p.resolve($0, in: [mount]) })
        XCTAssertTrue(localized.isEmpty, "网页行必须整条排除在 SMB 解析之外，实际被改写：\(localized)")
        // 原行也不许被就地改动 —— 它会被原样发给界面。
        XCTAssertEqual(webRow.openTarget, .webURL(URL(string: webURLText)!), "网页目标被改写成了挂载目标")
        XCTAssertNil(webRow.localURL, "网页行不该被写 localURL")
    }

    /// 同一批里混着普通 NAS 行时：网页行排除、其它行照旧补全（不能因为修 #1 把群晖修坏）。
    func testSMBRowsInTheSameBatchAreStillLocalized() async throws {
        let p = try await provider(vendor: .synology, host: "nas.example.invalid", port: 5001)
        let mount = try matchingMount(host: "nas.example.invalid")
        let webRow = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id, path: webPath,
            target: ["kind": "webLocation", "url": "https://nas.example.invalid:5001/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"])))
        let smbRow = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id, path: webPath,
            target: ["kind": "smbLocation", "host": "nas.example.invalid",
                     "share": "A0002", "relativeSegments": ["体系审核"]])))

        let localized = NASSearchProvider.localizedRows([webRow, smbRow], mounts: [mount],
                                                        exposesSMBShares: true,
                                                        resolve: { try p.resolve($0, in: [mount]) })
        XCTAssertEqual(localized.count, 1, "只应补全那一条 SMB 行")
        guard let only = localized.first else { return XCTFail("SMB 行没有被补全，群晖链路被修坏了") }
        XCTAssertEqual(only.id, smbRow.id)
        XCTAssertNotNil(only.localURL)
        guard case .mountedFile = only.openTarget else {
            return XCTFail("SMB 行应变成 mountedFile，实际：\(only.openTarget)")
        }
        XCTAssertTrue(only.canOpen)
    }

    /// 不走 SMB 的来源（OpenList）：**一条都不许动**。
    ///
    /// 覆盖的是「网页目标缺失 / 校验失败 → 停在 `.unavailable`」这条路：
    /// 这时若允许挂载兜底，等于把「网页打不开」翻译成「挂了个不相干的共享」。
    func testSourceWithoutSMBExposureNeverFallsBackToMounting() async throws {
        let p = try await provider()
        let mount = try matchingMount()
        // 没有 openTarget（Dart 没给 / Swift 把校验失败的那条丢了）。
        let bare = try XCTUnwrap(p.result(payload(sourceID: p.source.id, path: webPath)))
        XCTAssertEqual(bare.openTarget, .unavailable, "前置：没有网页目标时应停在 unavailable")

        let localized = NASSearchProvider.localizedRows([bare], mounts: [mount],
                                                        exposesSMBShares: false,
                                                        resolve: { try p.resolve($0, in: [mount]) })
        XCTAssertTrue(localized.isEmpty, "没有 SMB 的来源不许退化成挂载")
        XCTAssertNil(bare.localURL)
        XCTAssertEqual(bare.openTarget, .unavailable)
    }

    /// 悬挂载表的来源配上没有网页目标的行：补全是允许的（旧行为），
    /// 这条防的是「把 exposesSMBShares=false 的保护写成对所有来源都不补全」。
    func testSMBExposedSourceStillLocalizesRowsWithoutWebTarget() async throws {
        let p = try await provider(vendor: .synology, host: "nas.example.invalid", port: 5001)
        let mount = try matchingMount(host: "nas.example.invalid")
        let bare = try XCTUnwrap(p.result(payload(sourceID: p.source.id, path: webPath)))
        let localized = NASSearchProvider.localizedRows([bare], mounts: [mount],
                                                        exposesSMBShares: true,
                                                        resolve: { try p.resolve($0, in: [mount]) })
        XCTAssertEqual(localized.count, 1, "没有网页目标、来源挂 SMB 时仍应补本地路径")
    }

    /// 没有挂载候选时函数直接返回空，不做任何 `resolve` 调用。
    func testNoMountsMeansNoResolutionWork() async throws {
        let p = try await provider()
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, path: webPath)))
        var calls = 0
        let localized = NASSearchProvider.localizedRows([row], mounts: [], exposesSMBShares: true,
                                                        resolve: { _ in calls += 1; return URL(fileURLWithPath: "/tmp/x") })
        XCTAssertTrue(localized.isEmpty)
        XCTAssertEqual(calls, 0, "没有候选时不该逐行尝试解析")
    }

    /// 打开动作的兜底入口也不许去挂载：OpenList 的行如果没拿到网页目标，
    /// 用户按 Return 时会走到 `verifiedFileURL`。那里必须直接说「在网页上」，
    /// 而不是「尚未连接共享 … 请先在 Finder 里连接」——后者会让用户以为
    /// 这台机器上本来应该有个共享。
    func testVerifiedFileURLRefusesToMountForWebOnlySource() async throws {
        let p = try await provider()
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, path: webPath)))
        do {
            _ = try await p.verifiedFileURL(row)
            XCTFail("只走网页的来源不该走到挂载解析")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("网页上") == true,
                          "错误应说清「在网页上」，实际：\(String(describing: error))")
        }
        do {
            _ = try p.verifiedFileURLWithoutMounting(row)
            XCTFail("只走网页的来源不该读挂载表")
        } catch {
            XCTAssertTrue((error as? LocalizedError)?.errorDescription?.contains("网页上") == true,
                          "实际：\(String(describing: error))")
        }
    }

    /// 来源的 SMB 能力必须与核心适配器一致，且默认不误伤群晖。
    func testVendorSMBExposureMatchesTheAdapterContract() {
        XCTAssertFalse(NASSourceConfig.Vendor.openlist.exposesSMBShares,
                       "OpenList 的存储不是 SMB 共享（对齐 adapter_contract.dart / openlist.dart:108）")
        XCTAssertTrue(NASSourceConfig.Vendor.synology.exposesSMBShares)
        XCTAssertTrue(NASSourceConfig.Vendor.webdav.exposesSMBShares)
        XCTAssertFalse(NASLocator.empty.exposesSMBShares == false, "默认应当是 true，避免旧调用点被误伤")
    }
}
