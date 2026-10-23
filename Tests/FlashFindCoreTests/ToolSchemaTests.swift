import XCTest
@testable import FlashFindCore

/// Phase 5.2：ToolSchema 的契约测试（方案 §4.1 / §4.3 / §4.3.1）。
///
/// **先写测试再写实现**：这一层是 Agent 唯一能看见的东西，写错不会有编译错误，
/// 只会在真实对话里表现为「Agent 传错参数」「Agent 根本不用这个工具」。
///
/// 这批用例守四类事实：
///
/// 1. **工具集合是闭集**：六个、不多不少。多一个等于给 Agent 多一条它不会用的路；
///    少一个等于某个卖点没有入口。
/// 2. **每个 Tool 的 limit 上限各是各的**（`locate` 20 / `search` 50 / `recent` 20 /
///    `locate_many` 5）。统一成一个数的写法看起来很整齐，但会把宽口径 `search` 压成
///    和 `locate` 一样窄，或者让 `locate_many` 一次返回 50×5 条。
/// 3. **输入里不许出现路径**：身份一律走 `file_id`（路径穿越与「Agent 猜路径」都不可控）。
/// 4. **Schema 文案是英文且非空**：它会原样进 Agent 上下文，中英混排会降低工具调用准确率。
final class ToolSchemaTests: XCTestCase {

    // MARK: - 1. 工具集合

    /// 六个 Tool，名字与顺序都必须稳定（`tools/list` 的顺序会进客户端缓存与 benchmark 记录）。
    func testCatalogIsExactlyTheSixApprovedTools() {
        XCTAssertEqual(ToolCatalog.all.map(\.name),
                       ["list_sources", "locate", "locate_many", "search", "get_metadata", "recent"])
        XCTAssertEqual(Set(ToolCatalog.all.map(\.name)).count, 6, "有重名")
    }

    /// 只读工具：1.1.2 不做任何写/删/改/打开/读内容。
    ///
    /// 这条用「名字里不许出现这些动词」守住，比写一句注释强：以后有人想加
    /// `open_file` / `read_document`，会先撞上这条用例，必须走评审。
    func testNoMutatingOrReadingToolsInThisVersion() {
        let forbidden = ["write", "delete", "remove", "move", "rename", "open", "reveal", "read"]
        for tool in ToolCatalog.all {
            for word in forbidden {
                XCTAssertFalse(tool.name.lowercased().contains(word),
                               "1.1.2 不该出现 \(tool.name)（含 \(word)）")
            }
        }
    }

    func testEveryToolHasAnEnglishNonEmptySummary() {
        for tool in ToolCatalog.all {
            XCTAssertFalse(tool.summary.isEmpty, "\(tool.name) 没有描述，Agent 不会知道什么时候用它")
            XCTAssertGreaterThan(tool.summary.count, 30, "\(tool.name) 的描述太短，无法区分它与相邻工具")
            let isASCII = tool.summary.unicodeScalars.allSatisfy { $0.isASCII }
            XCTAssertTrue(isASCII, "\(tool.name) 的 description 混进了非 ASCII 字符：它会进 Agent 上下文")
        }
    }

    // MARK: - 2. 参数形状

    func testListSourcesTakesNoParameters() {
        let schema = try! XCTUnwrap(ToolCatalog.schema(named: "list_sources"))
        XCTAssertTrue(schema.parameters.isEmpty,
                      "list_sources 不吃参数：它的语义是「我可以用哪些来源」，不是「筛来源」")
    }

    func testLocateParameterShape() {
        let schema = try! XCTUnwrap(ToolCatalog.schema(named: "locate"))
        XCTAssertEqual(schema.parameters.map(\.name), ["query", "source_ids", "kind", "modified_after", "limit"])
        XCTAssertEqual(schema.requiredNames, ["query"])

        let kind = try! XCTUnwrap(schema.parameter(named: "kind"))
        XCTAssertEqual(kind.allowedValues, ["file", "folder"], "kind 在 1.1.2 只有这两种取值")

        let limit = try! XCTUnwrap(schema.parameter(named: "limit"))
        XCTAssertFalse(limit.isRequired)
        XCTAssertEqual(limit.defaultValue, .integer(5))
        XCTAssertEqual(limit.maximum, 20)
    }

    func testLocateManyParameterShape() {
        let schema = try! XCTUnwrap(ToolCatalog.schema(named: "locate_many"))
        XCTAssertEqual(schema.parameters.map(\.name), ["queries", "per_query_limit", "source_ids"])
        XCTAssertEqual(schema.requiredNames, ["queries"])

        let queries = try! XCTUnwrap(schema.parameter(named: "queries"))
        XCTAssertEqual(queries.kind, .stringArray)
        XCTAssertEqual(queries.minItems, 1)
        XCTAssertEqual(queries.maxItems, 5, "一次最多 5 个查询：再多应该由 Agent 拆成两次调用")

        let perQuery = try! XCTUnwrap(schema.parameter(named: "per_query_limit"))
        XCTAssertEqual(perQuery.defaultValue, .integer(3))
        XCTAssertEqual(perQuery.maximum, 5)
    }

