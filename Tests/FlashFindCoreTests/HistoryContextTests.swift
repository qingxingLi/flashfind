import XCTest
@testable import FlashFindCore

/// Phase 7a：History 的身份与 wire 契约（方案 §6.4 / §7a）。
///
/// ## 这一组守的四件事
///
/// ```text
/// ① 上下文与 args 同级   —— context 不是「Agent 给的参数」
/// ② session ≠ request id —— 进程生命周期 vs 每次调用（§4.7 / §6.2.2）
/// ③ 标签不可信          —— 三个权限/路由文件都不许提到 HistoryContext
/// ④ 标签不影响判定      —— 换掉标签，路由与判定结果必须逐字相同
/// ```
///
/// ## ★ 为什么 ③ 只能是结构测试
///
/// 「`session_id` / `agent_id` 不许进判定」这件事写不成一条行为断言：
/// 伪造标签之后再去看结果，结果**本来就应该一样**——于是「标签被误用」
/// 与「标签没被用」长得一模一样。真正能机械验证的是**引用关系**：
/// 判定的那三个文件里不许出现这个类型名。谁把标签接进
/// `PermissionPolicy` / `ToolRouter` / `AuthorizedSourceSnapshot`，
/// 这里当场变红。
///
/// ★ 所有来源 id、文件名、查询词都是编造的。
@MainActor
final class HistoryContextTests: XCTestCase {

    /// 全编造的 id：测试不许出现真实设备名或来源名。
    private let work = "src_nas_work"

