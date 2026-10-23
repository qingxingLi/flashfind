import XCTest
@testable import FlashFindCore

/// Phase 6.3a 契约三：`locate` 成功返回的 schema（方案 §4.4）。
///
/// ## 为什么现在才定
///
/// Phase 5.5 特意没有提前猜结果 JSON——那时还没有任何一条真实结果，
/// 猜出来的字段名十有八九会和 provider 的实际能力对不上。现在要接真 `locate` 了，
/// 再不定就会由「执行侧想到什么写什么」来决定 Agent 看到什么。
///
/// ## 冻结的字段（1.1.2 就这么少）
///
/// ```text
/// { results: [ { file_id, name, relative_path, source_id, kind, score, reasons } ],
///   truncated, limit_applied, warnings }
/// ```
///
/// ★ **不带** `size` / `modified_at` / `source_name` / `absolute_path`：
/// * 大小与时间在 provider 之间不一致（本机有、某些 WebDAV 没有），
///   做成「有时有有时没有」的字段会让 Agent 写出 `if let` 分支；
/// * 完整元数据只有一个出口：`get_metadata`；
/// * 绝对路径是本机概念，NAS 结果给不出来，给了就是假装。
///
/// 本文件因此同时是**字段清单**（`Set(keys)` 断言）和**不变量的守门人**：
/// 以后谁想加字段，必须同时改这条用例——那正是让人停下来想一秒的地方。
final class LocateResponseTests: XCTestCase {

    private func makeResult(name: String = "年度汇总报告.xlsx",
                            path: String = "供应商资料/年度汇总报告.xlsx",
                            sourceID: String = "src_nas_work",
                            kind: FileKind = .file,
                            score: Double = 0.87,
                            reasons: [LocateReason] = [.nameMatch, .recentlyModified]) throws -> LocateResult {
        try LocateResult(fileID: FileID.make(sourceID: sourceID, canonicalRelativePath: path),
                         name: name,
                         relativePath: path,
                         sourceID: sourceID,
                         kind: kind,
                         score: score,
                         reasons: reasons)
    }

    /// 造一个「没被钳位」的 `LimitApplication`，默认就是 `locate` 的默认条数。
    private func application(_ applied: Int = LimitRange.locate.defaultValue,
                             wasClamped: Bool = false) -> LimitApplication {
        LimitApplication(applied: applied, wasClamped: wasClamped)
    }

    /// 唯一构造入口是 `init(selecting:application:warnings:)`：候选进、窗口出。
    private func makeResponse(_ candidates: [LocateResult],
                              limit: Int = LimitRange.locate.defaultValue,
                              wasClamped: Bool = false,
                              warnings: [String] = []) -> LocateResponse {
        LocateResponse(selecting: candidates,
                       application: application(limit, wasClamped: wasClamped),
                       warnings: warnings)
    }

    // MARK: - 1. 字段清单
    func testTheSuccessPayloadHasExactlyTheFrozenTopLevelKeys() throws {
        let response = makeResponse([try makeResult()])
        guard case .object(let fields) = response.payload() else {
            return XCTFail("结果必须是 JSON 对象")
        }
        XCTAssertEqual(Set(fields.keys),
                       ["results", "truncated", "limit_applied", "warnings"],
                       "顶层字段被改了：改它就要改这条用例，并且要在方案里写明理由")
    }

    func testEveryHitCarriesExactlyTheFrozenKeys() throws {
        let response = makeResponse([try makeResult()])
        guard case .object(let fields) = response.payload(),
              case .array(let items)? = fields["results"],
              case .object(let hit)? = items.first else {
            return XCTFail("结果结构不对")
        }
        XCTAssertEqual(Set(hit.keys),
                       ["file_id", "name", "relative_path", "source_id", "kind", "score", "reasons"],
                       "单条结果的字段被改了")
    }

    /// 已经删掉的字段不许回来：路径只有一个名字（`relative_path`），
    /// 元数据只有一个出口（`get_metadata`）。
    func testRetiredFieldsDoNotComeBack() throws {
        let response = makeResponse([try makeResult()])
        guard case .object(let fields) = response.payload(),
              case .array(let items)? = fields["results"],
              case .object(let hit)? = items.first else {
            return XCTFail("结果结构不对")
        }
        for retired in ["path", "absolute_path", "full_path", "source", "source_name",
                        "size", "modified", "modified_at", "ranking_score",
                        "history_match", "changed_since_last_access", "id"] {
            XCTAssertNil(hit[retired], "字段「\(retired)」又回来了：1.1.2 的 locate 只给最小集")
        }
    }

    // MARK: - 2. 值

