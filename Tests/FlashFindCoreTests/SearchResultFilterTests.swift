import XCTest
@testable import FlashFindCore

/// 「钉在桌面上之后还能改筛选」这条路上唯一的判定（`SearchResultFilter`）。
///
/// ★ 这些用例存在的理由：正常搜索时类型/位置是**下发给设备**的，客户端从不自己筛；
///   钉住的窗口没有设备在手边，于是「筛得对不对」第一次成了客户端的事。
///   任何一条错了的表现都很像「这功能坏了」：筛 pdf 冒出文件夹、选某个共享一行不剩。
final class SearchResultFilterTests: XCTestCase {

    private func row(_ name: String,
                     kind: String = "file",
                     sourceID: String? = "src1",
                     path: String = "/Book/\(UUID().uuidString)") -> SearchResult {
        var result = SearchResult(id: name + path, name: name, relativePath: path,
                                  sourceID: sourceID, sourceName: "测试来源",
                                  kind: kind, size: 1, localURL: nil)
        result.fileType = kind == "directory" ? "folder" : "file"
        return result
    }

    private var pdf: SearchFileTypeCatalog.FileType {
        SearchFileTypeCatalog.all.first { $0.id == "type:pdf" }!
    }
    private var photo: SearchFileTypeCatalog.FileType {
        SearchFileTypeCatalog.all.first { $0.id == "type:photo" }!
    }

    // MARK: - 类型

    func testNoTypeFilterPassesEverything() {
        XCTAssertTrue(SearchResultFilter.matches(fileType: nil, name: "报告.pdf", kind: "file"))
        XCTAssertTrue(SearchResultFilter.matches(fileType: nil, name: "项目", kind: "directory"))
    }

    func testTypeFilterKeepsOnlyThatFamily() {
        XCTAssertTrue(SearchResultFilter.matches(fileType: pdf, name: "报告.pdf", kind: "file"))
        XCTAssertFalse(SearchResultFilter.matches(fileType: pdf, name: "报告.docx", kind: "file"))
        XCTAssertTrue(SearchResultFilter.matches(fileType: photo, name: "海边.jpg", kind: "file"),
                      "「照片」是类别词，要走 FileFormatVocabulary 展开成整类")
    }

    func testTypeFilterDropsFolders() {
        // ★ 文件夹没有扩展名。不显式排掉，选 pdf 时它们会照样留在列表里 ——
        //   看起来像「筛选没生效」。
        XCTAssertFalse(SearchResultFilter.matches(fileType: pdf, name: "项目资料", kind: "directory"))
    }

    // MARK: - 位置

    func testUnrestrictedLocationKeepsEverything() {
        XCTAssertTrue(SearchResultFilter.matches(location: .unrestricted, result: row("a.pdf")))
        XCTAssertTrue(SearchResultFilter.matches(location: .unrestricted, result: row("b", sourceID: nil)))
    }

    func testLocalLocationOnlyKeepsLocalRows() {
        XCTAssertTrue(SearchResultFilter.matches(location: .local, result: row("a.pdf", sourceID: nil)))
        XCTAssertFalse(SearchResultFilter.matches(location: .local, result: row("a.pdf", sourceID: "src1")))
    }

    func testSourceRootRequiresSameSourceAndPrefix() {
        let target = SearchTarget.sourceRoot(sourceID: "src1", root: "/Book")
        XCTAssertTrue(SearchResultFilter.matches(location: target, result: row("a.pdf", path: "/Book/a.pdf")))
        XCTAssertTrue(SearchResultFilter.matches(location: target, result: row("b", path: "/Book/子目录/b.pdf")))
        // 别的来源：同一个路径也不能算。
        XCTAssertFalse(SearchResultFilter.matches(location: target, result: row("a.pdf", sourceID: "src2", path: "/Book/a.pdf")))
        // 根之外。
        XCTAssertFalse(SearchResultFilter.matches(location: target, result: row("c", path: "/Other/c.pdf")))
    }

