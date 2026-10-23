import XCTest
@testable import FlashFindCore

/// 「关掉最后一个窗口之后怎么办」的判定。
///
/// 锁的是 2026-10-22 那次报障：OTP 账号点登录 → 向导关闭 → **应用消失**，
/// 且 `~/Library/Logs/DiagnosticReports` 里一条崩溃报告都没有。
/// 根因不是崩溃，是 macOS 的 Automatic Termination 在「零可见窗口」时回收了进程。
final class LastWindowClosePolicyTests: XCTestCase {

    // MARK: - 要不要把搜索浮窗放回来

    func testRestoresTheSearchPanelWhenNoOtherWindowIsVisible() {
        // 设置窗口已关、只剩向导：关掉向导就没窗口了，必须放回浮窗，
        // 否则屏幕上什么都没有。
        XCTAssertTrue(LastWindowClosePolicy.shouldRestoreSearchPanel(hasOtherVisibleWindow: false))
    }

    func testDoesNotStealFocusWhenAnotherWindowIsStillOpen() {
        // 从设置里点「重新登录…」进向导是常见路径：关掉向导应该回到设置窗口，
        // 而不是把搜索浮窗顶到设置前面把用户拽出上下文。
        XCTAssertFalse(LastWindowClosePolicy.shouldRestoreSearchPanel(hasOtherVisibleWindow: true))
    }

    // MARK: - 进程本身要留住

    func testAutomaticTerminationIsDisabledWithANonEmptyReason() {
        // 理由串会进统一日志。写成空串就意味着「日志里看不出是谁关掉的」，
        // 出问题时只能靠猜；写成 nil（Optional）就等于没禁用。
        let reason = LastWindowClosePolicy.automaticTerminationDisabledReason
        XCTAssertFalse(reason.isEmpty, "禁用自动终止必须留下可检索的理由")
        XCTAssertTrue(reason.contains("闪寻"), "理由要能归属到本应用：\(reason)")
    }
}
