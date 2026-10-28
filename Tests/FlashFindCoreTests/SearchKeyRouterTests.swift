import XCTest
@testable import FlashFindCore

/// 锁定实机反馈：**搜索框打不出空格**（后用户复测）。
///
/// 根因不在 TextField，也不在输入法，而在浮窗的按键监视器：
///
///   `SearchKeyboardScope` 用 `NSEvent.addLocalMonitorForEvents(.keyDown)`
///   统一处理快捷键，其中 `case 49: self.quickLook?(); return nil` 是
///   **无条件**的 —— 只要 `inScope`（= 焦点在输入框 **或** 在结果表）
///   成立就把空格吞掉转成预览。于是「搜索框里敲空格」永远不会落到
///   文本系统，用户看到的就是「空格键失灵」。
///
/// 期望语义（对齐 macOS Spotlight）：空格是文件名的常见字符，
/// 在输入框里必须放行；只有焦点在结果列表时才是快速查看。
final class SearchKeyRouterTests: XCTestCase {

    private func context(keyCode: UInt16,
                         command: Bool = false,
                         other: Bool = false,
                         inSearchField: Bool = false,
                         inResults: Bool = false,
                         composing: Bool = false,
                         hasToken: Bool = false,
                         keywordEmpty: Bool = true) -> SearchKeyContext {
        SearchKeyContext(keyCode: keyCode, hasCommand: command, hasOtherModifier: other,
                         inSearchField: inSearchField, inResults: inResults, isComposing: composing,
                         hasSearchToken: hasToken, keywordEmpty: keywordEmpty)
    }

    // MARK: - 空格（本次修复的核心）

    /// 回归：搜索框聚焦时空格必须放行，不能被当成快速查看。
    func testSpaceInSearchFieldPassesThrough() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 49, inSearchField: true)), .passThrough)
    }

    /// 结果列表聚焦时空格仍然是快速查看。
    func testSpaceInResultsTriggersQuickLook() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 49, inResults: true)), .quickLook)
    }

    /// 两个焦点都不在搜索区（例如焦点在别处）时，空格同样放行。
    func testSpaceWithoutScopePassesThrough() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 49)), .passThrough)
    }

    /// 搜「2026 10 10」这类带空格的查询：每个空格都得原样进文本。
    func testSpaceIsUsableInRealisticQuery() {
        let allPassThrough = "2026 10 10".allSatisfy { character in
            character == " "
                ? SearchKeyRouter.route(context(keyCode: 49, inSearchField: true)) == .passThrough
                : true
        }
        XCTAssertTrue(allPassThrough)
    }

    // MARK: - 其余快捷键不能被这次改动带坏

    func testArrowKeysMoveSelectionAcrossSearchScope() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 125, inSearchField: true)), .move(1))
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 126, inSearchField: true)), .move(-1))
        // 焦点已在结果表时同样由我们接管：事件被消费后 List 收不到，
        // 不会出现「移一格变移两格」。
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 125, inResults: true)), .move(1))
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 126, inResults: true)), .move(-1))
        // 焦点不在搜索区时一律不碰。
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 125)), .passThrough)
    }

    func testReturnOpensInBothScopes() {
        for inSearch in [true, false] {
            XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 36, inSearchField: inSearch,
                                                       inResults: !inSearch)), .submit)
        }
    }

    func testEscapeHides() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 53, inSearchField: true)), .hide)
    }

    /// ⌘↩ / ⌘C 在浮窗内任何位置都生效，不要求焦点在搜索区。
    func testCommandShortcutsWorkWithoutScope() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 36, command: true)), .reveal)
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 8, command: true)), .copyPath)
    }

    /// ⌘ 命中不了的组合一律放行，免得抢走系统的 ⌘⇧F 等。
    func testUnhandledCommandCombosPassThrough() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 3, command: true, inSearchField: true)),
                       .passThrough)
    }

    /// 带修饰键（⌥⌃⇧）不接管，交还系统与文本控件。
    func testModifierCombosPassThrough() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 36, other: true, inSearchField: true)),
                       .passThrough)
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 49, other: true, inSearchField: true)),
                       .passThrough)
    }

    /// 输入法组字中一切不抢，否则拼音候选会被打断。
    func testComposingNeverIntercepts() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 36, inSearchField: true, composing: true)),
                       .passThrough)
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 49, inSearchField: true, composing: true)),
                       .passThrough)
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 36, command: true, composing: true)),
                       .passThrough)
    }

    /// 普通字符键（字母/数字）一律不拦——这是「搜索框能打字」的底线。
    func testPrintableKeysAreNeverSwallowed() {
        // 8=C 不带 ⌘ 时要放行，否则输不了 "c"
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 8, inSearchField: true)), .passThrough)
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 18, inSearchField: true)), .passThrough)
    }

    // MARK: - 命令模式（`/` 唤起命令面板）

    /// ★ 删除键：关键词为空且有前置限定 ⇒ 删限定。
    func testBackspaceDeletesTokenWhenKeywordIsEmpty() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 51, inSearchField: true,
                                                     hasToken: true, keywordEmpty: true)),
                       .deleteSearchToken)
    }

    /// ★ 关键词还在 ⇒ 删除键归文本编辑，不许抢（否则输入框删不动字）。
    func testBackspaceDoesNotStealWhenKeywordPresent() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 51, inSearchField: true,
                                                     hasToken: true, keywordEmpty: false)),
                       .passThrough)
    }

    /// 没有前置限定时，删除键就是普通删除。
    func testBackspacePassesThroughWithoutToken() {
        XCTAssertEqual(SearchKeyRouter.route(context(keyCode: 51, inSearchField: true,
                                                     hasToken: false, keywordEmpty: true)),
                       .passThrough)
    }

}
