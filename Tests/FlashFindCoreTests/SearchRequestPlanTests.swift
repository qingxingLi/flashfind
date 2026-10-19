import XCTest
@testable import FlashFindCore

/// 一次搜索到底请求哪些来源（审核 R01 的验证面）。
///
/// 判定搬到 Core 之前，「NAS 有没有被请求」这件事只能靠人在界面上点出来 ——
/// 而它恰恰是 R01 的故障点：来源卡片写着已连接，搜索却一个 NAS 都不请求。
final class SearchRequestPlanTests: XCTestCase {

    private let local = "local"
    private let apps = "local_apps"
    private let nasA = "nas-A"
    private let nasB = "nas-B"

    private func plan(includeLocal: Bool,
                      includeNAS: Bool,
                      includeApps: Bool = false,
                      candidates: [(String, Bool, Bool)]) -> Set<String> {
        SearchRequestPlan(
            localSourceID: local,
            appSourceID: apps,
            includeLocal: includeLocal,
            includeApps: includeApps,
            includeNAS: includeNAS,
            nasCandidates: candidates.map { (sourceID: $0.0, ready: $0.1, enabled: $0.2) }
        ).sourceIDs
    }

    /// 作用域「全部」：本机与两台 NAS 都要请求。
    func testAllScopeRequestsLocalAndNAS() {
        let ids = plan(includeLocal: true, includeNAS: true,
                       candidates: [(nasA, true, true), (nasB, true, true)])
        XCTAssertEqual(ids, [local, nasA, nasB])
    }

    /// ★ 总开关关掉 ⇒ 一个 NAS 来源都不请求，但本机照常。
    ///
    /// 这是 R01 的正面对照：如果这条不成立，用户关掉开关却仍然在搜 NAS。
    func testMasterSwitchOffSkipsAllNAS() {
        let ids = plan(includeLocal: true, includeNAS: false,
                       candidates: [(nasA, true, true), (nasB, true, true)])
        XCTAssertEqual(ids, [local])
    }

    /// 作用域「NAS」：不请求本机。
    func testNASScopeSkipsLocal() {
        let ids = plan(includeLocal: false, includeNAS: true,
                       candidates: [(nasA, true, true)])
        XCTAssertEqual(ids, [nasA])
    }

    /// 逐来源关掉 ⇒ 只不请求那一个，另一台不受影响。
    func testPerSourceDisableAffectsOnlyThatSource() {
        let ids = plan(includeLocal: false, includeNAS: true,
                       candidates: [(nasA, true, false), (nasB, true, true)])
        XCTAssertEqual(ids, [nasB])
    }

    /// 还没登录（ready=false）的来源不请求 —— 发过去只会失败。
    func testNotReadySourceIsNotRequested() {
        let ids = plan(includeLocal: false, includeNAS: true,
                       candidates: [(nasA, false, true)])
        XCTAssertTrue(ids.isEmpty)
    }

    /// ★ R01 的端到端串一遍：全新安装（总开关默认开）+ 已登录且启用的来源 ⇒ 必须请求 NAS。
    ///
    /// 分开测两段不够——R01 恰恰是「两段各自看着都对、接起来就搜不到」。
    func testFreshInstallEndToEndRequestsNAS() {
        let enabled = NASMasterSwitch.resolve(stored: nil, legacy: nil)
        let ids = plan(includeLocal: true, includeNAS: enabled,
                       candidates: [(nasA, true, true)])
        XCTAssertTrue(ids.contains(nasA), "全新安装 + 已连接 ⇒ NAS 必须被请求")
        XCTAssertTrue(ids.contains(local))
    }

    /// 一个都没有 ⇒ 空集合，界面不该进入「正在搜索」态。
    func testEmptyPlan() {
        let plan = SearchRequestPlan(localSourceID: local, appSourceID: apps,
                                     includeLocal: false, includeApps: false,
                                     includeNAS: true, nasCandidates: [])
        XCTAssertTrue(plan.isEmpty)
        XCTAssertTrue(plan.sourceIDs.isEmpty)
    }

    // MARK: - 应用搜索

    /// 本机作用域内要搜应用：应用来源跟着一起进请求集合。
    func testAppsAreRequestedAlongsideLocal() {
        let ids = plan(includeLocal: true, includeNAS: true, includeApps: true,
                       candidates: [(nasA, true, true)])
        XCTAssertEqual(ids, [local, apps, nasA])
    }

    /// 不请求应用时，集合里不该出现应用来源。
    func testAppsAreSkippedWhenNotRequested() {
        let ids = plan(includeLocal: true, includeNAS: true, includeApps: false,
                       candidates: [(nasA, true, true)])
        XCTAssertFalse(ids.contains(apps))
    }

    /// 作用域「NAS」时不搜应用——应用属于本机那一侧。
    func testNASScopeSkipsApps() {
        let ids = plan(includeLocal: false, includeNAS: true, includeApps: false,
                       candidates: [(nasA, true, true)])
        XCTAssertFalse(ids.contains(apps))
        XCTAssertFalse(ids.contains(local))
    }
}
