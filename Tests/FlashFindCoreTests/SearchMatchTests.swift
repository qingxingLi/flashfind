import XCTest
@testable import FlashFindCore

/// 模糊匹配：等级、分值、以及「哪些必须不命中」。
///
/// 这组用例的重点不是「能命中」，而是**边界**：模糊一旦放宽过头，
/// 搜什么都满屏，用户会直接关掉这个功能。所以每条「不命中」的用例
/// 都在守一个具体的阈值。
final class SearchMatchTests: XCTestCase {

    private func grade(_ name: String, _ query: String, path: String = "") -> SearchMatchGrade {
        SearchMatch.evaluate(name: name, path: path, query: query).grade
    }

    private func value(_ name: String, _ query: String, path: String = "") -> Double {
        SearchMatch.evaluate(name: name, path: path, query: query).value
    }

    // MARK: - 四档旧口径不变

    func testExactPrefixTermsKeepTheirOldGrades() {
        XCTAssertEqual(grade("report.pdf", "report.pdf"), .exact)
        XCTAssertEqual(grade("report-2026.pdf", "report"), .prefix)
        XCTAssertEqual(grade("annual report 2026.pdf", "report annual"), .terms)
        XCTAssertEqual(grade("scan001.pdf", "报告", path: "/共享/报告/scan001.pdf"), .pathOnly)
        XCTAssertEqual(grade("scan001.pdf", "完全不像"), .none)
    }

    /// 等级 → 旧 rank 的映射必须与 1.1.x 完全一致（MCP 的 `ranking score`
    /// 与既有排序断言都靠它）。
    func testLegacyRankMappingIsUnchanged() {
        XCTAssertEqual(SearchMatchGrade.exact.legacyRank, 0)
        XCTAssertEqual(SearchMatchGrade.prefix.legacyRank, 1)
        XCTAssertEqual(SearchMatchGrade.terms.legacyRank, 2)
        XCTAssertEqual(SearchMatchGrade.pathOnly.legacyRank, 3)
        XCTAssertEqual(SearchMatchGrade.subsequence.legacyRank, 4)
        XCTAssertEqual(SearchMatchGrade.partial.legacyRank, 4)
        XCTAssertEqual(SearchMatchGrade.typo.legacyRank, 4)
        XCTAssertEqual(SearchMatchGrade.none.legacyRank, 4)
    }

    // MARK: - 第 1 层「同名」= 去扩展名之后完全相等（2026-10-28 用户定）

    /// 「报告.pdf」搜「报告」是**同名**，不是前缀。
    ///
    /// 改口记录：2026-10-28 之前这条断言是 `.prefix`（`rank 1`），
    /// 用户定下「同名优先」后改为 `.exact`（`rank 0`）。
    func testSameNameIgnoresExtension() {
        XCTAssertEqual(grade("报告.pdf", "报告"), .exact)
        XCTAssertEqual(grade("报告", "报告"), .exact)
        XCTAssertEqual(grade("报告.txt", "报告"), .exact)
        XCTAssertEqual(SearchResultRanker.rank(name: "报告.pdf", path: "/共享/报告.pdf", query: "报告"), 0)
    }

    /// 「含查询词但不等于」不算同名——用户举的例子就是「年度报告」不该跟「报告」同级。
    func testNameThatMerelyContainsTheQueryIsNotExact() {
        XCTAssertEqual(grade("年度报告.pdf", "报告"), .terms)
        XCTAssertEqual(grade("报告说明.pdf", "报告"), .prefix)
    }

    /// ★ 只剥文件名的扩展名，不剥查询串的：`report.2026` 里的 `.2026` 是名字的一部分。
    func testQueryIsNeverStrippedOfItsOwnDottedPart() {
        XCTAssertNotEqual(grade("report.pdf", "report.2026"), .exact,
                          "剥掉查询串的 `.2026` 会造出「搜 report.2026 命中 report.pdf」的假同名")
    }

    // MARK: - 子序列（模糊）

    /// 用户最常用的一种模糊写法：每个词打首字母。
    func testWordInitialAbbreviationMatches() {
        XCTAssertEqual(grade("best_seller_report.xlsx", "bsr"), .subsequence)
        let abbreviation = value("best_seller_report.xlsx", "bsr")
        XCTAssertGreaterThan(abbreviation, value("unrelated-file.pdf", "bsr"),
                             "缩写命中必须排在完全不像的文件前面")
    }

