import XCTest
@testable import FlashFindCore

/// Phase 7e：History 的**生命周期闸门**（方案 §6.5）。
///
/// ## 这一组守的四件事
///
/// ```text
/// ① 启动/首次调用 → 真的跑一次修剪
/// ② 同一天第二次  → 空操作（返回 false，不扫表）
/// ③ 跨过 24 小时  → 再跑一次
/// ④ 没有 History 库 → 不崩、不报错，只当这次没跑
/// ```
///
/// ## ★★ 为什么「每日一次」这件事值得单独写测试
///
/// 修剪的**语义**（删什么）由 `HistoryStoreTests` 守着；这里守的是**什么时候跑**。
/// 这两件事容易被写成同一个函数，然后其中一个先坏掉：
///
/// ```text
/// 语义坏了  → 历史越攒越多（磁盘慢慢涨，没人立刻发现）
/// 时机坏了  → 修剪出现在请求热路径上（搜索变慢，且每台机器慢法不同）
/// ```
///
/// 方案 §6.5 明令「**不在请求路径上做**」。这条禁令本身需要一个可执行的判据，
/// 否则它只是一句好意。
///
/// ★ 所有来源 id、文件名都是编造的；库一律落在临时目录。
final class HistoryMaintenanceTests: XCTestCase {

    private var scratch: URL!

    private let base = Date(timeIntervalSince1970: 1_800_000_000)

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ff2-maint-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - 脚手架

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(url: scratch.appendingPathComponent("ai-history.sqlite"))
    }

    private func event(_ action: HistoryAction,
                       path: String,
                       source: String = "src_nas_work",
                       session: String = "sess-A",
                       at: Date? = nil) throws -> AccessEvent {
        AccessEvent(sessionID: session,
                    agentID: "flashfind-tests/0.0.0",
                    fileID: try FileID.make(sourceID: source, canonicalRelativePath: path),
                    sourceID: source,
                    action: action,
                    timestamp: at ?? base,
                    lastKnownRelativePath: path)
    }

    // MARK: - ① 首次调用真的跑

    /// 第一次 `runIfNeeded` 必须返回 `true`，并且**真的删掉**超窗的行。
    ///
    /// ★ 只断言返回值是不够的：一个「什么都不做但返回 true」的实现
    ///   会把 90 天保留窗口变成一句空话，而磁盘会一直涨。
    func testTheFirstRunPrunesForReal() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/新鲜.pdf", at: base))
        try store.recordLocated(try event(.located, path: "共享/一年前.pdf",
                                          at: base.addingTimeInterval(-400 * 86_400)))

        let maintenance = HistoryMaintenance(store: store)
        XCTAssertTrue(maintenance.runIfNeeded(now: base), "首次该跑")
        XCTAssertEqual(try store.count(), 1, "超 90 天的那一条该被删掉")
    }

    // MARK: - ② 同一天不重复

    /// 同一天第二次调用是**空操作**：返回 `false`，且不扫表。
    ///
    /// ★ 怎么证明「没扫表」：把库关掉。若第二次真的去扫，关闭的句柄会让
    ///   修剪抛错——虽然错误被吞，但返回值仍是 `true`，这条就红。
    ///   ★ 这是本轮唯一能把「空操作」写成行为断言的办法：
    ///     返回值相同、副作用相同，只有「有没有真的碰数据库」不同。
    func testTheSecondRunOnTheSameDayTouchesNothing() throws {
        let store = try makeStore()
        defer { store.close() }

        let maintenance = HistoryMaintenance(store: store)
        XCTAssertTrue(maintenance.runIfNeeded(now: base), "当天第一次该跑")

        store.close()  // 关掉之后任何一次真的修剪都会失败
        XCTAssertFalse(maintenance.runIfNeeded(now: base.addingTimeInterval(60)),
                       "同一天第二次必须是空操作：它不该去碰数据库")
        XCTAssertFalse(maintenance.runIfNeeded(now: base.addingTimeInterval(86_399)),
                       "差一秒不到一天也还是同一天")
    }

    // MARK: - ③ 跨天再跑

    /// 过了 24 小时，闸门重新打开。
    ///
    /// ★ 边界取**正好一天**：`stamp - previous < dayLength` 用的是严格小于，
    ///   所以正好 86 400 秒时该再跑一次。写错成 `<=` 会让修剪永远停在「今天」。
    func testANewDayOpensTheGateAgain() throws {
        let store = try makeStore()
        defer { store.close() }

        let maintenance = HistoryMaintenance(store: store)
        XCTAssertTrue(maintenance.runIfNeeded(now: base))
        XCTAssertFalse(maintenance.runIfNeeded(now: base.addingTimeInterval(60)))
        XCTAssertTrue(maintenance.runIfNeeded(now: base.addingTimeInterval(86_400)),
                      "正好过一天该再跑一次（边界是严格小于）")
    }

    // MARK: - ④ 没有库不是故障

    /// 没装 History 库时，闸门照常「跑过一次」，且**不崩、不抛**。
    ///
    /// ★ 与 §6.6 是同一条纪律：历史是旁路，它不在就不在，
    ///   不许把「没有历史」升级成一次失败。
    func testNoHistoryStoreIsNotAFailure() {
        let maintenance = HistoryMaintenance(store: nil)
        XCTAssertTrue(maintenance.runIfNeeded(now: base))
        XCTAssertFalse(maintenance.runIfNeeded(now: base.addingTimeInterval(10)),
                       "有没有库都不改变闸门本身的节律")
    }

    // MARK: - ⑤ 修剪失败不许冒泡

    /// 库是坏的（句柄已关）→ 修剪失败，但 `runIfNeeded` 照常返回，不抛。
    ///
    /// ★ 这条守的是 §6.6「写入/读取失败不得让搜索失败」的另一半：
    ///   维护任务的失败也不许冒泡到 App 的启动路径上。
    func testABrokenStoreDoesNotThrow() throws {
        let store = try makeStore()
        store.close()  // 让它之后的修剪一律抛

        let maintenance = HistoryMaintenance(store: store)
        XCTAssertTrue(maintenance.runIfNeeded(now: base), "跑过一次就算跑过，不因失败而反复重试")
    }
}