    func testTheHitValuesAreCarriedVerbatim() throws {
        let id = try FileID.make(sourceID: "src_nas_work",
                                 canonicalRelativePath: "供应商资料/年度汇总报告.xlsx")
        let response = makeResponse([try makeResult()])
        guard case .object(let fields) = response.payload(),
              case .array(let items)? = fields["results"],
              case .object(let hit)? = items.first else {
            return XCTFail("结果结构不对")
        }
        XCTAssertEqual(hit["file_id"], .string(id.value))
        XCTAssertEqual(hit["name"], .string("年度汇总报告.xlsx"))
        XCTAssertEqual(hit["relative_path"], .string("供应商资料/年度汇总报告.xlsx"))
        XCTAssertEqual(hit["source_id"], .string("src_nas_work"))
        XCTAssertEqual(hit["kind"], .string("file"))
        XCTAssertEqual(hit["score"], .double(0.87))
        XCTAssertEqual(hit["reasons"], .array([.string("name-match"), .string("recently-modified")]))
    }

    /// 排序就是 `locate` 的全部价值：结果顺序必须原样保留，不许重排成字典序之类的。
    ///
    /// ★ 名字故意**不按字母序**给：如果名字本身就是 A/B/C，那么「按名字重排」的
    /// 回归也会绿——那种用例只是在测「数组能不能遍历」。
    func testTheResultOrderIsPreserved() throws {
        let first = try makeResult(name: "zeta", path: "docs/zeta.txt", score: 0.9)
        let second = try makeResult(name: "alpha", path: "docs/alpha.txt", score: 0.5)
        let third = try makeResult(name: "mu", path: "docs/mu.txt", score: 0.1)
        let response = makeResponse([first, second, third])
        guard case .object(let fields) = response.payload(),
              case .array(let items)? = fields["results"] else {
            return XCTFail("结果结构不对")
        }
        let names = items.compactMap { item -> String? in
            guard case .object(let hit) = item, case .string(let name)? = hit["name"] else { return nil }
            return name
        }
        XCTAssertEqual(names, ["zeta", "alpha", "mu"], "结果顺序被重排了")
    }

    func testReasonsOnlyComeFromTheClosedSet() {
        XCTAssertEqual(LocateReason.allCases.map(\.rawValue).sorted(),
                       ["located-recently", "metadata-access", "name-match", "recently-modified"],
                       "reasons 是闭集（§7.1）：加一个值要同时改权重表与这条用例")
    }

    /// 空结果是**成功**：`results: []` 的语义是「搜过了，没有」。
    /// 它和「这条路径还没接上」必须一眼能分开（后者是 `internal_error`）。
    func testAnEmptyResultListIsStillASuccessPayload() throws {
        let response = makeResponse([])
        guard case .object(let fields) = response.payload() else { return XCTFail() }
        XCTAssertEqual(fields["results"], .array([]))
        XCTAssertEqual(fields["truncated"], .bool(false))
        XCTAssertEqual(fields["limit_applied"], .int(5))
        XCTAssertEqual(fields["warnings"], .array([]))
    }

    // MARK: - 3. truncated / limit / warnings

    /// ★ Phase 6.3b-0 锁死的三条：`truncated` 的含义**只有**「确实还有更多合格结果」。
    ///
    /// 三条用例是同一条规则的三个边界。少任何一条都会让实现有一种「恰好绿」的写法：
    /// * 只有 21/20 那条 → 把 `truncated` 写成 `count >= applied` 也能过；
    /// * 只有 3/20 那条 → 直接写 `truncated = false` 也能过。
    func testThreeHitsUnderTheLimitAreNotTruncated() throws {
        let response = makeResponse(try (0..<3).map { _ in try makeResult() }, limit: 20)
        XCTAssertFalse(response.truncated, "3 条候选、上限 20：没有更多结果，不能说 truncated")
        XCTAssertEqual(response.limitApplied, 20)
        XCTAssertEqual(response.results.count, 3)
    }

    /// 正好用满上限、且**确实只有这么多**：仍然不是 truncated。
    ///
    /// 这条是最容易被写错的一条：`count == applied` 看起来「刚好截断」，
    /// 但候选总数就是 20，没有第 21 条。实现必须拿到「21 条候选」才知道还有更多。
    func testExactlyTheLimitIsNotTruncated() throws {
        let response = makeResponse(try (0..<20).map { _ in try makeResult() }, limit: 20)
        XCTAssertFalse(response.truncated, "候选正好 20 条、上限 20：没有第 21 条就不能说还有更多")
        XCTAssertEqual(response.results.count, 20)
    }

