import XCTest
@testable import FlashFindCore

/// 网页打开目标（OL-OPEN）：**这个 URL 会被直接交给系统**，所以落地前必须过四道卡。
///
/// 逐条对应 `NASSearchProvider.result(_:)` 里的四个条件：
///  ① scheme 只能是 http/https（否则 `file://` 能借结果行触发本地动作）；
///  ② 主机必须等于本来源主机（否则点一条搜索结果会被送到任意站点）；
///  ③ 解码后的路径必须等于这条结果的逻辑路径（否则同主机上也能张冠李戴）；
///  ④ 不许带查询串 / 片段 / user@ 凭据（网页地址里不该有秘密）。
///
/// ★ 每条「应被拒」的用例都必须断言**没有**变成 `.webURL`，而不是只断言
/// 「不是 nil」——`openTarget` 的默认值是 `.unavailable`，只判空永远绿。
@MainActor
final class OpenTargetWebTests: XCTestCase {

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

    private func provider(host: String = "openlist.example.invalid", port: Int = 443,
                          plainHTTP: Bool = false) async throws -> NASSearchProvider {
        var config = NASSourceConfig(vendor: .openlist, host: host, port: port,
                                     username: "tester", scopes: ["/A0002"])
        config.usePlainHTTP = plainHTTP
        let subject = NASSearchProvider(bridge: StubBridge(), config: config, port: port)
        try await subject.login(account: "tester", password: "p")
        _ = try await subject.selectScopes(["/A0002"])
        XCTAssertTrue(subject.ready, "前置：应已就绪")
        return subject
    }

    /// 一条 OpenList 形状的结果行。`target` 传 `nil` 表示不带 openTarget。
    private func payload(sourceID: String, path: String = "/A0002/体系审核",
                         target: [String: Any]? = nil) -> [String: Any] {
        var m: [String: Any] = ["id": "1:" + path, "name": (path as NSString).lastPathComponent,
                                "path": path, "fileType": "folder",
                                "sourceID": sourceID, "canOpen": true]
        if let target { m["openTarget"] = target }
        return m
    }

    private func web(_ url: String) -> [String: Any] { ["kind": "webLocation", "url": url] }

    func testValidWebTargetIsAcceptedAndOpenable() async throws {
        let p = try await provider()
        let url = "https://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, target: web(url))))
        XCTAssertEqual(row.openTarget, .webURL(URL(string: url)!))
        XCTAssertTrue(row.hasWebOpenTarget, "视图层据此切换右键菜单")
        XCTAssertTrue(row.canOpen, "网页目标已指向确切路径，不需要先挂载")
    }

