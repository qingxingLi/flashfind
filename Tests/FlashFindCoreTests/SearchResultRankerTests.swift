import XCTest
@testable import FlashFindCore

@MainActor
private final class NoopBridge: MyNASBridgeTransport {
    func request(_ command: String, sourceID: String, queryID: String,
                 fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] { [:] }
}

@MainActor
private final class ResultBridge: MyNASBridgeTransport {
    var files: [[String: Any]] = []
    func request(_ command: String, sourceID: String, queryID: String,
                 fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        switch command {
        case "discover": return ["event": "capabilities"]
        case "login": return ["state": "scopeReady"]
        case "search":
            event?(["event": "batch", "sourceID": sourceID, "queryID": queryID, "files": files])
            return ["resultState": "completed", "isComplete": true]
        default: return [:]
        }
    }
}

final class SearchResultRankerTests: XCTestCase {

    /// 直接调用 ranker 是纯函数测试；这条走 NASSearchProvider.result，
    /// 确保真实结果行也会带上按查询词计算出的 rank。
    @MainActor func testNASSearchProviderAssignsRankFromQuery() {
        let config = NASSourceConfig(id: "fixture", name: "fixture", vendor: .synology,
                                     host: "192.168.1.96", port: 5001, username: "u",
                                     scopes: ["/共享"])
        let provider = NASSearchProvider(bridge: NoopBridge(), config: config, port: 5001)
        let base: [String: Any] = ["id": "1", "fileType": "file",
                                   "sourceID": provider.source.id]
        let matching202 = provider.result(base.merging(["name": "202系列工艺手册-图纸.dwg",
                                                         "path": "/共享/202系列/202系列工艺手册-图纸.dwg"],
                                                       uniquingKeysWith: { _, new in new }),
                                         query: "202系列工艺手册")
        let matching201 = provider.result(base.merging(["name": "201系列工艺手册-图纸.dwg",
                                                         "path": "/共享/201系列/201系列工艺手册-图纸.dwg"],
                                                       uniquingKeysWith: { _, new in new }),
                                         query: "202系列工艺手册")
        XCTAssertEqual(matching202?.rank, 1)
        XCTAssertEqual(matching201?.rank, 4)
        XCTAssertLessThan(matching202?.rank ?? 0, matching201?.rank ?? 0)
    }

    /// 走完整 search 路径，验证 NASSearchProvider 把查询词传给了 result 并据此赋 rank。
    @MainActor func testSearchPipelinePassesQueryAndAssignsRank() async throws {
        let config = NASSourceConfig(id: "fixture", name: "fixture", vendor: .synology,
                                     host: "192.168.1.96", port: 5001, username: "u",
                                     scopes: ["/共享"])
        let bridge = ResultBridge()
        let provider = NASSearchProvider(bridge: bridge, config: config, port: 5001)
        _ = try await provider.discover()
        try await provider.login(account: "u", password: "p")
        bridge.files = [["id": "1",
                         "name": "202系列工艺手册-图纸.dwg",
                         "path": "/共享/202系列/202系列工艺手册-图纸.dwg",
                         "fileType": "file",
                         "sourceID": provider.source.id]]
        var events = [ProviderEvent]()
        await provider.search("202系列工艺手册", queryID: UUID()) { events.append($0) }
        let ranks = events.flatMap(\.results).map(\.rank)
        XCTAssertTrue(ranks.contains(1), "search 路径必须把查询词传进 ranker，前缀匹配应得 rank 1；实际 ranks = \(ranks)")
    }

    func testExactMatchIsRankZero() {
        XCTAssertEqual(SearchResultRanker.rank(name: "202系列工艺手册.pdf",
                                               path: "/共享/202系列工艺手册.pdf",
                                               query: "202系列工艺手册.pdf"), 0)
    }

    func testPrefixMatchIsRankOne() {
        XCTAssertEqual(SearchResultRanker.rank(name: "202系列工艺手册-图纸.dwg",
                                               path: "/共享/202系列/202系列工艺手册-图纸.dwg",
                                               query: "202系列工艺手册"), 1)
    }

    func testAllTermsInNameIsRankTwo() {
        XCTAssertEqual(SearchResultRanker.rank(name: "202系列工艺手册-图纸.dwg",
                                               path: "/共享/202系列/202系列工艺手册-图纸.dwg",
                                               query: "202 系列 工艺 手册"), 2)
    }

    func testTermsOnlyInPathIsRankThree() {
        XCTAssertEqual(SearchResultRanker.rank(name: "图纸.dwg",
                                               path: "/共享/202系列工艺手册/图纸.dwg",
                                               query: "202 系列 工艺 手册"), 3)
    }

    func testMismatchedSeriesRanksBehindMatchingSeries() {
        let query = "202系列工艺手册"
        let matching202 = SearchResultRanker.rank(name: "202系列工艺手册-图纸.dwg",
                                                  path: "/主机/202系列/202系列工艺手册-图纸.dwg",
                                                  query: query)
        let matching201 = SearchResultRanker.rank(name: "201系列工艺手册-图纸.dwg",
                                                  path: "/主机/201系列/201系列工艺手册-图纸.dwg",
                                                  query: query)
        let matching174 = SearchResultRanker.rank(name: "174系列工艺手册-图纸.dwg",
                                                  path: "/主机/174系列/174系列工艺手册-图纸.dwg",
                                                  query: query)
        XCTAssertEqual(matching202, 1)
        XCTAssertEqual(matching201, 4)
        XCTAssertEqual(matching174, 4)
        XCTAssertLessThan(matching202, matching201)
        XCTAssertLessThan(matching202, matching174)
    }

    func testCaseAndDiacriticsAreIgnored() {
        XCTAssertEqual(SearchResultRanker.rank(name: "RÉSUMÉ.PDF",
                                               path: "/docs/RÉSUMÉ.PDF",
                                               query: "resume.pdf"), 0)
    }

    func testEmptyQueryFallsBackToDefaultRank() {
        XCTAssertEqual(SearchResultRanker.rank(name: "anything.txt", path: "/a/anything.txt", query: ""), 3)
        XCTAssertEqual(SearchResultRanker.rank(name: "anything.txt", path: "/a/anything.txt", query: "   "), 3)
    }
}
