import XCTest
@testable import FlashFindCore

final class SearchQueryParserTests: XCTestCase {

    private func parse(_ text: String) -> ParsedSearchQuery { SearchQueryParser.parse(text) }

    // MARK: - 名称 + 格式（顺序无关）

    func testFormatWordAfterKeyword() {
        let q = parse("测试报告 ppt")
        XCTAssertEqual(q.terms, ["测试报告"])
        XCTAssertEqual(q.extensions, ["ppt", "pptx"])
        XCTAssertTrue(q.hasFormatFilter)
    }

    func testFormatWordBeforeKeyword() {
        // 用户原话：「ppt 测试报告」也要能出结果 —— 顺序不该影响解析。
        let q = parse("ppt 测试报告")
        XCTAssertEqual(q.terms, ["测试报告"])
        XCTAssertEqual(q.extensions, ["ppt", "pptx"])
    }

    func testKeywordTextStripsFormatWords() {
        XCTAssertEqual(parse("2026 测试报告 pdf").keywords, "2026 测试报告")
        XCTAssertEqual(parse("月度 总结 xlsx").keywords, "月度 总结")
    }

    // MARK: - 同族连带（用户拍板）

    func testFamilyExpansionCoversBothGenerations() {
        XCTAssertEqual(parse("报告 ppt").extensions, ["ppt", "pptx"])
        XCTAssertEqual(parse("报告 doc").extensions, ["doc", "docx"])
        XCTAssertEqual(parse("报告 xls").extensions, ["xls", "xlsx"])
        XCTAssertEqual(parse("报告 jpg").extensions, ["jpg", "jpeg"])
    }

    func testRedundantFormatWordsDeduplicated() {
        // doc 连带出 docx，再显式写一次 docx 不该重复出现第二次。
        //
        // ⚠️ 这里用 doc 族而不是 ppt 族：受控回归的变异是**一起**应用的，
        // 「同族连带被去掉」那处变异改的正好是 ppt 族，用它做样本的话
        // 两个变异会互相抵消，这条锁就形同虚设（实测踩到过一次）。
        XCTAssertEqual(parse("报告 doc docx").extensions, ["doc", "docx"])
    }

    // MARK: - 1 代的点写法兼容

    func testDottedFormKeepsKeywordAndExtension() {
        let q = parse("测试报告.ppt")
        XCTAssertEqual(q.terms, ["测试报告"])
        XCTAssertEqual(q.extensions, ["ppt", "pptx"])
    }

    func testDottedWildcardDropsKeyword() {
        let q = parse("*.dwg")
        XCTAssertTrue(q.terms.isEmpty)
        XCTAssertEqual(q.extensions, ["dwg"])
    }

    func testDottedUnknownExtensionStillHonoredAsExplicitIntent() {
        // 不在白名单，但用户写了「名字.后缀」——这是显式意图，按格式处理，
        // 且不连带（`foo` 不该被展开成 `foo/foox`）。
        let q = parse("报告.foo")
        XCTAssertEqual(q.terms, ["报告"])
        XCTAssertEqual(q.extensions, ["foo"])
    }

    // MARK: - 中文类别词

    func testCategoryWordExpandsToWholeClass() {
        let docs = parse("测试报告 文档").extensions
        XCTAssertTrue(docs.contains("doc") && docs.contains("docx") && docs.contains("pdf"))
        let images = parse("现场 图片").extensions
        XCTAssertTrue(images.contains("jpg") && images.contains("png"))
        let archives = parse("备份 压缩包").extensions
        XCTAssertTrue(archives.contains("zip") && archives.contains("rar"))
    }

    func testCategoryWordKeepsKeyword() {
        XCTAssertEqual(parse("测试报告 视频").keywords, "测试报告")
    }

    // MARK: - 不该被当格式的情况

    func testNumericSuffixStaysInKeyword() {
        // 吃掉 `10` 会让「2026.10」变成「2026」——日期、版本号必须原样保留。
        let q = parse("2026.10 报告")
        XCTAssertEqual(q.terms, ["2026.10", "报告"])
        XCTAssertTrue(q.extensions.isEmpty)
        XCTAssertEqual(parse("v1.2").terms, ["v1.2"])
    }

