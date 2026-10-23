import XCTest
@testable import FlashFindCore

/// Phase 6.3b-0 preflight ④：**判权用的那份来源，必须就是执行用的那份**（方案 §15 #23）。
///
/// ## 它挡的是什么
///
/// `RoutingAuthorityService` 每个请求读一次注册表，`PermissionPolicy` 按那次读数判权。
/// 如果执行侧自己再读一遍，就存在「T0 判权时 A 在、T2 执行时 A 已经变成 A′」的窗口，
/// 而结果不是失败，是**这次请求拿到了它当初没被授予的来源**。
///
/// `AuthorizedSourceSnapshot` 把「判定时的来源」变成一份不可变的值：能进 `ids` 的
/// 只有 `AuthorizationScope` 里已有的 id，执行侧拿不到注册表，也就写不出第二次读。
///
/// ★ 它**不做权限判定**：`PermissionPolicy` 仍然是唯一判定点。这里的用例只证明
/// 「这份快照不会比授权更宽」，不证明「授权是对的」。
final class AuthorizedSourceSnapshotTests: XCTestCase {

    private func scope(_ ids: [String], warnings: [String] = []) -> AuthorizationScope {
        // 只有 `PermissionDecision.allow` 能造出 scope——快照的输入本来就已经是放行结果。
        AuthorizationScope(granting: .allow(sources: ids, warnings: warnings))!
    }

    private func registry(_ pairs: [(String, String)]) -> [AuthoritySource] {
        pairs.map { AuthoritySource(id: $0.0, name: $0.1) }
    }

    // MARK: - 1. 只装授权的

