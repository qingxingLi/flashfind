import XCTest
import Foundation
@testable import FlashFindCore

/// 「已连接」必须真的有设备在线的证据。
///
/// ★ 这组用例存在的理由不是覆盖分支，而是钉死 2026-11-08 那个 bug 的**形状**：
///   代理环境下 TCP connect 会假成功。任何把「连上了」当在线的写法，都必须在
///   `testATCPConnectAloneIsNotEvidenceOfAnOnlineDevice` 与代理 5xx 两条上变红。
final class DeviceReachabilityTests: XCTestCase {

    func testATCPConnectAloneIsNotEvidenceOfAnOnlineDevice() {
        // 裸 socket 成功 ⇒ 既没有状态码，也没有传输层报错。
        // 这种情况只能说「不知道」，绝不能说「设备在线」。
        XCTAssertEqual(DeviceReachability.evidence(statusCode: nil, transportErrorCode: nil), .unknown)
        // 而且不许因为「不知道」就把已有的「已连接」撤掉。
        XCTAssertEqual(DeviceReachability.display(ready: true, evidence: .unknown), .connected)
    }

    func testARealHTTPResponseIsTheEvidenceWeNeed() {
        XCTAssertEqual(DeviceReachability.evidence(statusCode: 200, transportErrorCode: nil), .responded)
        // 401 / 404 同样证明服务在监听：设备确实回了响应行。
        XCTAssertEqual(DeviceReachability.evidence(statusCode: 401, transportErrorCode: nil), .responded)
        XCTAssertEqual(DeviceReachability.evidence(statusCode: 404, transportErrorCode: nil), .responded)
        XCTAssertEqual(DeviceReachability.display(ready: true, evidence: .responded), .connected)
    }

    func testAProxyErrorPageIsNeitherOnlineNorOffline() {
        // fake-ip 代理可能回 502/503 而不是超时。当「在线」会假通过，
        // 当「离线」又会冤枉好设备 ⇒ 只能是 unknown。
        for code in [500, 502, 503, 504] {
            XCTAssertEqual(DeviceReachability.evidence(statusCode: code, transportErrorCode: nil), .unknown,
                           "\(code) 不该被当成在线")
        }
        XCTAssertEqual(DeviceReachability.display(ready: true, evidence: .unknown), .connected)
    }

    func testTimeoutAndTLSFailureAreTheRealOfflineEvidence() {
        // -1001 超时 / -1004 连不上主机 / -1200 TLS 失败：HTTPS 往返根本没完成。
        for code in [-1001, -1004, -1200, -1202] {
            XCTAssertEqual(DeviceReachability.evidence(statusCode: nil, transportErrorCode: code), .unreachable)
        }
        XCTAssertEqual(DeviceReachability.display(ready: true, evidence: .unreachable), .deviceOffline)
    }

    func testLocalNetworkLossIsNotEvidenceAgainstTheDevice() {
        // 本机自己没网 / 连接中途断 / 主动取消：都是「不知道」，不是「设备离线」。
        for code in [-1009, -1005, -999] {
            XCTAssertEqual(DeviceReachability.evidence(statusCode: nil, transportErrorCode: code), .unknown)
        }
    }

    func testAnUnreadySourceNeverShowsConnectedRegardlessOfEvidence() {
        for evidence in [DeviceReachability.Evidence.responded, .unreachable, .unknown] {
            XCTAssertEqual(DeviceReachability.display(ready: false, evidence: evidence), .notConnected)
        }
    }

    /// ★ 探活失败只撤显示，会话还在。Core 判据里 ready 与 display 是两条独立输入，
    ///   没有任何一处会把 ready 改掉——这样才能在设备回来后自动恢复。
    func testOfflineDisplayDoesNotConsumeTheReadyState() {
        let ready = true
        XCTAssertEqual(DeviceReachability.display(ready: ready, evidence: .unreachable), .deviceOffline)
        XCTAssertEqual(DeviceReachability.display(ready: ready, evidence: .responded), .connected,
                       "设备恢复拿到响应后必须自动回到已连接，不需要重新登录")
        XCTAssertTrue(ready)
    }

    func testProbeOnlyRunsForReadyEnabledConfiguredSources() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        XCTAssertTrue(DeviceReachability.shouldProbe(ready: true, enabled: true,
                                                     isConnectConfigured: true,
                                                     lastProbeAt: nil, now: now))
        XCTAssertFalse(DeviceReachability.shouldProbe(ready: false, enabled: true,
                                                      isConnectConfigured: true,
                                                      lastProbeAt: nil, now: now))
        XCTAssertFalse(DeviceReachability.shouldProbe(ready: true, enabled: false,
                                                      isConnectConfigured: true,
                                                      lastProbeAt: nil, now: now))
        XCTAssertFalse(DeviceReachability.shouldProbe(ready: true, enabled: true,
                                                      isConnectConfigured: false,
                                                      lastProbeAt: nil, now: now))
    }

    func testCooldownPreventsRepeatedNetworkHits() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let recent = now.addingTimeInterval(-5)
        XCTAssertFalse(DeviceReachability.shouldProbe(ready: true, enabled: true,
                                                      isConnectConfigured: true,
                                                      lastProbeAt: recent, now: now))
        let old = now.addingTimeInterval(-DeviceReachability.probeCooldown - 1)
        XCTAssertTrue(DeviceReachability.shouldProbe(ready: true, enabled: true,
                                                     isConnectConfigured: true,
                                                     lastProbeAt: old, now: now))
    }

    func testSynologyProbeUsesThePublicAPIInfoEndpointWithoutCredentials() {
        let url = DeviceReachability.probeURL(scheme: "https", host: "192.0.2.96", port: 5001,
                                              basePath: "", isSynology: true)
        XCTAssertEqual(url?.host, "192.0.2.96")
        XCTAssertEqual(url?.port, 5001)
        XCTAssertEqual(url?.path, "/webapi/query.cgi")
        let query = url?.query ?? ""
        XCTAssertTrue(query.contains("api=SYNO.API.Info"))
        XCTAssertTrue(query.contains("method=query"))
        // 探活不许带账号、密码、查询词或任何可搜索内容。
        XCTAssertFalse(query.contains("query=报告"))
        XCTAssertFalse(query.contains("account"))
        XCTAssertFalse(query.contains("passwd"))
    }

    func testOtherVendorsProbeTheConfiguredRoot() {
        let url = DeviceReachability.probeURL(scheme: "http", host: "192.0.2.88", port: 5244,
                                              basePath: "/dav", isSynology: false)
        XCTAssertEqual(url?.absoluteString, "http://192.0.2.88:5244/dav")
        let root = DeviceReachability.probeURL(scheme: "http", host: "192.0.2.88", port: 5244,
                                               basePath: "", isSynology: false)
        XCTAssertEqual(root?.path, "/")
    }

    func testProbeURLRejectsAnIncompleteConfiguration() {
        XCTAssertNil(DeviceReachability.probeURL(scheme: "https", host: "", port: 5001,
                                                 basePath: "", isSynology: true))
        XCTAssertNil(DeviceReachability.probeURL(scheme: "https", host: "192.0.2.96", port: 0,
                                                 basePath: "", isSynology: true))
    }

    func testOfflineWordingHasASingleSource() {
        XCTAssertEqual(DeviceReachability.offlineDetail, "设备不可达")
        XCTAssertEqual(DeviceReachability.offlineDiagnostic, "设备不可达")
    }
}
