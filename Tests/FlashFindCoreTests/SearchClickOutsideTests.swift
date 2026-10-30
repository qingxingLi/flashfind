import XCTest
@testable import FlashFindCore

/// 「这一点点击算不算在浮窗外」的判定。
///
/// ★ 这条用例守的是 2026-10-28 的报障（原话）：
///   「搜索结果钉住后,关闭搜索结果,搜索框不再点击任意位置关闭」。
///   根因是**隐藏窗口的 frame 仍然留在屏幕上**（`orderOut` 不清 frame），
///   结果窗与钉住窗都摆在搜索框正下方，于是那块看起来是空桌面的地方变成禁点区。
///
/// ★ 尺子：把「可见性」这件事从判定里**剥掉**，只让调用方传可见的 frame，
///   于是「忘了过滤」就成了一个能在结构闸里查出来的错误（而不是靠人记）。
final class SearchClickOutsideTests: XCTestCase {
    private let field = CGRect(x: 100, y: 600, width: 680, height: 64)

    func testClickInsideTheSearchFieldNeverDismisses() {
        XCTAssertFalse(SearchClickOutside.shouldDismiss(click: CGPoint(x: 400, y: 630),
                                                        field: field,
                                                        otherVisibleWindows: []),
                       "点在输入框上收窗 = 用户点哪儿都没法输入")
    }

    func testClickOnTheFieldEdgeIsStillInside() {
        // `CGRect.contains` 对 minX/minY 是闭区间、maxX/maxY 是开区间——
        // 这里把四个角都过一遍，避免以后换成别的包含判定时悄悄改掉手感。
        for point in [CGPoint(x: 100, y: 600), CGPoint(x: 779, y: 663)] {
            XCTAssertFalse(SearchClickOutside.shouldDismiss(click: point, field: field,
                                                            otherVisibleWindows: []),
                           "边缘点也算在窗口里（\(point)）")
        }
    }

