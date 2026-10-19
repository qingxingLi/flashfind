import Foundation

public actor SyncCoordinator {
    public let directory: URL
    private var current: [Source] = []
    private var busy = false
    private var permissionBlocked = false
    public init(directory: URL) throws {
        self.directory = directory
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
        let manifestURL = directory.appendingPathComponent("sources.json")
        if let data = try? Data(contentsOf: manifestURL) { current = (try? JSONDecoder().decode([Source].self, from: data)) ?? [] }
        permissionBlocked = FileManager.default.fileExists(atPath: directory.appendingPathComponent("permissions-pending").path)
    }
    public func sources() -> [Source] { current }
    public func searchableSourceIDs() throws -> Set<String> {
        guard !permissionBlocked else { return [] }
        var available = Set<String>()
        for source in current {
            let url = try databaseURL(source.id)
            guard FileManager.default.isReadableFile(atPath: url.path) else { continue }
            let db = try IndexDatabase(url: url, create: false)
            defer { db.close() }
            if try db.metadata("generation") == source.generation { available.insert(source.id) }
        }
        return available
    }
    public func databaseURL(_ sourceID: String) throws -> URL {
        guard !sourceID.isEmpty, sourceID.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { throw FlashFindError.message("Invalid source identifier") }
        return directory.appendingPathComponent(sourceID + ".sqlite")
    }
    public func sync(settings: ServerSettings, password: String, selectedSourceIDs: Set<String>? = nil, authenticatedConnection: ServerConnection? = nil,
                     permissionsChanged: (@Sendable () async -> Void)? = nil) async throws -> String {
        guard !busy else { throw FlashFindError.message("此 NAS 同步尚在结束，请稍后重试") }
        busy = true; defer { busy = false }
        let connection = try authenticatedConnection ?? ServerConnection(settings: settings)
        if authenticatedConnection == nil { try await connection.login(password: password) }
        let manifest = try await connection.manifest()
        // Invalidate displayed metadata before deleting/replacing any permission generation.
        // This callback runs even if a later snapshot download fails.
        let old = Dictionary(uniqueKeysWithValues: current.map { ($0.id, $0.generation) })
        let new = Dictionary(uniqueKeysWithValues: manifest.sources.map { ($0.id, $0.generation) })
        var changed = old != new
        if manifest.capabilities.contains("permission_filtered_v1") {
            for source in manifest.sources {
                let url = try databaseURL(source.id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let db = try IndexDatabase(url: url, create: false)
                defer { db.close() }
                if try db.metadata("generation") != source.generation { changed = true }
            }
        }
        if changed || permissionBlocked {
            await permissionsChanged?()
            permissionBlocked = true
            try Data("Permission generation pending verification".utf8).write(to: directory.appendingPathComponent("permissions-pending"), options: .atomic)
        }
        try Task.checkCancellation()
        if manifest.capabilities.contains("permission_filtered_v1") {
            for source in manifest.sources {
                let url = try databaseURL(source.id)
                guard FileManager.default.fileExists(atPath: url.path) else { continue }
                let db = try IndexDatabase(url: url, create: false)
                let generation = try db.metadata("generation"); db.close()
                if generation != source.generation {
                    for suffix in ["", "-wal", "-shm"] {
                        if FileManager.default.fileExists(atPath: url.path + suffix) { try FileManager.default.removeItem(atPath: url.path + suffix) }
                    }
                }
            }
        }
        let allowed = Set(manifest.sources.map(\.id))
        for source in current where !allowed.contains(source.id) {
            let url = try databaseURL(source.id)
            for suffix in ["", "-wal", "-shm"] {
                if FileManager.default.fileExists(atPath: url.path + suffix) { try FileManager.default.removeItem(atPath: url.path + suffix) }
            }
        }
        current = manifest.sources
        try JSONEncoder().encode(current).write(to: directory.appendingPathComponent("sources.json"), options: .atomic)
        var total = 0
        for source in current {
            guard selectedSourceIDs?.contains(source.id) ?? true else { continue }
            try Task.checkCancellation()
            guard Int64(source.minValidCursor) != nil, Int64(source.maxChangeID) != nil else { throw FlashFindError.message("Invalid source cursor") }
            let url = try databaseURL(source.id)
            var needsSnapshot = !FileManager.default.fileExists(atPath: url.path)
            if !needsSnapshot {
                let db = try IndexDatabase(url: url, create: false)
                let generation = try db.metadata("generation")
                let cursor = Int64(try db.metadata("cursor") ?? "") ?? -1
                needsSnapshot = generation != source.generation || cursor < Int64(source.minValidCursor)! || cursor > Int64(source.maxChangeID)!
                db.close()
            }
            if needsSnapshot {
                guard !source.snapshotID.isEmpty else { continue }
                let downloaded = try await connection.snapshot(source: source)
                defer { try? FileManager.default.removeItem(at: downloaded) }
                try installSnapshot(downloaded, source: source)
            }
            guard FileManager.default.fileExists(atPath: url.path) else { continue }
            var until: String?
            while true {
                try Task.checkCancellation()
                let db = try IndexDatabase(url: url)
                let cursor = try db.metadata("cursor") ?? "0"
                db.close()
                do {
                    let page = try await connection.changes(source: source, cursor: cursor, until: until)
                    if let until, until != page.untilChangeID { throw FlashFindError.message("Paging upper bound changed") }
                    until = page.untilChangeID
                    let writer = try IndexDatabase(url: url)
                    try writer.apply(page, source: source); total = try writer.count(); writer.close()
                    if !page.hasMore { break }
                } catch let error as HTTPFailure where error.status == 409 {
                    throw error
                }
            }
        }
        if permissionBlocked {
            try FileManager.default.removeItem(at: directory.appendingPathComponent("permissions-pending"))
            permissionBlocked = false
        }
        return "\(current.count) sources synchronized; last source has \(total) records"
    }

    public func installSnapshot(_ fileURL: URL, source: Source) throws {
        struct Line: Decodable {
            let type: String
            let schemaVersion: Int?
            let sourceID: String?
            let generation: String?
            let snapshotID: String?
            let snapshotChangeID: String?
            let recordCount: String?
            enum CodingKeys: String, CodingKey {
                case type, generation, schemaVersion = "schema_version", sourceID = "source_id"
                case snapshotID = "snapshot_id", snapshotChangeID = "snapshot_change_id", recordCount = "record_count"
            }
        }
        let target = try databaseURL(source.id)
        let temporary = directory.appendingPathComponent(source.id + "-" + UUID().uuidString + ".sqlite")
        defer { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: temporary.path + suffix) } }
        let db = try IndexDatabase(url: temporary)
        let file = try FileHandle(forReadingFrom: fileURL); defer { try? file.close() }
        var buffered = Data(), header = false, footer = false, count: Int64 = 0, snapshotCursor: String?
        try db.transaction {
            func consume(_ data: Data) throws {
                guard !footer else { throw FlashFindError.message("Data after snapshot footer") }
                let line = try JSONDecoder().decode(Line.self, from: data)
                switch line.type {
                case "header":
                    guard !header, line.schemaVersion == 1, line.sourceID == source.id,
                          line.generation == source.generation, line.snapshotID == source.snapshotID,
                          let cursor = line.snapshotChangeID, let number = Int64(cursor), number >= 0 else { throw FlashFindError.message("Snapshot header does not match source") }
                    header = true; snapshotCursor = cursor
                case "file":
                    guard header else { throw FlashFindError.message("Missing snapshot header") }
                    try db.upsert(JSONDecoder().decode(RemoteFile.self, from: data)); count += 1
                case "footer":
                    guard header, let declared = line.recordCount, Int64(declared) == count,
                          Int64(declared) == Int64(try db.count()) else { throw FlashFindError.message("Incomplete snapshot or duplicate paths") }
                    footer = true
                default: throw FlashFindError.message("Unsupported snapshot record")
                }
            }
            while let chunk = try file.read(upToCount: 65536), !chunk.isEmpty {
                try Task.checkCancellation(); buffered.append(chunk)
                while let newline = buffered.firstIndex(of: 10) {
                    let line = buffered[..<newline]; if !line.isEmpty { try consume(Data(line)) }
                    buffered.removeSubrange(...newline)
                }
                guard buffered.count < 4 * 1024 * 1024 else { throw FlashFindError.message("Snapshot line is too large") }
            }
            if !buffered.isEmpty { try consume(buffered) }
            guard footer, let snapshotCursor else { throw FlashFindError.message("Snapshot footer missing") }
            try db.setMetadata("cursor", snapshotCursor); try db.setMetadata("generation", source.generation)
        }
        try db.checkpoint(); db.close()
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: target.path + suffix) }
        guard rename(temporary.path, target.path) == 0 else { throw FlashFindError.message("Unable to install completed snapshot") }
    }

    public func search(_ text: String, limit: Int = 100, selectedSourceIDs: Set<String>? = nil) throws -> [SearchResult] {
        try searchReport(text, limit: limit, selectedSourceIDs: selectedSourceIDs).results
    }
    public func searchReport(_ text: String, limit: Int = 100, selectedSourceIDs: Set<String>? = nil) throws -> CacheSearchReport {
        guard !permissionBlocked else { throw FlashFindError.message("权限代际同步未完成，旧缓存已隔离，请重新同步") }
        var results: [SearchResult] = []
        var incomplete = false
        var missing: [String] = []
        var searched = 0
        for source in current {
            guard selectedSourceIDs?.contains(source.id) ?? true else { continue }
            let url = try databaseURL(source.id)
            guard FileManager.default.fileExists(atPath: url.path) else { missing.append(source.name); continue }
            let db = try IndexDatabase(url: url, create: false)
            results += try db.search(text, source: source, limit: limit)
            searched += 1
            incomplete = incomplete || db.searchWasIncomplete; db.close()
        }
        return CacheSearchReport(results: Array(results.sorted { $0.rank == $1.rank ? $0.name < $1.name : $0.rank < $1.rank }.prefix(limit)), incomplete: incomplete || results.count > limit, missingSources: missing, searchedSources: searched)
    }
}

public struct CacheSearchReport {
    public let results: [SearchResult]
    public let incomplete: Bool
    public let missingSources: [String]
    public let searchedSources: Int
}
