import Foundation
import CSQLite

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

public final class IndexDatabase {
    private var handle: OpaquePointer?
    public let url: URL
    public init(url: URL, create: Bool = true) throws {
        self.url = url
        let flags = create ? SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE : SQLITE_OPEN_READONLY
        guard sqlite3_open_v2(url.path, &handle, flags | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK else {
            let message = handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Unable to open database"
            sqlite3_close(handle); handle = nil; throw FlashFindError.message(message)
        }
        sqlite3_busy_timeout(handle, 5000)
        if create {
            try exec("PRAGMA journal_mode=WAL; PRAGMA synchronous=NORMAL;")
            try exec("""
                CREATE TABLE IF NOT EXISTS meta(key TEXT PRIMARY KEY,value TEXT NOT NULL);
                CREATE TABLE IF NOT EXISTS files(id INTEGER PRIMARY KEY,relative_path TEXT UNIQUE NOT NULL,
                kind TEXT NOT NULL,size INTEGER NOT NULL,mtime INTEGER NOT NULL,normalized_name TEXT NOT NULL,normalized_path TEXT NOT NULL);
                CREATE VIRTUAL TABLE IF NOT EXISTS files_fts USING fts5(normalized_name,normalized_path,
                content='files',content_rowid='id',tokenize='trigram');
                CREATE TRIGGER IF NOT EXISTS files_ai AFTER INSERT ON files BEGIN
                INSERT INTO files_fts(rowid,normalized_name,normalized_path) VALUES(new.id,new.normalized_name,new.normalized_path); END;
                CREATE TRIGGER IF NOT EXISTS files_ad AFTER DELETE ON files BEGIN
                INSERT INTO files_fts(files_fts,rowid,normalized_name,normalized_path) VALUES('delete',old.id,old.normalized_name,old.normalized_path); END;
                CREATE TRIGGER IF NOT EXISTS files_au AFTER UPDATE ON files BEGIN
                INSERT INTO files_fts(files_fts,rowid,normalized_name,normalized_path) VALUES('delete',old.id,old.normalized_name,old.normalized_path);
                INSERT INTO files_fts(rowid,normalized_name,normalized_path) VALUES(new.id,new.normalized_name,new.normalized_path); END;
                """)
            if try metadata("search_schema") != "2" {
                func decodedSQL(_ column: String) -> String {
                    SMBPath.punctuation.reduce(column) { sql, pair in
                        "replace(\(sql),char(\(pair.0)),char(\(pair.1)))"
                    }
                }
                try transaction {
                    let name = decodedSQL("normalized_name"), path = decodedSQL("normalized_path")
                    try exec("UPDATE files SET normalized_name=\(name),normalized_path=\(path) WHERE normalized_path!=\(path)")
                    try setMetadata("search_schema", "2")
                }
            }
        }
    }
    deinit { close() }
    public func close() { if let handle { sqlite3_close(handle) }; handle = nil }
    private func error() -> FlashFindError { .message(handle.map { String(cString: sqlite3_errmsg($0)) } ?? "Database closed") }
    private func exec(_ sql: String) throws { guard sqlite3_exec(handle, sql, nil, nil, nil) == SQLITE_OK else { throw error() } }
    private func statement(_ sql: String, _ values: [String] = []) throws -> OpaquePointer {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else { throw error() }
        for (index, value) in values.enumerated() { sqlite3_bind_text(stmt, Int32(index + 1), value, -1, transient) }
        return stmt
    }
    private func run(_ sql: String, _ values: [String] = []) throws {
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_DONE else { throw error() }
    }
    public func metadata(_ key: String) throws -> String? {
        let stmt = try statement("SELECT value FROM meta WHERE key=?", [key]); defer { sqlite3_finalize(stmt) }
        let rc = sqlite3_step(stmt)
        if rc == SQLITE_DONE { return nil }
        guard rc == SQLITE_ROW else { throw error() }
        return String(cString: sqlite3_column_text(stmt, 0))
    }
    public func setMetadata(_ key: String, _ value: String) throws {
        try run("INSERT INTO meta VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [key, value])
    }
    public func transaction(_ action: () throws -> Void) throws {
        try exec("BEGIN IMMEDIATE")
        do { try action(); try exec("COMMIT") } catch { try? exec("ROLLBACK"); throw error }
    }
    public func upsert(_ file: RemoteFile) throws {
        try file.validate()
        let displayPath = SMBPath.display(file.relativePath)
        let name = (displayPath as NSString).lastPathComponent
        try run("""
            INSERT INTO files(relative_path,kind,size,mtime,normalized_name,normalized_path) VALUES(?,?,?,?,?,?)
            ON CONFLICT(relative_path) DO UPDATE SET kind=excluded.kind,size=excluded.size,mtime=excluded.mtime,
            normalized_name=excluded.normalized_name,normalized_path=excluded.normalized_path
            """, [file.relativePath, file.kind, file.size, file.mtimeNS, RelativePath.normalized(name), RelativePath.normalized(displayPath)])
    }
    public func apply(_ page: ChangePage, source: Source) throws {
        guard page.schemaVersion == 1, page.sourceID == source.id, page.generation == source.generation,
              try metadata("generation") == source.generation,
              let cursor = Int64(try metadata("cursor") ?? ""), let next = Int64(page.nextCursor),
              let until = Int64(page.untilChangeID), next >= cursor, until >= next,
              !page.hasMore || next > cursor else { throw FlashFindError.message("Invalid change page or cursor") }
        try transaction {
            var previous = cursor
            for change in page.changes {
                guard let id = Int64(change.changeID), id > previous, id <= next else { throw FlashFindError.message("Unordered changes") }
                previous = id; try RelativePath.validate(change.relativePath)
                switch change.op {
                case "upsert":
                    guard let kind = change.kind, let size = change.size, let time = change.mtimeNS else { throw FlashFindError.message("Incomplete upsert") }
                    try upsert(RemoteFile(relativePath: change.relativePath, kind: kind, size: size, mtimeNS: time))
                case "delete": try run("DELETE FROM files WHERE relative_path=?", [change.relativePath])
                default: throw FlashFindError.message("Unsupported change operation")
                }
            }
            guard page.hasMore || next == until else { throw FlashFindError.message("Final page does not reach its fixed upper bound") }
            try setMetadata("cursor", page.nextCursor)
        }
    }
    public func checkpoint() throws { try exec("PRAGMA wal_checkpoint(TRUNCATE)") }
    public func count() throws -> Int {
        let stmt = try statement("SELECT COUNT(*) FROM files"); defer { sqlite3_finalize(stmt) }
        guard sqlite3_step(stmt) == SQLITE_ROW else { throw error() }; return Int(sqlite3_column_int64(stmt, 0))
    }
    public func search(_ query: String, source: Source, limit: Int = 100, budget: TimeInterval = 0.15) throws -> [SearchResult] {
        searchWasIncomplete = false
        let terms = RelativePath.normalized(query).split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        let long = terms.filter { $0.count >= 3 }
        let deadline = Date().addingTimeInterval(budget)
        let cancellation = ProgressBox { Date() > deadline || Task.isCancelled }
        sqlite3_progress_handler(handle, 1000, { pointer in
            guard let pointer else { return 0 }
            return Unmanaged<ProgressBox>.fromOpaque(pointer).takeUnretainedValue().stop() ? 1 : 0
        }, Unmanaged.passUnretained(cancellation).toOpaque())
        defer { sqlite3_progress_handler(handle, 0, nil, nil) }
        let match = long.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }.joined(separator: " AND ")
        var sql = "SELECT relative_path,kind,size,normalized_name,normalized_path FROM files"
        var values: [String] = []
        var predicates: [String] = []
        if !long.isEmpty { predicates.append("id IN (SELECT rowid FROM files_fts WHERE files_fts MATCH ?)"); values = [match] }
        // Trigram FTS cannot narrow one/two-character terms. Filter common literal terms
        // inside SQLite to avoid decoding every row in Swift; preserve other Unicode semantics.
        for term in terms where term.count < 3 && term.unicodeScalars.allSatisfy({ $0.isASCII || (0x4E00...0x9FFF).contains($0.value) }) {
            predicates.append("instr(normalized_path,?)>0"); values.append(term)
        }
        if !predicates.isEmpty { sql += " WHERE " + predicates.joined(separator: " AND ") }
        let stmt = try statement(sql, values); defer { sqlite3_finalize(stmt) }
        var results: [SearchResult] = []
        while true {
            let rc = sqlite3_step(stmt)
            if rc == SQLITE_DONE { break }
            if rc == SQLITE_INTERRUPT {
                try Task.checkCancellation()
                searchWasIncomplete = true; break
            }
            guard rc == SQLITE_ROW else { throw error() }
            let path = String(cString: sqlite3_column_text(stmt, 0))
            let name = String(cString: sqlite3_column_text(stmt, 3))
            let normalizedPath = String(cString: sqlite3_column_text(stmt, 4))
            guard terms.allSatisfy({ normalizedPath.contains($0) }) else { continue }
            let literal = terms.joined(separator: " ")
            let rank = name == literal ? 0 : name.hasPrefix(literal) ? 1 : terms.allSatisfy({ name.contains($0) }) ? 2 : 3
            results.append(SearchResult(id: source.id + ":" + path, name: (SMBPath.display(path) as NSString).lastPathComponent,
                                        relativePath: path, sourceID: source.id, sourceName: source.name,
                                        kind: String(cString: sqlite3_column_text(stmt, 1)), size: sqlite3_column_int64(stmt, 2), localURL: nil, rank: rank))
            if results.count >= limit * 4 { searchWasIncomplete = true; break }
        }
        searchWasIncomplete = searchWasIncomplete || results.count > limit
        return Array(results.sorted { $0.rank == $1.rank ? $0.relativePath < $1.relativePath : $0.rank < $1.rank }.prefix(limit))
    }
    public private(set) var searchWasIncomplete = false
}

private final class ProgressBox {
    let stop: () -> Bool
    init(_ stop: @escaping () -> Bool) { self.stop = stop }
}