    func testSearchIsWiderThanLocate() {
        let search = try! XCTUnwrap(ToolCatalog.schema(named: "search"))
        let locate = try! XCTUnwrap(ToolCatalog.schema(named: "locate"))
        let searchLimit = try! XCTUnwrap(search.parameter(named: "limit"))
        let locateLimit = try! XCTUnwrap(locate.parameter(named: "limit"))

        XCTAssertEqual(searchLimit.defaultValue, .integer(10))
        XCTAssertEqual(searchLimit.maximum, 50)
        XCTAssertGreaterThan(searchLimit.maximum!, locateLimit.maximum!,
                             "search 是宽口径：上限必须大于 locate，否则两个工具没有区别")
    }

    func testRecentParameterShape() {
        let schema = try! XCTUnwrap(ToolCatalog.schema(named: "recent"))
        XCTAssertEqual(schema.parameters.map(\.name), ["limit", "source_ids", "within_days"])
        XCTAssertTrue(schema.requiredNames.isEmpty)

        let withinDays = try! XCTUnwrap(schema.parameter(named: "within_days"))
        XCTAssertEqual(withinDays.kind, .integer)
        XCTAssertEqual(withinDays.minimum, 1, "0 天没有意义，应判 invalid 而不是「搜今天」")
    }

    func testGetMetadataTakesFileIDOnly() {
        let schema = try! XCTUnwrap(ToolCatalog.schema(named: "get_metadata"))
        XCTAssertEqual(schema.parameters.map(\.name), ["file_id"])
        XCTAssertEqual(schema.requiredNames, ["file_id"])
    }

    /// §4.1 硬规则：**任何 Tool 都不接受路径作为输入**。
    ///
    /// 遍历而不是只查一个：漏掉的那个可能正好是以后新加的 Tool。
    func testNoToolAcceptsAPathAsInput() {
        for tool in ToolCatalog.all {
            for parameter in tool.parameters {
                let name = parameter.name.lowercased()
                XCTAssertFalse(name.contains("path") || name.contains("filepath") || name.contains("directory"),
                               "\(tool.name) 接受路径参数 \(parameter.name)：身份必须走 file_id")
            }
        }
    }

    func testParameterNamesAreUniqueWithinEachTool() {
        for tool in ToolCatalog.all {
            let names = tool.parameters.map(\.name)
            XCTAssertEqual(names.count, Set(names).count, "\(tool.name) 的参数重名")
        }
    }

    // MARK: - 3. limit 钳位（Router 会用同一套）

    /// 四个 Tool 的上限**各是各的**。这条按 Tool 逐个断言，不接受「随便挑一个测」。
    func testEachToolClampsToItsOwnMaximum() {
        XCTAssertEqual(LimitRange.forTool("locate")?.maximum, 20)
        XCTAssertEqual(LimitRange.forTool("search")?.maximum, 50)
        XCTAssertEqual(LimitRange.forTool("recent")?.maximum, 20)
        XCTAssertEqual(LimitRange.forTool("locate_many")?.maximum, 5)
        XCTAssertNil(LimitRange.forTool("list_sources"), "无 limit 的工具不该有一个「顺手给」的默认上限")
        XCTAssertNil(LimitRange.forTool("get_metadata"))
    }

    func testLimitDefaultsWhenOmitted() {
        let range = try! XCTUnwrap(LimitRange.forTool("locate"))
        XCTAssertEqual(range.apply(nil), .applied(.init(applied: 5, wasClamped: false)))
    }

    func testLimitClampsAndReportsTruncation() {
        let range = try! XCTUnwrap(LimitRange.forTool("locate"))
        XCTAssertEqual(range.apply(3), .applied(.init(applied: 3, wasClamped: false)))
        XCTAssertEqual(range.apply(20), .applied(.init(applied: 20, wasClamped: false)))
        XCTAssertEqual(range.apply(1000), .applied(.init(applied: 20, wasClamped: true)),
                       "超上限要钳位并告诉 Agent 被截断了，不能静默返回 20 条当没事")
    }

    /// `limit <= 0` 是**参数错误**，不是「用默认值」。
    ///
    /// 静默改成默认值会让 Agent 永远不知道自己的参数写错了，也会让 benchmark 里
    /// 「Agent 传错参数」这一类失败被掩盖成「顺利返回 5 条」。
    func testNonPositiveLimitIsInvalidNotDefaulted() {
        let range = try! XCTUnwrap(LimitRange.forTool("search"))
        XCTAssertEqual(range.apply(0), .invalid)
        XCTAssertEqual(range.apply(-1), .invalid)
    }

    // MARK: - 4. 查找

    func testUnknownToolHasNoSchema() {
        XCTAssertNil(ToolCatalog.schema(named: "open_file"))
        XCTAssertNil(ToolCatalog.schema(named: ""))
        XCTAssertNil(ToolCatalog.schema(named: "LOCATE"), "工具名大小写敏感，不做模糊匹配")
    }

    /// 每个 Tool 都能被自己的名字找到（防止 `all` 与查找表两处各写一份、慢慢漂移）。
    func testLookupFindsEveryToolInTheCatalog() {
        for tool in ToolCatalog.all {
            XCTAssertEqual(ToolCatalog.schema(named: tool.name), tool)
        }
    }
}
