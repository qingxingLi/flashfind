import XCTest
@testable import FlashFindCore

/// 第五批架构拆分的回归（P2-01 诊断 / P2-02 连接管理）。
///
/// 拆分本身不是目的：**行为不变**才是。这里锁的是拆分后必须仍然成立的事实，
/// 以及那些「写错了当时看不出来、事后无法追查」的规则。
final class ArchitectureSplitTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-arch-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// 状态目录。诊断写在它的**兄弟**目录里，所以这里要给一层子目录，
    /// 否则会写到 temp 根下，被所有用例共享（互相污染）。
    private func stateDirectory() -> URL {
        scratch.appendingPathComponent("app-state/trust", isDirectory: true)
    }

    private func makeController() -> NASDiagnosticsController {
        let controller = NASDiagnosticsController()
        controller.stateDirectory = { [self] in stateDirectory() }
        controller.acceptanceDirectory = { [self] in scratch }
        return controller
    }

    private func lines() throws -> [String] {
        let file = stateDirectory().deletingLastPathComponent()
            .appendingPathComponent("diagnostics")
            .appendingPathComponent("nas-search-events.jsonl")
        guard FileManager.default.fileExists(atPath: file.path) else { return [] }
        return try String(contentsOf: file, encoding: .utf8)
            .split(separator: "\n").map(String.init)
    }

    /// 正常结束不落盘。诊断文件是排查时最先看的东西，
    /// 被「一切正常」的行淹没就等于失效。
    func testCompletedSearchWithoutLeakIsNotRecorded() throws {
        let controller = makeController()
        controller.recordSearchFailureTrace(["event": "terminal", "resultState": "completed",
                                             "cleanupState": "cleaned"])
        XCTAssertTrue(try lines().isEmpty, "搜索正常结束不该占用诊断文件")
    }

    /// 结果拿到了、但设备上的任务没清掉 ⇒ 必须破例记下来。
    ///
    /// 这种「看似正常」的行最该留下：一次泄漏看不出问题，攒够几十次才是故障，
    /// 而那时候现场早就没了。
    func testCompletedButLeakedIsRecorded() throws {
        let controller = makeController()
        controller.recordSearchFailureTrace(["event": "terminal", "resultState": "completed",
                                             "cleanupState": "pending"])
        XCTAssertEqual(try lines().count, 1, "任务没清掉就必须留痕")
    }

    /// 连接 / 登录 / 选范围时核心会发一大堆正常事件，它们**一个都不许**进来。
    ///
    /// 重构时漏掉过这道闸，实测启动一次就多写 5 条
    /// （capabilities / authState / scopeState …），把排查最先看的文件淹掉。
    func testRoutineConnectionEventsAreNotRecorded() throws {
        let controller = makeController()
        for event in ["capabilities", "sessionState", "authState", "scopeState", "trustState"] {
            controller.recordSearchFailureTrace(["event": event, "sourceID": "s1"])
        }
        let written = try lines()
        XCTAssertTrue(written.isEmpty, "常规连接事件不得进诊断：\(written)")
    }

    /// 成功断开不解释任何东西——它曾被当成故障写进诊断，误导排查方向。
    func testSuccessfulDisconnectIsNotRecorded() throws {
        let controller = makeController()
        controller.recordSearchFailureTrace(["event": "terminal", "resultState": "disconnected"])
        XCTAssertTrue(try lines().isEmpty)
    }

    /// 诊断里**不许**出现查询词。这条是隐私底线，不是风格问题。
    func testQueryTextIsNeverWritten() throws {
        let controller = makeController()
        // 即便上层不小心把查询词带进来，白名单也只挑结构化字段。
        controller.recordSearchFailureTrace(["event": "terminal", "resultState": "failed",
                                             "sourceID": "s1", "query": "季度报告", "fileName": "工资表.xlsx"])
        let written = try lines()
        XCTAssertEqual(written.count, 1)
        XCTAssertFalse(written[0].contains("季度报告"), "查询词不得落盘：\(written[0])")
        XCTAssertFalse(written[0].contains("工资表"), "文件名不得落盘：\(written[0])")
        XCTAssertTrue(written[0].contains("s1"), "sourceID 这类结构化字段要保留")
    }

    /// 失败要带上「挂在哪个 API / 方法上」——这是定位的第一把钥匙。
    func testFailureCarriesApiAndMethod() throws {
        let controller = makeController()
        controller.recordSearchFailureTrace(["event": "terminal", "resultState": "failed",
                                             "error": ["kind": "AuthenticationFailed",
                                                       "api": "SYNO.API.Auth", "method": "login"]])
        let written = try lines()
        XCTAssertTrue(written[0].contains("SYNO.API.Auth"), "要带上出错的 API：\(written[0])")
        XCTAssertTrue(written[0].contains("login"), "要带上出错的方法：\(written[0])")
    }
}

