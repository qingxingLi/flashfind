import XCTest
@testable import FlashFindCore

/// 线上报文（`AuthorityWire`）的契约（Phase 6.1 起，6.2 按 B 方案重写）。
///
/// 这一层最容易出的错不是「算错了」，是「同一个概念有两种叫法」：
/// Agent 传 `source_ids`、权威端读 `sources`，两边各自的测试都能绿。
///
/// ★ 6.2 之后这里只搬不解释：线上参数表就是 `ToolArguments` 的镜像，
/// 没有第二份「参数名叫什么」的常量表。所以核心断言变成了**往返属性**——
/// 「SDK → ToolArgument → 线上 → ToolArgument」必须与「SDK → ToolArgument」逐项相等。
final class AuthorityWireTests: XCTestCase {

    // MARK: - op 名

    /// 线上 op 就是 Tool 名。**第二份名字表**是这类代码最常见的腐烂点。
    func testOperationIsTheToolName() {
        for schema in ToolCatalog.all {
            let wire = AuthorityWire.request(tool: schema.name, arguments: ToolArguments())
            XCTAssertEqual(wire.op, schema.name)
            XCTAssertEqual(wire.operation?.rawValue, schema.name,
                           "\(schema.name) 的 op 在 Operation 里找不到同名项")
        }
    }

    /// `ping` 只走 socket，**不能**变成第七个 Tool。
    ///
    /// 它一旦被列进 `ToolCatalog`，Agent 就会以为有个叫 ping 的搜索工具，
    /// 而它的返回值（`pong`）对 Agent 没有任何用处。
    func testPingIsNotATool() {
        XCTAssertFalse(ToolCatalog.all.contains { $0.name == AuthorityWire.Operation.ping.rawValue },
                       "ping 是传输层探活，不是 Tool")
        XCTAssertEqual(ToolCatalog.all.count, 6)
    }

    // MARK: - 参数：往返属性

    /// ★ 这条是 B 方案的**结构性护栏**。
    ///
    /// 按 B，参数要在助手编一次（`ToolArgument` → 线上）App 解一次（线上 → `ToolArgument`）。
    /// 两次映射各写一份，规则不一致时**两边各自的单测都会绿**——只有往返能抓住
    /// （v0.12 那个「同一事实写两遍」的老病，换了个位置）。
    ///
    /// 八种 JSON 形态逐个走一遍，与「直接映射」的结果逐项比。
    func testArgumentMappingSurvivesTheWireRoundTrip() {
        let cases: [(title: String, argument: ToolArgument, expected: ToolArgument)] = [
            ("字符串", .string("年度报告"), .string("年度报告")),
            ("空串", .string(""), .string("")),
            ("整数", .integer(7), .integer(7)),
            ("负数", .integer(-3), .integer(-3)),
            ("字符串数组", .stringArray(["a", "b"]), .stringArray(["a", "b"])),
            ("空数组", .stringArray([]), .stringArray([])),
            // 以下四种在线上都落成 `null`，但解回来必须仍是 `.unsupported`：
            // 只要有一个变成「没传」，`source_ids: null` 就会放宽搜索范围。
            ("bool", .unsupported, .unsupported),
            ("小数", .unsupported, .unsupported),
            ("null", .unsupported, .unsupported),
            ("对象", .unsupported, .unsupported),
            ("混合数组", .unsupported, .unsupported),
        ]

        for item in cases {
            let wire = AuthorityWire.arguments(from: ["p": item.argument])
            let back = AuthorityWire.toolArguments(from: wire)
            XCTAssertEqual(back["p"], item.expected, "\(item.title)：往返之后变了")
        }
    }

    /// 键名**一个都不许改**：助手不认识参数，只搬。
    func testArgumentKeysPassThroughUnchanged() {
        let arguments = ToolArguments(["query": .string("q"),
                                       "per_query_limit": .integer(3),
                                       "modified_after": .string("2026-10-01T00:00:00+08:00"),
                                       "source_ids": .stringArray(["src_a"]),
                                       "未在 schema 里出现过的键": .integer(1)])
        let wire = AuthorityWire.request(tool: "locate", arguments: arguments, id: "r1")

        XCTAssertEqual(Set(wire.args.keys), Set(arguments.values.keys),
                       "线上键必须与入参键完全一致（改名是「同一事实写两遍」的开端）")
        XCTAssertEqual(AuthorityWire.toolArguments(from: wire.args), arguments)
    }

    /// 每个 Tool 的参数长什么样，线上就长什么样：不存在「某个参数特别处理」。
    func testEveryToolArgumentShapeRoundTrips() {
        for schema in ToolCatalog.all {
            var arguments: [String: ToolArgument] = [:]
            for parameter in schema.parameters {
                switch parameter.kind {
                case .string:      arguments[parameter.name] = .string("x")
                case .integer:     arguments[parameter.name] = .integer(2)
                case .stringArray: arguments[parameter.name] = .stringArray(["src_a"])
                }
            }
            let wire = AuthorityWire.request(tool: schema.name, arguments: ToolArguments(arguments))
            XCTAssertEqual(AuthorityWire.toolArguments(from: wire.args), ToolArguments(arguments),
                           "\(schema.name) 的参数过一趟线就变形了")
            XCTAssertEqual(Set(wire.args.keys), Set(arguments.keys),
                           "\(schema.name) 的线上键与 schema 参数不一致")
        }
    }

