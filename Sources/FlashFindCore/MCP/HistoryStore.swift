import Foundation
import CSQLite

/// History 记录的**动作**集合（方案 §6.2）。
///
/// ```text
/// located    locate / locate_many / search / recent 真正把这条结果交给了 Agent
/// metadata   调用了一次 get_metadata
/// ```
///
/// ★ 这里**只有两个值**。`selected` / `open` / `read` 一律不预留：
/// 「被返回过」只代表 Agent 看到了，不代表它选了它——那条语义在 v0.2 已经冻结
/// （§6.2.1）。预留一个永远不会被写入的动作值，等于在库里放一列假数据。
public enum HistoryAction: String, Equatable, Sendable, CaseIterable {
    case located
    case metadata
}

/// 一条历史事实：「某个会话里的某个客户端，在某一刻看到了某个文件」。
///
/// ## 它是**旁路**数据
///
/// ```text
/// 写失败 → 只丢一条事件，Tool Call 照常成功
/// ```
///
/// ★ 与 `FileReferenceStore` 正好相反：那边写失败**必须**让 Tool Call 失败
/// （否则会发出兑现不了的 id），这边写失败**必须不让** Tool Call 失败
/// （否则一个与本次搜索无关的磁盘问题会毁掉整次搜索，§6.6）。
///
/// ## ★ 里面没有查询词、没有绝对路径、没有凭据、没有 size / mtime
///
/// 只有 `session_id` + `agent_id`（两个不可信标签）+ `file_id` + `source_id`
/// + 动作 + 时刻 + 当时的相对路径。这条是 §6.3 的机器执行版本。
///
/// ★ **为什么不记 `size` / `mtime`**：§4.11 冻结了「完整元数据只有一个出口 ——
///   `get_metadata`」，在这里再存一份就是同一事实的第二份说法；而 1.1.2 不实现
///   `changed_since_last_access`（§4.4），这两列**没有任何消费者**。
///   与 6.4b-0 删掉 `FileReferenceStore.kind` / `last_seen_at` 是同一条纪律：
///   **没有现行用途的字段不预留**（§15 #30）。
public struct AccessEvent: Equatable, Sendable {

    /// Helper 进程标识（不可信标签）。
    public let sessionID: String
    /// MCP 客户端标识（不可信标签）。
    public let agentID: String
    public let fileID: FileID
    public let sourceID: String
    public let action: HistoryAction
    /// 事件发生时刻。
    public let timestamp: Date
    /// 当时解析出来的相对路径（已过 `RelativePath.isSafe`）。
    public let lastKnownRelativePath: String

    public init(sessionID: String,
                agentID: String,
                fileID: FileID,
                sourceID: String,
                action: HistoryAction,
                timestamp: Date,
                lastKnownRelativePath: String) {
        self.sessionID = sessionID
        self.agentID = agentID
        self.fileID = fileID
        self.sourceID = sourceID
        self.action = action
        self.timestamp = timestamp
        self.lastKnownRelativePath = lastKnownRelativePath
    }
}

/// History 库的标准位置。
///
/// ```text
/// ~/Library/Application Support/FlashFind2/ai-history.sqlite
/// ```
///
/// ★ 与 `FileReferenceStorePath` **同目录、不同文件**：历史会被用户主动清空，
///   映射表不会；两个生命周期绑在同一个文件里，「清空 AI 历史」就会顺手
///   清掉 Agent 手里已有 `file_id` 的解析能力（§15.3）。
public enum HistoryStorePath {

    public static let fileName = "ai-history.sqlite"

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(FileReferenceStorePath.directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}

public enum HistoryStoreError: Error, Equatable, Sendable {