@MainActor
final class NASConnectionManagerTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff2-conn-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    private func config(_ id: String, port: Int = 5001) -> NASSourceConfig {
        NASSourceConfig(id: id, host: "192.168.1.96", port: port, username: "nasuser", scopes: ["/示例共享"])
    }

    /// 造一个「像 app 包」的资源目录：里面有核心可执行文件就行。
    /// 桥接层对象创建时**不会**启动进程，所以测试里不会真的跑 Dart。
    private func prepareResources() throws -> URL {
        let resources = scratch.appendingPathComponent("Resources", isDirectory: true)
        let bin = resources.appendingPathComponent("MyNAS/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("mynas-core").path, contents: Data("#!/bin/sh\n".utf8))
        return resources
    }

    /// 配置没变的来源必须**保留同一个 Provider 实例**——
    /// 否则改一个无关设置就会把所有 NAS 踢下线，用户得重新登录。
    func testRebuildKeepsProviderWhenConfigUnchanged() async throws {
        let manager = NASConnectionManager()
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try prepareResources()))
        manager.onProvidersChanged = { _ in }

        manager.rebuild(configs: [config("a")], queryBudgetMs: 60_000, mountService: nil)
        let first = manager.provider(for: "a")
        manager.rebuild(configs: [config("a")], queryBudgetMs: 60_000, mountService: nil)
        let second = manager.provider(for: "a")

        XCTAssertTrue(first === second, "配置未变就必须是同一个实例（否则登录态丢失）")
    }

    /// 配置变了 ⇒ 换成新实例，旧的要断开。
    func testRebuildReplacesProviderWhenConfigChanged() async throws {
        let manager = NASConnectionManager()
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try prepareResources()))
        manager.rebuild(configs: [config("a", port: 5001)], queryBudgetMs: 60_000, mountService: nil)
        let first = manager.provider(for: "a")

        manager.rebuild(configs: [config("a", port: 5002)], queryBudgetMs: 60_000, mountService: nil)
        let second = manager.provider(for: "a")

        XCTAssertTrue(first !== second, "端口变了就必须重建")
        XCTAssertEqual(second?.resolvedPort, 5002)
    }

    /// 停用的来源不再出现在 Provider 里，且要通知外部（界面据此刷新）。
    func testDisabledSourceIsDroppedAndNotified() async throws {
        let manager = NASConnectionManager()
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try prepareResources()))
        var notified: [[String: NASSearchProvider]] = []
        manager.onProvidersChanged = { notified.append($0) }

        var disabled = config("a"); disabled.enabled = false
        manager.rebuild(configs: [disabled], queryBudgetMs: 60_000, mountService: nil)

        XCTAssertNil(manager.provider(for: "a"), "停用的来源不该有 Provider")
        XCTAssertEqual(notified.count, 1, "集合变化必须通知外部，否则界面停在旧状态")
    }

    /// 每个 Provider 都要装上自动重连——向导里手工建的和保存下来的走同一套。
    func testEveryProviderGetsAutoReconnect() async throws {
        let manager = NASConnectionManager()
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try prepareResources()))
        manager.rebuild(configs: [config("a"), config("b")], queryBudgetMs: 60_000, mountService: nil)

        XCTAssertNotNil(manager.provider(for: "a")?.autoReconnect)
        XCTAssertNotNil(manager.provider(for: "b")?.autoReconnect)
    }

    /// 开发树里的桥接状态目录必须落在**构建目录**下，不许拼内部工作区路径。
    ///
    /// 它曾经写死一个历史实验目录（``）：
    /// 换台机器、换个人就指到不存在的地方，而且把内部目录名写进了产品代码。
    /// 现在统一到项目根的 `.build` 下——能删能重建，也不进版本控制。
    func testDevelopmentStateDirectoryStaysInsideTheBuildDirectory() throws {
        let manager = NASConnectionManager()
        // 造出项目根标记，让 ensureBridge 认定自己跑在开发树里。
        FileManager.default.createFile(
            atPath: scratch.appendingPathComponent("README-目录说明.md").path, contents: Data())
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try prepareResources()))

        let state = try XCTUnwrap(manager.stateDirectory)
        XCTAssertTrue(state.path.hasSuffix("/.build/mynas-state/trust"),
                      "状态目录应落在项目根的 .build 下：\(state.path)")
        XCTAssertFalse(state.path.contains("工作区"),
                       "状态目录不该再指向任何内部工作区：\(state.path)")
    }

    /// 资源缺失时不能假装成功——要返回 false，让界面如实说「缺少搜索资源」。
    func testMissingResourcesIsReported() {
        let manager = NASConnectionManager()
        let empty = scratch.appendingPathComponent("empty", isDirectory: true)
        XCTAssertFalse(manager.ensureBridge(resourceDirectory: empty))
        XCTAssertNil(manager.bridge)
    }

}