    /// `source_ids` 在线上是**请求**，不是授权。
    ///
    /// ★ 这条与 6.1 的 `testEveryRequestCarriesItsAuthorizedSources` 正好相反：
    /// 那时候它由 Router 追加、代表「判过了」；现在它只可能来自 Agent 自己，
    /// App 收到后仍要走一遍判定。
    func testSourceIDsOnTheWireIsTheAgentsRequestNotAnAuthorization() throws {
        let wire = AuthorityWire.request(tool: "locate",
                                         arguments: ToolArguments(["query": .string("q"),
                                                                   "source_ids": .stringArray(["src_a"])]))
        XCTAssertEqual(wire.args["source_ids"], .array([.string("src_a")]),
                       "Agent 点名的来源必须原样到达权威端")

        // 没点名时**不能**被补上一个：补 = 助手替 App 生成授权范围。
        let plain = AuthorityWire.request(tool: "locate", arguments: ToolArguments(["query": .string("q")]))
        XCTAssertNil(plain.args["source_ids"])
    }

    // MARK: - 值的编解码

    func testValueRoundTripsEveryJSONShape() throws {
        let values: [AuthorityWire.Value] = [
            .string("中文 / 带斜杠 / \"引号\""),
            .int(-3),
            .double(1.5),
            .bool(true),
            .null,
            .array([.string("a"), .int(2)]),
            .object(["k": .array([.bool(false)]), "n": .null]),
        ]
        for value in values {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(AuthorityWire.Value.self, from: data)
            XCTAssertEqual(decoded, value)
        }
    }

    /// 整数不能被解成 `Double`：`limit: 5` 变成 `5.0` 之后，
    /// 权威端拿它去比 `5` 会得到「不相等」，于是把请求当成超限。
    func testIntegersStayIntegers() throws {
        let decoded = try JSONDecoder().decode(AuthorityWire.Value.self, from: Data("5".utf8))
        XCTAssertEqual(decoded, .int(5))
    }

    func testRequestAndResponseRoundTrip() throws {
        let request = AuthorityWire.request(tool: "search",
                                            arguments: ToolArguments(["query": .string("q"),
                                                                      "limit": .integer(10)]),
                                            id: "req-1")
        let decoded = try AuthorityWire.decodeRequest(try AuthorityWire.line(request))
        XCTAssertEqual(decoded.id, "req-1")
        XCTAssertEqual(decoded.op, "search")
        XCTAssertEqual(decoded.args["query"], .string("q"))
        XCTAssertEqual(decoded.args["limit"], .int(10))

        let response = AuthorityWire.Response(id: "req-1", ok: false,
                                              error: .init(code: "auth_required", message: "m"))
        let decodedResponse = try AuthorityWire.decodeResponse(try AuthorityWire.line(response))
        XCTAssertEqual(decodedResponse.error?.code, "auth_required")
        XCTAssertNil(decodedResponse.result)
    }

    /// `pong` 里**只有活着**这一个事实。
    ///
    /// 这条报文任何同 UID 进程都能发；多一个字段（版本号、路径、来源数量）
    /// 就是多一次泄露机会。
    func testPongCarriesNothingButLiveness() {
        let response = AuthorityWire.pong(id: "p")
        guard case .object(let fields)? = response.result else {
            return XCTFail("pong 的结果不是对象：\(String(describing: response.result))")
        }
        XCTAssertEqual(Set(fields.keys), ["pong"])
        XCTAssertTrue(AuthorityWire.isPong(response))
        XCTAssertFalse(AuthorityWire.isPong(AuthorityWire.Response(id: "p", ok: true)))
    }

    /// `ok: true` 但没有正文的执行端违约必须能被识别出来（否则会变成「空结果」）。
    func testMissingResultIsNotASuccess() {
        let outcome = UnixSocketAuthorityLink.outcome(.success(AuthorityWire.Response(id: "x", ok: true)))
        guard case .failure(let code, _) = outcome else {
            return XCTFail("没有正文却算成功了：\(outcome)")
        }
        XCTAssertEqual(code, "internal_error")
    }

    /// 执行端的错误码原样转发：传输层不许改码（§4.2 的语义在改码那一刻就没了）。
    func testAuthorityFailureCodeIsForwardedVerbatim() {
        let response = AuthorityWire.Response(id: "x", ok: false,
                                              error: .init(code: "source_unavailable", message: "m"))
        XCTAssertEqual(UnixSocketAuthorityLink.outcome(.success(response)),
                       .failure(code: "source_unavailable", message: "m"))
    }

    // MARK: - 路径

    /// App 与 Helper 必须算出同一个路径。
    func testStandardPathIsUnderApplicationSupport() {
        let home = URL(fileURLWithPath: "/Users/someone")
        XCTAssertEqual(AuthoritySocketPath.standard(home: home),
                       "/Users/someone/Library/Application Support/FlashFind2/ipc/mcp.sock")
        XCTAssertEqual(AuthoritySocketPath.directory(of: "/tmp/a/mcp.sock"), "/tmp/a")
    }
}
