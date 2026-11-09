import XCTest
import Foundation
@testable import FlashFindCore

/// ★★ 1.1.68：两窗同步从「didMove 追赶」改成「AppKit 父子窗口组」。
/// ★★ 1.1.69：用户第三次真机反馈把契约说死 —— **只有固定以后才能拖动**。
///
/// ## 这些守卫能证什么、不能证什么（2026-11-08 复盘）
/// 1.1.67 那 6 条守卫只查源码里有没有某个调用，在「拖起来还是一卡一卡」
/// 这个 bug 存在时照样全绿 —— 结构守卫**只能防回退，不能当验收**。
/// 1.1.68 的帧日志才是硬证据：`ATTACH ok=true`、`FORWARD_END` 存在（拖搜索框
/// 整体移动成立），但出现两段 `FIELD_DID_MOVE=0 / RESULTS_DID_MOVE=27、26`，
/// 即结果窗被单独拖走、父窗一帧没动。用户原话：「没改好，单独拖动搜索结果
/// 还是可以的，我要求的是只有固定以后才能拖动，否则就是整体移动」。
///
/// 本次唯一验收判据仍是真机帧日志：拖结果窗时有 `RESULTS_MOUSE_DOWN`、
/// **没有** `RESULTS_DID_MOVE`；拖搜索框时两类 `DID_MOVE` 成对、`D` 恒定。
/// 下面每条断言只扫源码文本、不引用新 API，因此能在**未改 App 源码**时
/// 编译通过并集体跑红 —— 红证不靠编译失败冒充。
final class DraggingUnityTests: XCTestCase {

    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFind2App/\(name)"),
                          encoding: .utf8)
    }

    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/\(name)"),
                          encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 从 marker 之后取第一个配平的 `{…}` 块。
    private func braceBlock(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text.range(of: "{", range: markerRange.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open.lowerBound...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// ★ 联动必须交给 WindowServer：结果窗挂成搜索框的 child window。
    func testWindowGroupIsEstablishedByAppKit() throws {
        let c = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertTrue(c.contains("addChildWindow("),
                      "★ 未固定时要把结果窗挂成搜索框的 child window，由系统整体移动")
        XCTAssertTrue(c.contains("removeChildWindow("),
                      "★ 结果窗隐藏/整组收起时要解绑")
        XCTAssertTrue(c.contains("WindowGroupPolicy."),
                      "★ 挂/解绑判据必须在 Core，App 层不许另写一套")
        let core = codeOnly(try coreSource("WindowGroupPolicy.swift"))
        XCTAssertTrue(core.contains("shouldAttach"),
                      "★ Core 要有「何时挂」的判据")
    }

    /// ★ 父子组生效后，`didMove` 追赶链必须**整条删掉**。
    /// 留着它就会二次提交位置，把系统刚做好的同帧又拆成两帧。
    func testDidMoveChasingIsRemoved() throws {
        let c = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertFalse(c.contains("syncResults("),
                       "★ 不许再在 didMove 里 setFrame 结果窗")
        XCTAssertFalse(c.contains("syncField("),
                       "★ 不许再在 didMove 里 setFrame 搜索框")
        XCTAssertFalse(c.contains("handleLinkedMove"),
                       "★ 联动的 didMove 追赶入口要删掉")
        XCTAssertFalse(c.contains("isSyncing"),
                       "★ 反馈循环标志属于追赶实现；1.1.67 里它跨帧吞掉 didMove，正是「一卡一卡」")
    }

    /// ★★ 用户 2026-11-08 22:19：「我要求的是只有固定以后才能拖动，否则就是整体移动」。
    /// 1.1.68 的 `performDrag(with:)` 转发**整条删掉**：它只在背景 `hitTest == nil` 时
    /// 生效，点到结果行/筛选条就由 AppKit 把结果窗自己拖走（帧日志两段 27/26 帧单拖）。
    func testUnpinnedResultsWindowIsNotADragHandle() throws {
        let r = codeOnly(try appSource("SearchResultsPanel.swift"))
        XCTAssertFalse(r.contains("performDrag(with:"),
                       "★ 跨窗口转发整条删掉：真机证明它挡不住结果窗被单独拖")
        XCTAssertFalse(r.contains("FORWARD"),
                       "★ 不再有 FORWARD / FORWARD_END 转发事件")
        XCTAssertFalse(r.contains("NSEvent.mouseEvent("),
                       "★ 不许再造一个属于父窗的假 mouseDown")
        XCTAssertTrue(r.contains("WindowGroupPolicy.mayDragResultsWindowIndependently"),
                      "★ 结果窗能不能拖必须由 Core 判据决定，不许 App 层硬写")
        XCTAssertTrue(r.contains("mayDragResultsWindowIndependently(isPinnedSnapshot: false)"),
                      "★ 未固定就是未固定，不许偷偷把参数传成 true")
        XCTAssertFalse(r.contains("isMovableByWindowBackground = true"),
                       "★ 未固定结果窗不许声明背景可拖")
        XCTAssertTrue(r.contains("RESULTS_MOUSE_DOWN"),
                      "★ 诊断包要记下「用户按过结果窗」，才能证「按了也没动」")
        XCTAssertTrue(r.contains("super.sendEvent(event)"),
                      "★ 事件必须原样交回 AppKit，不许吞掉点击")
    }

    /// ★ 唯一剩下的两个把手：搜索框（带整个父子组走）与钉住后的快照窗。
    func testOnlyPinnedSnapshotAndSearchFieldRemainDragHandles() throws {
        let pinned = codeOnly(try appSource("PinnedResultsWindow.swift"))
        XCTAssertTrue(pinned.contains("WindowGroupPolicy.mayDragResultsWindowIndependently"),
                      "★ 钉住窗的可拖能力走同一条 Core 判据")
        XCTAssertTrue(pinned.contains("mayDragResultsWindowIndependently(isPinnedSnapshot: true)"),
                      "★ 钉住快照窗必须显式传 true，别让它跟着未固定一起被关掉")
        XCTAssertFalse(pinned.contains("isMovableByWindowBackground = true"),
                       "★ 不许再硬写 true，避免契约分叉")
        let c = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertTrue(c.contains("panel.isMovableByWindowBackground = true"),
                      "★ 搜索框仍然是唯一能带动整体移动的把手")
    }

    /// ★ 帧日志必须是 release 构建里真实存在的代码，不能用 `#if DEBUG` 包起来
    /// （本地试用包走 `--release`，DEBUG 段会被整段编译掉）。
    func testFrameTraceIsCompiledIntoReleaseBuild() throws {
        let trace = codeOnly(try appSource("DragFrameTrace.swift"))
        XCTAssertFalse(trace.contains("#if DEBUG"),
                       "★ 诊断包是 release 构建，帧日志不能被 DEBUG 编译掉")
        XCTAssertTrue(trace.contains("CACurrentMediaTime"),
                      "★ 时间戳要高精度，否则判不出「差一帧」")
        let c = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertTrue(c.contains("DragFrameTrace.record("),
                      "★ didMove 与挂/解绑都要真的记进帧日志")
    }

    /// ★ 拖动期间仍禁止自动重排：两段 0.18s 动画会打断系统拖动。
    func testAutoLayoutDefersToWindowGroupPolicy() throws {
        let c = codeOnly(try appSource("SearchPanelController.swift"))
        // ★ 锚点只钉函数名，不钉参数列表。
        let layout = try XCTUnwrap(braceBlock(after: "private func layoutForResults(", in: c),
                                   "取不到 layoutForResults 函数体")
        XCTAssertTrue(layout.contains("WindowGroupPolicy.shouldDeferAutoLayout"),
                      "★ 重排开头先问 Core 判据：鼠标按着就立刻返回")
        guard let judge = layout.range(of: "WindowGroupPolicy.shouldDeferAutoLayout"),
              let moving = layout.range(of: "animate(panel") else {
            XCTFail("判据与动画都要在重排里"); return
        }
        XCTAssertLessThan(judge.lowerBound, moving.lowerBound,
                          "★ 判据必须在动画之前")
    }

    /// ★ 可见性真变时要通知协调者同步父子关系，且仍不许每帧通知重排。
    func testVisibilityChangeUpdatesTheWindowGroup() throws {
        let r = codeOnly(try appSource("SearchResultsPanel.swift"))
        let visibility = try XCTUnwrap(
            braceBlock(after: "private struct SearchResultsPanelVisibility: NSViewRepresentable", in: r),
            "取不到 SearchResultsPanelVisibility 结构体")
        XCTAssertTrue(visibility.contains("lastVisible") && visibility.contains("if changed"),
                      "★ 可见性没真变就不许通知重排")
        XCTAssertTrue(visibility.contains("onVisibilityChanged"),
                      "★ 可见性翻转要同步挂/解绑 child window")
    }
}
