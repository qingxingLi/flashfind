import XCTest
@testable import FlashFindCore

/// 结果批合并：顺序、去重、元数据回填，以及「分批并入 == 一次排完」。
final class SearchResultMergeTests: XCTestCase {

    private func row(_ id: String, _ name: String, rank: Int = 3,
                     path: String? = nil, localURL: URL? = nil) -> SearchResult {
        var r = SearchResult(id: id, name: name, relativePath: path ?? "/共享/\(name)",
                             sourceID: "nas_x", sourceName: "测试 NAS",
                             kind: "file", size: nil, localURL: localURL, rank: rank)
        r.modifiedDate = Date(timeIntervalSince1970: 1_793_000_000)
        return r
    }

    func testEmptyIncomingKeepsArrayUntouched() {
        let existing = [row("b", "b.pdf"), row("a", "a.pdf", rank: 1)]
        let merged = SearchResultMerge.apply(existing: existing, incoming: [])
        XCTAssertEqual(merged.map(\.id), existing.map(\.id), "空批次不该改变任何东西")
    }

    func testNewRowsAreSortedByRankThenName() {
        let existing = [row("x", "zeta.pdf", rank: 3)]
        let merged = SearchResultMerge.apply(existing: existing, incoming: [
            row("b", "beta.pdf", rank: 3),
            row("a", "alpha.pdf", rank: 1),
            row("c", "alpha.pdf", rank: 2)
        ])
        XCTAssertEqual(merged.map(\.id), ["a", "c", "b", "x"])
    }

    /// 设备重复发同一行：只替换，不许出现两条。
    func testDuplicateIDReplacesInsteadOfAppending() {
        let existing = [row("a", "a.pdf"), row("b", "b.pdf")]
        let merged = SearchResultMerge.apply(existing: existing, incoming: [row("a", "a.pdf")])
        XCTAssertEqual(merged.count, 2, "同 id 只能有一条")
        XCTAssertEqual(merged.map(\.id), ["a", "b"], "纯替换不该改变顺序")
    }

    /// 后台补全元数据（挂载路径、能否打开）会走第二遍：**不许重排**。
    ///
    /// 这条守的是 `apply` 的判据是「排序键变没变」，而不是调用方口头声称的
    /// 「这是一次元数据更新」—— 后者是上层的 intent，前者才是事实。
    func testMetadataFillInDoesNotReorder() {
        let local = URL(fileURLWithPath: "/Volumes/共享/a.pdf")
        let existing = [row("a", "a.pdf", rank: 1), row("b", "b.pdf", rank: 3), row("c", "c.pdf", rank: 3)]
        var filled = existing[2]
        filled.localURL = local
        filled.openTarget = .mountedFile(local)
        filled.canOpen = true
        let merged = SearchResultMerge.apply(existing: existing, incoming: [filled])
        XCTAssertEqual(merged.map(\.id), ["a", "b", "c"], "只补字段，顺序必须原样")
        XCTAssertEqual(merged[2].localURL, local, "补上的字段要真的写进去")
        XCTAssertTrue(merged[2].canOpen)
    }

    /// 名字变了就是换了排序位置 —— 不能因为「是同一批」就留在原地。
    func testRenamedRowIsResorted() {
        let existing = [row("a", "aaa.pdf", rank: 3), row("b", "mmm.pdf", rank: 3)]
        let renamed = row("a", "zzz.pdf", rank: 3)
        let merged = SearchResultMerge.apply(existing: existing, incoming: [renamed])
        XCTAssertEqual(merged.map(\.id), ["b", "a"], "改名后要按新名字重排")
    }

    /// ★ 核心不变量：分批并入的结果 == 一次性排完的结果。
    ///
    /// 界面上就是分批来的；如果两者不等，用户会看到「越搜越乱的顺序」。
    func testMergingInBatchesEqualsSingleSort() {
        var rows: [SearchResult] = []
        for i in 0..<300 {
            rows.append(row("id-\(i)", "报告-\(i % 37).pdf", rank: i % 5))
        }
        var state = 20261027
        func nextRandom(_ bound: Int) -> Int {
            state = (state &* 1103515245 &+ 12345) & 0x7FFF_FFFF
            return state % bound
        }
        var shuffled = rows
        for i in stride(from: shuffled.count - 1, to: 0, by: -1) {
            shuffled.swapAt(i, nextRandom(i + 1))
        }

        let expected = shuffled.sorted(by: SearchResultMerge.precedes).map(\.id)
        var accumulated: [SearchResult] = []
        var offset = 0
        while offset < shuffled.count {
            let size = 1 + nextRandom(17)
            let slice = Array(shuffled[offset..<min(offset + size, shuffled.count)])
            accumulated = SearchResultMerge.apply(existing: accumulated, incoming: slice)
            offset += size
        }
        XCTAssertEqual(accumulated.map(\.id), expected)
    }

    /// 同 rank 同名时次序必须是确定的（旧实现用不稳定排序，两次跑可能不同）。
    func testTieBreakIsDeterministic() {
        let ties = [row("c", "同名.pdf"), row("a", "同名.pdf"), row("b", "同名.pdf")]
        let once = SearchResultMerge.apply(existing: [], incoming: ties).map(\.id)
        let twice = SearchResultMerge.apply(existing: [], incoming: ties.reversed()).map(\.id)
        XCTAssertEqual(once, ["a", "b", "c"], "同 rank 同名按 id 定序")
        XCTAssertEqual(twice, once, "同一份数据的两种到货顺序必须得到同一个次序")
    }
}
