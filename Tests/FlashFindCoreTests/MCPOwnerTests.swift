import XCTest
@testable import FlashFindCore

/// Phase 6.3a 契约二：**一次 wire 请求 = 一个 `SearchOwner`**（方案 §4.7）。
///
/// ## 为什么必须在第一次真正调用 `SearchScheduler` 之前定下来
///
/// `SearchScheduler` 已经是冻结件（`.ui` / `.mcp(sessionID:)` 两类 owner，跨 owner
/// 永不互相取消）。真正接 `locate` 时唯一没定的就是：**收到一条 socket 报文，
/// 它对应哪个 owner？** 这个映射一旦随手写成「用 pid」或「用 clientInfo.name」，
/// 后面所有「Agent A 的搜索被 Agent B 取消」的怪事都从这里长出来。
///
/// 选 `authorityRequest.id` 的三个理由：
///
/// 1. **稳定**：`UnixSocketAuthorityLink` 每条请求现生成一个 UUID，不依赖进程
///    是否重启、客户端自报什么名字；
/// 2. **天然隔离**：Claude 的 `locate A`、Codex 的 `locate B`、GUI 的一次搜索
///    是三个 owner，互不取消；
/// 3. **`locate_many` 自动正确**：一次报文展开的 N 条子查询共用同一个 id，
///    即同一个 owner，配合 `supersedePrevious = false` 就不会自己吃掉自己。
///
/// ★ 它**不是**身份，也不是安全边界：谁都可能连 socket（同 UID）。这里只解决
/// 「谁的搜索会被谁取消」，不解决「谁被允许搜哪里」——那是 `PermissionPolicy` 的事。
final class MCPOwnerTests: XCTestCase {

    // MARK: - 1. 一次请求一个 owner

    func testEachWireRequestBecomesItsOwnOwner() {
        let a = MCPOwner.owner(requestID: "9F1E6C1A-0000-4000-8000-000000000001")
        let b = MCPOwner.owner(requestID: "9F1E6C1A-0000-4000-8000-000000000002")

        XCTAssertNotEqual(a, b, "两条请求变成同一个 owner 就会互相取消")
        if case .mcp(let sessionID) = a {
            XCTAssertEqual(sessionID, "9F1E6C1A-0000-4000-8000-000000000001",
                           "能原样保留就原样保留：诊断时 `mcp:<id>` 要能和日志对得上")
        } else {
            XCTFail("请求必须映射成 .mcp，不能是 .ui")
        }
    }

    /// `locate_many` 的 N 条子查询必须落在同一个 owner 上——
    /// 否则「一次调用展开 5 条」会变成 5 个 owner，`cancelAll` 也收不回来。
    func testOneWireRequestIsOneOwnerAcrossItsSubQueries() {
        let requestID = "8C0A0B7E-1111-4000-8000-00000000ABCD"
        let owners = (0..<5).map { _ in MCPOwner.owner(requestID: requestID) }
        XCTAssertEqual(Set(owners).count, 1, "同一条请求的子查询必须同 owner")
    }

    /// MCP 的 owner 永远不是 `.ui`：否则 Agent 的搜索会按「GUI 最新输入优先」
    /// 的规则被取代，或者反过来取代用户正在看的搜索。
    func testTheMCPOwnerIsNeverTheUIOwner() {
        let owner = MCPOwner.owner(requestID: "abc")
        XCTAssertFalse(owner.isUserInteractive, "MCP owner 不许是 .ui")
        XCTAssertEqual(SearchOwner.ui.isUserInteractive, true)
    }

    func testTheOwnerLabelIsDiagnosticAndPrefixed() {
        XCTAssertEqual(MCPOwner.owner(requestID: "req-1").label, "mcp:req-1")
        XCTAssertEqual(SearchOwner.ui.label, "ui")
    }

    // MARK: - 2. 不可信的 id 必须被夹住

    /// `id` 来自报文（任何同 UID 进程都能发），长度与字符集都不受我们控制。
    /// 它会被当成 `Dictionary` 键、被写进诊断标签——所以必须先夹一遍。
    ///
    /// ★ 上限是 `maxDigestSessionIDBytes`（`h:` + 64），不是 `maxSessionIDBytes`：
    /// 后者是「原样保留的用户 id」的上限，摘要形态是我们自己定长的派生串。
    func testAnOverlongOrHostileIDIsBounded() {
        let hostile = String(repeating: "A", count: 4_000)
        let sessionID = MCPOwner.sessionID(for: hostile)

        XCTAssertLessThanOrEqual(sessionID.utf8.count, MCPOwner.maxDigestSessionIDBytes,
                                 "超长 id 直接把调度器的键和日志撑爆")
        XCTAssertFalse(sessionID.contains("A"), "不可用的 id 不该原样出现在标签里")

        let withNewline = MCPOwner.sessionID(for: "req\n1")
        XCTAssertFalse(withNewline.contains("\n"), "控制字符能伪造日志行")
        XCTAssertLessThanOrEqual(withNewline.utf8.count, MCPOwner.maxDigestSessionIDBytes)
    }

