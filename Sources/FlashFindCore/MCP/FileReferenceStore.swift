import Foundation
import CSQLite

/// 一条 `file_id` 的**反查记录**：这个不可逆的 id 当初是由谁、由哪条路径生成的。
///
/// ## 它是什么，不是什么（Phase 6.4b-0 冻结）
///
/// ```text
/// 是  ：file_id → (source_id, canonical_relative_path)     ← 只够重建 FileID.make 的前像
/// 不是：metadata 缓存（size / mtime / kind / name）
/// 不是：History（谁在什么时候用过哪个文件，不在这里）
/// ```
///
/// `get_metadata` 只收 `FileID`，而 SHA-256 的前 128 位**不可逆**——没有这张表，
/// 拿到 `ff1_…` 之后既不知道是哪个来源、也不知道是哪条路径，只能去全盘重扫。
/// 所以这张表的存在理由只有一个：让「Agent 手里那个 id」能被解释。
///
/// ★ 三列就是全部。**不预留** `kind` / `size` / `mtime` / `last_seen_at`：
/// 项目已经在 `query_hash` 上确立过这条纪律——没有现行用途的字段不要先加。
/// 元数据要么现查（`get_metadata` 的执行层），要么根本不该在这里有一份会过期的副本。
public struct FileReference: Equatable, Sendable {

    public let fileID: FileID
    public let sourceID: String
    /// 生成 `fileID` 时用的那条相对路径（**已经通过 `RelativePath.isSafe`**）。
    public let canonicalRelativePath: String

    public init(fileID: FileID, sourceID: String, canonicalRelativePath: String) {
        self.fileID = fileID
        self.sourceID = sourceID
        self.canonicalRelativePath = canonicalRelativePath
    }
}

/// `FileReference` 的出入口。**只验证，不修复；只查表，不授权。**
public enum FileReferenceStoreError: Error, Equatable, Sendable {

    /// 路径没通过 `RelativePath.isSafe`（绝对路径 / `..` / 空段 / NUL / 尾随斜杠）。
    case unsafePath
    /// `FileID.make(sourceID, path)` 算出来不是这个 id —— 三条字段互相对不上。
    case identityMismatch
    /// 库里的行读回来不满足写入时那条不变量（库被改坏 / 被别的版本写坏）。
    ///
    /// ★ 读侧**不允许**把它拆成「路径不安全」与「id 对不上」两种报错：
    /// 对调用方来说结论只有一个——这一行不能拿去 Provider 查。
    case corruptRow
    /// ★ **冲突即失败**（6.4b-1 冻结）：这个 `file_id` 已经指向别的位置。
    ///
    /// ```text
    /// 库里已有 ff1_x → sourceA/pathA
    /// 试图写入  ff1_x → sourceB/pathB
    ///        ↓
    /// 绝不 INSERT OR REPLACE，必须抛这个错
    /// ```
    ///
    /// deterministic `FileID` 让同一个 `(source, path)` 永远得到同一个 id，
    /// 但 128 位 hash 理论上仍会碰撞；更重要的是**库可能被别的路径写坏过**。
    /// 静默替换的后果是：Agent 手里那个 `ff1_x` 从「指向 A/pA」变成了
    /// 「指向 B/pB」，而它上一次拿到的结果还摆在同一段上下文里——
    /// 同一个 id 在两次调用之间换了所指，且没有任何一方被告知。
    case conflictingMapping
    /// SQLite 层失败。**不是**「没找到」。
    case storage(String)
}

/// 三列表的唯一实现（方案 §15.3）。
///
/// ```sql
/// CREATE TABLE file_reference (
///     file_id                 TEXT PRIMARY KEY,
///     source_id               TEXT NOT NULL,
///     canonical_relative_path TEXT NOT NULL,
///     UNIQUE(source_id, canonical_relative_path)
/// );
/// ```
///
/// ## 三条冻结的边界
///
/// 1. **Store 永远不授予权限。** `lookup` 只说「这个 id 曾经指向哪里」，
///    它不知道来源现在还在不在、还授不授权。判权在调用方，且是**每一次**都判
///    （过去返回过 ≠ 现在仍授权）。
/// 2. **坏路径绝不修。** 本类型**不调用** `RelativePath.canonical(...)`。
///    它只问「这条路径安不安全」「这个 id 和这条路径对不对得上」，不成立就拒绝。
///    悄悄修 `.` / `..` / `//` 会让两条不同的路径撞成同一个 `file_id`
///    （§3.2.1.1 有实测反例），那比「这条结果没进表」严重得多。
/// 3. **独立文件，与 History 不同生命周期。** 表在
///    `~/Library/Application Support/FlashFind2/ai-file-reference.sqlite`，
///    **不放进** `ai-history.sqlite`：否则用户点「清空 AI 历史」会顺手把 Agent
///    手里已有 id 的解析能力一起清掉。
///
/// ## 写入失败必须让步于「不许发出不能兑现的引用」
///
/// 本类型只负责如实报错；**「先落盘、再回成功响应」这条顺序由调用方保证**
/// （§4.11.4）：`registerAll` 抛错时，那一次 Tool Call 必须是 `internal_error`，
/// 不能照样把 `file_id` 发出去——否则 Agent 拿着一个重启后就 `file_not_found`
/// 的引用，而它在收到的当下看起来完全正常。
/// `@unchecked Sendable` 的根据：**所有** SQLite 访问都发生在自己的串行队列上。
///
/// 这个类型里除了队列之外只有一个 `OpaquePointer`（SQLite 句柄）。那个句柄
/// 从来不跨线程使用，所以真正的共享状态只有「队列」这一处共识——
/// 用 `@unchecked` 把这件事写下来，比留一个会在 Swift 6 模式里变成错误的
/// 警告要好（那条警告会把别的真警告淹掉）。
public final class FileReferenceStore: @unchecked Sendable {

