import XCTest
@testable import FlashFindCore
import CSQLite

/// Phase 6.4b-1：`get_metadata` 的执行链与七字段契约。
///
/// ## 这一组守的六件事（v0.29 拍板）
///
/// ```text
/// ① 落盘先于成功响应 —— 去掉 registerAll，id 就查不出来
/// ② 每一次都判权     —— 撤销来源 / 关掉本机，下一次 get_metadata 立即生效
/// ③ 冻结句柄         —— 不可用来源不许借别人的句柄，不许重读注册表
/// ④ null ≠ 0         —— 设备没给大小就是 null，不能折成 0
/// ⑤ 七字段闭集       —— 没有 absolute_path
/// ⑥ 重启后仍在       —— 映射表落盘，不是内存里的东西
/// ```
///
/// ★ 只替换 provider 与映射表文件，**权限判定与快照是真的**：
/// 「判权之后又读一次注册表」这类问题只有在真快照上才暴露得出来。
///
/// ★ 所有来源 id、文件名、查询词都是编造的；映射表一律落在临时目录。
@MainActor
final class GetMetadataExecutionTests: XCTestCase {

    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let archive = "src_nas_archive"

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    // MARK: - 替身 Provider

    /// 既能搜（给 `locate` 用）、又能按路径直查的 provider。
    ///
    /// `metadata` 的取值按路径查表，查不到用 `fallback`。
    final class Fake: SearchProvider, PathMetadataProviding, @unchecked Sendable {

        let source: SearchSource
        private let rows: [String: [SearchResult]]
        private let outcomes: [String: MetadataOutcome]
        private let fallback: MetadataOutcome

        private(set) var asked: [String] = []

        init(id: String,
             rows: [String: [SearchResult]] = [:],
             outcomes: [String: MetadataOutcome] = [:],
             fallback: MetadataOutcome = .notFound) {
            self.source = SearchSource(id: id, name: id, type: .nas, displayName: id)
            self.rows = rows
            self.outcomes = outcomes
            self.fallback = fallback
        }

