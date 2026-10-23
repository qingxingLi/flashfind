import XCTest
@testable import FlashFindCore
import CSQLite

/// Phase 7b：`HistoryStore`（方案 §6.1 / §6.2 / §6.5 / §6.6）。
///
/// ## 这一组守的五件事
///
/// ```text
/// ① located 一个 session 一次   —— 不因次数放大「被看过」
/// ② metadata 每次都记           —— Phase 8 要按次数算 metadata-access
/// ③ 两个 session 互不污染       —— 去重键里必须有 session_id
/// ④ 修剪两条边界                —— 90 天 / 20 000 条，先到为准
/// ⑤ 库里没有查询词 / 绝对路径   —— 键闭集机器执行
/// ```
///
/// ★ 所有来源 id、文件名都是编造的；库一律落在临时目录。
final class HistoryStoreTests: XCTestCase {

    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ff2-hist-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - 脚手架

    private func makeStore() throws -> HistoryStore {
        try HistoryStore(url: scratch.appendingPathComponent("ai-history.sqlite"))
    }

    private var base: Date { Date(timeIntervalSince1970: 1_800_000_000) }

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

    // MARK: - ① located 的去重

    /// 同一个 session 里，同一个文件只记一次。
    ///
    /// ★ §6.2.2 的机器执行版本：20 次 locate 都返回同一个文件，
    ///   与 1 次 locate 返回它，在 History 里留下的痕迹必须一样——
    ///   否则 `located-recently` 会被次数带偏，而它的权重只有 0.05，
    ///   最容易被次数淹没。
    func testLocatedIsRecordedOncePerSessionPerFile() throws {
        let store = try makeStore()
        defer { store.close() }

        let event = try self.event(.located, path: "共享/预算.xlsx")
        for _ in 0..<5 { try store.recordLocated(event) }

        XCTAssertEqual(try store.count(), 1)
    }

    /// ★★ 两个 Helper 进程互不污染：session 不同 ⇒ 各记一次。
    ///
    /// 去重键若是 `file_id` 而不是 `(session_id, file_id)`，
    /// 第二个助手就永远记不下它看过什么——而这种 bug **只在开两个客户端时才出现**，
    /// 单会话下无论怎么实现都表现正常。
    func testTwoHelperSessionsDoNotShareTheLocatedDedup() throws {
        let store = try makeStore()
        defer { store.close() }

        let path = "共享/预算.xlsx"
        try store.recordLocated(try event(.located, path: path, session: "sess-A"))
        try store.recordLocated(try event(.located, path: path, session: "sess-B"))

        XCTAssertEqual(try store.count(), 2, "不同 session 必须各记一条")
    }

    /// 不同文件当然各记各的。
    func testDifferentFilesAreRecordedSeparately() throws {
        let store = try makeStore()
        defer { store.close() }

        for index in 0..<4 {
            try store.recordLocated(try event(.located, path: "共享/文件\(index).pdf"))
        }
        XCTAssertEqual(try store.count(), 4)
    }

    // MARK: - ② metadata 不去重

    /// 每次成功的 `get_metadata` 都记一条。
    ///
    /// ★ 与 `located` 正好相反，且**必须**相反：Phase 8 的
    ///   `metadata-access` 按 `1-exp(-n/5)` 用次数，去重会让信号永远停在 n=1。
    ///   这条用例是「顺手给 metadata 也加个唯一索引」那个改动的直接抓手。
    func testMetadataIsRecordedEveryTime() throws {
        let store = try makeStore()
        defer { store.close() }

        let event = try self.event(.metadata, path: "共享/预算.xlsx")
        for _ in 0..<5 { try store.recordMetadata(event) }

        XCTAssertEqual(try store.count(), 5)
    }