    func testSiblingRootIsNotMatched() {
        // ★ 整段比较：`/示例共享` 不能吃掉 `/示例共享2` 里的东西。
        let target = SearchTarget.sourceRoot(sourceID: "src1", root: "/示例共享")
        XCTAssertFalse(SearchResultFilter.matches(location: target,
                                                  result: row("a.pdf", path: "/示例共享2/a.pdf")))
        XCTAssertTrue(SearchResultFilter.matches(location: target,
                                                 result: row("a.pdf", path: "/示例共享/a.pdf")))
    }

    func testWholeRootMatchesEverything() {
        // ★★ 整根（"/"）：`"/".split("/")` 是两个空段，按前缀比较永远匹配不上，
        //    症状是「钉住里选那个整根共享，一行都不剩」。
        let target = SearchTarget.sourceRoot(sourceID: "src1", root: "/")
        XCTAssertTrue(SearchResultFilter.matches(location: target, result: row("a.pdf", path: "/Book/a.pdf")))
        XCTAssertTrue(SearchResultFilter.matches(location: target, result: row("b", path: "/深一层/目录/b.pdf")))
        // 来源仍然要对得上。
        XCTAssertFalse(SearchResultFilter.matches(location: target, result: row("a.pdf", sourceID: "src2", path: "/Book/a.pdf")))
    }

    func testTrailingSlashOnRootIsIgnored() {
        let target = SearchTarget.sourceRoot(sourceID: "src1", root: "/Book/")
        XCTAssertTrue(SearchResultFilter.matches(location: target, result: row("a.pdf", path: "/Book/a.pdf")))
    }

    func testLeadingSlashOnPathDoesNotMatter() {
        // ★ 两类数据的口径本来就不一样：NAS 结果行的 `relativePath` 带前导 `/`，
        //   本机与预览夹具不带。按字符串比较就得先统一口径，漏一处就是
        //   「某类来源永远筛不出来」。
        let target = SearchTarget.sourceRoot(sourceID: "src1", root: "/团队文档")
        XCTAssertTrue(SearchResultFilter.matches(location: target,
                                                 result: row("a.pdf", path: "团队文档/a.pdf")))
        XCTAssertTrue(SearchResultFilter.matches(location: target,
                                                 result: row("b.pdf", path: "/团队文档/子/b.pdf")))
    }

    func testRawSourceIdentifierIsNormalizedBeforeComparing() {
        // ★ 结果行里的 `sourceID` 是**来源 id**（`NASSourceProvider` 用它建的），
        //   而位置限定里的是**协议 sourceID**（非法字符被换成 `-` 并加 `nas_` 前缀）。
        //   不换算就永远对不上，表现是「某个共享下的结果一条都筛不出来」。
        let raw = "测试 来源"
        let protocolID = NASSourceConfig.protocolIdentifier(for: raw)
        XCTAssertNotEqual(raw, protocolID, "这条用例的前提就是两个 id 不一样")
        let target = SearchTarget.sourceRoot(sourceID: protocolID, root: "/Book")
        XCTAssertTrue(SearchResultFilter.matches(location: target,
                                                 result: row("a.pdf", sourceID: raw, path: "/Book/a.pdf")))
    }

    // MARK: - 一起筛

    func testRowsApplyBothFiltersAndKeepOrder() {
        let rows = [
            row("a.pdf", path: "/Book/a.pdf"),
            row("b.docx", path: "/Book/b.docx"),
            row("c.pdf", path: "/Other/c.pdf"),
            row("d.pdf", path: "/Book/子/d.pdf"),
        ]
        let out = SearchResultFilter.rows(rows,
                                          fileType: pdf,
                                          location: .sourceRoot(sourceID: "src1", root: "/Book"))
        XCTAssertEqual(out.map(\.name), ["a.pdf", "d.pdf"], "顺序必须保持原样：排序在更早的一步就定了")
    }

    func testRowsWithNoFilterReturnsInputUntouched() {
        let rows = [row("a.pdf"), row("b", kind: "directory")]
        XCTAssertEqual(SearchResultFilter.rows(rows, fileType: nil, location: .unrestricted).map(\.name),
                       ["a.pdf", "b"])
    }
}