        func metadata(canonicalRelativePath: String) async -> MetadataOutcome {
            asked.append(canonicalRelativePath)
            return outcomes[canonicalRelativePath] ?? fallback
        }

        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
            emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                               results: rows[text] ?? [], state: .completed))
        }

        func cancel(queryID: UUID) {}
    }

    /// 一个**不会**直查的 provider（与 `AppSearchProvider` 同型：不实现
    /// `PathMetadataProviding`）。直查到它身上必须是 `.unsupported`。
    final class Blind: SearchProvider, @unchecked Sendable {
        let source: SearchSource
        init(id: String) { source = SearchSource(id: id, name: id, type: .nas, displayName: id) }
        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .completed))
        }
        func cancel(queryID: UUID) {}
    }

    // MARK: - 脚手架

    private func row(_ path: String, kind: String = "file") -> SearchResult {
        SearchResult(id: path,
                     name: (path as NSString).lastPathComponent,
                     relativePath: path,
                     sourceID: nil,
                     sourceName: "",
                     kind: kind,
                     size: 1,
                     localURL: nil)
    }

    /// 本次请求的快照。
    ///
    /// ★ `providers` 里没有的来源 = 这一刻没有可用句柄（掉线 / 还没建好），
    /// 而 `ids` 是「这次请求被允许的范围」——两者是两件事，分开给。
    private func snapshot(ids: [String], providers: [any SearchProvider]) -> AuthorizedSourceSnapshot {
        let shared = SearchScheduler(providers: providers)
        var byID: [String: any SearchProvider] = [:]
        for provider in providers { byID[provider.source.id] = provider }
        let registry = ids.map { id -> AuthoritySource in
            var handle: SourceExecutionHandle?
            if let provider = byID[id] {
                handle = SourceExecutionHandle(provider: provider, scheduler: shared)
            }
            return AuthoritySource(id: id, name: "Source \(id)", execution: handle)
        }
        let scope = AuthorizationScope(granting: .allow(sources: ids, warnings: []))!
        return AuthorizedSourceSnapshot(scope: scope, registry: registry)
    }

    private func application(_ applied: Int) -> LimitApplication {
        LimitApplication(applied: applied, wasClamped: false)
    }

    private func makeStore() throws -> (FileReferenceStore, URL) {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("ff2-meta-\(UUID().uuidString)", isDirectory: true)
        let url = directory.appendingPathComponent("ai-file-reference.sqlite")
        return (try FileReferenceStore(url: url), url)
    }

    /// 把一条映射直接写进库（绕开 Store 的校验，用来造出「库里已经有别的映射」）。
    private func write(_ reference: FileReference, into store: FileReferenceStore) async throws {
        try store.register(reference)
    }

    private func body(_ outcome: ToolOutcome) throws -> [String: Any] {
        guard case .success(let json) = outcome else {
            XCTFail("不是成功结果：\(outcome)")
            throw Failure()
        }
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
    }

    private func code(of outcome: ToolOutcome) -> String? {
        guard case .failure(let code, _) = outcome else { return nil }
        return code
    }

    private struct Failure: Error {}

    // MARK: - ① 落盘先于成功响应

    /// `locate` 返回的那批 id，当次就能被反查到。
    ///
    /// ★ 这条是「去掉 `registerAll`」那个变异的直接抓手：删掉登记那一步，
    /// 搜索仍然成功、`file_id` 仍然发得出去，只有这条会红。
    func testLocateRegistersTheIdsItReturns() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let provider = Fake(id: work, rows: ["预算": [row("/" + path)]],
                            outcomes: [path: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                                 sizeBytes: 4096, modified: nil))])
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: store)

        let run = await executor.run(query: "预算",
                                     kind: nil,
                                     modifiedAfter: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     owner: .mcp(sessionID: "locate"))
        let results = try XCTUnwrap((try body(run.outcome))["results"] as? [[String: Any]])
        let id = try XCTUnwrap(FileID.parse(try XCTUnwrap(results.first?["file_id"] as? String)))

        let outcome = await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome
        let payload = try body(outcome)
        XCTAssertEqual(payload["size_bytes"] as? Int, 4096, "刚返回的 id 必须查得到：\(outcome)")
    }

    /// 没有登记过的 id 就是查不到。
    ///
    /// ★ 与上面那条成对：只断言「登记了能查」会被「一律查得到」蒙过去。
    func testAnUnregisteredIdIsNotFoundEvenWhenTheSourceIsFine() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 1, modified: nil)))
        let id = try FileID.make(sourceID: work, canonicalRelativePath: "共享/预算.xlsx")

        let run = await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.fileNotFound.rawValue)
        XCTAssertTrue(provider.asked.isEmpty, "表里没有这条映射时，根本不该去问设备：\(provider.asked)")
    }

    /// `search` 也要登记：它是 `file_id` 的第二个出口。
    ///
    /// ★ 三个 Tool 各自接线的话，漏掉 `search` 那一条会表现为「search 出来的
    /// id 问不出元数据」，而三个 Tool 各自的用例都是绿的。
    func testSearchRegistersTheIdsItReturns() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let provider = Fake(id: work, rows: ["预算": [row("/" + path)]],
                            outcomes: [path: .found(PathMetadata(name: "预算.xlsx", kind: .file,
                                                                 sizeBytes: 7, modified: nil))])
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: store)

        let run = await executor.runSearch(query: "预算",
                                           application: application(5),
                                           snapshot: snapshot(ids: [work], providers: [provider]),
                                           owner: .mcp(sessionID: "s"))
        let results = try XCTUnwrap((try body(run.outcome))["results"] as? [[String: Any]])
        let id = try XCTUnwrap(FileID.parse(try XCTUnwrap(results.first?["file_id"] as? String)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["size_bytes"] as? Int, 7)
    }

    /// `locate_many` 的每个分组都要能反查（合成一笔事务）。
    func testLocateManyRegistersEveryGroup() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let a = "共享/甲.pdf"
        let b = "共享/乙.pdf"
        let provider = Fake(id: work,
                            rows: ["甲": [row("/" + a)], "乙": [row("/" + b)]],
                            outcomes: [a: .found(PathMetadata(name: "甲.pdf", kind: .file,
                                                              sizeBytes: 1, modified: nil)),
                                       b: .found(PathMetadata(name: "乙.pdf", kind: .file,
                                                              sizeBytes: 2, modified: nil))],
                            fallback: .notFound)
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: store)

        let run = await executor.runMany(queries: ["甲", "乙"],
                                         application: application(3),
                                         snapshot: snapshot(ids: [work], providers: [provider]),
                                         owner: .mcp(sessionID: "s"))
        let groups = try XCTUnwrap((try body(run.outcome))["queries"] as? [[String: Any]])
        var ids: [FileID] = []
        for group in groups {
            let results = try XCTUnwrap(group["results"] as? [[String: Any]])
            for entry in results {
                ids.append(try XCTUnwrap(FileID.parse(try XCTUnwrap(entry["file_id"] as? String))))
            }
        }
        XCTAssertEqual(ids.count, 2)
        for id in ids {
            let payload = try body(await MetadataExecutor(store: store)
                .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
            XCTAssertNotNil(payload["size_bytes"] as? Int, "分组里的 id 必须能反查：\(payload)")
        }
    }

    /// 落盘失败 → 整次 Tool Call 失败，**不发出那些 id**。
    ///
    /// ★ 这是「不许发出不能兑现的引用」的正面断言：反过来实现会先回成功，
    /// 于是 Agent 手里有个重启后就 `file_not_found` 的 id，而它当下看不出来。
    func testAStoreThatCannotWriteFailsTheWholeCall() async throws {
        let (store, url) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        // 库里先有一条指向别处的同 id 映射 → 这一批必然撞上冲突。
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try injectRow(url: url, fileID: id, sourceID: archive, path: "别处/预算.xlsx")

        let provider = Fake(id: work, rows: ["预算": [row("/" + path)]])
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: store)

        let run = await executor.run(query: "预算",
                                     kind: nil,
                                     modifiedAfter: nil,
                                     application: application(5),
                                     snapshot: snapshot(ids: [work], providers: [provider]),
                                     owner: .mcp(sessionID: "s"))
        XCTAssertEqual(code(of: run.outcome), "internal_error",
                       "写不进去就不许回成功：\(run.outcome)")
    }

    /// 分组合成**一笔**事务：后一组撞了，前一组也不许留下。
    ///
    /// ★ 这条是「逐组各提交一次」那个变异的直接抓手：那样写会得到
    /// 「前三组的 id 能查、后两组的不能」，而响应本身看起来是完整的。
    func testLocateManyRegistersEveryGroupInOneTransaction() async throws {
        let (store, url) = try makeStore()
        defer { store.close() }
        let first = "共享/甲.pdf"
        let second = "共享/乙.pdf"
        // 提前把「乙」的 id 占给别处，让第二组必然撞上。
        try injectRow(url: url,
                      fileID: try FileID.make(sourceID: work, canonicalRelativePath: second),
                      sourceID: archive,
                      path: "别处/乙.pdf")

        let provider = Fake(id: work, rows: ["甲": [row("/" + first)], "乙": [row("/" + second)]])
        let executor = LocateExecutor(timing: LocateExecutor.Timing(now: { self.now }),
                                      referenceStore: store)
        let run = await executor.runMany(queries: ["甲", "乙"],
                                         application: application(3),
                                         snapshot: snapshot(ids: [work], providers: [provider]),
                                         owner: .mcp(sessionID: "s"))
        XCTAssertEqual(code(of: run.outcome), "internal_error")

        // ★ 第一组的 id **也不许**留下来：留了就是「有的能查有的不能」。
        let firstID = try FileID.make(sourceID: work, canonicalRelativePath: first)
        XCTAssertNil(try store.lookup(firstID), "事务没回滚干净")
        XCTAssertEqual(try store.count(), 1, "只剩注入的那一条")
    }

    // MARK: - ② 每次都判权

    /// 撤销来源之后，下一次 `get_metadata` 立即 `source_denied`。
    ///
    /// ★ 与「Store 有这条 → 直接读」那种写法的分水岭：那种写法在这里会
    /// 照常返回元数据，而用户刚刚撤销了那个来源。
    func testRevokingTheSourceDeniesTheNextCall() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "归档/旧报告.pdf"
        let id = try FileID.make(sourceID: archive, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: archive, canonicalRelativePath: path))

        // 这次请求的 scope 里已经没有 archive 了（用户在设置里取消了勾选）。
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "旧报告.pdf", kind: .file, sizeBytes: 1, modified: nil)))
        let run = await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider]))

        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.sourceDenied.rawValue)
        XCTAssertEqual(run.reached, .outsideScope)
        XCTAssertTrue(provider.asked.isEmpty, "未授权的来源不该被问到：\(provider.asked)")
    }

    /// 撤销**不删库**：映射还在，只是这次不给你。
    ///
    /// ★ 少了这条，有人会用「撤销时把映射删掉」来实现判权——那样开关一开回来
    /// 就永久失效了（latent authorization 被剪掉）。
    func testRevocationDoesNotEraseTheMapping() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "归档/旧报告.pdf"
        let id = try FileID.make(sourceID: archive, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: archive, canonicalRelativePath: path))

        _ = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [work], providers: [Fake(id: work)]))
        XCTAssertEqual(try store.count(), 1, "撤销不该顺手清掉映射")

        // 重新授权 → 不需要重新搜一遍。
        let again = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [archive], providers: [Fake(id: archive, fallback:
                .found(PathMetadata(name: "旧报告.pdf", kind: .file, sizeBytes: 1, modified: nil)))]))
        XCTAssertNil(code(of: again.outcome), "重新授权后原有 id 应当立刻可用：\(again.outcome)")
    }

    /// AI 总开关关着 → `mcp_disabled`，**不是** `file_not_found`。
    ///
    /// ★ 顺序必须如此：权限判定在查表之前。反过来会因为「表里有没有这条」
    /// 给出不同的错误码，Agent 就会以为文件没了。
    func testMcpDisabledBeatsEverything() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let disabled = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: false, allowedSources: [self.work]) },
            sources: { [AuthoritySource(id: self.work, name: "Work NAS")] },
            referenceStore: store)
        let outcome = await disabled.handle(AuthorityJob(
            id: "job", op: .getMetadata, arguments: ["file_id": .string(id.value)]))
        // 表里明明有这条，也必须先说「AI 关着」。
        XCTAssertEqual(code(of: outcome), "mcp_disabled", "关着的 MCP 不能报 file_not_found")

        // 对照：同一个 id、AI 开着时，能走到直查。
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 3, modified: nil)))
        let enabled = RoutingAuthorityService(
            settings: { AIAccessSettings(isEnabled: true, allowedSources: [self.work]) },
            sources: {
                let scheduler = await SearchScheduler(providers: [])
                return [AuthoritySource(id: self.work, name: "Work NAS",
                                        execution: SourceExecutionHandle(provider: provider,
                                                                        scheduler: scheduler))]
            },
            referenceStore: store)
        let ok = await enabled.handle(AuthorityJob(
            id: "job2", op: .getMetadata, arguments: ["file_id": .string(id.value)]))
        XCTAssertNil(code(of: ok), "开着的时候应该真的查到：\(ok)")
    }

    // MARK: - ③ 冻结句柄

    /// 这次没有可用句柄 → `source_unavailable`。
    func testASourceWithoutAHandleIsUnavailable() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "归档/旧报告.pdf"
        let id = try FileID.make(sourceID: archive, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: archive, canonicalRelativePath: path))

        // archive 在 scope 里，但这一刻没有 provider（设备掉线）。
        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [archive], providers: [Fake(id: work)]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.sourceUnavailable.rawValue)
        XCTAssertEqual(run.reached, .noHandle)
    }

    /// 掉线的那个来源**不许借**别人的句柄去查。
    ///
    /// ★ 这条是「拿快照里第一个可用句柄」那个变异的直接抓手：那样写会拿到
    /// work 的句柄、返回 work 的元数据，而 ref 明明指向 archive。
    func testAnUnavailableSourceDoesNotBorrowAnotherSourcesHandle() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "归档/旧报告.pdf"
        let id = try FileID.make(sourceID: archive, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: archive, canonicalRelativePath: path))

        let worker = Fake(id: work, fallback: .found(
            PathMetadata(name: "真有这个文件.pdf", kind: .file, sizeBytes: 9, modified: nil)))
        // 两个来源都在 scope 里，但只有 work 有句柄。
        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [archive, work], providers: [worker]))

        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.sourceUnavailable.rawValue)
        XCTAssertTrue(worker.asked.isEmpty, "不许拿别的来源的句柄去问：\(worker.asked)")
    }

    /// 没有直查能力的来源 → `internal_error`（能力缺口，不新立码）。
    func testAProviderWithoutTheCapabilityIsAnInternalError() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [work], providers: [Blind(id: work)]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.internalError.rawValue)
    }

    /// 直查问的是**库里那条路径**。
    func testTheStoredPathIsTheOneSentToTheDevice() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算 2026.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let provider = Fake(id: work, fallback: .notFound)
        _ = await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider]))
        XCTAssertEqual(provider.asked, [path])
    }

    // MARK: - ④ null ≠ 0 / 时间口径

    /// 设备没给大小 → `size_bytes` 是 JSON `null`，**不是 0**。
    ///
    /// ★ 这是 6.4b-0 探针抓到的那个真问题的正面断言：WebDAV 会把「没给」
    /// 折成 0，而 0 会被 Agent 读成「这是个空文件」。
    func testAnUnknownSizeIsNullNotZero() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: nil, modified: nil)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["size_bytes"] as? NSNull, NSNull(), "未知大小必须是 null")
        XCTAssertNil(payload["size_bytes"] as? Int)
    }

    /// 真的是 0 字节的文件，必须是 `0`——与上面那条**相反**。
    ///
    /// ★ 两条成对才有意义：只有「未知 → null」会被「一律 null」蒙过去，
    /// 只有「0 字节 → 0」会被「一律 0」蒙过去。
    func testAZeroByteFileReportsZeroNotNull() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/空.txt"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "空.txt", kind: .file, sizeBytes: 0, modified: nil)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["size_bytes"] as? Int, 0)
        XCTAssertNil(payload["size_bytes"] as? NSNull)
    }

    /// 时间一律 UTC + ISO 8601。
    ///
    /// ★ 三个来源给的形态不一样（群晖带 Z、WebDAV 本地不带偏移），
    /// 不在出参这一层统一，同一个文件在两个来源上会差 8 小时。
    func testModifiedIsWrittenInUtcIso() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 1, modified: now)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["modified"] as? String, MetadataResponse.utcFormatter.string(from: now))
        XCTAssertTrue((payload["modified"] as? String)?.hasSuffix("Z") == true,
                      "必须带 UTC 标记：\(String(describing: payload["modified"]))")
    }

    /// 设备没给时间 → `null`，**不是 1970**。
    func testAnUnknownTimeIsNullNotEpoch() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 1, modified: nil)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["modified"] as? NSNull, NSNull())
    }

    // MARK: - ⑤ 七字段闭集

    /// 多一个键或少一个键都要红。
    func testTheResponseCarriesExactlySevenFields() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 1, modified: nil)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(Set(payload.keys),
                       ["file_id", "source_id", "name", "kind", "relative_path", "size_bytes", "modified"])
        XCTAssertEqual(payload["file_id"] as? String, id.value)
        XCTAssertEqual(payload["source_id"] as? String, work)
        XCTAssertEqual(payload["relative_path"] as? String, path)
        XCTAssertEqual(payload["kind"] as? String, "file")
        // ★ 没有 absolute_path（v0.29 正式改掉的旧冻结项）。
        XCTAssertNil(payload["absolute_path"])
    }

    // MARK: - 错误语义

    /// 来源可用但文件不在 → `file_not_found`（不是 `source_unavailable`）。
    func testAFileThatIsGoneIsFileNotFound() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/被删了.pdf"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [work], providers: [Fake(id: work)]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.fileNotFound.rawValue)
        XCTAssertEqual(run.reached, .lookedUp, "必须真的去问了设备，才能说「不在了」")
    }

    func testAnExpiredSessionIsAuthRequired() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [work], providers: [Fake(id: work, fallback: .needsAuth)]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.authRequired.rawValue)
    }

    /// 库坏了的那一行的 id → `internal_error`，**不是** `file_not_found`。
    ///
    /// ★ 折成 file_not_found 会把「我们的库坏了」说成「文件没了」，
    /// 用户会去找一个其实还在的文件。
    func testACorruptRowIsAnInternalErrorNotFileNotFound() async throws {
        let (store, url) = try makeStore()
        defer { store.close() }
        let id = try FileID.make(sourceID: work, canonicalRelativePath: "共享/预算.xlsx")
        try injectRow(url: url, fileID: id, sourceID: work, path: "共享/别的.pdf")

        let run = await MetadataExecutor(store: store).run(
            fileID: id, snapshot: snapshot(ids: [work], providers: [Fake(id: work)]))
        XCTAssertEqual(code(of: run.outcome), MetadataExecutor.FailureCode.internalError.rawValue)
    }

    /// 目录可以查，但 `size_bytes` 是 null（目录项大小不是文件大小）。
    func testAFolderHasNoSize() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }
        let path = "共享/项目"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "项目", kind: .folder, sizeBytes: nil, modified: now)))

        let payload = try body(await MetadataExecutor(store: store)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["kind"] as? String, "folder")
        XCTAssertEqual(payload["size_bytes"] as? NSNull, NSNull())
    }

    // MARK: - ⑥ 重启后仍在

    /// 关掉 Store 再打开（模拟 App 重启），映射仍然在。
    ///
    /// ★ 少了这条，「存内存里」的实现也能让上面所有用例通过。
    func testTheMappingSurvivesAReopen() async throws {
        let (store, url) = try makeStore()
        let path = "共享/预算.xlsx"
        let id = try FileID.make(sourceID: work, canonicalRelativePath: path)
        try store.register(FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))
        store.close()

        let reopened = try FileReferenceStore(url: url)
        defer { reopened.close() }
        XCTAssertEqual(try reopened.lookup(id),
                       FileReference(fileID: id, sourceID: work, canonicalRelativePath: path))

        let provider = Fake(id: work, fallback: .found(
            PathMetadata(name: "预算.xlsx", kind: .file, sizeBytes: 1, modified: nil)))
        let payload = try body(await MetadataExecutor(store: reopened)
            .run(fileID: id, snapshot: snapshot(ids: [work], providers: [provider])).outcome)
        XCTAssertEqual(payload["size_bytes"] as? Int, 1)
    }

    // MARK: - ⑦ 并发

    /// 八个任务同时写读同一张库，不许出现 `database is locked`。
    ///
    /// ★ 三个 Tool 并发时 Store 是共享写点。这条不写，「偶发锁超时」会表现成
    /// MCP 搜索**随机** `internal_error`——那种故障在生产上几乎查不出来。
    func testConcurrentReadersAndWritersDoNotLockEachOtherOut() async throws {
        let (store, _) = try makeStore()
        defer { store.close() }

        let ids = try (0..<8).map { index in
            try FileID.make(sourceID: work, canonicalRelativePath: "共享/文件\(index).pdf")
        }

        // 用后台任务真并发：MainActor 上串行跑等于什么都没测。
        await withTaskGroup(of: Bool.self) { group in
            for (index, id) in ids.enumerated() {
                group.addTask {
                    let path = "共享/文件\(index).pdf"
                    do {
                        try store.register(FileReference(fileID: id,
                                                         sourceID: "src_nas_work",
                                                         canonicalRelativePath: path))
                        return (try? store.lookup(id)) != nil
                    } catch {
                        return false
                    }
                }
            }
            var succeeded = 0
            for await ok in group where ok { succeeded += 1 }
            XCTAssertEqual(succeeded, ids.count, "并发写读里有失败的：\(succeeded)/\(ids.count)")
        }
        XCTAssertEqual(try store.count(), ids.count)
    }

    // MARK: - 内部工具

    /// 直接往库里插一行（绕过 Store 的校验），用来造出「库里已经有别的映射」。
    private func injectRow(url: URL, fileID: FileID, sourceID: String, path: String) throws {
        var handle: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &handle), SQLITE_OK)
        guard let handle else { return XCTFail("打不开库") }
        defer { sqlite3_close(handle) }
        var statement: OpaquePointer?
        XCTAssertEqual(sqlite3_prepare_v2(
            handle,
            "INSERT INTO file_reference(file_id, source_id, canonical_relative_path) VALUES(?,?,?)",
            -1, &statement, nil), SQLITE_OK)
        guard let statement else { return XCTFail("prepare 失败") }
        defer { sqlite3_finalize(statement) }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        sqlite3_bind_text(statement, 1, fileID.value, -1, transient)
        sqlite3_bind_text(statement, 2, sourceID, -1, transient)
        sqlite3_bind_text(statement, 3, path, -1, transient)
        XCTAssertEqual(sqlite3_step(statement), SQLITE_DONE)
    }
}