    /// 同一个文件：一次 located + 三次 metadata = 四条事件。
    func testLocatedAndMetadataCoexist() throws {
        let store = try makeStore()
        defer { store.close() }

        let path = "共享/预算.xlsx"
        try store.recordLocated(try event(.located, path: path))
        for _ in 0..<3 { try store.recordMetadata(try event(.metadata, path: path)) }

        XCTAssertEqual(try store.count(), 4)
    }

    // MARK: - ③ 读取顺序

    /// `recent` 按时间倒序；同一刻则后写的在前（`id DESC`）。
    func testRecentIsNewestFirst() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/旧.pdf", at: base.addingTimeInterval(-100)))
        try store.recordLocated(try event(.located, path: "共享/新.pdf", at: base))
        try store.recordLocated(try event(.located, path: "共享/中.pdf", at: base.addingTimeInterval(-50)))

        let paths = try store.recent(limit: 10).map(\.lastKnownRelativePath)
        XCTAssertEqual(paths, ["共享/新.pdf", "共享/中.pdf", "共享/旧.pdf"])
    }

    /// `source_ids` 只是候选筛选器：真正的授权收紧发生在更早的判定里。
    ///
    /// ★ 这条只证明「筛选器生效」，不证明「它能扩大授权」——后者由
    ///   `PermissionPolicyTests` / `AuthorityServiceTests` 守着。
    func testRecentHonoursTheSourceFilter() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/A.pdf", source: "src_nas_work"))
        try store.recordLocated(try event(.located, path: "归档/B.pdf", source: "src_nas_archive"))

        let only = try store.recent(limit: 10, sourceIDs: ["src_nas_archive"])
        XCTAssertEqual(only.map(\.sourceID), ["src_nas_archive"])
    }

    /// `within_days` = 不传就**不按时间筛**，不是「筛 0 天」。
    func testRecentHonoursWithinDays() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/三天前.pdf", at: base.addingTimeInterval(-3 * 86_400)))
        try store.recordLocated(try event(.located, path: "共享/十天前.pdf", at: base.addingTimeInterval(-10 * 86_400)))

        let week = try store.recent(limit: 10, withinDays: 7, now: base)
        XCTAssertEqual(week.map(\.lastKnownRelativePath), ["共享/三天前.pdf"])

        let all = try store.recent(limit: 10, now: base)
        XCTAssertEqual(all.count, 2, "不传 within_days 不该把老事件筛掉")
    }

    /// `limit` 只作用在**候选**上；授权筛选之后只会更少，不会更多。
    func testRecentLimitBoundsTheCandidateSet() throws {
        let store = try makeStore()
        defer { store.close() }

        for index in 0..<10 {
            try store.recordLocated(try event(.located, path: "共享/文件\(index).pdf"))
        }
        XCTAssertEqual(try store.recent(limit: 3).count, 3)
    }

    // MARK: - ④ 修剪

    /// 边界一：超过 90 天的删掉，**正好 90 天的留着**。
    func testPruneDropsEventsOlderThanNinetyDays() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/新鲜.pdf", at: base))
        try store.recordLocated(try event(.located, path: "共享/正好九十天.pdf",
                                        at: base.addingTimeInterval(-90 * 86_400)))
        try store.recordLocated(try event(.located, path: "共享/九十一天前.pdf",
                                          at: base.addingTimeInterval(-91 * 86_400)))

        let removed = try store.prune(now: base)
        XCTAssertEqual(removed, 1, "只有超 90 天的那一条该被删")
        let paths = try store.recent(limit: 10).map(\.lastKnownRelativePath)
        XCTAssertTrue(paths.contains("共享/正好九十天.pdf"), "边界值要保留（>=）")
        XCTAssertFalse(paths.contains("共享/九十一天前.pdf"))
    }

    /// 边界二：最多保留 20 000 条，超出的按时间从老的先删。
    func testPruneKeepsAtMostTwentyThousand() throws {
        let store = try makeStore()
        defer { store.close() }

        let total = HistoryStore.maxEvents + 50
        for index in 0..<total {
            // 时间戳严格递增 ⇒ 保留下来的必须是最大的那 20 000 条。
            try store.recordLocated(try event(.located,
                                              path: "共享/文件\(index).pdf",
                                              at: base.addingTimeInterval(Double(index))))
        }
        XCTAssertEqual(try store.count(), total)

        try store.prune(now: base.addingTimeInterval(Double(total)))

        let kept = try store.recent(limit: HistoryStore.maxEvents + 10)
        XCTAssertEqual(kept.count, HistoryStore.maxEvents)
        // 最新的一条必须还在（老的在 90 天窗口内也保留，只按条数裁）。
        XCTAssertEqual(kept.first?.lastKnownRelativePath, "共享/文件\(total - 1).pdf")
    }

    /// 修剪是幂等的，且不碰仍在窗口内的行。
    func testPruneIsIdempotent() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/保留.pdf", at: base))
        XCTAssertEqual(try store.prune(now: base), 0)
        XCTAssertEqual(try store.prune(now: base), 0)
        XCTAssertEqual(try store.count(), 1)
    }

    // MARK: - ⑤ 不存什么的机器执行

    /// ★ `access_event` 的列闭集：只有这九列，没有查询词 / 绝对路径 / 凭据。
    ///
    /// 与 `HistoryContext` 的键闭集合起来就是 §6.3 的机器执行版本：
    /// 想多存一类信息，得先改 schema，而改它会让这条用例红。
    func testTheRowCarriesExactlyEightColumns() throws {
        let columns = Self.columns(of: HistoryStore.schemaSQL)
        XCTAssertEqual(columns, ["id", "session_id", "agent_id", "file_id", "source_id",
                                 "action", "timestamp", "last_known_relative_path"],
                   "access_event 的列闭集变了：\(columns)")
    }

    /// History 里**没有** size / mtime 列。
    ///
    /// ★ 这是 §6.1 相对早期草案的一处收紧：那两列没有消费者
    ///   （`changed_since_last_access` 在 1.1.2 不实现，§4.4），
    ///   而它们一旦存在就会变成「元数据的第二份说法」，与 §4.11「完整元数据
    ///   只有 `get_metadata` 一个出口」冲突。
    func testTheRowCarriesNoSizeOrTimeSnapshot() throws {
        let schema = HistoryStore.schemaSQL
        XCTAssertFalse(schema.contains("size_at_access"),
                       "History 不该存 size 快照：要大小就调 get_metadata")
        XCTAssertFalse(schema.contains("mtime_at_access"),
                       "History 不该存 mtime 快照：要时间就调 get_metadata")
    }

    /// 动作集合恒等于这两个值——多一个就说明有人预留了没实现的动作。
    func testTheActionSetIsExactlyLocatedAndMetadata() {
        XCTAssertEqual(Set(HistoryAction.allCases.map(\.rawValue)), ["located", "metadata"])
    }

    /// 绝对路径的事件**绝不入库**（不修、不截断，直接拒）。
    func testAnAbsolutePathIsRejected() throws {
        let store = try makeStore()
        defer { store.close() }

        // ★ 故意让「id」与「路径字段」对不上：Store 校验的是**路径字段本身**，
        //   不依赖调用方有没有先算过 id。少这一层校验，历史里就会混进绝对路径，
        //   而 §6.3 明令不存绝对路径。
        let event = AccessEvent(sessionID: "sess-A",
                                agentID: "flashfind-tests/0.0.0",
                                fileID: try FileID.make(sourceID: "src_nas_work",
                                                         canonicalRelativePath: "共享/预算.xlsx"),
                                sourceID: "src_nas_work",
                                action: .located,
                                timestamp: base,
                                lastKnownRelativePath: "/Volumes/共享/预算.xlsx")
        XCTAssertThrowsError(try store.recordLocated(event)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .unsafePath)
        }
        XCTAssertEqual(try store.count(), 0)
    }

    /// 穿越型路径同样拒绝：`..` 不修，直接拒（§3.2.1.1）。
    func testATraversalIsRejected() throws {
        let store = try makeStore()
        defer { store.close() }

        let event = AccessEvent(sessionID: "sess-A",
                                agentID: "flashfind-tests/0.0.0",
                                fileID: try FileID.make(sourceID: "src_nas_work",
                                                         canonicalRelativePath: "共享/预算.xlsx"),
                                sourceID: "src_nas_work",
                                action: .metadata,
                                timestamp: base,
                                lastKnownRelativePath: "共享/../私密.pdf")
        XCTAssertThrowsError(try store.recordMetadata(event)) { error in
            XCTAssertEqual(error as? HistoryStoreError, .unsafePath)
        }
        XCTAssertEqual(try store.count(), 0)
    }

    /// 清空只清事件，不动映射表（映射表在另一个库，这里顺带断言本库为空）。
    func testClearEmptiesEveryEvent() throws {
        let store = try makeStore()
        defer { store.close() }

        try store.recordLocated(try event(.located, path: "共享/A.pdf"))
        try store.clear()
        XCTAssertEqual(try store.count(), 0)
        XCTAssertTrue(try store.recent(limit: 10).isEmpty)
    }

    /// 重启（重开句柄）后历史仍在。
    func testTheHistorySurvivesAReopen() throws {
        let url = scratch.appendingPathComponent("ai-history.sqlite")
        do {
            let store = try HistoryStore(url: url)
            try store.recordLocated(try event(.located, path: "共享/预算.xlsx"))
            store.close()
        }
        let reopened = try HistoryStore(url: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.count(), 1)
    }

    // MARK: - 并发

    /// 8 个任务同时写读，不许出现锁失败。
    func testConcurrentWritersDoNotLockEachOtherOut() async throws {
        let store = try makeStore()
        defer { store.close() }

        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<8 {
                group.addTask {
                    let event = try self.event(.located, path: "共享/文件\(index).pdf")
                    try store.recordLocated(event)
                    _ = try store.count()
                }
            }
        }
        XCTAssertEqual(try store.count(), 8)
    }

    /// 结构：九个入口全走同一条串行队列（因此不需要额外的锁）。
    ///
    /// ```text
    /// close / recordLocated / recordLocatedAll / recordMetadata
    /// recent / recentDistinct / count / clear / prune
    /// ```
    ///
    /// ★ 阈值取**正好 9**而不是一个宽松的下界：只要有人新加了一个直接摸
    ///   `handle` 的入口、忘了包 `queue.sync`，这里就该红。写成 `>= 5` 的话，
    ///   删掉任意一处都还是 7，规则看起来被守着，其实已经漏了一个口子。
    ///
    /// ★ `recentDistinct` 是 build 29 加的（BUG-112-03：先按文件收敛再限量），
    ///   它和 `recent` 一样必须走这条队列——两者会读同一批行。
    func testEveryEntryPointGoesThroughOneSerialQueue() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/HistoryStore.swift")
        XCTAssertFalse(text.contains("NSLock"),
                       "串行队列已保证互斥，再加一把锁必然有一处是多余的")
        let entries = text.components(separatedBy: "queue.sync").count - 1
        XCTAssertEqual(entries, 9, "有入口没走队列（或多了个入口没登记）：\(entries)")
    }

    // MARK: - 小工具

    private func code(of relativePath: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent(relativePath)
        let source = try String(contentsOf: url, encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 从 `CREATE TABLE access_event(...)` 里切出列名。
    private static func columns(of schema: String) -> [String] {
        guard let open = schema.range(of: "access_event(") else { return [] }
        let rest = schema[open.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return [] }
        let body = rest[rest.startIndex..<close]
        return body
            .split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.hasPrefix("UNIQUE") }
            .compactMap { line in
                let parts = line.split(separator: " ")
                return parts.isEmpty ? nil : String(parts[0])
            }
    }
}