    /// 路径没通过 `RelativePath.isSafe`。
    case unsafePath
    /// 库里的行读回来不满足不变量（被改坏 / 被旧版本写坏）。
    ///
    /// ★ 与 `FileReferenceStore` 同一条纪律：读侧只有一个结论——
    ///   这一行不能信，不许拿去返回给 Agent。
    case corruptRow
    /// SQLite 层失败。
    case storage(String)
}

/// `access_event` 的唯一实现（方案 §6.1）。
///
/// ```sql
/// CREATE TABLE IF NOT EXISTS access_event(
///     id INTEGER PRIMARY KEY,
///     session_id TEXT NOT NULL,
///     agent_id TEXT NOT NULL,
///     file_id TEXT NOT NULL,
///     source_id TEXT NOT NULL,
///     action TEXT NOT NULL,
///     timestamp REAL NOT NULL,
///     last_known_relative_path TEXT NOT NULL
/// );
/// ```
///
/// ## ★ 保留与清理：90 天 / 20 000 条，先到为准
///
/// 两条边界**都**执行：先按时间删一遍，再按条数删一遍。`prune` 是幂等的，
/// 且**不放在请求路径上**——只在启动时与每日维护里调（§6.5）。
///
/// ## ★ `located` 的去重 = 部分唯一索引
///
/// ```sql
/// CREATE UNIQUE INDEX … ON access_event(session_id, file_id) WHERE action='located';
/// ```
///
/// 用**数据库约束**而不是「先查一次再决定插不插」：后者在两个写者之间天然有窗口，
/// 而这个库将来可能被第二个进程打开。撞约束时按 §6.2.2 当成幂等处理——
/// 同一 `(session, file)` 的第二条 `located` 什么都不做。
///
/// `metadata` **不**在这个索引里：Phase 8 要用它的**次数**算 `metadata-access`，
/// 去重会把信号掐掉。
///
/// ## 并发：单写者 + WAL
///
/// 所有 SQLite 访问都发生在自己的串行队列上（与 `FileReferenceStore` 同一手法），
/// 因此不需要额外加锁。WAL 只解决「跨进程读写并发」。
public final class HistoryStore: @unchecked Sendable {

    /// 表名。诊断与结构测试共用这一处。
    public static let tableName = "access_event"

