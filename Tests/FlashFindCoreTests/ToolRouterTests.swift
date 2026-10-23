import XCTest
@testable import FlashFindCore

/// Phase 5.3 验收：`ToolRouter`（方案 §4.2 / §4.3 / §5.1 / §14.3.3）。
///
/// 这一层只做四件事，用例也按这四件事分组：
///
/// ```text
/// Tool 名  → 找到 schema（未知工具 → unknown_tool）
/// 参数     → 类型 / 必填 / 枚举 / 空串 / 未知参数
/// limit    → 交给 LimitRange（Router 里不许出现第二个上限数字）
/// 来源     → 交给 PermissionPolicy（Router 里不许出现 allowedSources.contains）
/// ```
///
/// 输出是**纯 Core 类型** `AuthorityRequest`，不是 MCP SDK 类型——
/// 所以这一层能在工具链还解析不了 SDK 的时候写完、测完（§14.3.3）。
///
/// ★ 三条最容易写错的语义，每条都有专门用例：
/// 1. `source_ids` **没传** 与 **传了空数组** 必须分开：前者搜 allowlist，后者是拒绝。
///    合并成一条，一次参数错误就静默变成一次范围更大的搜索。
/// 2. `source_ids: null` **不能**当成「没传」。权限参数上只许收紧，不许放宽。
/// 3. 权限判定必须在**造出 `AuthorityRequest` 之前**：所以 `AuthorizationScope`
///    只能从「放行」的判定里构造，拒绝时根本造不出请求。
final class ToolRouterTests: XCTestCase {

    // 全是编造的 id：测试不许出现真实设备名或来源名。
    private let mac = "local_mac"
    private let work = "src_nas_work"
    /// 授权过、但用户已经删掉（不在 existing 里）。
    private let gone = "src_nas_gone"
    /// 还存在、但从未被授权。
    private let finance = "src_nas_finance"

    /// 默认场景：开着，授权 [mac, work, gone]，存在 [mac, work, finance]。
    /// 于是「可用 = 授权 ∩ 存在 = [mac, work]」，另外两个 id 各自代表一类失败。
    private var facts: PermissionFacts {
        PermissionFacts(mcpEnabled: true,
                        allowedSources: [mac, work, gone],
                        existing: [mac, work, finance])
    }

    private var validFileID: String { "ff1_" + String(repeating: "a", count: 32) }

    // MARK: - 1. 未知工具

    /// 未知工具 → `unknown_tool`（不是 `invalid_argument`）。
    /// 两个码对 Agent 的动作完全不同：前者去查 `tools/list`，后者去改参数。
    func testUnknownToolIsReportedAsUnknownTool() {
        let result = ToolRouter.route(tool: "delete_file", arguments: [:], permission: facts)
        XCTAssertNil(result.request, "未知工具绝不能走到路由成功")
        XCTAssertEqual(result.failure?.code, "unknown_tool")
    }

    /// 未知工具的判定要**先于**参数校验：工具名都没有，参数对不对无从谈起。
    func testUnknownToolIsCheckedBeforeArguments() {
        let args: ToolArguments = ["query": .integer(42), "路径": .unsupported]
        XCTAssertEqual(ToolRouter.route(tool: "nope", arguments: args, permission: facts).failure?.code,
                       "unknown_tool")
    }

    /// 六个工具都能路由，且 `request.tool` 与 schema 里的名字一致。
    /// 这条同时守住 `ToolCall.toolName` 不是另一份会漂的名字副本。
    func testEveryCatalogToolRoutesAndKeepsItsName() {
        for schema in ToolCatalog.all {
            let result = ToolRouter.route(tool: schema.name,
                                          arguments: ToolArguments(minimalArguments(for: schema.name)),
                                          permission: facts)
            guard let request = result.request else {
                XCTFail("\(schema.name) 路由失败：\(String(describing: result.failure))")
                continue
            }
            XCTAssertEqual(request.tool, schema.name)
        }
    }

    // MARK: - 2. query

