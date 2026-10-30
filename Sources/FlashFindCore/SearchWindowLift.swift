import Foundation

/// 「结果展开时，搜索框要不要往上让」——纯几何，可脱离窗口测。
///
/// ## 2026-10-30 报障（用户原话）
///
/// 「当用户把搜索框拉到屏幕下方的时候，输入文字闪寻的搜索框会直接被搜索结果盖住，
///   而聚焦搜索的做法是随着搜索框的变大而逐渐往上走，最后关闭的时候会跳到设定好的
///   屏幕的某个位置。」
///
/// 成因在 App 层：结果模块固定 470pt 高，摆位规则是「贴着搜索框下沿 10pt」。
/// 搜索框被拖到屏幕下方时下面放不下，旧代码只把**结果窗**往里顶到屏幕底边内 12pt ——
/// 结果窗于是压在搜索框身上（两块都是 `.floating`，后摆的在上）。
///
/// 正确的做法是反过来：**抬搜索框**，让结果在它下面放得下；搜索框已经顶到屏幕上沿
/// 时抬不动，这时才允许结果被裁（把它的上沿夹在可见区内，至少露出标题与类型条）。
public enum SearchWindowLift {

    /// 距屏幕可见区边缘至少留这么多。
    public static let margin: CGFloat = 12

    /// 摆位方案。**永远有解**，`lifted == 0` 就表示「原位放得下，搜索框一步不用动」。
    ///
    /// ★★ 返回可选类型（`nil` = 放得下）是个设计错误，2026-10-30 当天就咬回来了：
    ///   协调者拿到 `nil` 走的那条分支只把搜索框放回原位、**没摆结果窗**，于是最常见的
    ///   处境（搜索框在中上部、结果放得下）结果窗停在原点——用户原话：「第一次打开的
    ///   搜索结果不在搜索框下方了」。所以这里把「放得下」也算成一条方案：
    ///   `fieldY` 原封不动，`resultsY` 照样贴在它下面。调用方只有一条路可走。
    ///
    /// - Parameters:
    ///   - field: 搜索框那一块窗口**没有抬高时**的 frame（用户设定的位置）。
    ///   - resultsHeight: 结果窗当前的高度。
    ///   - gap: 两块模块之间的真实空隙。
    ///   - screen: 所在屏幕的 `visibleFrame`（已扣掉菜单栏与程序坞）。
    public static func plan(field: CGRect,
                            resultsHeight: CGFloat,
                            gap: CGFloat,
                            screen: CGRect) -> Plan {
        let bottom = screen.minY + margin
        let wanted = field.minY - gap - resultsHeight
        // 原位放得下：搜索框留在用户设定的位置，结果贴着它下沿。
        guard bottom - wanted > 0 else {
            return Plan(fieldY: field.minY, resultsY: wanted, lifted: 0)
        }
        let overlap = bottom - wanted
        // 抬得动多少：上方剩的空间。已经贴着上沿就是 0 —— 那时宁可裁结果，也不能把
        // 搜索框推出屏幕（推出去了连输入框都看不见，比被盖住更糟）。
        let capacity = max(0, (screen.maxY - margin) - field.maxY)
        let lift = min(overlap, capacity)
        let fieldY = field.minY + lift
        let resultsY = max(fieldY - gap - resultsHeight, bottom)
        return Plan(fieldY: fieldY, resultsY: resultsY, lifted: lift)
    }

    public struct Plan: Equatable, Sendable {
        /// 搜索框新的下沿（`field.minY` 抬起来之后的值）。
        public let fieldY: CGFloat
        /// 结果窗新的下沿。
        public let resultsY: CGFloat
        /// 抬了多少。`0` = 想抬但抬不动（已到屏幕上沿）。
        public let lifted: CGFloat

        public init(fieldY: CGFloat, resultsY: CGFloat, lifted: CGFloat) {
            self.fieldY = fieldY
            self.resultsY = resultsY
            self.lifted = lifted
        }
    }
}