    func testOnlyAuthorizedSourcesAreInTheSnapshot() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["local_mac", "src_nas_work"]),
            registry: registry([("src_nas_private", "Private Archive"),
                                ("local_mac", "This Mac"),
                                ("src_nas_work", "Work NAS")]))

        XCTAssertEqual(snapshot.ids, ["local_mac", "src_nas_work"])
        XCTAssertFalse(snapshot.contains("src_nas_private"))
        XCTAssertEqual(snapshot.namedSources.map(\.name), ["This Mac", "Work NAS"],
                       "未授权来源的名字不许进快照")
    }

    /// 未授权来源的名字**连查都查不到**（这是「名字也是信息」那条规则的落地）。
    func testAnUnauthorizedNameIsNotReachableAnyWay() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["local_mac"]),
            registry: registry([("local_mac", "This Mac"), ("src_nas_private", "Private Archive")]))

        XCTAssertEqual(snapshot.namedSources.count, 1)
        XCTAssertFalse(snapshot.namedSources.contains { $0.name.contains("Private") })
        XCTAssertFalse(snapshot.contains("src_nas_private"))
    }

    // MARK: - 2. 顺序与去重是本类型的性质

    /// 注册表顺序跟着用户添加顺序走，`scope.sourceIDs` 的顺序也不该被依赖：
    /// 快照自己排序。**排序出错会直接改变 `list_sources` 的字节**（同一份设置两次请求不同串）。
    func testIDsAreSortedAndDeduplicated() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["src_nas_work", "local_mac", "src_nas_work"]),
            registry: registry([("src_nas_work", "Work NAS"),
                                ("local_mac", "This Mac"),
                                ("src_nas_work", "Work NAS (duplicate)")]))

        XCTAssertEqual(snapshot.ids, ["local_mac", "src_nas_work"], "既没排序也没去重")
        XCTAssertEqual(snapshot.count, 2)
        XCTAssertEqual(snapshot.namedSources.map(\.id), ["local_mac", "src_nas_work"],
                       "名字的输出顺序也必须跟 ids 一致")
    }

    /// 注册表里 id 重复时取**第一条**，不许崩溃（旧写法用
    /// `Dictionary(uniqueKeysWithValues:)` 遇到重复键会直接 trap）。
    func testADuplicateRegistryEntryDoesNotCrashOrSwapTheName() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["local_mac"]),
            registry: registry([("local_mac", "First"), ("local_mac", "Second")]))

        XCTAssertEqual(snapshot.namedSources.map(\.name), ["First"])
    }

    // MARK: - 3. 没有名字也能执行，但不能出现在 list_sources

    /// 注册表里查不到名字（数据不一致）时：id 仍然可以搜，但列表里不出现。
    /// 宁可少一条，也不要在执行端现编一个名字。
    func testAnIDWithoutANameIsExecutableButNotListed() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["src_nas_work"]),
            registry: registry([("src_nas_other", "Other")]))

        XCTAssertEqual(snapshot.ids, ["src_nas_work"], "id 来自授权范围，不来自注册表")
        XCTAssertTrue(snapshot.contains("src_nas_work"))
        XCTAssertTrue(snapshot.namedSources.isEmpty, "没有名字就不许出现在 list_sources")
    }

    // MARK: - 4. warnings 原样带出

    func testWarningsComeFromTheScopeVerbatim() {
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["local_mac"], warnings: ["source_denied:src_nas_gone"]),
            registry: registry([("local_mac", "This Mac")]))

        XCTAssertEqual(snapshot.warnings, ["source_denied:src_nas_gone"])
        XCTAssertFalse(snapshot.warnings.joined().contains("Gone NAS"),
                       "warnings 里只许有 id，不许有来源名")
    }

    // MARK: - 5. 结构：没有「再加一个来源」的入口

    /// 不可变是**类型**上的事，不是纪律：一旦有一个 `append(_:)`，
    /// 执行侧就能在判权之后把来源加回来。这条用例锁住「只有构造那一刻能定 ids」。
    func testTheSnapshotHasNoWayToGrow() throws {
        let source = try String(contentsOf: Self.clientRoot
            .appendingPathComponent("Sources/FlashFindCore/MCP/AuthorizedSourceSnapshot.swift"),
            encoding: .utf8)
        XCTAssertTrue(source.contains("public let ids"), "ids 必须是 let")
        for marker in ["func append", "func insert", "func add(", "var ids"] {
            XCTAssertFalse(source.contains(marker), "快照出现了可增长入口：\(marker)")
        }
    }

    // MARK: - 6. 执行句柄按 id 取，不按「随便一个」

    /// 执行侧拿 provider 的唯一入口是 `execution(for:)`。这条钉住「按 id 精确取」：
    /// 谁要是把它改成 `handles.values.first` 之类的「随手拿一个」，两个来源就会
    /// 互相拿到对方的 provider——那等于把未授权的执行能力交出去（§15 #23）。
    ///
    /// ★ **两次身份断言缺一不可**：`values.first` 只可能等于其中一个，字典序
    /// 还是随机的——只断言一个就是碰运气。两个都断言，这条变异**必然**变红。
    @MainActor
    func testTheExecutionHandleIsFetchedBySourceIDNotByWhicheverComesFirst() async {
        let macProvider = NilProvider(id: "local_mac")
        let workProvider = NilProvider(id: "src_nas_work")
        let scheduler = SearchScheduler(providers: [])
        let snapshot = AuthorizedSourceSnapshot(
            scope: scope(["local_mac", "src_nas_work"]),
            registry: [
                AuthoritySource(id: "local_mac", name: "This Mac",
                                execution: SourceExecutionHandle(provider: macProvider,
                                                                 scheduler: scheduler)),
                AuthoritySource(id: "src_nas_work", name: "Work NAS",
                                execution: SourceExecutionHandle(provider: workProvider,
                                                                 scheduler: scheduler)),
            ])

        XCTAssertTrue(snapshot.execution(for: "local_mac")?.provider === macProvider,
                      "local_mac 拿到的不是自己的 provider")
        XCTAssertTrue(snapshot.execution(for: "src_nas_work")?.provider === workProvider,
                      "src_nas_work 拿到的不是自己的 provider")
        XCTAssertNil(snapshot.execution(for: "src_nas_private"),
                     "不在快照里的 id 不许拿到任何执行句柄")
    }

    // MARK: - 小工具

    /// 只当「身份载体」的 provider：这条用例不真的跑搜索。
    private final class NilProvider: SearchProvider, @unchecked Sendable {
        let source: SearchSource
        init(id: String) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
        }
        func search(_ text: String, queryID: UUID, owner: SearchOwner,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {}
        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {}
        func cancel(queryID: UUID) {}
    }

    private static var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