    /// 表名。诊断与结构测试共用这一处。
    public static let tableName = "file_reference"

    /// 建表语句。**列名闭集就写在里**——`FileReferenceStoreTests` 会解析它，
    /// 加第四列会当场变红（「不预留字段」这条纪律的机器执行者）。
    public static let schemaSQL = """
        CREATE TABLE IF NOT EXISTS file_reference(
            file_id TEXT PRIMARY KEY,
            source_id TEXT NOT NULL,
            canonical_relative_path TEXT NOT NULL,
            UNIQUE(source_id, canonical_relative_path)
        );
        """

    private var handle: OpaquePointer?
    /// ★ **Store 自己的串行队列**（6.4b-1 冻结）：三个 Tool 并发时它是共享写点。
    ///
    /// ```text
    /// Agent A locate  ┐
    /// Agent B search  ├→ FileReferenceStore ─→ 一条串行队列
    /// Agent C locate_many ┘
    /// ```
    ///
    /// 不要指望「SQLite 大概扛得住」：偶发的 `database is locked` 会表现成
    /// MCP 搜索**随机** `internal_error`，那种故障在生产上几乎查不出来
    /// （复现不了、日志里只有一行锁超时）。WAL + `busy_timeout` 解决的是
    /// 跨进程争用，进程内的并发顺序由这条队列保证。
    ///
    /// ★ 队列是私有的：所有 SQLite 句柄访问都只在这条队列上发生，
    /// 因此不需要额外的锁（加了就必然有一处是多余的）。
    private let queue = DispatchQueue(label: "com.flashfind.mcp.file-reference-store")
    /// 复用的三条语句：批量注册时每条都 prepare 一次会慢 3 倍以上，而
    /// 一次 `locate_many` 最多 25 条、`search` 也常是几十条。
    private var insertStatement: OpaquePointer?
    private var lookupStatement: OpaquePointer?
    /// 冲突时读既有行用的那条（`insert` 在队列里，不能反过来走 `lookup` 再进队列）。
    private var existingStatement: OpaquePointer?

    public let url: URL

