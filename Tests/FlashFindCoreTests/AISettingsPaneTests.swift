import XCTest
@testable import FlashFindCore

/// 「AI」设置页上那两行事实的文案（Phase 9-lite）。
///
/// 这两块之所以放进 Core，是因为它们各自守着一条容易写错的区分：
///
/// * `MCPHelperStatus` —— 「没在跑」「被别人占着」「启动失败」不是同一件事；
/// * `AIHistorySummary` —— 「0 条」与「库打不开」不是同一件事。
///
/// 把它们并成一句「不可用」，用户就不知道该去修什么。
final class MCPHelperStatusTests: XCTestCase {

    /// 只有 `running` 算健康。`ownedByAnotherInstance` 不算故障，但对**这一份**
    /// 闪寻来说服务确实不在这里——所以不能点亮绿灯。
    func testListeningIsTheOnlyHealthyState() {
        XCTAssertTrue(MCPHelperStatus.running.isHealthy)
        XCTAssertFalse(MCPHelperStatus.notStarted.isHealthy)
        XCTAssertFalse(MCPHelperStatus.ownedByAnotherInstance.isHealthy)
        XCTAssertFalse(MCPHelperStatus.failed("port busy").isHealthy)
    }

    /// 四种取值各有各的说法——不许两种状态读出同一句话。
    func testEveryStartResultHasItsOwnWords() {
        let all: [MCPHelperStatus] = [
            .running, .notStarted, .ownedByAnotherInstance, .failed("拒绝连接"),
        ]
        XCTAssertEqual(all.map(\.title),
                       ["正常运行", "未启动", "被另一份闪寻占用", "启动失败"])
        XCTAssertEqual(Set(all.map(\.detail)).count, all.count,
                       "四种状态的说明必须互不相同，否则用户分不出该修哪个")
        for status in all {
            XCTAssertFalse(status.detail.isEmpty, "\(status.title) 没有说明")
        }
    }

    /// 「另一份闪寻占着」必须说清是**别人的**。写成「已连接」会让用户以为
    /// 自己在设置里改的授权已经生效，其实生效的是另一份。
    func testTheOccupiedStateSaysAnotherInstanceOwnsIt() {
        XCTAssertTrue(MCPHelperStatus.ownedByAnotherInstance.detail.contains("另一份"))
    }

    /// 失败原因原样转述，不加工、不吞掉。
    func testAFailedStartCarriesTheReasonVerbatim() {
        let reason = "bind: Address already in use"
        XCTAssertTrue(MCPHelperStatus.failed(reason).detail.contains(reason))
    }

    /// 没走到启动那一步，是「未启动」，不是「正常」也不是「失败」。
    func testNoStartResultIsNotStarted() {
        XCTAssertEqual(MCPHelperStatus(start: nil), .notStarted)
        XCTAssertEqual(MCPHelperStatus(start: .listening("/tmp/x.sock")), .running)
        XCTAssertEqual(MCPHelperStatus(start: .ownedByAnotherInstance), .ownedByAnotherInstance)
        XCTAssertEqual(MCPHelperStatus(start: .failed("x")), .failed("x"))
    }
}

/// 「AI 历史」那一行。
final class AIHistorySummaryTests: XCTestCase {

    /// ★ 库打不开 ≠ 0 条。前者是故障（`recent` 只会返回空），
    /// 后者是正常空库（可以点清空，虽然没东西可清）。
    func testAMissingStoreIsUnavailableNotZero() {
        let broken = AIHistorySummary(isRecording: true, eventCount: nil)
        XCTAssertTrue(broken.isUnavailable)
        XCTAssertEqual(broken.title, "不可用")
        XCTAssertFalse(broken.canClear, "打不开的库不该给一个「清空」按钮")
        XCTAssertNotEqual(broken.title, AIHistorySummary(isRecording: true, eventCount: 0).title,
                          "「不可用」与「已开启」不能读成同一句")
    }

    /// 开与关说的是两件事：开=在记，关=不再记但旧记录还在。
    func testRecordingAndStoppedSayDifferentThings() {
        let on = AIHistorySummary(isRecording: true, eventCount: 42)
        let off = AIHistorySummary(isRecording: false, eventCount: 42)
        XCTAssertEqual(on.title, "已开启")
        XCTAssertEqual(off.title, "已关闭")
        XCTAssertNotEqual(on.detail, off.detail)
        // 关着的时候必须说清旧记录**还在**：不然用户会以为关开关就等于删了历史。
        XCTAssertTrue(off.detail.contains("仍保留"), "关闭状态下没说清旧记录还在：\(off.detail)")
        XCTAssertTrue(on.detail.contains("42"), "记录中的说明要带上真实条数")
        XCTAssertTrue(off.detail.contains("42"), "关闭状态的说明也要带上真实条数")
    }

    /// 空库不给清空按钮：点了也不会发生任何事。
    func testEmptyHistoryCannotBeCleared() {
        XCTAssertFalse(AIHistorySummary(isRecording: true, eventCount: 0).canClear)
        XCTAssertTrue(AIHistorySummary(isRecording: true, eventCount: 1).canClear)
    }

    /// 三种结局必须分得开。折成一个 Bool，「删失败」就会被显示成「已清空」。
    func testClearOutcomeKeepsSuccessApartFromFailure() {
        let outcomes: [AIHistoryClearOutcome] = [.cleared(12), .unavailable, .failed]
        XCTAssertEqual(Set(outcomes.map(String.init(describing:))).count, 3)
        if case .cleared(let count) = outcomes[0] {
            XCTAssertEqual(count, 12, "成功要说清删了多少条")
        } else {
            XCTFail("cleared 丢了条数")
        }
    }

    /// 二次确认必须说明「清的是什么、不清什么」——映射表不动，是这条功能的核心承诺。
    func testTheConfirmationPromisesTheFileIDsSurvive() {
        XCTAssertTrue(AIHistoryText.clearDetail.contains("不可恢复"))
        XCTAssertTrue(AIHistoryText.clearDetail.contains("文件编号"),
                      "确认框没说清「文件编号仍然有效」，用户会以为清历史等于让 AI 失忆")
        XCTAssertTrue(AIHistoryText.cleared(7).contains("7"))
    }
}