    /// 连续但夹杂别的字符（`ace` → `aXcXe`）也应该命中。
    func testLooseSubsequenceMatchesWithEnoughCompactness() {
        XCTAssertEqual(grade("abcdefghij.pdf", "ace"), .subsequence)
    }

    /// ★ 阈值守门：字符摊得太开就不算命中。
    ///
    /// `abc` 在 60 个字符里各出现一次，任何人都不认为这是「模糊匹配」，
    /// 但纯子序列算法会认。没有这条阈值，搜三个字母等于搜全部文件。
    func testSubsequenceRejectsCharactersSpreadTooFarApart() {
        let spread = "a" + String(repeating: "x", count: 30) + "b"
            + String(repeating: "y", count: 30) + "c.pdf"
        XCTAssertEqual(grade(spread, "abc"), .none)
    }

    /// 两个字符的查询不做子序列：噪声远大于价值。
    func testTwoCharacterQueryDoesNotFuzzyMatch() {
        XCTAssertEqual(grade("best_seller_report.xlsx", "bs"), .none)
    }

    // MARK: - 第 3 层「匹配字符多的优先」（2026-10-28 用户定）

    /// 用户原话：「一个文件七个字，我搜四个字这个文件都有，另一个文件只有
    /// 三个字符合，四个字的排前边」——**命中率高的在前**。
    func testMoreMatchedCharactersRankHigher() {
        let full = SearchMatch.evaluate(name: "项目说明报告.pdf", query: "项目报告")
        let threeOfFour = SearchMatch.evaluate(name: "项目汇报.pdf", query: "项目报告")

        XCTAssertEqual(full.grade, .subsequence, "四个字全中，按顺序但是不连续")
        XCTAssertEqual(threeOfFour.grade, .partial, "四个字中三个（命中率 0.75）")
        XCTAssertGreaterThan(full.value, threeOfFour.value)
    }

    /// 同一命中率时比紧凑：命中的字挨得近的更可信。
    func testSameCoveragePrefersTighterSpan() {
        let tight = SearchMatch.evaluate(name: "项目x报告.pdf", query: "项目报告")
        let loose = SearchMatch.evaluate(name: "项x目x报x告.pdf", query: "项目报告")
        XCTAssertEqual(tight.grade, .subsequence)
        XCTAssertEqual(loose.grade, .subsequence)
        XCTAssertGreaterThan(tight.value, loose.value)
    }

    /// ★ 半命中的两条准入线（新增档的防噪声闸，不是放宽旧阈值）：
    /// 命中字符不足 3 个、或命中率低于 0.6，一律不算命中。
    func testPartialMatchRejectsLowCoverage() {
        // 4 个字里只中 2 个（2 < 3）
        XCTAssertEqual(grade("项目总结.pdf", "项目报告"), .none)
        // 7 个字里中 4 个：0.57 < 0.6
        XCTAssertEqual(grade("axbxcxd.pdf", "abcdefg"), .none)
    }

    /// 全命中但摊得太开仍然是**不命中**，不许从半命中那条路混进来。
    func testSpreadOutFullMatchNeverDegradesToPartial() {
        let spread = "a" + String(repeating: "x", count: 30) + "b"
            + String(repeating: "y", count: 30) + "c.pdf"
        XCTAssertEqual(grade(spread, "abc"), .none)
    }

    // MARK: - 容错（打错字）

    /// 顺序打错（子序列能过）→ 子序列档，不是 typo 档。
    func testTransposedCharactersLandInSubsequenceNotTypo() {
        XCTAssertEqual(grade("flashfind.pdf", "flshfind"), .subsequence,
                       "少一个字母仍然是有序子序列，不该走到编辑距离那一档")
    }

    /// 真的打错：插入了一个不该有的字符，且破坏了子序列顺序。
    func testTypoIsToleratedWithinDistance() {
        XCTAssertEqual(grade("flashfind.pdf", "flazhfind"), .typo)
        XCTAssertEqual(grade("quarterly.pdf", "quartxrly"), .typo)
    }

    /// ★ 短查询不做容错：`cat` 与 `car` 只差一个字母，但它们是两个词。
    func testShortQueryNeverGetsTypoTolerance() {
        XCTAssertEqual(grade("car.pdf", "cat"), .none)
    }

    /// 差得太多就不算「打错」，而是「不是它」。
    func testDistantWordsAreNotTypos() {
        XCTAssertEqual(grade("flashfind.pdf", "flzzzfind"), .none)
    }

