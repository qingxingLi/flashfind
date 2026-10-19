import XCTest
@testable import FlashFindCore

/// 「名称 + 格式」搜索在**各来源上的落地**：格式单独下传、结果按格式收敛。
///
/// 这里的桩刻意让 `search` 返回**什么格式都有**的结果，用来模拟
/// 设备不具备下推能力的品牌（群晖之外都没有 extension 参数）——
/// 那种情况下客户端必须自己筛，否则用户看到的就是另一回事。
@MainActor
final class SearchFormatFilterTests: XCTestCase {

    private final class RecordingBridge: MyNASBridgeTransport {
        var files: [[String: Any]] = []
        private(set) var searchFields: [String: Any] = [:]
        private(set) var calls: [String] = []

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(command)
            switch command {
            case "discover": return ["event": "capabilities"]
            case "login": return ["event": "authState", "state": "scopeReady", "isManager": false]
            case "selectScope": return ["event": "scopeState", "state": "scopeReady", "scopes": ["/共享"]]
            case "search":
                searchFields = fields
                event?(["event": "batch", "sourceID": sourceID, "queryID": queryID, "files": files])
                return ["resultState": "completed", "isComplete": true]
            default: return [:]
            }
        }
    }

    private func readyProvider(_ bridge: RecordingBridge) async throws -> NASSearchProvider {
        let subject = NASSearchProvider(
            bridge: bridge,
            config: NASSourceConfig(host: "192.168.1.96", port: 5001,
                                    username: "nasuser", scopes: ["/共享"]),
            port: 5001)
        try await subject.login(account: "nasuser", password: "p")
        _ = try await subject.selectScopes(["/共享"])
        XCTAssertTrue(subject.ready, "前置：应已就绪")
        return subject
    }

    private func row(_ name: String) -> [String: Any] {
        ["id": "1:" + name, "fileType": "file", "name": name, "path": "/共享/" + name]
    }

    private func search(_ text: String, files: [[String: Any]] = []) async throws
    -> (fields: [String: Any], names: [String], ranks: [Int]) {
        let bridge = RecordingBridge()
        let provider = try await readyProvider(bridge)
        // sourceID 必须与来源一致，否则 `result(_:)` 会整行丢弃（那是定位防串源的护栏）。
        bridge.files = files.map { $0.merging(["sourceID": provider.source.id]) { _, new in new } }
        var names: [String] = []
        var ranks: [Int] = []
        await provider.search(text, queryID: UUID()) { event in
            names.append(contentsOf: event.results.map { $0.name })
            ranks.append(contentsOf: event.results.map { $0.rank })
        }
        return (bridge.searchFields, names, ranks)
    }

    // MARK: - 下发

    /// 格式词**不能**留在发给设备的名字模式里：设备会去找「名字里同时含
    /// 「测试报告」和「ppt」的文件，那几乎必然是空的。
    func testFormatWordIsStrippedFromPattern() async throws {
        let out = try await search("测试报告 ppt")
        XCTAssertEqual(out.fields["query"] as? String, "测试报告")
    }

    func testFormatWordBeforeKeywordParsesTheSame() async throws {
        let out = try await search("ppt 测试报告")
        XCTAssertEqual(out.fields["query"] as? String, "测试报告")
    }

    func testPlainQueryIsUntouched() async throws {
        let out = try await search("测试报告")
        XCTAssertEqual(out.fields["query"] as? String, "测试报告")
    }

    func testOnlyFormatWordUsesWildcardPattern() async throws {
        // 只给格式时名字模式必须是「全部」：空 pattern 在核心里会被当成
        // 「没什么可搜」直接返回 0 条。
        let out = try await search("ppt")
        XCTAssertEqual(out.fields["query"] as? String, "*")
    }

    // MARK: - 结果收敛

    func testResultsKeepOnlyRequestedFormats() async throws {
        let files = [row("测试报告.ppt"), row("测试报告.pptx"),
                     row("测试报告.docx"), row("测试报告.pdf"), row("测试报告")]
        let out = try await search("测试报告 ppt", files: files)
        XCTAssertEqual(Set(out.names), ["测试报告.ppt", "测试报告.pptx"])
    }

    func testPlainQueryKeepsEveryResult() async throws {
        let files = [row("测试报告.ppt"), row("测试报告.docx")]
        let out = try await search("测试报告", files: files)
        XCTAssertEqual(Set(out.names), ["测试报告.ppt", "测试报告.docx"])
    }

    func testRankUsesStrippedKeywords() async throws {
        // 拿整串「测试报告 ppt」算相关度的话，没有文件名匹配得上，结果掉到最后一档（4）。
        // 用剥离后的关键词「测试报告」则是前缀命中（1）。
        let out = try await search("测试报告 ppt", files: [row("测试报告.ppt")])
        XCTAssertEqual(out.ranks, [1])
        XCTAssertLessThan(out.ranks[0], 4)
    }

    // MARK: - 应用侧

    func testAppSearchStaysQuietWithFormatFilter() async {
        let provider = AppSearchProvider(limit: 10, scan: {
            [AppSearchCandidate(name: "Keynote", url: URL(fileURLWithPath: "/Applications/Keynote.app"))]
        })
        var count = 0
        await provider.search("keynote ppt", queryID: UUID()) { event in count += event.results.count }
        XCTAssertEqual(count, 0, "带格式限制时不该返回应用：应用没有扩展名")
    }

    func testAppSearchStillWorksWithoutFormatFilter() async {
        let provider = AppSearchProvider(limit: 10, scan: {
            [AppSearchCandidate(name: "Keynote", url: URL(fileURLWithPath: "/Applications/Keynote.app"))]
        })
        var count = 0
        await provider.search("keynote", queryID: UUID()) { event in count += event.results.count }
        XCTAssertEqual(count, 1)
    }
}
