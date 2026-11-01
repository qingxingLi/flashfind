import CoreGraphics
import Foundation

/// 「钉住的那一批」摆在哪儿、开多高 —— 纯几何，可脱离窗口测。
///
/// ## 2026-11-01 报障（用户原话）
///
/// 「钉住的时候应该是搜索的数量变多了，导致钉住的内容钻到搜索框下方了」
/// （附了一张翻拍截图：钉住窗只剩下半截，题头与类型条整块不见）。
///
/// 实测（1470×956 屏、可见区 `y 87..923`、搜索框在默认位置 `y 625..689`、1680pt 宽里的 680pt）：
/// 一批 200 条结果钉出来的窗口高 **588**（9 行），而搜索框下方只剩 `625 - 10 - 99 = 516`。
/// `present` 原来只有三条路（下方 / 上方 / 退回下方），**没有一条是「把窗口开矮一点」**：
/// 退回下方后 `clamped()` 又把窗口顶回屏幕内，上沿被顶到 687，正好压住 625..687 的搜索框。
/// 结果就是「条数越多，钉住的窗口越容易钻到搜索框底下」——不是偶发，是条数一多必现。
///
/// 所以摆位只剩一条规矩：**先看空间，再定高度；任何情况下不与锚点搜索框重叠**。
/// 收高度按**整行**收，收掉的行由钉住窗自己的 `ScrollView` 滚动，不是被裁掉。
public enum PinnedWindowPlacement {

    /// 距屏幕可见区边缘至少留这么多。
    public static let margin: CGFloat = 12

    /// 「下方还剩这么多行，就值得留在下方」的门槛。
    ///
    /// ★ 没有它会出现另一种荒唐结果：搜索框摆在屏幕中段（可见区 `y 400` 左右）时，
    ///   下方只剩 291pt，只够 1 行——而上方空着 437pt，能放 6 行。
    ///   那时把人钉住的 200 条塞进「下面一行的缝」、上面一大片空着，比换到上方更糟。
    ///   少于这个行数就换边；够这个行数就留在下方（位置稳定，跟搜索结果一个方向）。
    public static let comfortableRows = 3

    /// 题头 + 类型条 + 列表上下留白（**不含行**）。高度与摆位共用这一个式子，
    /// 少算一项就会出现「算出来 7 行、画出来 6 行半」。
    public static var chromeHeight: CGFloat {
        SearchModuleLayout.pinnedHeaderHeight
            + SearchModuleLayout.typeBarHeight
            + SearchModuleLayout.pinnedListPadding * 2
    }

    /// 按行数算高度（含题头与类型条）。**唯一出处**：`PinnedResults.windowHeight` 也走它。
    public static func height(rows: Int, rowHeight: CGFloat) -> CGFloat {
        let visible = min(max(rows, 0), SearchModuleLayout.pinnedMaximumRows)
        return chromeHeight + CGFloat(max(visible, 1)) * rowHeight
    }

    /// 一段高度里能放下几整行。
    public static func rows(inHeight height: CGFloat, rowHeight: CGFloat) -> Int {
        guard rowHeight > 0 else { return 0 }
        return Int(((height - chromeHeight) / rowHeight).rounded(.down))
    }