    // MARK: - 中文

    func testChineseSubsequenceMatches() {
        XCTAssertEqual(grade("2026年度报告.pdf", "年报告"), .subsequence)
    }

    /// 中文查询通常只有两三个字，子序列之外不该再放宽。
    func testChineseTwoCharacterQueryStaysStrict() {
        XCTAssertEqual(grade("2026年度报告.pdf", "季度"), .none)
    }

    // MARK: - 分值单调性

    /// 分值必须与等级同向：整名 > 前缀 > 词命中 > 子序列 > 半命中 > 容错 > 路径 > 不像。
    ///
    /// 这条是给排序和「取前 200」用的。四个值一旦乱序，界面上的顺序就会
    /// 出现「前缀命中的文件排在整名命中前面」这种说不通的结果。
    /// 2026-10-28 加入「半命中」档后区间全部重排（旧区间彼此有重叠）。
    func testScoresAreMonotonicAcrossGrades() {
        let exact = value("report.pdf", "report.pdf")
        let prefix = value("report-2026.pdf", "report")
        let terms = value("2026 annual report.pdf", "annual report")
        let subsequence = value("best_seller_report.xlsx", "bsr")
        let partial = value("项目汇报.pdf", "项目报告")
        let typo = value("flashfind.pdf", "flazhfind")
        let pathOnly = value("scan001.pdf", "报告", path: "/共享/报告/scan001.pdf")
        let none = value("scan001.pdf", "完全不像")

        XCTAssertEqual(exact, 1.0, accuracy: 0.0001)
        XCTAssertGreaterThan(exact, prefix)
        XCTAssertGreaterThan(prefix, terms)
        XCTAssertGreaterThan(terms, subsequence)
        XCTAssertGreaterThan(subsequence, partial)
        XCTAssertGreaterThan(partial, typo)
        XCTAssertGreaterThan(typo, pathOnly)
        XCTAssertGreaterThan(pathOnly, none)
        XCTAssertEqual(none, 0, accuracy: 0.0001)

        // 区间本身也锁住：任何一档跨到别档里去都要在这里红。
        XCTAssertGreaterThanOrEqual(subsequence, 0.60)
        XCTAssertLessThanOrEqual(subsequence, 0.745)
        XCTAssertGreaterThanOrEqual(partial, 0.46)
        XCTAssertLessThan(partial, 0.55)
        XCTAssertLessThanOrEqual(typo, 0.45)
    }

    /// 空查询与纯空白：不命中，也不许崩。
    func testEmptyQueryIsNoMatch() {
        XCTAssertEqual(SearchMatch.evaluate(name: "a.pdf", query: ""), .none)
        XCTAssertEqual(SearchMatch.evaluate(name: "a.pdf", query: "   "), .none)
    }

    /// 大小写与变音符号照旧不敏感（这条与 1.1.x 一致）。
    ///
    /// 改口记录：2026-10-28 起「去掉扩展名后完全相等」算同名，
    /// `Résumé.PDF` 搜 `resume` 由 `.prefix` 变成 `.exact`。
    func testCaseAndDiacriticsAreIgnored() {
        XCTAssertEqual(grade("Résumé.PDF", "resume"), .exact)
    }

    // MARK: - `SearchResultRanker` 的对外口径

    /// `SearchResultRanker.rank` 仍给 0…4，且与新等级一致。
    func testRankerStillReportsLegacyRank() {
        XCTAssertEqual(SearchResultRanker.rank(name: "report.pdf", path: "", query: "report.pdf"), 0)
        XCTAssertEqual(SearchResultRanker.rank(name: "report-2026.pdf", path: "", query: "report"), 1)
        XCTAssertEqual(SearchResultRanker.rank(name: "2026 annual report.pdf", path: "", query: "annual report"), 2)
        XCTAssertEqual(SearchResultRanker.rank(name: "scan001.pdf", path: "/共享/报告/scan001.pdf", query: "报告"), 3)
        // 模糊命中也落在 4（旧注释里的「其它，仍然会显示」）。
        XCTAssertEqual(SearchResultRanker.rank(name: "best_seller_report.xlsx", path: "", query: "bsr"), 4)
        XCTAssertEqual(SearchResultRanker.rank(name: "scan001.pdf", path: "", query: "完全不像"), 4)
    }
}