    func testClickOnAnotherVisibleOwnWindowDoesNotDismiss() {
        let results = CGRect(x: 100, y: 120, width: 680, height: 470)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(click: CGPoint(x: 400, y: 300),
                                                        field: field,
                                                        otherVisibleWindows: [results]),
                       "点在结果窗上不该把整组收起来（拆成两块窗之后最容易踩的一条）")
    }

    func testClickOutsideEveryWindowDismisses() {
        let results = CGRect(x: 100, y: 120, width: 680, height: 470)
        XCTAssertTrue(SearchClickOutside.shouldDismiss(click: CGPoint(x: 1000, y: 300),
                                                       field: field,
                                                       otherVisibleWindows: [results]),
                      "点桌面空白处必须收窗——这是这个浮窗唯一的关闭手势")
    }

    /// ★★ 就是这条 bug 本身。
    ///
    /// 结果窗被收起来之后位置不变（`orderOut` 只改可见性），调用方若把它算进豁免列表，
    /// 搜索框正下方那 680×470 就点不穿了。这里模拟「调用方已经筛过可见性」：
    /// 隐藏的结果窗**不在**列表里，于是同一个点在有无列表两种情况下必须给出相反结论。
    func testHiddenWindowIsNotInTheExemptListSoTheSamePointDismisses() {
        let hiddenResultsFrame = CGRect(x: 100, y: 120, width: 680, height: 470)
        let point = CGPoint(x: 400, y: 300)   // 落在「结果窗」那块，但它是隐藏的

        XCTAssertTrue(SearchClickOutside.shouldDismiss(click: point, field: field,
                                                       otherVisibleWindows: []),
                      "★ 隐藏窗口不许豁免点击：否则钉住之后搜索框正下方是一整片看不见的禁点区")
        XCTAssertFalse(SearchClickOutside.shouldDismiss(click: point, field: field,
                                                        otherVisibleWindows: [hiddenResultsFrame]),
                       "对照：同一点在窗口可见时确实该豁免——没有这条对照，上一条断言是聋的")
    }

    func testEmptyFramesFromClosingWindowsDoNotSwallowClicks() {
        // 关掉的窗口偶尔会留下零尺寸或退化 frame；`contains` 对它们是恒假的，
        // 这里只是把它钉成契约，避免以后有人「优化」成按并集判断。
        XCTAssertTrue(SearchClickOutside.shouldDismiss(click: .zero, field: field,
                                                       otherVisibleWindows: [.zero, CGRect(x: 0, y: 0, width: 0, height: 800)]),
                      "退化/零宽窗口不该吃掉任何点击")
    }

    func testAnyOfSeveralVisibleWindowsExempts() {
        let pinned = CGRect(x: 620, y: 120, width: 680, height: 588)
        let settings = CGRect(x: 200, y: 200, width: 520, height: 520)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(click: CGPoint(x: 700, y: 300),
                                                        field: field,
                                                        otherVisibleWindows: [pinned, settings]),
                       "多块钉住窗并排时，点在任意一块上都算「点自家窗口」")
    }

    /// ★★ 2026-10-30 报障（用户原话）：「闪寻无法被截图，一截图就直接消失了」。
    ///
    /// 截图工具的选区遮罩是一块**盖满整屏、层级高于浮窗**的窗口。用 ⌘⇧5 或第三方
    /// 截图工具时闪寻被挤成非前台，那一下鼠标按下正好落进补挂的全局监视里 ——
    /// 浮窗在选区画到一半时被收掉，截出来的图里当然没有闪寻。
    ///
    /// 判据：**盖满整屏 + 层级高于浮窗**，两条同时成立才算截图遮罩。
    /// 只判其中一条会误伤两类很常见的点击（下面两种对照就是它们）。
    func testClickOnAScreenCoveringOverlayDoesNotDismiss() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 900)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(click: CGPoint(x: 700, y: 300),
                                                        field: field,
                                                        otherVisibleWindows: [],
                                                        overlayBlocksDismissal: true),
                       "★ 点落在截图遮罩上不许收窗：否则截图工具一开，闪寻自己先没了")
        XCTAssertTrue(SearchClickOutside.shouldDismiss(click: CGPoint(x: 700, y: 300),
                                                       field: field,
                                                       otherVisibleWindows: [],
                                                       overlayBlocksDismissal: false),
                      "对照：同一位置若底下是普通窗口，就该收窗——否则上一条断言是聋的")

        // 1498 = 实测的系统截图选区遮罩层级（见 `overlayLayerFloor` 的表）。
        XCTAssertTrue(SearchClickOutside.blocksDismissal(windowLayer: 1498,
                                                         windowBounds: screen,
                                                         screen: screen),
                      "盖满整屏 + 层级在常驻元素之上 = 截图遮罩")
        XCTAssertFalse(SearchClickOutside.blocksDismissal(windowLayer: 0,
                                                          windowBounds: screen,
                                                          screen: screen),
                       "别的 App 的全屏窗口层级是 0：点它就该收窗（那是「点了外面」）")
        XCTAssertFalse(SearchClickOutside.blocksDismissal(windowLayer: 25,
                                                          windowBounds: CGRect(x: 0, y: 870, width: 1440, height: 30),
                                                          screen: screen),
                       "菜单栏那条层级虽高，但盖不满屏幕 —— 点它得照常收窗")
        // ★ 实测撞出来的对照：程序坞有一块**常驻、铺满整屏、层级 20** 的窗口。
        //   门槛若只按「高于浮窗（3）」判，它会一直命中 ⇒ 点击外面永远不收窗。
        XCTAssertFalse(SearchClickOutside.blocksDismissal(windowLayer: 20,
                                                          windowBounds: screen,
                                                          screen: screen),
                       "程序坞那块常驻全屏窗口（层级 20）不许被当成截图遮罩")
    }
}