    /// 摆位方案。**永远有解**，`above` 表示这一块被摆到了搜索框上方（下方连一行都放不下）。
    ///
    /// - Parameters:
    ///   - field: 锚点 —— 搜索框**用户设定的位置**（不是它为了放下结果临时抬上去的位置：
    ///     钉住之后这一轮立刻结束、搜索框马上回到设定位置，按临时位置摆就会正好被它压住）。
    ///   - intrinsicHeight: 按快照行数算出来的理想高度（`PinnedResults.windowHeight`）。
    ///   - rowHeight: 一行的高度（App 的 `SearchLayout.rowHeight`）。
    ///   - offset: 第 N 块钉住窗的错开量（向下 / 向上错开，**必须计入可用空间**，
    ///     否则错开量会把窗口推出屏幕，再被夹回来就又压住搜索框）。
    ///   - screen: 所在屏幕的 `visibleFrame`（已扣掉菜单栏与程序坞）。
    ///   - gap: 两块模块之间的真实空隙。
    public static func plan(field: CGRect,
                            intrinsicHeight: CGFloat,
                            rowHeight: CGFloat,
                            offset: CGFloat,
                            screen: CGRect,
                            gap: CGFloat = SearchModuleLayout.moduleGap) -> Plan {
        let fullRows = min(max(rows(inHeight: intrinsicHeight, rowHeight: rowHeight), 1),
                           SearchModuleLayout.pinnedMaximumRows)
        let bottom = screen.minY + margin
        let top = screen.maxY - margin
        let roomBelow = (field.minY - gap - offset) - bottom
        let roomAbove = top - (field.maxY + gap + offset)

        // 1) 下方整批放得下 —— 最常见，钉住的东西跟搜索结果一样长在搜索框下面。
        if roomBelow >= height(rows: fullRows, rowHeight: rowHeight) {
            return Plan(height: height(rows: fullRows, rowHeight: rowHeight),
                        originY: field.minY - gap - offset - height(rows: fullRows, rowHeight: rowHeight),
                        above: false,
                        visibleRows: fullRows)
        }
        // 2) 下方收掉几行之后**仍然够看**（至少 `comfortableRows` 行）——留在下方。
        //    位置稳定比「多露两行」重要：钉住的窗口按条数忽上忽下，就是用户说过的「跳」。
        let comfortable = min(comfortableRows, fullRows)
        if roomBelow >= height(rows: comfortable, rowHeight: rowHeight) {
            let fit = min(min(rows(inHeight: roomBelow, rowHeight: rowHeight), fullRows),
                          SearchModuleLayout.pinnedMaximumRows)
            let h = height(rows: fit, rowHeight: rowHeight)
            return Plan(height: h, originY: field.minY - gap - offset - h, above: false, visibleRows: fit)
        }
        // 3) 下方连「够看」都做不到 —— 换到上方（用户 2026-10-28 定的第二条规矩）。
        if roomAbove >= height(rows: fullRows, rowHeight: rowHeight) {
            return Plan(height: height(rows: fullRows, rowHeight: rowHeight),
                        originY: field.maxY + gap + offset,
                        above: true,
                        visibleRows: fullRows)
        }
        if roomAbove >= height(rows: 1, rowHeight: rowHeight) {
            let fit = min(rows(inHeight: roomAbove, rowHeight: rowHeight), fullRows)
            let h = height(rows: fit, rowHeight: rowHeight)
            return Plan(height: h, originY: field.maxY + gap + offset, above: true, visibleRows: fit)
        }
        // 4) 两侧都「不够看」（屏幕极小 / 搜索框几乎占满）：取能放的行数多的那一侧，至少一行。
        //    这一步会与搜索框相邻但**不重叠**——宁可矮，也不能把题头藏到它后面。
        let belowRows = min(max(rows(inHeight: roomBelow, rowHeight: rowHeight), 1), fullRows)
        let aboveRows = min(max(rows(inHeight: roomAbove, rowHeight: rowHeight), 1), fullRows)
        if aboveRows > belowRows {
            return Plan(height: height(rows: aboveRows, rowHeight: rowHeight),
                        originY: field.maxY + gap,
                        above: true,
                        visibleRows: aboveRows)
        }
        return Plan(height: height(rows: belowRows, rowHeight: rowHeight),
                    originY: field.minY - gap - height(rows: belowRows, rowHeight: rowHeight),
                    above: false,
                    visibleRows: belowRows)
    }

    public struct Plan: Equatable, Sendable {
        /// 窗口高度（已按可用空间收过行）。
        public let height: CGFloat
        /// 窗口下沿（`NSWindow` 的 `origin.y`）。
        public let originY: CGFloat
        /// 摆在了搜索框上方。
        public let above: Bool
        /// 一屏能完整显示几行（收掉的行由钉住窗内的滚动条负责）。
        public let visibleRows: Int

        public init(height: CGFloat, originY: CGFloat, above: Bool, visibleRows: Int) {
            self.height = height
            self.originY = originY
            self.above = above
            self.visibleRows = visibleRows
        }
    }
}
