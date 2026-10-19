import XCTest
import CSQLite
@testable import FlashFindCore

final class CoreTests: XCTestCase {
    func testAccountProfilesDoNotShareCaches() throws {
        let root = try directory()
        XCTAssertNotEqual(AccountProfile.directory(root: root, address: "https://nas:9443", username: "alice"), AccountProfile.directory(root: root, address: "https://nas:9443", username: "bob"))
        XCTAssertNotEqual(AccountProfile.key(address: "https://nas:9443", username: "alice"), AccountProfile.key(address: "https://other:9443", username: "alice"))
        XCTAssertEqual(AccountProfile.key(address: "https://nas:9443/", username: "alice"), AccountProfile.key(address: "https://nas:9443", username: "alice"))
        XCTAssertNotEqual(AccountProfile.key(address: "https://nas:9443", username: "Alice"), AccountProfile.key(address: "https://nas:9443", username: "alice"))
    }
    func testUnselectedSourcesAreNotSearched() async throws {
        let root = try directory(), source = try source()
        try JSONEncoder().encode([source]).write(to: root.appendingPathComponent("sources.json"))
        let coordinator = try SyncCoordinator(directory: root)
        let db = try IndexDatabase(url: root.appendingPathComponent(source.id + ".sqlite"))
        try db.upsert(RemoteFile(relativePath: "报告.txt")); db.close()
        let excluded = try await coordinator.search("报告", selectedSourceIDs: [])
        let included = try await coordinator.search("报告", selectedSourceIDs: [source.id])
        XCTAssertTrue(excluded.isEmpty); XCTAssertEqual(included.count, 1)
    }
    func source() throws -> Source {
        try JSONDecoder().decode(Source.self, from: Data("""
        {"source_id":"test-source","name":"备份","generation":"gen-1","smb_endpoint":"smb://nas/资料", "share_relative_root":"项目", "index_state":"ready", "min_valid_cursor":"0", "max_change_id":"10", "snapshot_id":"snap-1", "snapshot_change_id":"0"}
        """.utf8))
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    func testPathMappingAndTraversal() throws {
        let root = try directory(), source = try source()
        XCTAssertEqual(try MountBinding(root: root).resolve(source: source, relativePath: "客户/合同.pdf").path, root.path + "/项目/客户/合同.pdf")
        XCTAssertEqual(try MountBinding(root: root, mountedSharePrefix: "项目").resolve(source: source, relativePath: "客户/合同.pdf").path, root.path + "/客户/合同.pdf")
        for path in ["/root", "../escape", "a/../b", "a//b", "a/", "", "a\0b"] { XCTAssertThrowsError(try RelativePath.validate(path)) }
        XCTAssertThrowsError(try MountBinding(root: root, mountedSharePrefix: "别的目录").resolve(source: source, relativePath: "合同.pdf"))
    }
    func testSFMDisplayMigrationKeepsWirePathsAndCursor() throws {
        XCTAssertEqual(SMBPath.display("x\u{F020}\u{F021}\u{F022}\u{F023}\u{F024}\u{F025}\u{F026}\u{F027}"), "x\"*:<>?\\|")
        let url = try directory().appendingPathComponent("sfm.sqlite"), source = try source()
        let raw = "quote\u{F020}name.txt"
        let first = try IndexDatabase(url: url)
        try first.upsert(RemoteFile(relativePath: raw))
        try first.setMetadata("generation", source.generation); try first.setMetadata("cursor", "123")
        first.close()
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        XCTAssertEqual(sqlite3_exec(handle, "UPDATE files SET normalized_name='quote'||char(61472)||'name.txt',normalized_path='quote'||char(61472)||'name.txt'; DELETE FROM meta WHERE key='search_schema';", nil, nil, nil), SQLITE_OK)
        sqlite3_close(handle)
        let migrated = try IndexDatabase(url: url)
        let results = try migrated.search("quote\"name", source: source)
        XCTAssertEqual(results.count, 1); XCTAssertEqual(results.first?.relativePath, raw)
        XCTAssertEqual(results.first?.name, "quote\"name.txt"); XCTAssertEqual(results.first?.displayPath, "quote\"name.txt")
        XCTAssertEqual(try migrated.metadata("cursor"), "123")
        let data = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "source_id": source.id, "generation": source.generation,
            "until_change_id": "124", "next_cursor": "124", "has_more": false,
            "changes": [["change_id": "124", "op": "delete", "relative_path": raw]]])
        try migrated.apply(JSONDecoder().decode(ChangePage.self, from: data), source: source)
        XCTAssertEqual(try migrated.search("quote\"name", source: source).count, 0)
    }
    func testDisconnectedShareDoesNotResolveBookmark() throws {
        let root = try directory().appendingPathComponent("unmounted-share")
        let binding = MountBinding(root: root, bookmark: Data("invalid-bookmark".utf8))
        XCTAssertThrowsError(try binding.resolve(source: source(), relativePath: "报告.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("SMB 共享未连接"))
        }
    }
    func testInvalidBookmarkRequestsRebinding() throws {
        let binding = MountBinding(root: try directory(), bookmark: Data("invalid-bookmark".utf8))
        XCTAssertThrowsError(try binding.resolve(source: source(), relativePath: "报告.txt")) { error in
            XCTAssertTrue(error.localizedDescription.contains("重新绑定共享根目录"))
        }
    }
    func testIncrementalRollbackAndFTSDeletion() throws {
        let db = try IndexDatabase(url: directory().appendingPathComponent("index.sqlite")), source = try source()
        try db.setMetadata("generation", "gen-1"); try db.setMetadata("cursor", "0")
        func page(_ body: String) throws -> ChangePage {
            try JSONDecoder().decode(ChangePage.self, from: Data("""
            {"schema_version":1,"source_id":"test-source","generation":"gen-1","until_change_id":"2","next_cursor":"2","has_more":false,"changes":\(body)}
            """.utf8))
        }
        let invalid = try page("""
        [{"change_id":"1","op":"upsert","relative_path":"报告合同.pdf","kind":"file","size":"1","mtime_ns":"0"},{"change_id":"2","op":"unknown","relative_path":"x"}]
        """)
        XCTAssertThrowsError(try db.apply(invalid, source: source))
        XCTAssertEqual(try db.count(), 0); XCTAssertEqual(try db.metadata("cursor"), "0")
        let valid = try page("""
        [{"change_id":"1","op":"upsert","relative_path":"报告合同.pdf","kind":"file","size":"1","mtime_ns":"0"},{"change_id":"2","op":"upsert","relative_path":"literal%_name.txt","kind":"file","size":"1","mtime_ns":"0"}]
        """)
        try db.apply(valid, source: source)
        XCTAssertEqual(try db.search("报告合", source: source).count, 1)
        XCTAssertEqual(try db.search("报告", source: source).count, 1)
        XCTAssertEqual(try db.search("报告 同", source: source).count, 1)
        XCTAssertEqual(try db.search("报 合", source: source).count, 1)
        XCTAssertEqual(try db.search("报 无", source: source).count, 0)
        XCTAssertEqual(try db.search("%_", source: source).count, 1)
        XCTAssertEqual(try db.search("报告 合同", source: source).count, 1)
        XCTAssertEqual(try db.search("不存在", source: source).count, 0)
        let deletion = try JSONDecoder().decode(ChangePage.self, from: Data("""
        {"schema_version":1,"source_id":"test-source","generation":"gen-1","until_change_id":"3","next_cursor":"3","has_more":false,"changes":[{"change_id":"3","op":"delete","relative_path":"报告合同.pdf"}]}
        """.utf8))
        try db.apply(deletion, source: source)
        XCTAssertEqual(try db.search("报告合", source: source).count, 0)
    }
    @MainActor
    func testSpotlightSingleTermCompletes() async throws {
        let provider = SpotlightProvider()
        _ = try await provider.search("flashfind2-unlikely-regression-token")
        _ = try await provider.search("flashfind2 unlikely regression token")
    }

    func testTruncatedSnapshotKeepsPreviousIndex() async throws {
        let root = try directory(), source = try source(), sync = try SyncCoordinator(directory: root)
        let dbURL = try await sync.databaseURL(source.id)
        let db = try IndexDatabase(url: dbURL); try db.upsert(RemoteFile(relativePath: "保留的文件.txt")); db.close()
        let snapshot = root.appendingPathComponent("bad.ndjson")
        try Data("""
        {"type":"header","schema_version":1,"source_id":"test-source","generation":"gen-1","snapshot_id":"snap-1","snapshot_change_id":"0"}
        {"type":"file","relative_path":"新文件.txt","kind":"file","size":"0","mtime_ns":"0"}
        """.utf8).write(to: snapshot)
        do { try await sync.installSnapshot(snapshot, source: source); XCTFail("Truncated snapshot installed") } catch {}
        let existing = try IndexDatabase(url: dbURL, create: false)
        XCTAssertEqual(try existing.search("保留的", source: source).count, 1)
        XCTAssertEqual(try existing.search("新文件", source: source).count, 0)
    }
}
