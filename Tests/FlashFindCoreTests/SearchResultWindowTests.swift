import XCTest
@testable import FlashFindCore

/// 一次搜索的上限窗口：只留最可能的前 200 条，同时记住「总共匹配多少」。
final class SearchResultWindowTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    private func row(_ id: String, score: Double, name: String? = nil) -> SearchResult {
        var r = SearchResult(id: id, name: name ?? "\(id).pdf", relativePath: "/共享/\(id).pdf",
                             sourceID: "nas_x", sourceName: "测试 NAS",
                             kind: "file", size: nil, localURL: nil, rank: 4)
        r.score = score
        r.modifiedDate = now
        return r
    }

    // MARK: - 上限

    func testLimitKeepsOnlyTheBestRowsButCountsEverything() {
        var window = SearchResultWindow(limit: 3)
        window.integrate((0..<10).map { row("id-\($0)", score: Double($0) / 10) })
        XCTAssertEqual(window.rows.count, 3, "上限就是上限：多余的不能进界面")
        XCTAssertEqual(window.rows.map(\.id), ["id-9", "id-8", "id-7"], "留下的是分最高的三条")
        XCTAssertEqual(window.totalMatched, 10, "总共匹配 10 条，不能因为截断就说成 3 条")
        XCTAssertTrue(window.isTruncated)
    }

    /// ★ 上限**不会**把「后到的更相关结果」扔掉。
    ///
    /// 这是流式搜索最容易写错的地方：先把前 200 填满就不再看后面，
    /// 于是设备第二批才发来的那个精确命中永远进不来。
    func testBetterRowsArrivingLaterStillMakeItIn() {
        var window = SearchResultWindow(limit: 3)
        window.integrate((0..<3).map { row("old-\($0)", score: 0.1) })
        XCTAssertEqual(window.rows.count, 3)
        window.integrate([row("better", score: 0.95)])
        XCTAssertEqual(window.rows.first?.id, "better")
        XCTAssertEqual(window.rows.count, 3, "进来一条就要挤掉一条，不能变成 4 条")
        XCTAssertEqual(window.totalMatched, 4)
    }

    /// 更差的结果不影响已有顺序（否则界面会随批次抖动）。
    func testWorseRowsArrivingLaterDoNotDisplaceAnything() {
        var window = SearchResultWindow(limit: 2)
        window.integrate([row("a", score: 0.9), row("b", score: 0.8)])
        window.integrate([row("c", score: 0.1)])
        XCTAssertEqual(window.rows.map(\.id), ["a", "b"])
        XCTAssertEqual(window.totalMatched, 3, "没进列表也要计入匹配总数")
    }

    // MARK: - 去重与总数

    /// 设备会重复发同一行，后台补全元数据还会整批重发：
    /// 总数不能跟着涨，否则状态栏写着「共 400 条」其实只有 200 条。
    func testDuplicateRowsDoNotInflateTheMatchedCount() {
        var window = SearchResultWindow(limit: 10)
        window.integrate([row("a", score: 0.5), row("b", score: 0.4)])
        window.integrate([row("a", score: 0.5), row("b", score: 0.4)])
        XCTAssertEqual(window.totalMatched, 2)
        XCTAssertEqual(window.rows.count, 2)
    }

    func testEmptyBatchChangesNothing() {
        var window = SearchResultWindow(limit: 5)
        window.integrate([row("a", score: 0.5)])
        let before = window
        window.integrate([])
        XCTAssertEqual(window, before)
    }

    // MARK: - 清空

    /// 清空必须把「行 / 总数 / 去重集合」三样一起清掉。
    ///
    /// 只清 `rows` 的后果很具体：下一次搜索的第一批结果会和上一轮的
    /// 总数混在一起，状态栏显示「3 / 1374 项」而那时只搜到 3 条。
    func testResetClearsRowsCountAndSeenSet() {
        var window = SearchResultWindow(limit: 5)
        window.integrate((0..<8).map { row("id-\($0)", score: 0.1) })
        window.reset()
        XCTAssertEqual(window.rows.count, 0)
        XCTAssertEqual(window.totalMatched, 0)
        XCTAssertFalse(window.isTruncated)
        // 清空之后再收到同一个 id，要重新计数（上一轮的记忆不能留下）。
        window.integrate([row("id-0", score: 0.2)])
        XCTAssertEqual(window.totalMatched, 1)
    }

    // MARK: - 文案

    func testCaptionOnlyAppearsWhenTruncated() {
        XCTAssertNil(SearchResultLimit.caption(totalMatched: 120, shown: 120))
        XCTAssertNil(SearchResultLimit.caption(totalMatched: 0, shown: 0))
        let caption = SearchResultLimit.caption(totalMatched: 1374, shown: 200)
        XCTAssertEqual(caption, "共 1374 条匹配，已按匹配度与修改日期排好，先显示前 200 条")
        XCTAssertTrue(caption?.contains("1374") == true, "必须说出还有多少没显示")
    }

    func testDefaultLimitIsTwoHundred() {
        XCTAssertEqual(SearchResultLimit.perSearch, 200, "用户暂定 200；改这里就是改产品行为")
        XCTAssertEqual(SearchResultWindow().limit, 200)
        XCTAssertEqual(SearchResultLimit.step, SearchResultLimit.perSearch,
                       "「继续搜索」每次放多少与首批同值：手感才连续")
    }

    // MARK: - 继续搜索（2026-10-28 用户追加）

    /// ★ 200 条只是**第一批**：候选留在池子里，点「继续搜索」再放一批。
    ///
    /// 用户原话：「限制 200 结果后，如对结果不满意，可以选择继续搜索」。
    /// 这里锁三件事：多出来的一批来自**同一份候选**（不重新搜）、
    /// 放完之后 `canShowMore` 会变成 false（按钮该消失）、
    /// 显示的行永远是全池**最前面**的那一段（不是随便取一段）。
    func testContinueSearchRevealsTheNextSliceOfTheSamePool() {
        var window = SearchResultWindow(limit: 3)
        window.integrate((0..<7).map { row("id-\($0)", score: Double($0) / 10) })
        XCTAssertEqual(window.rows.map(\.id), ["id-6", "id-5", "id-4"])
        XCTAssertTrue(window.canShowMore)

        XCTAssertTrue(window.showMore(step: 3))
        XCTAssertEqual(window.rows.map(\.id), ["id-6", "id-5", "id-4", "id-3", "id-2", "id-1"])
        XCTAssertEqual(window.hiddenCount, 1)

        XCTAssertTrue(window.showMore(step: 3))
        XCTAssertEqual(window.rows.count, 7, "取到最后一屏时正好等于候选数")
        XCTAssertFalse(window.canShowMore, "★ 候选取完了按钮就该消失，否则点了没反应")
        XCTAssertEqual(window.totalMatched, 7, "继续搜索不会改变匹配总数")
    }

    /// 候选本来就不够一屏时，不该出现「继续搜索」。
    func testNoContinueOfferedWhenEverythingIsAlreadyShown() {
        var window = SearchResultWindow(limit: 200)
        window.integrate((0..<5).map { row("id-\($0)", score: 0.5) })
        XCTAssertFalse(window.canShowMore)
        XCTAssertFalse(window.showMore(), "没得放的时候返回 false，调用方就不该改界面")
    }

    /// 清空之后「继续搜索」的状态也要回到起点。
    func testResetAlsoForgetsTheExtraPages() {
        var window = SearchResultWindow(limit: 2)
        window.integrate((0..<5).map { row("id-\($0)", score: 0.5) })
        window.showMore(step: 2)
        window.reset()
        XCTAssertFalse(window.canShowMore)
        XCTAssertEqual(window.hiddenCount, 0)
        window.integrate([row("new", score: 0.9)])
        XCTAssertEqual(window.rows.count, 1, "清空之后 limit 还是 2，但池子里只有 1 条")
    }

    // MARK: - 夹具

    /// 预览夹具不冒充匹配总数：截图里的「共 N 条」必须是真数。
    func testFixtureWindowDoesNotFakeATotal() {
        let window = SearchResultWindow.fixture([row("a", score: 0.9), row("b", score: 0.8)], limit: 10)
        XCTAssertEqual(window.rows.count, 2)
        XCTAssertEqual(window.totalMatched, 2)
        XCTAssertFalse(window.isTruncated)
    }

    /// 排序必须与 `SearchResultMerge` 同一口径（这里只验证它真的用了那个比较器）。
    func testRowsFollowTheSharedOrdering() {
        var window = SearchResultWindow(limit: 10)
        window.integrate([row("low", score: 0.1), row("high", score: 0.9), row("mid", score: 0.5)])
        XCTAssertEqual(window.rows.map(\.id), ["high", "mid", "low"])
        XCTAssertEqual(window.rows.map(\.id),
                       window.rows.sorted(by: SearchResultMerge.precedes).map(\.id))
    }

    // MARK: - 性能守卫

    /// ★ 2000 行（设备侧 `maxResults` 的上限）走「评分 + 合并 + 截断」要够快。
    ///
    /// 这条**不是**精确的性能基准，只防一类灾难：把评分写成对每一行再做
    /// 一遍 O(n log n) 排序、或者每行新建一个 formatter / 正则。
    /// 阈值故意放得很宽（1 秒），抖动不会误报；真实耗时在
    /// `04-测试与验收/ui-fuzzy-search-limit-20261028/README.md` 里记着。
    func testScoringTwoThousandRowsStaysFast() {
        let now = Date()
        let rows: [SearchResult] = (0..<2000).map { index in
            let name = "季度报告-2026Q\(index % 4)-第\(index)版-best_seller_report.pdf"
            var r = SearchResult(id: "perf-\(index)", name: name,
                                 relativePath: "/共享/团队文档/2026/\(name)",
                                 sourceID: "nas_x", sourceName: "测试 NAS",
                                 kind: "file", size: 1024, localURL: nil, rank: 4)
            r.modifiedDate = now.addingTimeInterval(-86_400 * Double(index % 400))
            r.score = SearchRanking.score(name: name, path: r.relativePath, query: "季度报告",
                                          modified: r.modifiedDate, now: now).score
            return r
        }
        let started = Date()
        var window = SearchResultWindow()
        window.integrate(rows)
        let elapsed = Date().timeIntervalSince(started)
        print("[perf] 2000 行评分+合并+截断：\(String(format: "%.1f", elapsed * 1000)) ms")
        XCTAssertEqual(window.rows.count, 200)
        XCTAssertEqual(window.totalMatched, 2000)
        XCTAssertLessThan(elapsed, 1.0, "★ 2000 行超过 1 秒：一定是某处退化成了 O(n²) 或每行做了重活")
    }
}