/// 钉住的快照要能「记住限定 + 就地重筛」。
final class PinnedResultsFilterTests: XCTestCase {

    private var pdf: SearchFileTypeCatalog.FileType {
        SearchFileTypeCatalog.all.first { $0.id == "type:pdf" }!
    }

    private func row(_ name: String,
                     sourceID: String? = "src1",
                     path: String = "/Book/x") -> SearchResult {
        SearchResult(id: name, name: name, relativePath: path, sourceID: sourceID,
                     sourceName: "来源", kind: "file", size: 1, localURL: nil)
    }

    private func snapshot(_ rows: [SearchResult],
                          total: Int = 240,
                          fileType: SearchFileTypeCatalog.FileType? = nil,
                          location: SearchTarget = .unrestricted) -> PinnedResults {
        PinnedResults(query: "report", rows: rows, totalMatched: total,
                      locationTitle: nil, fileType: fileType, location: location)
    }

    func testSnapshotCarriesTheFiltersItWasPinnedWith() {
        // ★ 不记住的话窗口一开出来就是「全部 / 全部位置」，等于把用户刚做的筛选抹掉。
        let pinned = snapshot([row("a.pdf")], fileType: pdf, location: .sourceRoot(sourceID: "src1", root: "/Book"))
        XCTAssertEqual(pinned.fileType, pdf)
        XCTAssertEqual(pinned.location, .sourceRoot(sourceID: "src1", root: "/Book"))
    }

    func testRefilterStaysInsideTheSnapshot() {
        let pinned = snapshot([row("a.pdf"), row("b.docx"), row("c.pdf", path: "/Other/c.pdf")])
        let filtered = pinned.rows(fileType: pdf,
                                   location: .sourceRoot(sourceID: "src1", root: "/Book"))
        XCTAssertEqual(filtered.map(\.name), ["a.pdf"],
                       "既按类型又按位置筛；c.pdf 在根外，b.docx 类型不对")
    }

    func testVisibleCountMatchesRows() {
        let pinned = snapshot([row("a.pdf"), row("b.docx")])
        XCTAssertEqual(pinned.visibleCount(fileType: nil, location: .unrestricted), 2)
        XCTAssertEqual(pinned.visibleCount(fileType: pdf, location: .unrestricted), 1)
    }

    func testCountTextKeepsTheTotalAsDenominator() {
        let pinned = snapshot([row("a.pdf"), row("b.docx")], total: 240)
        // 不筛：2 / 240
        XCTAssertEqual(pinned.countText, "2 / 240 项")
        // 筛完只剩 1 条，分母仍是 240：用户要看得出「筛掉了」，不是「本来就只有 1 条」。
        XCTAssertEqual(pinned.countText(matching: 1), "1 / 240 项")
        // 没有截断时不留「/ 0」那种怪写法。
        XCTAssertEqual(snapshot([row("a.pdf")], total: 1).countText(matching: 1), "1 项")
    }

    func testWindowHeightFollowsFilteredRowCount() {
        let pinned = snapshot((0..<10).map { row("f\($0).pdf") })
        let full = pinned.windowHeight(rowCount: 10, rowHeight: 56)
        let one = pinned.windowHeight(rowCount: 1, rowHeight: 56)
        XCTAssertGreaterThan(full, one, "筛完只剩 1 行时窗口必须变矮，否则底下留一大片空玻璃")
        // 超过上限不再长高（超出的部分滚动看）。
        XCTAssertEqual(pinned.windowHeight(rowCount: 40, rowHeight: 56), full,
                       "钉住窗口最多 pinnedMaximumRows 行，多出来的走滚动")
        // 空结果也留一行的高度：否则筛到 0 条时窗口会塌成只剩题头，连「什么都没有」都写不下。
        XCTAssertGreaterThan(pinned.windowHeight(rowCount: 0, rowHeight: 56), one - 56)
    }
}