    /// 打开（必要时创建）表。
    ///
    /// - Parameter url: 数据库文件位置。测试用临时目录；产品用
    ///   `FileReferenceStorePath.standard()`。
    public init(url: URL) throws {
        self.url = url
        let directory = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory,
                                                withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        // 已存在的目录不会被 `createDirectory` 改权限，这里显式收一次（与
        // `AuthorityListener` 同一手法）。★ 这条不是洁癖：WAL 模式会额外生成
        // `-wal` / `-shm` 两个旁文件，它们由 SQLite 自己以默认权限创建；
        // 目录 0700 是唯一能同时挡住它们的边界。
        guard chmod(directory.path, 0o700) == 0 else {
            throw FileReferenceStoreError.storage("could not restrict the reference store directory")
        }
        var handle: OpaquePointer?
        guard sqlite3_open_v2(url.path, &handle,
                              SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,
                              nil) == SQLITE_OK, let handle else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "unable to open the reference store"
            sqlite3_close(handle)
            throw FileReferenceStoreError.storage(message)
        }
        self.handle = handle
        sqlite3_busy_timeout(handle, 5000)
        do {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try exec(Self.schemaSQL)
            // 0600：里面没有凭据，但它是「这台机器上 Agent 看过哪些文件」的地图。
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
            // ★ 刻意**不用** `INSERT OR REPLACE` / `ON CONFLICT … DO UPDATE`：
            // 那两种写法会静默改写既有引用（见 `conflictingMapping` 的注释）。
            // 冲突必须落到 `insert` 的冲突分支去逐个字段比对。
            insertStatement = try prepare("""
                INSERT INTO file_reference(file_id, source_id, canonical_relative_path)
                VALUES(?,?,?)
                """)
            lookupStatement = try prepare("""
                SELECT source_id, canonical_relative_path FROM file_reference WHERE file_id=?
                """)
            existingStatement = try prepare("""
                SELECT source_id, canonical_relative_path FROM file_reference WHERE file_id=?
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
            if let lookupStatement { sqlite3_finalize(lookupStatement) }
            if let existingStatement { sqlite3_finalize(existingStatement) }
            insertStatement = nil
            lookupStatement = nil
            existingStatement = nil
            if let handle { sqlite3_close(handle) }
            handle = nil
        }
    }

    // MARK: - 写

    /// 记一条。同一个 `file_id` 再来一次是**幂等**的（同 id 必然同来源同路径）。
    ///
    /// 校验与不写坏数据有关，与「省事」无关：
    /// * 路径不安全 → 拒绝。绝不先 `canonical` 一下再存（那是「修复」）。
    /// * `FileID.make(sourceID, path) != fileID` → 拒绝。这条挡住的是
    ///   「调用方拿了 A 的 id 配 B 的路径」这类接线错误，存进去以后
    ///   `get_metadata` 会去读一个**这个 id 从未指向过**的位置。
    public func register(_ reference: FileReference) throws {
        try queue.sync { try insert(reference) }
    }

    /// 一批一起写，**一个事务**。
    ///
    /// 一条不合法 → 全部回滚：`registerAll` 的语义是「这批要返回给 Agent 的
    /// 引用已经全部可解析」，写一半留一半会得到「有的 id 能查、有的不能」，
    /// 而调用方无法从返回值上区分是哪一半。
    ///
    /// ★ 原子性的另一半是「**冲突不能改写既有引用**」：一条冲突会让整个事务
    /// 回滚，所以「先写了 A 再撞上 B」不会留下 A 那半（见 `conflictingMapping`）。
    public func registerAll(_ references: [FileReference]) throws {
        try queue.sync {
            guard !references.isEmpty else { return }
            try exec("BEGIN IMMEDIATE")
            do {
                for reference in references { try insert(reference) }
                try exec("COMMIT")
            } catch {
                try? exec("ROLLBACK")
                throw error
            }
        }
    }

    // MARK: - 读

    /// 反查。`nil` = 表里没有这个 id（调用方据此报 `file_not_found`）。
    ///
    /// 读回来的行**再判一次同样的不变量**：库被改坏、被旧版本写坏、被手工
    /// `UPDATE` 过，都不能变成「拿一条错误路径去 Provider 试试看」。
    /// 那种失败在 Provider 侧会伪装成 `file_not_found`，把「我们的库坏了」
    /// 说成「文件不在了」。
    public func lookup(_ fileID: FileID) throws -> FileReference? {
        try queue.sync { try readRow(fileID) }
    }

    /// 队列内的一次反查。`insert` 的冲突分支也用它（不能再进一次队列）。
    private func readRow(_ fileID: FileID) throws -> FileReference? {
        guard let statement = lookupStatement else { throw FileReferenceStoreError.storage("store is closed") }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(statement, 1, fileID.value)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw error() }
        guard let sourceText = sqlite3_column_text(statement, 0),
              let pathText = sqlite3_column_text(statement, 1) else {
            throw FileReferenceStoreError.corruptRow
        }
        let reference = FileReference(fileID: fileID,
                                      sourceID: String(cString: sourceText),
                                      canonicalRelativePath: String(cString: pathText))
        // 读侧只有一个结论：**这一行不能信**。写入侧的细分错误（不安全 / 对不上）
        // 在这里没有区分意义——调用方要做的事完全一样（别再往下走）。
        do {
            try Self.validate(reference)
        } catch {
            throw FileReferenceStoreError.corruptRow
        }
        return reference
    }

    /// 行数。诊断与用例用；产品路径上不该有人拿它当「有没有数据」的判据。
    public func count() throws -> Int {
        try queue.sync {
            let statement = try prepare("SELECT COUNT(*) FROM file_reference")
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw error() }
            return Int(sqlite3_column_int64(statement, 0))
        }
    }

    // MARK: - 不变量（写入与读回**共用同一份**）

    /// 三列之间必须同时成立的两条。写入前、读回后各跑一次，共用这一处实现——
    /// 两处各写一份的话，迟早变成「写的时候查 A、读的时候查 B」。
    static func validate(_ reference: FileReference) throws {
        guard RelativePath.isSafe(reference.canonicalRelativePath) else {
            throw FileReferenceStoreError.unsafePath
        }
        // 算不出来（来源 id 不可用 / 路径不安全）与算出来不相等，是同一件事：
        // 这三列对不上，不许进表、也不许拿出去用。
        guard let derived = try? FileID.make(sourceID: reference.sourceID,
                                             canonicalRelativePath: reference.canonicalRelativePath),
              derived == reference.fileID else {
            throw FileReferenceStoreError.identityMismatch
        }
    }

    // MARK: - SQLite 细节

    /// 写一条。**冲突绝不覆盖**（6.4b-1 冻结）。
    ///
    /// ```text
    /// 插入 → SQLITE_DONE        → 写完
    ///      → SQLITE_CONSTRAINT  → 读既有行
    ///                             三字段指向同一个文件 → 幂等，什么都不做
    ///                             否则                 → conflictingMapping
    ///      → 其它                → storage
    /// ```
    private func insert(_ reference: FileReference) throws {
        try Self.validate(reference)
        guard let statement = insertStatement else { throw FileReferenceStoreError.storage("store is closed") }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(statement, 1, reference.fileID.value)
        bind(statement, 2, reference.sourceID)
        bind(statement, 3, reference.canonicalRelativePath)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return }
        guard rc == SQLITE_CONSTRAINT else { throw error() }
        try resolveConflict(reference)
    }

    /// 撞上了主键（`file_id`）或 `UNIQUE(source_id, path)`。
    ///
    /// ★ 幂等判定**按身份**算，不按字节：`FileID.make` 会做 NFC 归一化，
    /// 所以「同一个文件的 NFD 与 NFC 两种写法」是同一条映射——
    /// 以**先写的那一串字节**为准，不改写。
    ///
    /// 换成逐字节比较的话，一次 `locate` 里同一个文件被两个来源以两种
    /// 组合形态给出，后到的那条就会把整批 `registerAll` 打成失败。
    private func resolveConflict(_ reference: FileReference) throws {
        guard let existing = try readExisting(fileID: reference.fileID) else {
            // 撞的是 `UNIQUE(source_id, path)`：库里已经有另一个 id 指向
            // 这个 (source, path)。deterministic FileID 保证那两个 id 必须相等，
            // 所以这也是不变量坏了——不许用新 id 顶掉旧的。
            throw FileReferenceStoreError.conflictingMapping
        }
        let sameSource = existing.sourceID == reference.sourceID
        let samePath = (try? FileID.make(sourceID: existing.sourceID,
                                        canonicalRelativePath: existing.canonicalRelativePath)) == reference.fileID
        guard sameSource, samePath else {
            throw FileReferenceStoreError.conflictingMapping
        }
    }

    /// 队列内读一行（不校验，交由调用方决定怎么处理）。
    private func readExisting(fileID: FileID) throws -> FileReference? {
        guard let statement = existingStatement else { throw FileReferenceStoreError.storage("store is closed") }
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
        bind(statement, 1, fileID.value)
        let rc = sqlite3_step(statement)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw error() }
        guard let sourceText = sqlite3_column_text(statement, 0),
              let pathText = sqlite3_column_text(statement, 1) else {
            throw FileReferenceStoreError.corruptRow
        }
        return FileReference(fileID: fileID,
                             sourceID: String(cString: sourceText),
                             canonicalRelativePath: String(cString: pathText))
    }

    private func bind(_ statement: OpaquePointer, _ index: Int32, _ value: String) {
        // `SQLITE_TRANSIENT`：SQLite 自己留一份拷贝，字符串的生命周期不跨越这一步。
        sqlite3_bind_text(statement, index, value, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let handle else { throw FileReferenceStoreError.storage("store is closed") }
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw error()
        }
        return statement
    }

    private func exec(_ sql: String) throws {
        guard let handle else { throw FileReferenceStoreError.storage("store is closed") }
        guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() }
    }

    private func error() -> FileReferenceStoreError {
        .storage(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "store is closed")
    }
}

/// 库的标准位置。
///
/// ```text
/// ~/Library/Application Support/FlashFind2/ai-file-reference.sqlite
/// ```
///
/// ★ 与 `AuthoritySocketPath` 同样的理由：**不跟着缓存目录走**。
/// 缓存目录在 UI 预览里会被换成另一个根；映射表一旦跟着它走，
/// 「预览里搜出来的 id，正式 App 查不到」就成了一个必然复现的 bug。
/// ★ 文件名**不含** `history`：两者生命周期不同（见 `FileReferenceStore` 的注释）。
public enum FileReferenceStorePath {

    public static let directoryName = "FlashFind2"
    public static let fileName = "ai-file-reference.sqlite"

    public static func standard(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support", isDirectory: true)
            .appendingPathComponent(directoryName, isDirectory: true)
            .appendingPathComponent(fileName)
    }
}