    func testDecodedPathMustEqualResultPath() async throws {
        // 字面 % / # / ? / 中文都要能解码回原路径，否则「名字里带 % 的文件」永远打不开。
        let p = try await provider()
        let path = "/A0002/报告 100% #1?.pdf"
        let url = "https://openlist.example.invalid/A0002/%E6%8A%A5%E5%91%8A%20100%25%20%231%3F.pdf"
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, path: path,
                                                 target: web(url))))
        XCTAssertEqual(row.openTarget, .webURL(URL(string: url)!),
                       "编码正确时必须放行，否则特殊字符路径点不开")
    }

    func testForeignHostIsRejected() async throws {
        let p = try await provider()
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://evil.example/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"))))
        XCTAssertEqual(row.openTarget, .unavailable, "跨源地址必须拒绝")
        XCTAssertFalse(row.hasWebOpenTarget)
    }

    func testPathMismatchIsRejected() async throws {
        let p = try await provider()
        // 同一个主机，但指向另一条路径 —— 典型的「张冠李戴」。
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://openlist.example.invalid/A0002/%E5%85%B6%E4%BB%96"))))
        XCTAssertEqual(row.openTarget, .unavailable, "路径与结果不一致必须拒绝")
    }

    func testFileSchemeIsRejected() async throws {
        let p = try await provider()
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id, target: web("file:///etc/passwd"))))
        XCTAssertEqual(row.openTarget, .unavailable, "只接受 http/https")
    }

    func testQueryStringIsRejected() async throws {
        let p = try await provider()
        // 带查询串的地址会把 token 一类东西带进地址栏、浏览历史、剪贴板。
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8?token=abc"))))
        XCTAssertEqual(row.openTarget, .unavailable, "不许带查询串")
    }

    func testUserInfoIsRejected() async throws {
        let p = try await provider()
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://user:pass@openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"))))
        XCTAssertEqual(row.openTarget, .unavailable, "不许带 user@ 凭据")
    }

    // MARK: - 同源 = 协议 + 主机 + 有效端口（首轮审核 必须修改 #2）
    //
    // 只比主机是不够的：同一台主机上 5001 是 DSM 管理口、8443 可能是别的服务；
    // HTTPS 来源的地址降到 HTTP 就等于放弃了证书这一层。下面五条把三个维度
    // 各自的「放行 / 拒绝」都钉住，任何一条被删，另一条就该红。

    func testSameHostDifferentPortIsRejected() async throws {
        // 来源连的是 443，目标指向同主机的 8443 —— 那是另一个服务。
        let p = try await provider(port: 443)
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://openlist.example.invalid:8443/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"))))
        XCTAssertEqual(row.openTarget, .unavailable, "同主机不同端口必须拒绝")
    }

    func testHTTPSDowngradedToHTTPIsRejected() async throws {
        // 同一个主机名、同一个路径，只是协议被降级。
        let p = try await provider(port: 443)
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("http://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"))))
        XCTAssertEqual(row.openTarget, .unavailable, "HTTPS 来源不许接受 HTTP 目标")
    }

    func testCustomPortIsAcceptedWhenItMatchesTheConnection() async throws {
        // 真实 OpenList 常跑在 5244 这类自定义端口上：同源就该放行，否则谁都打不开。
        let p = try await provider(port: 5244)
        let url = "https://openlist.example.invalid:5244/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, target: web(url))))
        XCTAssertEqual(row.openTarget, .webURL(URL(string: url)!), "自定义端口同源必须放行")
    }

    func testOmittedDefaultPortMatchesExplicitDefaultPort() async throws {
        // 明文来源跑在 80：地址里不写端口，等于写 80。
        let p = try await provider(port: 80, plainHTTP: true)
        let url = "http://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"
        let row = try XCTUnwrap(p.result(payload(sourceID: p.source.id, target: web(url))))
        XCTAssertEqual(row.openTarget, .webURL(URL(string: url)!), "省略的默认端口应与显式端口等价")
    }

    func testPlainHTTPSourceRejectsHTTPSUpgradeTo443() async throws {
        // 反向的一条：来源实际是 http:80，目标却给了 https:443。
        // 看似「更安全」，但那是**另一个连接**，不是这个来源。
        let p = try await provider(port: 80, plainHTTP: true)
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: web("https://openlist.example.invalid/A0002/%E4%BD%93%E7%B3%BB%E5%AE%A1%E6%A0%B8"))))
        XCTAssertEqual(row.openTarget, .unavailable, "协议不同即不同源，即使「看起来更安全」")
    }

    func testSMBTargetStillWinsForDevicesThatProvideIt() async throws {
        // 回归：加这条分支不许把 SMB 那条路顶掉。
        let p = try await provider(host: "nas.example.invalid")
        let row = try XCTUnwrap(p.result(payload(
            sourceID: p.source.id,
            target: ["kind": "smbLocation", "host": "nas.example.invalid",
                     "share": "A0002", "relativeSegments": ["体系审核"]])))
        guard case .smbLocation(let url) = row.openTarget else {
            return XCTFail("SMB 行仍应得到 smbLocation，实际：\(row.openTarget)")
        }
        XCTAssertEqual(url.scheme, "smb")
        XCTAssertFalse(row.hasWebOpenTarget)
        XCTAssertFalse(row.canOpen, "SMB 行必须等挂载核对后才能说 canOpen")
    }
}
