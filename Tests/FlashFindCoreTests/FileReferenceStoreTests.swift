import XCTest
import CSQLite
@testable import FlashFindCore

/// Phase 6.4b-0：`FileReferenceStore` 的契约（方案 §15.3 / §4.11）。
///
/// 这一组用例守的不是「表能存能取」，而是三条一旦破了就很难在真机上复现的性质：
///
/// ```text
/// 1. 三列就是全部            → 多一列 = 偷偷做 metadata 缓存 / 偷偷做 History
/// 2. 只验证，不修复          → 修一下 . / .. 会让两条路径撞成同一个 file_id
/// 3. 读回来的行不能盲信     → 库坏了必须报错，不能拿错路径去 Provider 试
/// ```
final class FileReferenceStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-file-reference-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - 工具

    private func makeStore() throws -> FileReferenceStore {
        try FileReferenceStore(url: directory.appendingPathComponent("ai-file-reference.sqlite"))
    }

    private func reference(_ path: String, source: String = "nas_1") throws -> FileReference {
        FileReference(fileID: try FileID.make(sourceID: source, canonicalRelativePath: path),
                      sourceID: source,
                      canonicalRelativePath: path)
    }

    /// 故意绕过 Store 的校验，直接把一行改坏——模拟「库被旧版本写坏 / 被手工改过」。
    private func corruptRow(at url: URL, fileID: FileID, to path: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { return XCTFail("打不开库") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
                                          "UPDATE file_reference SET canonical_relative_path=? WHERE file_id=?",
                                          -1, &statement, nil), SQLITE_OK)
        guard let statement else { return XCTFail("prepare 失败") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, path, -1, transient)
        sqlite3_bind_text(statement, 2, fileID.value, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    /// 查询计划。`get_metadata` 必须是一次 O(1) 的主键查表，
    /// 不是「把整张映射表扫一遍找这条」。
    private func queryPlan(at url: URL, sql: String) throws -> String {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { throw FileReferenceStoreError.storage("打不开库") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle, "EXPLAIN QUERY PLAN " + sql, -1, &statement, nil), SQLITE_OK)
        guard let statement else { throw FileReferenceStoreError.storage("prepare 失败") }
        defer { sqlite3_finalize(statement) }
        var detail: [String] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            if let text = sqlite3_column_text(statement, 3) {
                detail.append(String(cString: text))
            }
        }
        return detail.joined(separator: " | ")
    }

    private func sourceText(_ relativePath: String) throws -> String {
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<3 { root.deleteLastPathComponent() }
        return try String(contentsOf: root.appendingPathComponent(relativePath), encoding: .utf8)
    }

    /// 去掉整行注释：注释里必然会出现被禁的符号名（本文件的注释就在解释为什么禁用）。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    // MARK: - ① 三列就是全部

    func testTheTableHasExactlyTheThreeFrozenColumns() throws {
        // 从建表语句里抓列名：每列只有一种写法 `名字 TEXT`。
        let pattern = try NSRegularExpression(pattern: #"^\s*([a-z_]+)\s+TEXT\s"#, options: [.anchorsMatchLines])
        let sql = FileReferenceStore.schemaSQL
        let range = NSRange(sql.startIndex..., in: sql)
        let columns = Set(pattern.matches(in: sql, range: range).compactMap { match -> String? in
            Range(match.range(at: 1), in: sql).map { String(sql[$0]) }
        })
        XCTAssertEqual(columns, ["file_id", "source_id", "canonical_relative_path"],
                       "列名闭集变了：这不是「多加一列」，是把 metadata 缓存或 History 偷带进来")

        // 这三列的语义也钉死：id 是主键，路径与来源不许为空，且二者唯一。
        let normalized = sql.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "  ", with: " ")
        XCTAssertTrue(normalized.contains("file_id TEXT PRIMARY KEY"), normalized)
        XCTAssertTrue(normalized.contains("source_id TEXT NOT NULL"), normalized)
        XCTAssertTrue(normalized.contains("canonical_relative_path TEXT NOT NULL"), normalized)
        XCTAssertTrue(normalized.contains("UNIQUE(source_id, canonical_relative_path)"), normalized)
    }

    func testTheTableDoesNotSmuggleInMetadataOrHistoryColumns() throws {
        let sql = FileReferenceStore.schemaSQL.lowercased()
        for forbidden in ["kind", "size", "mtime", "modified", "last_seen", "name",
                          "prompt", "query", "agent", "session", "absolute", "password", "token"] {
            XCTAssertFalse(sql.contains(forbidden), "表里出现了 \(forbidden)——这一列的现行用途是什么？")
        }
    }

    func testItStoresAndLooksUpTheSameTriple() throws {
        let store = try makeStore()
        defer { store.close() }
        let entry = try reference("共享/报告/预算.xlsx")
        try store.register(entry)

        let found = try XCTUnwrap(try store.lookup(entry.fileID))
        XCTAssertEqual(found, entry)
        XCTAssertEqual(try store.count(), 1)
    }

    func testAnUnknownIDIsNilInsteadOfAnError() throws {
        let store = try makeStore()
        defer { store.close() }
        let stranger = try FileID.make(sourceID: "nas_9", canonicalRelativePath: "从未/见过.txt")
        XCTAssertNil(try store.lookup(stranger), "「表里没有」必须是 nil（→ file_not_found），不是 storage 错误")
    }

    func testTheSameReferenceRegisteredTwiceStaysOneRow() throws {
        let store = try makeStore()
        defer { store.close() }
        let entry = try reference("a/b.txt")
        try store.register(entry)
        try store.register(entry)
        try store.registerAll([entry, entry])
        XCTAssertEqual(try store.count(), 1, "同一个 id 重复登记不该长行")
        XCTAssertEqual(try store.lookup(entry.fileID), entry)
    }

    // MARK: - ② 只验证，不修复

    func testAnUnsafePathIsRejectedInsteadOfRepaired() throws {
        let store = try makeStore()
        defer { store.close() }
        // 每一条都是「修一下就能存」的形态——正因如此才必须拒绝：
        // 修完的路径与另一条真实路径是同一个字符串，两条不同文件会撞一个 id。
        let unsafe = ["/绝对/路径.txt", "a/../b.txt", "a//b.txt", "a/b/", "./a.txt", "", "a/./b.txt"]
        for path in unsafe {
            // 用 `FileID.make` 也造不出来，所以手工拼一个形如 id 的值：
            // 这里要证明的是「Store 不看 id 长得像不像，而看三列对不对得上」。
            let fake = try XCTUnwrap(FileID.parse(FileID.prefix + String(repeating: "0", count: FileID.hexLength)))
            XCTAssertThrowsError(try store.register(FileReference(fileID: fake, sourceID: "nas_1",
                                                                 canonicalRelativePath: path)),
                                 "不安全路径被写进去了：\(path)") { error in
                XCTAssertEqual(error as? FileReferenceStoreError, .unsafePath, path)
            }
        }
        XCTAssertEqual(try store.count(), 0)

        // 反证：如果它偷偷 canonical 一下再存，「a/../b.txt」会变成「b.txt」并留下来。
        let repaired = try FileID.make(sourceID: "nas_1", canonicalRelativePath: "b.txt")
        XCTAssertNil(try store.lookup(repaired), "Store 修复了路径——它只该验证")
    }

    func testAnIDThatDoesNotBelongToThePathIsRejected() throws {
        let store = try makeStore()
        defer { store.close() }
        let other = try FileID.make(sourceID: "nas_1", canonicalRelativePath: "真实/另一个.txt")
        XCTAssertThrowsError(try store.register(FileReference(fileID: other, sourceID: "nas_1",
                                                             canonicalRelativePath: "借来的/路径.txt"))) { error in
            XCTAssertEqual(error as? FileReferenceStoreError, .identityMismatch)
        }
        // 来源 id 与路径不匹配同样拒绝（同一个 id 换个来源就不再是这个 id）。
        let entry = try reference("a/b.txt")
        XCTAssertThrowsError(try store.register(FileReference(fileID: entry.fileID, sourceID: "nas_2",
                                                             canonicalRelativePath: entry.canonicalRelativePath))) { error in
            XCTAssertEqual(error as? FileReferenceStoreError, .identityMismatch)
        }
        XCTAssertEqual(try store.count(), 0)
    }

    func testTheStoreNeverCallsTheCanonicalizer() throws {
        let code = codeOnly(try sourceText("Sources/FlashFindCore/MCP/FileReferenceStore.swift"))
        XCTAssertFalse(code.contains("RelativePath.canonical"),
                       "Store 调用了 canonical()——验证变成了修复（§3.2.1.1 的反例）")
        XCTAssertTrue(code.contains("RelativePath.isSafe"), "连安全校验都没有了")
        // 写入与读回共用同一份不变量：两处各写一份，迟早变成「写查 A、读查 B」。
        let validateCalls = code.components(separatedBy: "Self.validate(").count - 1
        XCTAssertEqual(validateCalls, 2, "validate 必须被写了的那一条与读回的那一条各调一次")
    }

    func testANonCanonicalUnicodeFormRoundTripsByteForByte() throws {
        // macOS 本地卷给 NFD、NAS 通常给 NFC。`FileID.make` 内部归一化，
        // 所以两种写法是同一个 id；Store 存的是**调用方给的那串字节**，不做二次归一化。
        // 用例里的名字要挑**真有分解形式**的字符：汉字（报告 / 预算）没有，
        // 拿它写这一条会得到「NFD 与 NFC 相等」的假绿。
        let nfd = "报告/预算-café".decomposedStringWithCanonicalMapping + ".xlsx"
        let nfc = nfd.precomposedStringWithCanonicalMapping
        // ★ 这里**不能**用 `!=`：Swift 的 `String` 相等是 Unicode 规范化等价，
        // NFD 与 NFC 比出来是「相等」——而 `FileID.make` 哈希的是 utf8 字节。
        // 正是这个差别让「不归一化就发 id」变成两个 id，所以断言必须落在字节上。
        XCTAssertNotEqual(Array(nfd.utf8), Array(nfc.utf8), "这个用例依赖两种组合形式的字节不同")

        let store = try makeStore()
        defer { store.close() }
        try store.register(try reference(nfd))
        XCTAssertEqual(try store.count(), 1)
        let found = try XCTUnwrap(try store.lookup(try FileID.make(sourceID: "nas_1", canonicalRelativePath: nfc)))
        XCTAssertEqual(Array(found.canonicalRelativePath.utf8), Array(nfd.utf8),
                       "Store 不该替调用方改写字节形态")
    }

    // MARK: - ③ 读回来的行不能盲信

    func testALookupRefusesACorruptRowInsteadOfHandingOutThePath() throws {
        let entry = try reference("允许共享/正常.txt")
        let url = directory.appendingPathComponent("ai-file-reference.sqlite")
        do {
            let store = try FileReferenceStore(url: url)
            try store.register(entry)
            store.close()
        }
        try corruptRow(at: url, fileID: entry.fileID, to: "../../etc/passwd")

        let store = try FileReferenceStore(url: url)
        defer { store.close() }
        XCTAssertThrowsError(try store.lookup(entry.fileID), "把坏路径原样交出去了") { error in
            XCTAssertEqual(error as? FileReferenceStoreError, .corruptRow)
        }
    }

    func testACorruptRowThatNoLongerMatchesItsIDIsAlsoRefused() throws {
        let entry = try reference("允许共享/正常.txt")
        let url = directory.appendingPathComponent("ai-file-reference.sqlite")
        do {
            let store = try FileReferenceStore(url: url)
            try store.register(entry)
            store.close()
        }
        // 路径本身安全，但与这个 id 对不上：同样是坏行，而且是**同一种**报错
        // （读侧不区分「路径不安全」和「id 对不上」——调用方要做的事一样）。
        try corruptRow(at: url, fileID: entry.fileID, to: "允许共享/另一个文件.txt")

        let store = try FileReferenceStore(url: url)
        defer { store.close() }
        XCTAssertThrowsError(try store.lookup(entry.fileID)) { error in
            XCTAssertEqual(error as? FileReferenceStoreError, .corruptRow)
        }
    }

    // MARK: - 原子性

    func testRegisterAllWritesTheWholeBatch() throws {
        let store = try makeStore()
        defer { store.close() }
        let batch = try (1...5).map { try reference("批量/\($0).txt") }
        try store.registerAll(batch)
        XCTAssertEqual(try store.count(), 5)
        for entry in batch { XCTAssertEqual(try store.lookup(entry.fileID), entry) }
    }

    func testOneBadEntryRollsBackTheWholeBatch() throws {
        let store = try makeStore()
        defer { store.close() }
        let good = try (1...3).map { try reference("好/\($0).txt") }
        let fake = try XCTUnwrap(FileID.parse(FileID.prefix + String(repeating: "0", count: FileID.hexLength)))
        let bad = FileReference(fileID: fake, sourceID: "nas_1", canonicalRelativePath: "../逃逸.txt")

        XCTAssertThrowsError(try store.registerAll(good + [bad]))
        XCTAssertEqual(try store.count(), 0, "写了一半：调用方无法从返回值上知道哪些 id 能查")

        // 收拾干净以后同一批能整体写进去（回滚没有留下锁或半截事务）。
        try store.registerAll(good)
        XCTAssertEqual(try store.count(), 3)
    }

    func testAnEmptyBatchIsANoOpInsteadOfAnEmptyTransaction() throws {
        let store = try makeStore()
        defer { store.close() }
        XCTAssertNoThrow(try store.registerAll([]))
        XCTAssertEqual(try store.count(), 0)
    }

    // MARK: - 落点与权限

    func testTheStoreFileLivesBesideTheAppButIsNotTheHistoryFile() throws {
        let home = URL(fileURLWithPath: "/Users/example")
        let url = FileReferenceStorePath.standard(home: home)
        XCTAssertEqual(url.path,
                       "/Users/example/Library/Application Support/FlashFind2/ai-file-reference.sqlite")
        XCTAssertFalse(url.lastPathComponent.contains("history"),
                       "映射表与 History 生命周期不同：用户清空 AI 历史不该顺手清掉 id 解析能力")
        XCTAssertNotEqual(FileReferenceStorePath.standard(home: home).lastPathComponent,
                          AuthoritySocketPath.fileName)
    }

    func testTheDirectoryAndTheFileAreNotReadableByOtherAccounts() throws {
        let store = try makeStore()
        defer { store.close() }
        let file = try FileManager.default.attributesOfItem(atPath: store.url.path)
        XCTAssertEqual((file[.posixPermissions] as? NSNumber)?.intValue, 0o600)

        _ = try store.count()   // 确保库文件真的落盘
        let reopened = try makeStore()
        reopened.close()
        let dir = try FileManager.default.attributesOfItem(atPath: directory.path)
        XCTAssertEqual((dir[.posixPermissions] as? NSNumber)?.intValue, 0o700)
    }

    func testAFailureToOpenTheStoreIsNotSilentlyTreatedAsEmpty() throws {
        // 目录位置被一个普通文件占住 → 打不开就必须抛，不能返回一个空表。
        let blocked = directory.appendingPathComponent("blocked")
        try Data("not a directory".utf8).write(to: blocked)
        XCTAssertThrowsError(try FileReferenceStore(url: blocked.appendingPathComponent("store.sqlite")))
    }

    // MARK: - 结构边界（§4.11.5）

    func testTheStoreKnowsNothingAboutHistorySearchOrCredentials() throws {
        let code = codeOnly(try sourceText("Sources/FlashFindCore/MCP/FileReferenceStore.swift"))
        for forbidden in ["HistoryStore", "ai-history", "SearchResult", "LocateResponse",
                          "SecretStore", "credentials", "prompt", "agentID", "sessionID",
                          "localURL", "absolutePath", "FileManager.default.contents"] {
            XCTAssertFalse(code.contains(forbidden), "Store 里出现了 \(forbidden)——它已经越界了")
        }
        // 它必须真的只认 FileID（不认 SearchResult / [String: Any] 这类"顺手能拿到更多"的入参）。
        XCTAssertTrue(code.contains("func register(_ reference: FileReference)"))
        XCTAssertTrue(code.contains("func lookup(_ fileID: FileID)"))
    }

    func testLookupIsAPrimaryKeySeekNotATableScan() throws {
        let store = try makeStore()
        defer { store.close() }
        try store.register(try reference("查/计划.txt"))
        let plan = try queryPlan(at: store.url, sql:
            "SELECT source_id, canonical_relative_path FROM \(FileReferenceStore.tableName) WHERE file_id='x'")
        XCTAssertTrue(plan.contains("USING"), "查询没走索引：\(plan)")
        XCTAssertFalse(plan.uppercased().contains("SCAN \(FileReferenceStore.tableName.uppercased())"),
                       "全表扫描：\(plan)")
    }

    // MARK: - ④ 冲突即失败（6.4b-1）

    /// 库里已有的映射**绝不被改写**（`ff1_x → A/pA` 撞上 `ff1_x → B/pB`）。
    ///
    /// ★ 这条是「把 INSERT 换成 INSERT OR REPLACE / ON CONFLICT DO UPDATE」那类
    /// 变异的直接抓手：那样写会让同一个 id 在两次调用之间悄悄换了所指，
    /// 而 Agent 手里还摆着上一次拿到它的那次结果。
    func testAnExistingMappingIsNeverOverwritten() throws {
        let entry = try reference("允许共享/原文件.txt", source: "nas_1")
        let store = try makeStore()
        defer { store.close() }
        try store.register(entry)
        // 手工把这一行改到别处去（模拟被旧版本写坏 / 被手工改过 / 撞了 hash）。
        try overwriteRow(at: store.url, fileID: entry.fileID,
                         sourceID: "nas_2", path: "别处/另一个.txt")

        let sameID = FileReference(fileID: entry.fileID,
                                   sourceID: "nas_1",
                                   canonicalRelativePath: "允许共享/原文件.txt")
        XCTAssertThrowsError(try store.register(sameID)) { error in
            XCTAssertEqual(error as? FileReferenceStoreError, .conflictingMapping)
        }
        // 旧的那条**原样留着**：不允许被顶掉。
        let stored = try overwriteReading(store, entry.fileID)
        XCTAssertNil(stored, "冲突之后旧行被改掉了")
    }

    /// 撞上一条的那一批，**整批都不写**（原子性的另一半）。
    ///
    /// ★ 只回滚坏的那一条会得到「有的 id 能查、有的不能」，
    /// 而调用方无法从返回值上区分是哪一半。
    func testOneConflictRollsBackTheWholeBatch() throws {
        let entry = try reference("允许共享/原文件.txt", source: "nas_1")
        let store = try makeStore()
        defer { store.close() }
        try store.register(entry)
        try overwriteRow(at: store.url, fileID: entry.fileID,
                         sourceID: "nas_2", path: "别处/另一个.txt")

        let fine = try reference("允许共享/新文件.txt", source: "nas_1")
        XCTAssertThrowsError(try store.registerAll([fine, entry]))
        XCTAssertEqual(try store.count(), 1, "冲突时连前面那条也不该留下")
    }

    /// 同一个文件被以两种**字节形态**写两次：以先写的为准，且不报错。
    ///
    /// ★ 幂等判定按**身份**算（都过 `FileID.make`），不按字节：
    /// 逐字节比较的话，一次 `locate` 里同一个文件的 NFD 与 NFC 两种写法
    /// 会把整批 `registerAll` 打成失败。
    func testTheFirstByteFormWinsAndTheSecondIsNotAnError() throws {
        // ★ 必须用**真有分解形式**的字符：汉字没有，「预算.xlsx」的 NFD 与 NFC
        //   是同一串字节，用例会变成一条永远成立的假绿（6.4b-0 踩过一次）。
        let nfc = "报告/café.txt"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        XCTAssertNotEqual(nfc.utf8.count, nfd.utf8.count, "这个用例依赖两种形态真的不同")
        let id = try FileID.make(sourceID: "nas_1", canonicalRelativePath: nfc)

        let store = try makeStore()
        defer { store.close() }
        try store.register(FileReference(fileID: id, sourceID: "nas_1", canonicalRelativePath: nfc))
        try store.register(FileReference(fileID: id, sourceID: "nas_1", canonicalRelativePath: nfd))
        XCTAssertEqual(try store.count(), 1)
        // ★ 必须比 utf8 字节，不能比 `String ==`：Swift 的 `==` 是**规范化等价**，
        //   NFD 与 NFC 在它眼里相等。用 `==` 的话这条用例在「冲突被静默覆盖」
        //   那条变异下照样是绿的——一条永远绿的用例等于没有（6.4b-1 实测到）。
        let stored = try XCTUnwrap(store.lookup(id)?.canonicalRelativePath)
        XCTAssertEqual(Array(stored.utf8), Array(nfc.utf8), "先写的那串字节不该被改写")
        XCTAssertEqual(stored.utf8.count, nfc.utf8.count, "先写的那串字节不该被改写")
    }

    /// 完全相同的登记是幂等的（同 id 必然同来源同路径）。
    func testRegisteringTheSameReferenceTwiceIsIdempotent() throws {
        let entry = try reference("允许共享/原文件.txt")
        let store = try makeStore()
        defer { store.close() }
        try store.register(entry)
        try store.register(entry)
        XCTAssertEqual(try store.count(), 1)
    }

    /// 源码里不许出现任何「覆盖式写入」的写法。
    ///
    /// ★ 结构断言而不是行为断言：行为上要撞到 128 位 hash 碰撞才可能触发，
    /// 而 `INSERT OR REPLACE` 那种写法一旦进去，在撞上之前**一次都不会红**。
    func testThereIsNoUpsertAnywhereInTheStore() throws {
        // ★ 必须先剥注释：这几个禁词本身就写在解释「为什么不用它们」的注释里。
        //   不剥的话这条会一直红，而它红了就等于没人再信它（狼来了）。
        let code = codeOnly(try sourceText("Sources/FlashFindCore/MCP/FileReferenceStore.swift"))
        for forbidden in ["INSERT OR REPLACE", "REPLACE INTO", "DO UPDATE", "ON CONFLICT"] {
            XCTAssertFalse(code.uppercased().contains(forbidden.uppercased()),
                           "Store 里出现了 \(forbidden)：那会静默改写既有引用")
        }
    }

    /// 所有 SQLite 访问都在**一条串行队列**上（6.4b-1 并发要求）。
    ///
    /// ★ 这条守的是并发模型本身：三个 Tool 并发时 Store 是共享写点，
    /// 少了队列，「偶发 database is locked」会变成随机 internal_error。
    func testEveryEntryPointGoesThroughOneSerialQueue() throws {
        let code = codeOnly(try sourceText("Sources/FlashFindCore/MCP/FileReferenceStore.swift"))
        XCTAssertTrue(code.contains("DispatchQueue(label:"), "没有自己的串行队列")
        XCTAssertFalse(code.contains("NSLock"), "已经有队列了还要锁，必然有一处是多余的")
        // register / registerAll / lookup / count / close 五个入口。
        XCTAssertGreaterThanOrEqual(code.components(separatedBy: "queue.sync").count - 1, 5,
                                    "有入口没走队列：\(code.components(separatedBy: "queue.sync").count - 1)")
    }

    // MARK: - 内部工具

    /// 手工把一行整个换掉（绕过 Store 的校验）。
    private func overwriteRow(at url: URL, fileID: FileID, sourceID: String, path: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { return XCTFail("打不开库") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(handle,
            "UPDATE file_reference SET source_id=?, canonical_relative_path=? WHERE file_id=?",
            -1, &statement, nil), SQLITE_OK)
        guard let statement else { return XCTFail("prepare 失败") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, sourceID, -1, transient)
        sqlite3_bind_text(statement, 2, path, -1, transient)
        sqlite3_bind_text(statement, 3, fileID.value, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }

    /// 读一行原始值（不看 Store 的校验结果），用来断言「旧行还在不在」。
    private func overwriteReading(_ store: FileReferenceStore, _ fileID: FileID) throws -> String? {
        // 冲突后被顶掉的话，lookup 会抛错；这里只要知道它有没有被改写。
        do {
            return try store.lookup(fileID)?.canonicalRelativePath
        } catch FileReferenceStoreError.corruptRow {
            return nil
        } catch FileReferenceStoreError.conflictingMapping {
            return nil
        }
    }
}