    func testHavingOneMoreCandidateThanTheLimitIsTruncated() throws {
        let response = makeResponse(try (0..<21).map { _ in try makeResult() }, limit: 20)
        XCTAssertTrue(response.truncated)
        XCTAssertEqual(response.results.count, 20, "只回前 limit_applied 条")
    }

    /// **参数被钳位 ≠ 结果被截断**（本轮复审纠正的那一条）。
    ///
    /// 请求 `limit=100`、上限 20、候选只有 3 条：`was_clamped` 是 true，
    /// 返回体里的 `truncated` 必须是 **false**。否则 Agent 会一直以为
    /// 「再要一点就有了」，反复加参数、永远拿不到。
    func testAClampedLimitIsNotATruncatedResult() throws {
        let response = makeResponse(try (0..<3).map { _ in try makeResult() },
                                    limit: 20, wasClamped: true)
        XCTAssertFalse(response.truncated, "参数被钳位不等于还有更多结果")
        XCTAssertEqual(response.limitApplied, 20, "生效条数仍然是上限")
        XCTAssertEqual(response.results.count, 3)
    }

    /// 部分失败的说明原样带出（`source_denied:<id>`）。**不含来源名**——
    /// 那串东西来自 `PermissionPolicy`，它的措辞已经决定了「只说 id 不说名字」。
    ///
    /// ★ 也**不许**把「有来源失败」折进 `truncated`：那是 warnings 的事。
    func testWarningsAreCarriedVerbatim() throws {
        let warnings = ["source_denied:src_nas_gone"]
        let response = makeResponse([try makeResult()], warnings: warnings)
        guard case .object(let fields) = response.payload() else { return XCTFail() }
        XCTAssertEqual(fields["warnings"], .array([.string("source_denied:src_nas_gone")]))
        XCTAssertEqual(fields["truncated"], .bool(false), "来源失败不是「还有更多结果」")
    }

    // MARK: - 4. 坏结果造不出来

    /// 绝对路径不许进结果：NAS 结果的「绝对路径」是骗人的，
    /// 而本机结果的绝对路径一旦发给 Agent，下一步就是「请读取 /Users/…」。
    func testAnAbsolutePathCannotBecomeAResult() throws {
        let id = try FileID.make(sourceID: "local_mac", canonicalRelativePath: "docs/a.txt")
        XCTAssertThrowsError(try LocateResult(fileID: id,
                                              name: "a.txt",
                                              relativePath: "/Users/someone/docs/a.txt",
                                              sourceID: "local_mac",
                                              kind: .file,
                                              score: 0.5,
                                              reasons: [])) { error in
            XCTAssertEqual(error as? LocateResult.Error, .unsafePath)
        }
    }

    /// `score` 是 `0…1` 的相对分，不是概率。越界就说明算错了——
    /// 放它过去，Agent 会把 `87` 读成「87%」。
    func testAScoreOutsideZeroToOneCannotBecomeAResult() throws {
        let id = try FileID.make(sourceID: "local_mac", canonicalRelativePath: "docs/a.txt")
        for bad in [-0.1, 1.1, 87.0, Double.nan, Double.infinity] {
            XCTAssertThrowsError(try LocateResult(fileID: id, name: "a.txt",
                                                  relativePath: "docs/a.txt",
                                                  sourceID: "local_mac",
                                                  kind: .file, score: bad, reasons: []),
                                 "越界分数被接受：\(bad)") { error in
                XCTAssertEqual(error as? LocateResult.Error, .scoreOutOfRange)
            }
        }
    }

    // MARK: - 5. 线上形态

    func testTheJSONIsOneParsableObject() throws {
        let response = makeResponse([try makeResult()])
        let json = try response.json()
        let decoded = try JSONSerialization.jsonObject(with: Data(json.utf8))
        let fields = try XCTUnwrap(decoded as? [String: Any])
        XCTAssertEqual(fields["limit_applied"] as? Int, 5)
        XCTAssertEqual(fields["truncated"] as? Bool, false)
        let results = try XCTUnwrap(fields["results"] as? [[String: Any]])
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results[0]["kind"] as? String, "file")
        XCTAssertEqual(results[0]["score"] as? Double, 0.87)
        XCTAssertFalse(json.contains("\n"), "结果 JSON 必须是单行（报文按行切帧）")
    }

    /// 同一份输入两次必须**逐字节**相同。`jsonString` 走 `sortedKeys` 就是为了这个：
    /// 否则断言只能写成「解析后相等」，键序错乱永远抓不到。
    func testTheSameResponseSerialisesIdenticallyTwice() throws {
        let response = makeResponse((0..<21).map { _ in try! makeResult() },
                                     limit: 20,
                                     warnings: ["source_denied:src_nas_gone"])
        XCTAssertEqual(try response.json(), try response.json())
    }
}
