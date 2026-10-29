import XCTest
@testable import FlashFindCore

/// 右键菜单的内容与「下载走哪条路」。
///
/// 2026-10-29 用户报障：飞牛的结果右键有「下载」，群晖、OpenList 的没有；
/// OpenList 的结果连「在 Finder 中显示」都没有。判定写在 App 层测不了
/// （App 是可执行目标），所以搬进 Core，用测试钉住「三家菜单一样」。
final class ResultMenuPlanTests: XCTestCase {

    private func nasRow(_ id: String, target: SearchOpenTarget = .unavailable) -> SearchResult {
        var row = SearchResult(id: id, name: "报告.pdf", relativePath: "/vol1/1000/文档/报告.pdf",
                               sourceID: id, sourceName: id, kind: "file", size: nil, localURL: nil)
        row.sourceType = .nas
        row.openTarget = target
        return row
    }

    private func smbTarget() -> SearchOpenTarget {
        var components = URLComponents()
        components.scheme = "smb"; components.host = "fn.example.net"; components.path = "/共享文档/报告.pdf"
        return .smbLocation(components.url!)
    }

    private func webTarget() -> SearchOpenTarget {
        .webURL(URL(string: "https://openlist.example.net/A0002/%E6%8A%A5%E5%91%8A.pdf")!)
    }

    /// ★★ 三个品牌的菜单必须一字不差（共享位置 / 没有目标 / 网页地址三种行）。
    func testEveryNASRowGetsTheSameMenu() {
        let fnos = ResultMenuPlan.items(for: nasRow("fnos", target: smbTarget()))
        let synology = ResultMenuPlan.items(for: nasRow("synology"))
        let openlist = ResultMenuPlan.items(for: nasRow("openlist", target: webTarget()))
        XCTAssertEqual(Array(fnos.prefix(6)), Array(synology.prefix(6)),
                       "★ 飞牛与群晖的动作项必须一样（旧实现里只有飞牛有下载）")
        XCTAssertEqual(Array(fnos.prefix(6)), Array(openlist.prefix(6)),
                       "★ 飞牛与 OpenList 的动作项必须一样（旧实现里 OpenList 连「在 Finder 中显示」都没有）")
    }

    /// 每一项都在：下载两个动作 + 在 Finder 中显示。
    func testNASMenuCarriesBothDownloadAndFinderItems() {
        let items = ResultMenuPlan.items(for: nasRow("synology"))
        let expected: [ResultMenuItem] = [.open, .reveal, .quickLook, .downloadAndOpen, .downloadToFolder, .copyPath, .copyName]
        for item in expected {
            XCTAssertTrue(items.contains(item), "菜单里少了 \(item.rawValue)")
        }
    }

    /// 「复制网页链接」只在**真的有网页地址**时出现：没有地址时复制出来是空串。
    func testWebLinkItemOnlyForRowsWithAWebTarget() {
        XCTAssertTrue(ResultMenuPlan.items(for: nasRow("openlist", target: webTarget())).contains(.copyWebLink))
        XCTAssertFalse(ResultMenuPlan.items(for: nasRow("synology")).contains(.copyWebLink))
    }

    /// 本机结果没有「下载」这回事（本地文件拷给自己没有意义）。
    func testLocalRowHasNoDownloadItems() {
        let local = SearchResult(id: "local", name: "报告.pdf", relativePath: "/Users/me/报告.pdf",
                                 sourceID: nil, sourceName: "此 Mac", kind: "file", size: nil,
                                 localURL: URL(fileURLWithPath: "/Users/me/报告.pdf"))
        let items = ResultMenuPlan.items(for: local)
        let expected: [ResultMenuItem] = [.open, .reveal, .quickLook, .copyPath, .copyName]
        XCTAssertEqual(items, expected)
    }

    /// 分组：动作 → 传文件 → 剪贴板，分隔线只画在换组那一项前面。
    func testSeparatorsOnlyBetweenSections() {
        let items = ResultMenuPlan.items(for: nasRow("fnos", target: smbTarget()))
        XCTAssertFalse(ResultMenuPlan.separatorBefore(items[0], in: items), "第一项前面不画线")
        XCTAssertTrue(ResultMenuPlan.separatorBefore(.downloadAndOpen, in: items))
        XCTAssertTrue(ResultMenuPlan.separatorBefore(.copyPath, in: items))
        XCTAssertFalse(ResultMenuPlan.separatorBefore(.open, in: items))
    }

    // MARK: - 下载路由

    func testFnOSDownloadsThroughTheDeviceAPI() {
        XCTAssertEqual(ResultDownloadRouting.route(for: nasRow("fnos", target: smbTarget()), vendor: .fnos),
                       .deviceDownload, "飞牛有设备侧下载接口，不需要挂载")
    }

    func testSynologyDownloadsByCopyingTheMountedFile() {
        XCTAssertEqual(ResultDownloadRouting.route(for: nasRow("synology"), vendor: .synology), .localCopy)
    }

    /// 网页来源没挂载时别假装能下：给一句能照做的话。
    func testWebOnlyRowExplainsWhyItCannotDownload() {
        guard case .unsupported(let message) = ResultDownloadRouting.route(
            for: nasRow("openlist", target: webTarget()), vendor: .openlist) else {
            return XCTFail("网页来源没有本地路径时不该谎称能下载")
        }
        XCTAssertTrue(message.contains("浏览器"), "要告诉用户接下来怎么做，而不是只说失败：\(message)")
    }

    /// 挂上了 WebDAV 之后同一个来源就能沿用「拷一份」。
    func testWebRowWithLocalPathDownloadsByCopy() {
        XCTAssertEqual(ResultDownloadRouting.route(for: nasRow("openlist", target: webTarget()),
                                                   vendor: .openlist, hasLocalPath: true), .localCopy)
    }

    /// 来源已下线：说清楚，别让用户以为文件坏了。
    func testMissingSourceIsReported() {
        guard case .unsupported = ResultDownloadRouting.route(for: nasRow("gone"), vendor: nil) else {
            return XCTFail("来源下线时应报不可下载")
        }
    }
}
