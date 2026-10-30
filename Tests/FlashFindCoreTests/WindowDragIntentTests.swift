import XCTest
@testable import FlashFindCore

/// 「这次移动是用户拖的吗」——搜索结果窗与搜索框共用的一条判据。
///
/// 2026-10-30 报障（用户）：「把搜索框拉到屏幕下方，输入文字后搜索框直接被
/// 搜索结果盖住」。根因不在几何，而在**这条判据一直答错**：程序化摆位产生的
/// `didMove` 被记成了用户拖动，于是抬升逻辑第一次调用就以为「用户亲手把结果
/// 窗挪走了」，从此不再自动摆位。所以这里把四种组合都钉住。
final class WindowDragIntentTests: XCTestCase {

    /// 用户按着鼠标移动窗口：这才是「拖」。
    func testPointerDownWithoutAutoPlacementIsAUserDrag() {
        XCTAssertTrue(WindowDragIntent.isUserDrag(pointerDown: true, autoPlaced: false))
    }

    /// 程序化摆位（动画中途 / 被抬高的临时位置）：不算，哪怕恰好按着鼠标。
    func testAutoPlacementIsNeverAUserDrag() {
        XCTAssertFalse(WindowDragIntent.isUserDrag(pointerDown: true, autoPlaced: true))
    }

    /// ★ 这条就是那个 bug：没按鼠标的移动一律是程序摆的，绝不能记成用户拖动。
    func testMoveWithoutTheMouseButtonIsNotAUserDrag() {
        XCTAssertFalse(WindowDragIntent.isUserDrag(pointerDown: false, autoPlaced: false))
    }

    func testNeitherConditionIsNotAUserDrag() {
        XCTAssertFalse(WindowDragIntent.isUserDrag(pointerDown: false, autoPlaced: true))
    }
}
