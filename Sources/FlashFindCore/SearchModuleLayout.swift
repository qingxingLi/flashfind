import Foundation

/// 搜索窗的**模块化布局**（用户 2026-10-27 定）。
///
/// ## 为什么搜索框与搜索结果要拆成两个模块
///
/// 原来是「一整块玻璃」，输入框只是它里面的一行：于是只有搜索框时
/// 外面还裹着一圈面板，玻璃胶囊四周多出一层壳，很丑。
///
/// 用户的方案是把它做成**两块独立的圆角模块，中间留一道空白**：
/// 搜索框是一块、搜索结果是一块，各自是完整的玻璃面；没有结果时
/// 就只有搜索框那两块圆角，四周不再有多余的遮罩。
///
/// 三件必须由**一处**说了算的事（散在视图里就会一块 20、一块 26）：
/// 1. 两个模块的圆角**必须相同**——用户原话「圆角大小要统一，否则很难看」；
/// 2. 中间那道空白的高度；
/// 3. 结果行里那块跟随遮罩的圆角（要小于模块圆角，否则贴着模块圆角会露出尖角）。
public enum SearchModuleLayout {

    /// 两个模块共用的圆角。
    ///
    /// 20 是原来整块面板的圆角，搜索结果模块保持它，搜索框模块跟着它走——
    /// 「统一」是照这个数走的，不是各取所好。
    public static let moduleRadius: CGFloat = 20

    /// 两个模块之间的空白。太小看起来像一块被切了缝，太大就不像同一个窗口。
    public static let moduleGap: CGFloat = 10

    /// 结果行里跟随鼠标的遮罩圆角。比模块圆角小一档：
    /// 遮罩离模块边缘只有 8pt，用同值会贴着模块圆角露出尖角。
    public static let rowLensRadius: CGFloat = 14

    /// 结果行遮罩与模块左右边缘的距离。
    public static let rowLensInset: CGFloat = 8

    // MARK: - 搜索框模块里的类型条（仿聚焦搜索 / Finder 的分段条）

    /// 类型条的高度。
    ///
    /// ★ 它住在**搜索框模块内部**（用户 2026-10-27：「此功能为搜索框模块的功能」），
    /// 所以窗口高度必须把它算进去（`SearchView.fieldModuleHeight`）。
    /// 少算一截的后果是类型条被模块底边裁掉一半——而它是常驻的，不是偶发状态。
    public static let typeBarHeight: CGFloat = 34

    /// 类型条与输入行共用的左右内边距（与 `SearchFieldModule` 的 22 同值）。
    public static let fieldInset: CGFloat = 22

    /// 类型条上每一段被选中时的圆角。
    ///
    /// 比结果行遮罩再小一档：段本身只有 24pt 高，用 14 会看不出圆角。
    public static let segmentRadius: CGFloat = 11

    // MARK: - 结果模块里的侧边栏

    /// 侧边栏宽度。
    ///
    /// ★ 用户要求「侧边栏不要突出搜索框左右宽度，宽度保持一致」：
    /// 侧边栏是**结果模块内部的一列**，模块本身仍与搜索框等宽——
    /// 窗口宽度不变，多出来的这一列是从结果区里让出来的，不是把窗口撑宽。
    public static let sidebarWidth: CGFloat = 132

    /// 侧边栏一行的高度。
    ///
    /// 32 = 主标题 12pt + 副标题 10pt + 行距 1pt + 上下各 4pt：
    /// 侧边栏的行要能同时写「根名」与「来源名（· 未连接）」两行，
    /// 30 会把第二行压掉。
    public static let sidebarRowHeight: CGFloat = 32

    /// 侧边栏与结果区之间那条分隔线的粗细。
    public static let sidebarDividerWidth: CGFloat = 0.5

    // MARK: - 结果模块的**固定**高度（2026-10-28 报障后定）

    /// 结果区一屏固定显示几行。
    ///
    /// ★ 用户原话：「搜索结果的区域大小固定，否则切换的时候侧边栏大小频繁跳动，影响筛选」。
    ///   原来高度是 `min(结果数, 7) × 行高 + 留白`——搜到 48 条是一屏、切到一个空位置
    ///   只剩 112pt，侧边栏跟着整块伸缩，正在点的那一行会从指头底下移开。
    ///   现在一屏永远是这么多行，结果少的时候底下留空，而不是把整块缩回去。
    public static let resultsVisibleRows = 7

    /// 结果区底部状态栏的高度（条数 / 「继续搜索」/ 键位提示）。
    ///
    /// 没有结果的时候这一条不画，但**高度照样留着**：它是固定高度的一部分，
    /// 少算这一截就会出现「有结果时面板比空状态高 32pt」——那正是这次要消掉的跳动。
    public static let resultsStatusBarHeight: CGFloat = 32

    /// 结果列表上下的留白之和。
    public static let resultsListPadding: CGFloat = 12

    /// 结果区（不含顶部类型条）的固定高度。
    public static func resultsListHeight(rowHeight: CGFloat) -> CGFloat {
        CGFloat(resultsVisibleRows) * rowHeight + resultsListPadding + resultsStatusBarHeight
    }

    /// 整个结果模块的固定高度 = 类型条 + 结果区。
    public static func resultsModuleHeight(rowHeight: CGFloat) -> CGFloat {
        typeBarHeight + resultsListHeight(rowHeight: rowHeight)
    }

    /// 有没有「结果模块」。
    ///
    /// 没有关键词、也没有打开失败时**只有搜索框一块**——这正是用户要的效果：
    /// 单独搜索框的时候不该再套一层外壳。
    /// 打开失败也必须算进来，否则提示条会被裁掉。
    ///
    /// ★ 2026-10-28：「输入命令」那套删掉之后这里少了一个 `isCommandMode` 参数——
    ///   命令面板不会再让第二块凭空出现，内容只可能来自「有查询」或「有打开失败」。
    public static func showsContentModule(hasQuery: Bool, hasOpenFailure: Bool) -> Bool {
        hasQuery || hasOpenFailure
    }

    // MARK: - 钉住的搜索结果窗口（2026-10-28 新增）

    /// 钉住后的结果窗口宽度：与搜索框同宽。
    ///
    /// 用户要的是「同一批结果从搜索框下方挪到桌面上」，宽度一变就是另一个东西了。
    public static let pinnedWidth: CGFloat = 680

    /// 钉住窗口的题头高度（查询词 + 条数 + 关闭）。
    ///
    /// 题头同时是**拖动把手**：钉住的窗口没有标题栏，没有这一条就没地方抓。
    public static let pinnedHeaderHeight: CGFloat = 38

    /// 钉住窗口最多一屏显示几行，超出的滚动。
    ///
    /// 比浮窗的 7 行多：它是独立窗口，没有「别挡着搜索框」的约束。
    ///
    /// ★ 2026-10-28 从 10 改成 9：10 行 = 644pt 高，而搜索框默认位置下方只剩 628，
    ///   整块放不下就会被顶上去、**题头正好被搜索框压住**（连拖都拖不动）。
    ///   9 行 = 588pt，默认位置能整块落在搜索框下方；真不够时还会摆到上方（见
    ///   `PinnedResultsWindows.present`）。行数上限与「能不能一次看全」是两件事，
    ///   这里优先保证后者。
    public static let pinnedMaximumRows = 9

    /// 钉住窗口里结果区上下的留白。
    public static let pinnedListPadding: CGFloat = 6
}