    /// 摘要形态是 **`h:` + 完整 SHA-256**，不是截断。
    ///
    /// 期望值用 python `hashlib` 独立算出（不是拿实现生成 golden 再拿 golden 断言实现）：
    ///
    /// ```text
    /// python3 -c 'import hashlib;print(hashlib.sha256(("A"*200).encode()).hexdigest())'
    /// ```
    ///
    /// ★ 改短它（128 bit、或任何截断）会让这条红——这正是本轮复审要求的方向：
    /// 内部 sessionID 多 32 个字符没有成本，而「128 bit 够不够」会变成一段
    /// 需要永久解释的话。
    func testTheDigestIsTheFullSHA256() {
        let long = MCPOwner.sessionID(for: String(repeating: "A", count: 200))
        XCTAssertEqual(long,
                       "h:70d3bf8b0b9d83a61012f35fbf460c4207063fe31b4d6178390fe3b721cc03f7")
        XCTAssertEqual(MCPOwner.sessionID(for: "req\n1"),
                       "h:f2c58ac68d6256230da9600a114cfae2f0d540c32088f29830c31f0ea2324d9f")
    }

    /// 夹住之后，两个不同的坏 id **仍然得到两个不同的 owner**。
    ///
    /// ★ 措辞（本轮复审纠正）：这条用例证明的是「不同的坏 id 在这一组样本上不撞」，
    /// 而**不是**「永不碰撞」——任何有限长度的摘要都存在碰撞，SHA-256 也只是概率极低。
    /// 契约准确的写法是：不可信 id 使用完整 SHA-256 派生的**稳定、抗碰撞** session id。
    /// 别把这条用例的意图写成「一一对应」，那是实现保证不了的命题。
    func testTwoDifferentHostileIDsStayDistinct() {
        let a = MCPOwner.owner(requestID: String(repeating: "A", count: 200))
        let b = MCPOwner.owner(requestID: String(repeating: "B", count: 200))
        let c = MCPOwner.owner(requestID: String(repeating: "A", count: 201))
        XCTAssertNotEqual(a, b)
        XCTAssertNotEqual(a, c)
    }

    func testAnEmptyIDStillProducesAUsableOwner() {
        let owner = MCPOwner.owner(requestID: "")
        guard case .mcp(let sessionID) = owner else { return XCTFail("必须是 .mcp") }
        XCTAssertFalse(sessionID.isEmpty, "空 sessionID 会让所有空 id 的请求共用一个 owner")
    }

    // MARK: - 3. 只由请求 id 决定

    /// 结构：映射里不许出现客户端自报身份或进程信息。
    ///
    /// 这是 reviewer 明确要求的一条：`clientInfo.name` / `pid` / 进程名都不是稳定身份，
    /// 把它们混进来会让「同一个 Agent 换个连接就换 owner」。
    func testTheMappingUsesNothingButTheRequestID() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/MCPOwner.swift")
        XCTAssertTrue(text.contains("requestID"), "没读到映射文件，这条断言会假绿")
        for marker in ["clientInfo", "clientName", "processIdentifier", "pid", "argv", "NSUserName"] {
            XCTAssertFalse(text.contains(marker), "映射里出现了 `\(marker)`：身份来源必须只有请求 id")
        }
    }

    // MARK: - 4. `AuthorityJob` 必须带着 id 过河

    /// 报文层把 id 交给业务层。没有这一步，App 侧根本拿不到 owner 的依据。
    func testTheAuthorityJobCarriesTheRequestID() {
        let job = AuthorityJob(id: "req-42", op: .locate, arguments: [:])
        XCTAssertEqual(job.id, "req-42")
        XCTAssertEqual(job.owner, MCPOwner.owner(requestID: "req-42"),
                       "AuthorityJob.owner 必须等于映射结果——两处各算一遍就会出现第二种算法")
    }

    /// 结构：`AuthorityJob` 的 owner **不是**另存一个字段，而是从 id 算出来的。
    /// 存字段等于允许「id 与 owner 不一致」，而它俩本来就该是同一个事实。
    func testTheOwnerIsDerivedNotStored() throws {
        let text = try code(of: "Sources/FlashFindCore/MCP/AuthorityService.swift")
        XCTAssertTrue(text.contains("var owner: SearchOwner"), "owner 应当是计算属性")
        XCTAssertFalse(text.contains("let owner: SearchOwner"), "owner 不许被存成字段")
    }

    // MARK: - 小工具

    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func code(of relativePath: String) throws -> String {
        let url = clientRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }
}
