import XCTest
@testable import FlashFindCore

/// 综合分：匹配度 0.72 + 新近度 0.28。**数字都是产品行为**，逐条锁住。
final class SearchRankingTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_793_000_000)

    // MARK: - 新近度

    func testRecencyIsOneForJustModified() {
        XCTAssertEqual(SearchRanking.recency(modified: now, now: now), 1, accuracy: 1e-9)
    }

    /// 半衰期就是「过了 180 天掉到一半」——这条同时锁住常量与指数公式。
    func testRecencyHalvesAtHalfLife() {
        let halfLifeAgo = now.addingTimeInterval(-SearchRanking.recencyHalfLife)
        XCTAssertEqual(SearchRanking.recency(modified: halfLifeAgo, now: now), 0.5, accuracy: 1e-9)
    }

    /// 没有修改时间不等于「很旧」：给一个低于中位、高于 0 的定值。
    func testUndatedResultGetsTheNeutralRecency() {
        XCTAssertEqual(SearchRanking.recency(modified: nil, now: now),
                       SearchRanking.undatedRecency, accuracy: 1e-9)
        XCTAssertGreaterThan(SearchRanking.undatedRecency, 0)
        XCTAssertLessThan(SearchRanking.undatedRecency, 0.5)
    }

    /// 设备时间比本机快（时钟漂移）时不能算出 > 1 的新近度。
    func testFutureTimestampIsClampedToOne() {
        let future = now.addingTimeInterval(86_400 * 30)
        XCTAssertEqual(SearchRanking.recency(modified: future, now: now), 1, accuracy: 1e-9)
    }

    func testVeryOldFileApproachesZero() {
        let decadeAgo = now.addingTimeInterval(-86_400 * 3650)
        XCTAssertLessThan(SearchRanking.recency(modified: decadeAgo, now: now), 0.001)
    }

    // MARK: - 综合分

    func testWeightsSumToOneAndScoreStaysInRange() {
        XCTAssertEqual(SearchRanking.matchWeight + SearchRanking.recencyWeight, 1.0, accuracy: 1e-9)
        XCTAssertEqual(SearchRanking.score(match: 1, modified: now, now: now), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SearchRanking.score(match: 0, modified: nil, now: now),
                       SearchRanking.recencyWeight * SearchRanking.undatedRecency, accuracy: 1e-9)
    }

    /// 越界的匹配分要被钳住，不许算出一个 > 1 的总分去压过一切。
    func testOutOfRangeMatchValueIsClamped() {
        XCTAssertEqual(SearchRanking.score(match: 2.5, modified: now, now: now), 1.0, accuracy: 1e-9)
        XCTAssertEqual(SearchRanking.score(match: -3, modified: now, now: now),
                       SearchRanking.recencyWeight, accuracy: 1e-9)
    }

    /// ★ 匹配度权重明显更大：一模一样的老文件必须排在「只是包含、
    /// 但昨天刚改过」的文件前面。
    func testMatchQualityOutweighsRecencyWithinReasonableRanges() {
        let decadeOld = now.addingTimeInterval(-86_400 * 3650)
        let exactButOld = SearchRanking.score(match: 1.0, modified: decadeOld, now: now)
        let weakButFresh = SearchRanking.score(match: 0.40, modified: now, now: now)
        XCTAssertGreaterThan(exactButOld, weakButFresh,
                             "「只沾边但很新」不能压过「整名命中但很老」")
    }

    /// 匹配度完全相同时，新文件在前。
    func testSameMatchQualityPrefersNewerFile() {
        let fresh = SearchRanking.score(match: 0.76, modified: now, now: now)
        let old = SearchRanking.score(match: 0.76, modified: now.addingTimeInterval(-86_400 * 400), now: now)
        XCTAssertGreaterThan(fresh, old)
    }

    /// 便利入口给的 rank / 等级 / 分数必须与分开算的一致。
    ///
    /// 改口记录：2026-10-28 起「报告.pdf」搜「报告」算**同名**（去扩展名相等），
    /// 所以这里由 `rank 1 / .prefix` 改为 `rank 0 / .exact`。
    func testConvenienceEntryMatchesTheSeparateCalls() {
        let combined = SearchRanking.score(name: "报告.pdf", path: "/共享/报告.pdf",
                                           query: "报告", modified: now, now: now)
        XCTAssertEqual(combined.rank, 0)
        XCTAssertEqual(combined.match, .exact)
        XCTAssertEqual(combined.score,
                       SearchRanking.score(match: SearchMatch.evaluate(name: "报告.pdf",
                                                                       path: "/共享/报告.pdf",
                                                                       query: "报告").value,
                                           modified: now, now: now),
                       accuracy: 1e-9)
    }

    // MARK: - 用户定的四层优先级（2026-10-28）

    /// 原话：「同名优先 → 然后关键词在前边的优先（搜报告，报告说明的排序要比
    /// 测试报告优先）→ 匹配字符多的优先 → 最后是可能相关的」。
    ///
    /// 时间相同（同一时刻改过）时，顺序必须正好是这四层。
    func testUserPriorityLadderAtTheSameTimestamp() {
        let query = "报告"
        let names = ["报告.pdf", "报告说明.pdf", "测试报告.pdf", "扫描件.pdf"]
        let ordered = names
            .map { ($0, SearchRanking.score(name: $0, path: "/共享/" + $0, query: query,
                                            modified: now, now: now).score) }
            .sorted { $0.1 > $1.1 }
            .map(\.0)
        XCTAssertEqual(ordered, names, "同名 > 前缀 > 含词 > 不像")
    }

    /// 同一层里时间说了算：两份「同名」的文件，新的在前。
    func testWithinTheTopTierTheNewerFileWins() {
        let fresh = SearchRanking.score(name: "报告.pdf", query: "报告", modified: now, now: now)
        let old = SearchRanking.score(name: "报告.docx", query: "报告",
                                      modified: now.addingTimeInterval(-86_400 * 400), now: now)
        XCTAssertEqual(fresh.match, .exact)
        XCTAssertEqual(old.match, .exact)
        XCTAssertGreaterThan(fresh.score, old.score)
    }

    /// ★ 0.72/0.28 的**必然后果**：相邻两层之间的分差（`exact` 与 `prefix` 只差
    /// 0.72 × 0.10 = 0.072）小于时间项能拉开的 0.28 —— 于是「很新的前缀命中」
    /// 能压过「十年前的整名命中」。
    ///
    /// 这条不是 bug，是用户 2026-10-28 明确选的「时间按规定的比重来」。
    /// 哪天要「同名压倒一切」，改的是 `matchWeight` 或这几档的分值，
    /// 而这条用例就是必须同时改口的那一个。
    func testRecencyCanOutweighTheGapBetweenAdjacentTiers() {
        let decadeOld = now.addingTimeInterval(-86_400 * 3650)
        let exactButOld = SearchRanking.score(name: "报告.pdf", query: "报告",
                                              modified: decadeOld, now: now)
        let prefixButFresh = SearchRanking.score(name: "报告说明.pdf", query: "报告",
                                                 modified: now, now: now)
        XCTAssertGreaterThan(prefixButFresh.score, exactButOld.score,
                             "按现行 0.72/0.28，时间确实能把相邻两层翻过来")
    }
}