    func testChineseAfterDotIsNotExtension() {
        XCTAssertEqual(parse("最终版.修改").terms, ["最终版.修改"])
    }

    func testGenericWordFileIsNotCategory() {
        // 「文件」不是一类格式。当类别词会让「文件管理」只剩文档类结果。
        let q = parse("文件 管理")
        XCTAssertEqual(q.terms, ["文件", "管理"])
        XCTAssertTrue(q.extensions.isEmpty)
    }

    func testUnknownWordStaysKeyword() {
        let q = parse("报告 abc")
        XCTAssertEqual(q.terms, ["报告", "abc"])
        XCTAssertTrue(q.extensions.isEmpty)
    }

    func testPlainKeywordQueryHasNoFormatFilter() {
        let q = parse("测试报告")
        XCTAssertEqual(q.extensions, [])
        XCTAssertFalse(q.hasFormatFilter)
    }

    func testEmptyInput() {
        XCTAssertTrue(parse("").isEmpty)
        XCTAssertTrue(parse("   ").isEmpty)
    }

    // MARK: - 其它写法

    func testExplicitPrefix() {
        XCTAssertEqual(parse("报告 ext:ppt").extensions, ["ppt", "pptx"])
        XCTAssertEqual(parse("报告 ext:ppt").terms, ["报告"])
    }

    func testCaseInsensitive() {
        XCTAssertEqual(parse("报告 PPT").extensions, ["ppt", "pptx"])
        XCTAssertEqual(parse("报告 PDF").extensions, ["pdf"])
    }

    func testMultipleFormatWords() {
        XCTAssertEqual(parse("报告 ppt pdf").extensions, ["ppt", "pptx", "pdf"])
    }

    func testOnlyFormatWordLeavesKeywordEmpty() {
        // 只输入格式 ⇒ 列出该格式的全部文件，关键词为空是**预期**，不是解析失败。
        let q = parse("ppt")
        XCTAssertTrue(q.terms.isEmpty)
        XCTAssertEqual(q.extensions, ["ppt", "pptx"])
        XCTAssertFalse(q.isEmpty)
    }

    func testZipIsExtensionNotCategory() {
        // `zip` 是具体扩展名，不能被当成「压缩包」整类。
        XCTAssertEqual(parse("备份 zip").extensions, ["zip"])
    }

    // MARK: - 词汇表自洽

    func testEveryFamilyKeyIsKnownExtension() {
        let known = FileFormatVocabulary.knownExtensions
        for (key, values) in FileFormatVocabulary.families {
            XCTAssertTrue(known.contains(key), "连带族的键 \(key) 必须在白名单里")
            for value in values { XCTAssertTrue(known.contains(value)) }
        }
    }

    func testCategoryValuesAreKnownExtensions() {
        let known = FileFormatVocabulary.knownExtensions
        for (word, values) in FileFormatVocabulary.categories {
            XCTAssertFalse(values.isEmpty, "类别词 \(word) 不能映射到空集合")
            for value in values { XCTAssertTrue(known.contains(value), "\(word) 的 \(value) 不在白名单") }
        }
    }

    // MARK: - 结果行匹配

    func testMatchesHonorsFamily() {
        let q = parse("测试报告 ppt")
        XCTAssertTrue(q.matches("测试报告.ppt"))
        XCTAssertTrue(q.matches("测试报告.PPTX"))
        XCTAssertFalse(q.matches("测试报告.docx"))
        XCTAssertFalse(q.matches("测试报告"))
    }

    func testMatchesWithoutFormatFilterPassesEverything() {
        XCTAssertTrue(parse("测试报告").matches("随便什么.xyz"))
    }

    func testDotFileNameHasNoExtension() {
        XCTAssertEqual(ParsedSearchQuery.extensionOf(".gitignore"), "")
        XCTAssertEqual(ParsedSearchQuery.extensionOf("报告.PDF"), "pdf")
    }

    func testPlainFactoryKeepsWholeText() {
        let q = ParsedSearchQuery.plain("测试报告 ppt")
        XCTAssertEqual(q.terms, ["测试报告", "ppt"])
        XCTAssertTrue(q.extensions.isEmpty)
    }
}