    func testMissingQueryIsInvalidArgument() {
        let result = ToolRouter.route(tool: "locate", arguments: [:], permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
        XCTAssertEqual(result.failure?.argumentName, "query")
    }

    /// 非 String（这里是整数）→ `invalid_argument`，**不做隐式转字符串**。
    func testNonStringQueryIsInvalidArgument() {
        let result = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .integer(2026)],
                                      permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
    }

    /// `""` / 全空白 / 制表换行都算空。空白 query 送进搜索引擎等于全量返回，
    /// 结果是「看起来成功、拿回一堆无关文件」，比报错难排查得多。
    func testBlankQueryIsInvalidArgument() {
        for blank in ["", " ", "   ", "\n", "\t \n"] {
            let result = ToolRouter.route(tool: "locate",
                                          arguments: ["query": .string(blank)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "空白 query 被放过了：\(blank.debugDescription)")
        }
    }

    func testQueryIsTrimmedBeforeRouting() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("  季度报告 \n")],
                                      permission: facts)
        guard case .search(let query, _)? = result.request?.call else {
            return XCTFail("应当路由成 search：\(String(describing: result.failure))")
        }
        XCTAssertEqual(query, "季度报告")
    }

    // MARK: - 3. limit

    func testNonIntegerLimitIsInvalidArgument() {
        let result = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告"), "limit": .string("10")],
                                      permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
        XCTAssertEqual(result.failure?.argumentName, "limit")
    }

    /// `<= 0` 是参数错误，**不静默换成默认值**（方案 §4.1）。
    func testNonPositiveLimitIsInvalidArgument() {
        for bad in [0, -1, -50] {
            let result = ToolRouter.route(tool: "locate",
                                          arguments: ["query": .string("报告"), "limit": .integer(bad)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "limit=\(bad) 被当成了默认值")
        }
    }

    /// 超上限 → 钳位到上限并回报 `wasClamped`。**上限从 schema 读**，
    /// 这条因此也是一次「Router 与 Schema 没漂」的交叉校验。
    func testLimitClampsAtSchemaMaximumAndReportsTruncation() {
        for tool in ["locate", "search", "recent"] {
            guard let schema = ToolCatalog.schema(named: tool),
                  let maximum = schema.parameter(named: "limit")?.maximum else {
                return XCTFail("\(tool) 没有 limit 上限")
            }
            let result = ToolRouter.route(tool: tool,
                                          arguments: ToolArguments(minimalArguments(for: tool)
                                                                   .merging(["limit": .integer(maximum + 1)]) { $1 }),
                                          permission: facts)
            guard result.request != nil else {
                return XCTFail("\(tool) 路由失败：\(String(describing: result.failure))")
            }
            XCTAssertEqual(limit(of: result)?.applied, maximum, "\(tool) 没钳到 schema 的上限")
            XCTAssertEqual(limit(of: result)?.wasClamped, true, "\(tool) 超上限却没报 wasClamped")
        }
    }

    /// 没传 limit → 用 `LimitRange` 里的默认值（不是 10、不是 20）。
    func testOmittedLimitUsesTheRangeDefault() {
        let locate = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告")],
                                      permission: facts)
        XCTAssertEqual(limit(of: locate),
                       LimitApplication(applied: LimitRange.locate.defaultValue, wasClamped: false))

        let many = ToolRouter.route(tool: "locate_many",
                                    arguments: ["queries": .stringArray(["a", "b"])],
                                    permission: facts)
        XCTAssertEqual(limit(of: many),
                       LimitApplication(applied: LimitRange.locateMany.defaultValue, wasClamped: false))
    }

    /// ★ 参数名从 schema 取，不写死：`locate_many` 的 limit 叫 `per_query_limit`。
    /// 这条用例证明 Router 没有「第二个参数名副本」——传 `limit` 会被当未知参数拒掉。
    func testLimitParameterNameComesFromSchema() {
        let wrong = ToolRouter.route(tool: "locate_many",
                                     arguments: ["queries": .stringArray(["a"]), "limit": .integer(2)],
                                     permission: facts)
        XCTAssertEqual(wrong.failure?.code, "invalid_argument",
                       "locate_many 接受了 limit：说明参数名被写死了")
        XCTAssertEqual(wrong.failure?.argumentName, "limit")

        let right = ToolRouter.route(tool: "locate_many",
                                     arguments: ["queries": .stringArray(["a"]), "per_query_limit": .integer(2)],
                                     permission: facts)
        guard case .locateMany(_, let perQuery)? = right.request?.call else {
            return XCTFail("per_query_limit 没被识别：\(String(describing: right.failure))")
        }
        XCTAssertEqual(perQuery.applied, 2)
    }

    /// ★ 必填**只在解析器里执行**（不在 Router 顶部再扫一遍 schema）：
    /// 所以这条按 catalog 遍历，逐个确认「schema 说必填的参数，真的有人拦」。
    /// 漏写一个解析器分支，或者以后给某个 Tool 加了必填参数却没实现校验，这里会红。
    func testEveryRequiredParameterIsActuallyEnforced() {
        for schema in ToolCatalog.all {
            let result = ToolRouter.route(tool: schema.name, arguments: [:], permission: facts)
            if schema.requiredNames.isEmpty {
                XCTAssertNotNil(result.request,
                                "\(schema.name) 没有必填参数，空调用应当成功：\(String(describing: result.failure))")
            } else {
                XCTAssertEqual(result.failure?.code, "invalid_argument",
                               "\(schema.name) 的必填参数没被拦：\(schema.requiredNames)")
                XCTAssertTrue(schema.requiredNames.contains(result.failure?.argumentName ?? ""),
                              "\(schema.name) 报错的参数 \(result.failure?.argumentName ?? "-") 不在必填列表里")
            }
        }
    }

    // MARK: - 4. kind

    func testKindAcceptsOnlyTheClosedSet() {
        for raw in ["file", "folder"] {
            let result = ToolRouter.route(tool: "locate",
                                          arguments: ["query": .string("报告"), "kind": .string(raw)],
                                          permission: facts)
            guard case .locate(_, let kind, _, _)? = result.request?.call else {
                return XCTFail("kind=\(raw) 路由失败：\(String(describing: result.failure))")
            }
            XCTAssertEqual(kind, FileKind(rawValue: raw))
        }
    }

    /// 多一个取值就等于 Agent 会传一个我们没实现的过滤条件。
    func testKindRejectsValuesOutsideTheClosedSet() {
        for bad in ["any", "pdf", "FILE", "Folder", "文件", ""] {
            let result = ToolRouter.route(tool: "locate",
                                          arguments: ["query": .string("报告"), "kind": .string(bad)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "kind=\(bad) 被放过了")
            XCTAssertEqual(result.failure?.argumentName, "kind")
        }
    }

    /// `kind` 对 Agent 暴露的取值集合是**对外契约**：1.1.2 只有 file / folder。
    /// schema 里的枚举由 `FileKind.allCases` 派生，所以这条守的是
    /// 「Agent 看到的取值」本身——给它加一个值就是改了 `tools/list` 的契约。
    func testKindExposesExactlyFileAndFolderToAgents() throws {
        let schema = try XCTUnwrap(ToolCatalog.schema(named: "locate"))
        let declared = try XCTUnwrap(schema.parameter(named: "kind")?.allowedValues)
        XCTAssertEqual(declared, ["file", "folder"])
        XCTAssertEqual(declared, FileKind.allCases.map(\.rawValue))
    }

    // MARK: - 5. source_ids：没传 / 空数组 / null 三种都不一样

    /// 没传 → 搜「授权 ∩ 存在」，即 [mac, work]。已删除的 gone 与未授权的 finance
    /// 都不许出现在结果里。
    func testOmittedSourceIDsSearchesEveryAuthorizedSource() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告")],
                                      permission: facts)
        XCTAssertEqual(result.request?.scope.sourceIDs, [mac, work])
        XCTAssertEqual(result.request?.scope.warnings, [])
    }

    /// ★ 传了空数组 = 「点了名但一个都没给」→ 拒绝，**不是**「没传」。
    func testEmptySourceIDsIsDeniedRatherThanOmitted() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告"), "source_ids": .stringArray([])],
                                      permission: facts)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.failure?.code, "source_denied")
    }

    /// ★ `null` 不许降级成「没传」：那会把一次参数错误放大成
    /// 「搜所有已授权来源」。权限参数上只许收紧。
    func testNullSourceIDsIsInvalidArgumentNotOmitted() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告"), "source_ids": .unsupported],
                                      permission: facts)
        XCTAssertNil(result.request, "null 被当成了「没传」，搜索范围被悄悄放大")
        XCTAssertEqual(result.failure?.code, "invalid_argument")
        XCTAssertEqual(result.failure?.argumentName, "source_ids")
    }

    func testSourceIDsRejectsBlankIdsAndNonStrings() {
        let blank = ToolRouter.route(tool: "search",
                                     arguments: ["query": .string("报告"), "source_ids": .stringArray([mac, "  "])],
                                     permission: facts)
        XCTAssertEqual(blank.failure?.code, "invalid_argument")

        let wrongType = ToolRouter.route(tool: "search",
                                         arguments: ["query": .string("报告"), "source_ids": .string(mac)],
                                         permission: facts)
        XCTAssertEqual(wrongType.failure?.code, "invalid_argument")
    }

    func testDuplicateSourceIDsDoNotDuplicateTheScope() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告"),
                                                   "source_ids": .stringArray([mac, mac, work])],
                                      permission: facts)
        XCTAssertEqual(result.request?.scope.sourceIDs, [mac, work])
    }

    /// 混合授权 → 部分成功：可用的照搜，不可用的降级成 warning（§4.2.1），
    /// 且 warning 里**不带来源名**。
    func testPartiallyAuthorizedRequestRoutesWithWarnings() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告"),
                                                   "source_ids": .stringArray([mac, finance])],
                                      permission: facts)
        XCTAssertEqual(result.request?.scope.sourceIDs, [mac])
        XCTAssertEqual(result.request?.scope.warnings, ["source_denied:\(finance)"])
    }

    /// 全部不可用 → 拒绝。此时一个可用来源都没有，不许造出空 scope 的请求。
    func testRequestedSourcesAllUnusableIsDenied() {
        let result = ToolRouter.route(tool: "search",
                                      arguments: ["query": .string("报告"),
                                                   "source_ids": .stringArray([finance, gone])],
                                      permission: facts)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.failure?.code, "source_denied")
    }

    // MARK: - 6. 权限前置

    /// ★ 结构上的保证：`AuthorizationScope` 只能从「放行」的判定里构造。
    /// 于是「拒绝之后还造出一个请求」这件事在类型层面就写不出来（契约 8）。
    func testDeniedDecisionCannotProduceAScope() {
        XCTAssertNil(AuthorizationScope(granting: .deny(code: .sourceDenied, message: "no")))
        XCTAssertNil(AuthorizationScope(granting: .allow(sources: [], warnings: [])),
                     "空来源的 allow 也不许造出 scope")
        XCTAssertNotNil(AuthorizationScope(granting: .allow(sources: [mac], warnings: [])))
    }

    func testMasterSwitchOffDeniesEvenWithPerfectArguments() {
        let off = PermissionFacts(mcpEnabled: false, allowedSources: [mac], existing: [mac])
        let result = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告")],
                                      permission: off)
        XCTAssertNil(result.request)
        XCTAssertEqual(result.failure?.code, "mcp_disabled")
    }

    /// 权限**每次调用重算**：同一个 Router 不缓存上一次的结论，
    /// 否则用户撤销授权后旧进程还能继续搜（§5.2）。
    func testPermissionIsRecomputedOnEveryCall() {
        let allowed = ToolRouter.route(tool: "locate",
                                       arguments: ["query": .string("报告")],
                                       permission: facts)
        XCTAssertNotNil(allowed.request)

        let revoked = PermissionFacts(mcpEnabled: true, allowedSources: [gone], existing: [mac, work])
        let denied = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告")],
                                      permission: revoked)
        XCTAssertNil(denied.request)
        XCTAssertEqual(denied.failure?.code, "mcp_disabled")
    }

    /// `list_sources` 也要过权限：AI 关着的时候连「有哪些来源」都不该回。
    func testListSourcesAlsoGoesThroughPermission() {
        let off = PermissionFacts(mcpEnabled: false, allowedSources: [mac], existing: [mac])
        XCTAssertEqual(ToolRouter.route(tool: "list_sources", arguments: [:], permission: off).failure?.code,
                       "mcp_disabled")

        let on = ToolRouter.route(tool: "list_sources", arguments: [:], permission: facts)
        XCTAssertEqual(on.request?.scope.sourceIDs, [mac, work])
        XCTAssertEqual(on.request?.tool, "list_sources")
    }

    func testListSourcesTakesNoArguments() {
        let result = ToolRouter.route(tool: "list_sources",
                                      arguments: ["limit": .integer(3)],
                                      permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
    }

    // MARK: - 7. 其它参数

    /// Agent 自己发明参数（尤其是 `path`）必须当场拒掉，
    /// 不能「忽略它然后照常搜」——那正是「猜路径」的失效点（§4.3.1）。
    func testUnknownArgumentIsRejected() {
        let result = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告"),
                                                   "path": .string("/Users/someone/secret.pdf")],
                                      permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
        XCTAssertEqual(result.failure?.argumentName, "path")
    }

    func testModifiedAfterParsesISO8601() throws {
        let result = ToolRouter.route(tool: "locate",
                                      arguments: ["query": .string("报告"),
                                                   "modified_after": .string("2026-10-01T00:00:00+08:00")],
                                      permission: facts)
        guard case .locate(_, _, let date, _)? = result.request?.call else {
            return XCTFail("modified_after 没解析：\(String(describing: result.failure))")
        }
        let utc = ISO8601DateFormatter()
        utc.timeZone = TimeZone(identifier: "UTC")
        XCTAssertEqual(utc.string(from: try XCTUnwrap(date)), "2026-09-30T16:00:00Z")
    }

    /// 解析不了就报错，**不许静默丢掉这个过滤条件**——丢掉的后果是
    /// 「按时间过滤」变成「没过滤」，返回一堆老文件而 Agent 以为筛过了。
    func testModifiedAfterRejectsGarbageAndDateOnly() {
        for bad in ["昨天", "2026-10-01", "2026/10/01 00:00", ""] {
            let result = ToolRouter.route(tool: "locate",
                                          arguments: ["query": .string("报告"),
                                                       "modified_after": .string(bad)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "modified_after=\(bad) 被放过")
        }
    }

    func testWithinDaysMustBeAPositiveInteger() {
        for bad in [0, -1] {
            let result = ToolRouter.route(tool: "recent",
                                          arguments: ["within_days": .integer(bad)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "within_days=\(bad) 被放过")
        }
        let ok = ToolRouter.route(tool: "recent",
                                  arguments: ["within_days": .integer(7)],
                                  permission: facts)
        guard case .recent(let days, _)? = ok.request?.call else {
            return XCTFail("within_days=7 路由失败：\(String(describing: ok.failure))")
        }
        XCTAssertEqual(days, 7)
    }

    /// 数组长度按 schema 的 minItems/maxItems 判（不写死 5）。
    func testQueriesRespectSchemaBounds() {
        let tooMany = ToolRouter.route(tool: "locate_many",
                                        arguments: ["queries": .stringArray(["1", "2", "3", "4", "5", "6"])],
                                        permission: facts)
        XCTAssertEqual(tooMany.failure?.code, "invalid_argument", "6 条查询被放过（schema 上限 5）")

        let empty = ToolRouter.route(tool: "locate_many",
                                      arguments: ["queries": .stringArray([])],
                                      permission: facts)
        XCTAssertEqual(empty.failure?.code, "invalid_argument", "空查询数组被放过")

        let five = ToolRouter.route(tool: "locate_many",
                                     arguments: ["queries": .stringArray(["1", "2", "3", "4", "5"])],
                                     permission: facts)
        XCTAssertNotNil(five.request)
    }

    func testQueriesRejectBlankEntries() {
        let result = ToolRouter.route(tool: "locate_many",
                                      arguments: ["queries": .stringArray(["报告", "   "])],
                                      permission: facts)
        XCTAssertEqual(result.failure?.code, "invalid_argument")
    }

    /// `file_id` 必须是**别的 Tool 返回的**那种形状。Agent 编一个 id
    /// （或直接把路径塞进来）在 Router 就被拦下，不会变成一次 `file_not_found`。
    func testFileIDShapeIsEnforced() {
        let ok = ToolRouter.route(tool: "get_metadata",
                                  arguments: ["file_id": .string(validFileID)],
                                  permission: facts)
        guard case .getMetadata(let id)? = ok.request?.call else {
            return XCTFail("合法 file_id 被拒：\(String(describing: ok.failure))")
        }
        XCTAssertEqual(id.value, validFileID, "Router 应当把 file_id 原样交给 FileID")

        let bad = ["report.pdf",
                   "/Users/someone/secret.pdf",
                   "ff1_" + String(repeating: "a", count: 31),
                   "ff1_" + String(repeating: "A", count: 32),
                   "ff1_" + String(repeating: "z", count: 32),
                   "ff2_" + String(repeating: "a", count: 32)]
        for value in bad {
            let result = ToolRouter.route(tool: "get_metadata",
                                          arguments: ["file_id": .string(value)],
                                          permission: facts)
            XCTAssertEqual(result.failure?.code, "invalid_argument", "file_id=\(value) 被放过")
        }
    }

    // MARK: - 8. 结构（这层永远不许长出来的东西）

    /// 契约 10：不 `import MCP`。工具链阻塞挡不住这一层，靠的就是这个约束。
    func testRouterDoesNotImportMCP() throws {
        let code = codeOnly(try coreSource("ToolRouter.swift"))
        XCTAssertFalse(code.contains("import MCP"), "ToolRouter 不许 import MCP")
    }

    /// 契约 9：Router 里不许有具体上限数字的第二份副本。
    /// 判据是「不自己构造 LimitRange、且确实从 forTool 取」——不是去 grep 数字
    /// （`5` 这种数字满文件都是，grep 数字只会得到噪声）。
    func testRouterHasNoSecondCopyOfLimitNumbers() throws {
        let code = codeOnly(try coreSource("ToolRouter.swift"))
        XCTAssertTrue(code.contains("LimitRange.forTool("),
                      "Router 没从 LimitRange 取上限：说明它自己抄了一份数字")
        XCTAssertFalse(code.contains("LimitRange(defaultValue:"),
                       "Router 自己构造了 LimitRange：上限又多了一份副本")
    }

    /// 契约：Router 不做授权判断，只转交 `PermissionPolicy`。
    func testRouterDoesNotDecideAuthorizationByItself() throws {
        let code = codeOnly(try coreSource("ToolRouter.swift"))
        XCTAssertTrue(code.contains("PermissionPolicy.decision("),
                      "Router 没调用 PermissionPolicy")
        XCTAssertFalse(code.contains("allowedSources.contains"),
                       "Router 自己判了授权：会与 PermissionPolicy 的六步判定分叉")
    }

    /// Contract 外的两条边界：不读偏好/文件系统/Ketchain，也不认识 JSON-RPC。
    /// `-32601` 是协议层的错误号，由 Phase 5.5 的 handler 映射（§8.1）。
    func testRouterStaysAFreeFunctionLayer() throws {
        let code = codeOnly(try coreSource("ToolRouter.swift"))
        for banned in ["UserDefaults", "FileManager", "Keychain", "ClientPreferences",
                       "JSONRPC", "jsonrpc", "-32601", "MCP"] {
            XCTAssertFalse(code.contains(banned), "ToolRouter 里出现了 \(banned)")
        }
    }

    // MARK: - 助手

    /// 路由结果里的条数（`list_sources` / `get_metadata` 没有条数，返回 nil）。
    private func limit(of result: ToolRoutingResult) -> LimitApplication? {
        result.request?.call.limit
    }

    private func minimalArguments(for tool: String) -> [String: ToolArgument] {
        switch tool {
        case "list_sources":            return [:]
        case "locate", "search":        return ["query": .string("季度报告")]
        case "locate_many":             return ["queries": .stringArray(["季度报告", "预算表"])]
        case "get_metadata":            return ["file_id": .string(validFileID)]
        case "recent":                  return [:]
        default:                        return [:]
        }
    }

    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/\(name)"),
                          encoding: .utf8)
    }

    /// 去掉 `//` 注释——注释里出现「不 import MCP」正是在说明「不许 import」。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }
}