    /// 只用来跑一次真实路由的最小 provider。
    ///
    /// ★ 它**不实现** `PathMetadataProviding`：这一组测的是「标签不参与判定」，
    ///   与直查能力无关，别让替身多带一份用不上的能力。
    private final class Fake: SearchProvider, @unchecked Sendable {
        let source: SearchSource
        init(id: String) { source = SearchSource(id: id, name: id, type: .nas, displayName: id) }
        func search(_ text: String, queryID: UUID,
                    emit: @escaping @MainActor (ProviderEvent) -> Void) async {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .completed))
        }
        func cancel(queryID: UUID) {}
    }

    // MARK: - ① 形状：context 是 args 的兄弟，不是它的内容

    /// 字面量报文 → `context` 被解出来，而且**没有**落进 `args`。
    ///
    /// ★ 后者是重点：`context` 一旦进了 `args`，Router 会把它当
    /// 「未声明的参数」拒掉（§4.3.1），表现为**助手每次调用都失败**；
    /// 而这条错误在开发机上不会出现——没有人手往 socket 里写 context。
    func testTheRidesNextToArgsNotInsideThem() throws {
        let body = #"{"v":1,"id":"req-1","op":"locate","args":{"query":"预算"},"#
            + #""context":{"session_id":"sess-A","agent_id":"claude-code/1.0.31"}}"#
        let request = try AuthorityWire.decodeRequest(Data(body.utf8))

        XCTAssertEqual(request.context?.sessionID, "sess-A")
        XCTAssertEqual(request.context?.agentID, "claude-code/1.0.31")
        XCTAssertEqual(request.args.count, 1, "context 不该混进参数：\(request.args)")
        XCTAssertNil(request.args["session_id"])
        XCTAssertNil(request.args["agent_id"])
        XCTAssertNil(request.args["context"])
    }

    /// 没有 `context` 的报文照常解析——它不是必填项。
    ///
    /// ★ 老客户端、直接写 socket 的脚本都不会带它。缺标签只影响 History 的
    ///   维度，**不许**因此让请求失败（历史是旁路，§6.6）。
    func testARequestWithoutContextIsNotAnError() throws {
        let line = Data(#"{"v":1,"id":"req-1","op":"locate","args":{"query":"预算"}}"#.utf8)
        let request = try AuthorityWire.decodeRequest(line)

        XCTAssertNil(request.context)
        XCTAssertEqual(request.operation, .locate)
    }

    /// 编码 → 解码，两个标签都在。
    func testBothLabelsSurviveTheRoundTrip() throws {
        let context = HistoryContext(sessionID: "sess-A", agentID: "claude-code/1.0.31")
        let request = AuthorityWire.request(tool: "locate",
                                             arguments: ToolArguments(["query": .string("预算")]),
                                             id: "req-1",
                                             context: context)
        let decoded = try AuthorityWire.decodeRequest(try AuthorityWire.line(request))

        XCTAssertEqual(decoded, request)
        XCTAssertEqual(decoded.context, context)
    }

    // MARK: - ② 身份：session 是 Helper 进程的生命周期

    /// 同一个 Helper 进程里 session 不变。
    func testTheSessionIdIsStableWithinOneHelperProcess() {
        let source = HistoryContextSource()
        XCTAssertEqual(source.current().sessionID, source.current().sessionID)
        XCTAssertFalse(source.sessionID.isEmpty)
    }

    /// 重启 Helper = 换一个 session。
    ///
    /// ★ 这是「同 session 同文件只记一次 located」（§6.2.2）能成立的前提：
    ///   session 必须能随进程结束而结束，否则去重会永久累积。
    func testRestartingTheHelperYieldsADifferentSessionId() {
        XCTAssertNotEqual(HistoryContextSource().sessionID,
                          HistoryContextSource().sessionID)
    }

    /// ★★ `session_id` 绝不能是 request id。
    ///
    /// 两个语义不同：request id 是**每次调用**的 owner（`MCPOwner` 拿它算
    /// `SearchOwner`，§4.7）；session 是**进程生命周期**。混了的后果是
    /// `located` 去重退化成「每条都算首见」——而且**只在真机上出现**，
    /// 因为单测里一次调用就一个 session，怎么混都对。
    ///
    /// 这条断言直接拿同一个 job 的 id 去比：真出了「用 request id 当 session」
    /// 的接线，这里就红。
    func testTheSessionIdIsNeverTheRequestId() throws {
        let source = HistoryContextSource()
        let job = AuthorityJob(id: "req-42", op: .locate, arguments: [:],
                               history: source.current())
        XCTAssertNotEqual(job.history?.sessionID, job.id,
                          "session_id 不许拿 request id 顶替（§4.7 vs §6.4）")

        // 结构再补一刀：这个类型不许认识 owner / scope 那些概念。
        let text = try code(of: "Sources/FlashFindCore/MCP/HistoryContext.swift")
        for marker in ["MCPOwner", "AuthorityJob", "AuthorizationScope"] {
            XCTAssertFalse(text.contains(marker),
                           "HistoryContext.swift 不该引用「\(marker)」："
                           + "它只是标签，与判权无关（§7a）")
        }
    }

    // MARK: - ② agent_id 来自 initialize

    func testTheAgentIdComesFromTheClientInfo() {
        let source = HistoryContextSource()
        source.noteClient(name: "claude-code", version: "1.0.31")
        XCTAssertEqual(source.current().agentID, "claude-code/1.0.31")
    }

    /// 客户端不报名字 → `unknown/<启动秒>`，不许造一个看起来像客户端名的串。
    func testAClientWithoutANameIsUnknownWithALaunchStamp() {
        let source = HistoryContextSource(launchedAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(source.current().agentID, "unknown/1800000000")

        source.noteClient(name: "   ", version: nil)
        XCTAssertEqual(source.current().agentID, "unknown/1800000000",
                       "空名字要按「没取到」处理")
    }

    /// 只报名字不报版本 → 只有名字，不要拖一个空斜杠。
    func testAClientWithoutAVersionKeepsTheBareName() {
        let source = HistoryContextSource()
        source.noteClient(name: "cursor", version: "")
        XCTAssertEqual(source.current().agentID, "cursor")
    }

    // MARK: - ③ 标签不可信

    /// ★★ 判权的三个文件里都不许出现 `HistoryContext`。
    ///
    /// 扫**代码行**（剥掉整行注释）：注释里提到它是应该的，那条注释正是写
    /// 给下一个想把它接进判定的人看的。
    func testNoPermissionOrRoutingFileMentionsTheHistoryContext() throws {
        let files = ["Sources/FlashFindCore/PermissionPolicy.swift",
                     "Sources/FlashFindCore/ToolRouter.swift",
                     "Sources/FlashFindCore/MCP/AuthorizedSourceSnapshot.swift"]

        for file in files {
            let text = try code(of: file)
            XCTAssertFalse(text.isEmpty, "没读到 \(file)，这条断言会假绿")
            XCTAssertFalse(text.contains("HistoryContext"),
                           "\(file) 里出现了 HistoryContext——"
                           + "它是不可信标签，绝不能进权限判定（§7a）")
        }
    }

    /// 超长标签在解码时就裁掉：不可信输入不许原样进库。
    func testLongLabelsAreClampedBeforeTheyReachTheStore() throws {
        let long = String(repeating: "A", count: 10_000)
        let line = Data(
            (#"{"v":1,"id":"req-1","op":"locate","args":{},"context":{"session_id":""# + long +
             #"","agent_id":"x"}}"#).utf8)

        let context = try XCTUnwrap(AuthorityWire.decodeRequest(line).context)
        XCTAssertEqual(context.sessionID.count, HistoryContext.maxLabelLength,
                       "不可信标签必须有界（§7a）")
        XCTAssertEqual(context.agentID, "x")
    }

    /// 换行 / NUL / 制表符一律去掉——它们会破坏 jsonl 诊断行的结构。
    func testLabelsNeverCarryControlCharacters() {
        let dirty = HistoryContext(sessionID: "abc\ndef\u{0000}ghi", agentID: "x\r\ty")
        let clean = dirty.clamped

        XCTAssertFalse(clean.sessionID.unicodeScalars.contains
                        { CharacterSet.controlCharacters.contains($0) },
                       "标签不许带控制字符：\(clean.sessionID.unicodeScalars.map { $0 })")
        XCTAssertFalse(clean.agentID.unicodeScalars.contains
                        { CharacterSet.controlCharacters.contains($0) })
        XCTAssertEqual(clean.sessionID, "abc def ghi")
        XCTAssertEqual(clean.agentID, "x y")
    }

    /// 全空白 → `unknown`。降级而不是报错。
    func testALabelOfOnlyNoiseFallsBackToUnknown() throws {
        let line = Data(
            #"{"v":1,"id":"req-1","op":"locate","args":{},"context":{"session_id":" \n\t","agent_id":"z"}}"#
                .utf8)
        let context = try XCTUnwrap(AuthorityWire.decodeRequest(line).context)
        XCTAssertEqual(context.sessionID, "unknown")
    }

    // MARK: - ③ 标签的键闭集

    /// `context` 里只有 `session_id` 与 `agent_id` 两个键。
    ///
    /// ★ 为什么把「History 不存 query / 绝对路径 / 凭据」写成键闭集断言：
    ///   想多存一个字段就得先改 CodingKeys，而改它会让这条用例红——
    ///   「顺手多带一个」这条路被堵在类型层。
    func testTheContextCarriesExactlyTwoKeys() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/HistoryContext.swift")

        guard let block = text.range(of: "enum CodingKeys: String, CodingKey {") else {
            return XCTFail("HistoryContext 里找不到 CodingKeys，这条断言会假绿")
        }
        let rest = text[block.upperBound...]
        guard let closing = rest.firstIndex(of: "}") else {
            return XCTFail("CodingKeys 没有闭合，这条断言会假绿")
        }
        let body = String(rest[rest.startIndex..<closing])
        let keys = body.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.hasPrefix("case ") }

        XCTAssertEqual(Set(keys), ["case sessionID = \"session_id\"",
                                   "case agentID = \"agent_id\""],
                       "context 的键闭集变了：\(keys)")
    }

    /// History 用的标签里不许出现路径 / 查询词 / 凭据那类名字。
    ///
    /// ★ 与上面那条互为补充：一条守「有哪些键」，一条守「不许出现什么名字」。
    func testTheContextTypeMentionsNoPathQueryOrCredential() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/HistoryContext.swift")
        for marker in ["absolutePath", "query", "prompt", "password", "Keychain", "Credential"] {
            XCTAssertFalse(text.contains(marker),
                           "HistoryContext.swift 里出现了「\(marker)」——"
                           + "History 只存 source_id + 相对路径 + 标签（§6.3）")
        }
    }

    // MARK: - ④ 行为：标签换了，判定不变

    /// 同一个请求、只换标签 → 路由结果与判定结果逐字相同。
    ///
    /// ★ 这是 ④ 唯一能写成行为断言的形式：不变量不是「标签被忽略」，
    ///   而是「标签不参与」。伪造标签（含超长、带换行）如果溜进了判定，
    ///   这条会红。
    @MainActor
    func testDifferentLabelsDoNotChangeTheAnswer() async throws {
        let settings = AIAccessSettings(isEnabled: true, allowedSources: [work])
        let provider = Fake(id: work)

        func answer(label: HistoryContext?) async -> ToolOutcome {
            let service = RoutingAuthorityService(
                settings: { settings },
                sources: {
                    let scheduler = await SearchScheduler(providers: [provider])
                    return [AuthoritySource(id: self.work, name: "Work NAS",
                                            execution: SourceExecutionHandle(
                                                provider: provider, scheduler: scheduler))]
                },
                referenceStore: nil)
            return await service.handle(AuthorityJob(id: "req-1", op: .locate,
                                                     arguments: ["query": .string("预算")],
                                                     history: label))
        }

        let plain = await answer(label: nil)
        let honest = await answer(label: HistoryContext(sessionID: "sess-A", agentID: "claude-code/1.0.31"))
        let forged = await answer(label: HistoryContext(
            sessionID: String(repeating: "x", count: 5_000),
            agentID: "admin\n\u{0000}root"))

        XCTAssertEqual(plain, honest, "换个诚实标签不该有任何差别")
        XCTAssertEqual(plain, forged, "伪造标签也绝不能改变判定结果（§7a）")
    }

    // MARK: - 小工具

    /// 取某个源码文件的**代码行**。
    ///
    /// ★ 必须先剥掉整行注释：注释里提到被禁的词是正常的（那些注释就是写给
    /// 下一个想踩坑的人看的），不剥就会一直误报。
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
}