    /// 建表语句。**列名与索引闭集就写在里**——结构测试会解析它。
    public static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS access_event(
            id INTEGER PRIMARY KEY,
            session_id TEXT NOT NULL,
            agent_id TEXT NOT NULL,
            file_id TEXT NOT NULL,
            source_id TEXT NOT NULL,
            action TEXT NOT NULL,
            timestamp REAL NOT NULL,
            last_known_relative_path TEXT NOT NULL
        );
        CREATE INDEX IF NOT EXISTS access_event_recent ON access_event(timestamp DESC);
        CREATE INDEX IF NOT EXISTS access_event_by_file ON access_event(file_id, timestamp DESC);
        CREATE INDEX IF NOT EXISTS access_event_session ON access_event(session_id, timestamp DESC);
        CREATE UNIQUE INDEX IF NOT EXISTS access_event_located_once
            ON access_event(session_id, file_id) WHERE action='located';
        """

    /// 保留窗口：最近 90 天。
    public static let retentionDays = 90
    /// 条数上限：20 000 条。
    public static let maxEvents = 20_000

    private var handle: OpaquePointer?
    /// ★ 与 `FileReferenceStore` 同一条纪律：**唯一**的 SQLite 访问点。
    private let queue = DispatchQueue(label: "com.flashfind.mcp.history-store")
    private var insertStatement: OpaquePointer?

    public let url: URL

    public init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        guard chmod(directory.path, 0o700) == 0 else {
            throw HistoryStoreError.storage("could not restrict the history store directory")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open the history store"
            sqlite3_close(handle)
            throw HistoryStoreError.storage(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try exec(Self.schemaSQL)
            // 0600：里面没有凭据，但它是「这台机器上 Agent 看过哪些文件」的地图。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            insertStatement = try prepare("""
                INSERT INTO access_event(session_id, agent_id, file_id, source_id,
                                         action, timestamp, last_known_relative_path)
                VALUES(?,?,?,?,?,?,?)
                """)
        } catch {
            close()
            throw error
        }
    }

    deinit { close() }

    public func close() {
        queue.sync {
            if let insertStatement { sqlite3_finalize(insertStatement) }
            insertStatement = nil
            if let handle { sqlite3_close(handle) }
            handle = nil
        }
    }

    // MARK: - 写

    /// 记一条 `located`：这一次**真的**把这条结果交给了 Agent。
    ///
    /// ★ 同一 `(session_id, file_id)` 已有 `located` → 什么都不做（§6.2.2）。
    ///   目的不是省空间，而是让「被看到过」这件事**不因次数放大**：
    ///   `located-recently` 只看最近一次时间，不按次数累加（§7.1.2）。
    public func recordLocated(_ event: AccessEvent) throws {
        try queue.sync { try insert(event, action: .located) }
    }

    /// 一批 `located`，**一个事务**。
    ///
    /// ★ 用事务不是为了原子性（历史本来就是旁路、可以丢），而是为了**速度**：
    ///   一次 `search` 最多 50 条，逐条各自提交会多写 50 次 WAL。
    ///   失败照抛，由 `HistorySink` 决定怎么降级。
    public func recordLocatedAll(_ events: [AccessEvent]) throws {
        try queue.sync {
            guard !events.isEmpty else { return }
            try exec("BEGIN IMMEDIATE")
            do {
                for event in events { try insert(event, action: .located) }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    /// 记一条 `metadata`：调用一次就记一次，**不做去重**。
    ///
    /// ★ Phase 8 的 `metadata-access` 要用次数算 `1-exp(-n/5)`，
    ///   这里去重会让信号永远停在 n=1。
    public func recordMetadata(_ event: AccessEvent) throws {
        try queue.sync { try insert(event, action: .metadata) }
    }

    /// 一次写入。**只在队列里调**（不再进一次队列），失败照实抛。
    private func insert(_ event: AccessEvent, action: HistoryAction) throws {

        // ★ 只验证，不修复：写入的永远是「当初解析出来的那条相对路径」。
        guard RelativePath.isSafe(event.lastKnownRelativePath) else {
            throw HistoryStoreError.unsafePath
        }
        guard let statement = insertStatement else {
            throw HistoryStoreError.storage("history store is closed")
        }

        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(statement, 1, event.sessionID)
        bind(statement, 2, event.agentID)
        bind(statement, 3, event.fileID.value)
        bind(statement, 4, event.sourceID)
        bind(statement, 5, action.rawValue)
        bind(statement, 6, event.timestamp.timeIntervalSince1970)
        bind(statement, 7, event.lastKnownRelativePath)

        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return }
        // 撞的是「同 session 同文件已经记过 located」——按幂等处理。
        // ★ 换任何别的错误都必须照实抛，不许拿幂等当遮羞布。
        guard rc == SQLITE_CONSTRAINT, action == .located else { throw error() }
    }

    // MARK: - 读

    /// `recent` 与 `recentDistinct` 共用的筛选条件。
    ///
    /// ★ **只此一处**：两处各写一份的话，「筛选口径」就有两个出处 ——
    ///   改了一边、另一边静默保留旧行为，而两边都编译得过。
    private static func whereConditions(sourceIDs: [String]?, withinDays: Int?) -> [String] {
        var conditions: [String] = []
        if withinDays != nil { conditions.append("timestamp >= ?") }
        if let sourceIDs, !sourceIDs.isEmpty {
            conditions.append("source_id IN (\(Self.placeholders(sourceIDs.count)))")
        }
        return conditions
    }

    /// 最近的事件，新在前。**只看 History，不判权**——判定在上层。
    ///
    /// - Parameters:
    ///   - limit: 最多取多少条候选（不是最终返回条数：上层还要按授权筛）。
    ///   - sourceIDs: `nil` = 不限；给值 = 只取这些来源。
    ///   - withinDays: `nil` = 不限；给值 = 只取最近这么多天。
    ///
    /// ★ `source_ids` 是 `recent` Tool 筛来源的**唯一一处**：真正的**放行判定**
    ///   发生在更早的 `PermissionPolicy`（§5.2.2），这里只是把那份已经收紧过的
    ///   交集带下来当筛选条件用。★ 调用方循环里**不许**再筛一遍——两处都筛时，
    ///   删掉任意一处的变异都不会变红，规则看起来被守住了，其实只是被守了两遍。
    public func recent(limit: Int,
                       sourceIDs: [String]? = nil,
                       withinDays: Int? = nil,
                       now: Date = Date()) throws -> [AccessEvent] {

        try queue.sync {
            let conditions = Self.whereConditions(sourceIDs: sourceIDs, withinDays: withinDays)
            var sql = """
                SELECT session_id, agent_id, file_id, source_id, action, timestamp,
                       last_known_relative_path
                FROM access_event
                """
            if !conditions.isEmpty { sql += " WHERE " + conditions.joined(separator: " AND ") }
            sql += " ORDER BY timestamp DESC, id DESC LIMIT ?"

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            // ★ 不给天数就是「不按时间筛」，而不是「筛 0 天」：写成
            //   `timestamp >= 0` 会把 1970 年前的时间戳也放进来，而那种值
            //   只可能来自损坏的行。
            var index: Int32 = 1
            if let days = withinDays {
                let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                sqlite3_bind_double(statement, index, cutoff.timeIntervalSince1970)
                index += 1
            }
            for id in sourceIDs ?? [] {
                bind(statement, index, id)
                index += 1
            }
            sqlite3_bind_int64(statement, index, Int64(limit))

            var events: [AccessEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(try Self.event(from: statement))
            }
            return events
        }
    }

    /// 每个文件**只取最近一条**事件，新在前（build 29 补，代码审核 BUG-112-03）。
    ///
    /// ## 为什么不能沿用 `recent(limit:)` 再在上层折叠
    ///
    /// 上层的做法是「先取 N 条事件，再按 `file_id` 去重」。可 `metadata` 事件是
    /// **按设计每次访问都记一条**的，于是同一个文件很容易占满那 N 条：
    ///
    /// ```text
    /// A 被看了 20 次（20 条事件），B 只看过 1 次（较早）
    /// recent(limit: 2) 先取 max(2*4, 2+16) = 18 条 → 全是 A
    /// 折叠之后只剩 1 条，还被报成 truncated=false
    /// ```
    ///
    /// 用户看到的是「明明昨天还看过另一个文件，它说没有」。固定倍数挡不住这种形态，
    /// 因为「一个文件能刷多少次」没有上界。
    ///
    /// 这里改成**在 SQL 里按文件收敛**：`id IN (SELECT MAX(id) … GROUP BY file_id)`。
    /// 同一文件的事件按写入顺序落库，`MAX(id)` 就是它最近的那一条
    /// （不依赖窗口函数，SQLite 3.25 以下也能跑）。
    ///
    /// - Parameters:
    ///   - offset: 已消费的**不同文件**数。上层靠它翻页，才能在遇到 stale 时继续往下取。
    public func recentDistinct(limit: Int,
                               sourceIDs: [String]? = nil,
                               withinDays: Int? = nil,
                               now: Date = Date(),
                               offset: Int = 0) throws -> [AccessEvent] {
        try queue.sync {
            let conditions = Self.whereConditions(sourceIDs: sourceIDs, withinDays: withinDays)
            let whereClause = conditions.isEmpty
                ? ""
                : " WHERE " + conditions.joined(separator: " AND ")

            // 条件写两遍：子查询负责「每个文件挑出最近那条」，外层再收一次范围。
            let sql = """
                SELECT session_id, agent_id, file_id, source_id, action, timestamp,
                       last_known_relative_path
                FROM access_event
                \(conditions.isEmpty ? " WHERE " : whereClause + " AND ")id IN (
                    SELECT MAX(id) FROM access_event\(whereClause) GROUP BY file_id
                )
                ORDER BY timestamp DESC, id DESC
                LIMIT ? OFFSET ?
                """

            let statement = try prepare(sql)
            defer { sqlite3_finalize(statement) }

            var index: Int32 = 1
            // 两遍条件参数顺序必须与外层/子查询在 SQL 里出现的先后一致。
            for _ in 0..<2 {
                if let days = withinDays {
                    let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
                    sqlite3_bind_double(statement, index, cutoff.timeIntervalSince1970)
                    index += 1
                }
                for id in sourceIDs ?? [] {
                    bind(statement, index, id)
                    index += 1
                }
            }
            sqlite3_bind_int64(statement, index, Int64(limit))
            index += 1
            sqlite3_bind_int64(statement, index, Int64(offset))

            var events: [AccessEvent] = []
            while sqlite3_step(statement) == SQLITE_ROW {
                events.append(try Self.event(from: statement))
            }
            return events
        }
    }

    /// 行数。诊断与用例用。
    public func count() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM access_event")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    /// 清空全部事件。
    ///
    /// ★ **只**清 `access_event`：映射表（`FileReferenceStore`）是另一个库，
    ///   清掉它会让 Agent 手里已有的 `file_id` 全部失效（§6.5 / §15.3）。
    public func clear() throws {
        try queue.sync { try exec("DELETE FROM access_event") }
    }

    // MARK: - 清理

    /// 修剪到保留窗口内。**先到为准**：超 90 天的删、超过 20 000 条的删。
    ///
    /// - Returns: 删掉了多少条。
    @discardableResult
    public func prune(now: Date = Date()) throws -> Int {
        try queue.sync {
            let before = try countHere()
            let cutoff = now.addingTimeInterval(-Double(Self.retentionDays) * 86_400)
            try exec("DELETE FROM access_event WHERE timestamp < \(cutoff.timeIntervalSince1970)")
            // 条数上限：按「保留最新的 maxEvents 条」执行，老的先走。
            try exec("""
                DELETE FROM access_event WHERE id NOT IN (
                    SELECT id FROM access_event ORDER BY timestamp DESC, id DESC
                    LIMIT \(Self.maxEvents)
                )
                """)
            return before - (try countHere())
        }
    }

    // MARK: - SQLite 细节

    /// `?,?,?` —— `IN` 列表的占位符。
    private static func placeholders(_ count: Int) -> String {
        Array(repeating: "?", count: count).joined(separator: ",")
    }

    /// 队列内的行数（**不**再进一次队列）。
    private func countHere() throws -> Int {
        let statement = try prepare("SELECT COUNT(*) FROM access_event")
        defer { sqlite3_finalize(statement) }
        guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
        return Int(sqlite3_column_int64(statement, 0))
    }

    private static func event(from statement: OpaquePointer) throws -> AccessEvent {
        guard let fileID = FileID.parse(text(statement, 2)),
              let action = HistoryAction(rawValue: text(statement, 4)) else {
            throw HistoryStoreError.corruptRow
        }
        return AccessEvent(sessionID: text(statement, 0),
                            agentID: text(statement, 1),
                            fileID: fileID,
                            sourceID: text(statement, 3),
                            action: action,
                            timestamp: Date(timeIntervalSince1970: sqlite3_column_double(statement, 5)),
                            lastKnownRelativePath: text(statement, 6))
    }

    private static func text(_ statement: OpaquePointer, _ index: Int32) -> String {
        guard let pointer = sqlite3_column_text(statement, index) else { return "" }
        return String(cString: pointer)
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: Double) {
        sqlite3_bind_double(statement, index, value)
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw HistoryStoreError.storage("history store is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        guard let handle else { throw HistoryStoreError.storage("history store is closed") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func error() -> HistoryStoreError {
        .storage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "history store is closed")
    }
}
