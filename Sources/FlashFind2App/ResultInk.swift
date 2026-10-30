import SwiftUI
import FlashFindCore

extension Color {
    /// Core 算好的字色（含 alpha）→ SwiftUI 颜色。
    ///
    /// 与 `Color(glassStroke:)` 分开命名，理由一样：不跟 `Color(_ shapeStyle:)`
    /// 那一票重载打架。
    init(ink value: SearchSelectionInk.Ink) {
        self.init(.sRGB, red: value.red, green: value.green, blue: value.blue, opacity: value.alpha)
    }
}

/// 让「遮罩下的那一行」的文字染成蓝，并且**逐帧**跟着遮罩走。
///
/// ## 为什么是 `Animatable`，不是 `.foregroundStyle(selected ? .blue : .primary)`
///
/// 那种写法有两个坑：
/// 1. `Color` 不是 `Animatable`，换色的那一刻是**硬切**——正是「慢慢变蓝」
///    想要避免的样子（这条是读代码就能定的，不需要截图）；
/// 2. 判据只能落在「选没选中」这一个布尔上，于是遮罩还在路上时字已经全蓝了，
///    等遮罩滑到才亮起来——先后顺序是反的。
///
/// 把**遮罩位置**放进 `animatableData`（和 `SearchLensMagnification` 同一套办法），
/// SwiftUI 会逐帧推进位置，每一行按「离遮罩多远」重算颜色：遮罩压过来时这一行
/// 越来越蓝，离开时退回去，停稳之后从深蓝过渡到天蓝。曲线本身在 Core
/// （`SearchSelectionInk.ink`），这里只做两件视图该做的事：把值取出来、画上去。
struct ResultInk: ViewModifier, Animatable {
    /// 遮罩中心落在第几行（可为小数，动画的中间值都在这里）。
    var position: CGFloat
    /// 本行是第几行。
    var row: CGFloat
    /// 遮罩在场程度 0…1：遮罩淡出时整行一起退色。
    var presence: CGFloat
    /// 深色外观。只影响「正常字色」是白还是黑。
    var dark: Bool

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(position, presence) }
        set {
            position = newValue.first
            presence = newValue.second
        }
    }

    func body(content: Content) -> some View {
        content.foregroundStyle(Color(ink: SearchSelectionInk.ink(rowDistance: row - position,
                                                                  presence: Double(presence),
                                                                  dark: dark)))
    }
}

extension View {
    /// 结果行标题的染色。`row` 是本行序号，`position` 是遮罩中心。
    func resultInk(position: CGFloat, row: Int, presence: Double, dark: Bool) -> some View {
        modifier(ResultInk(position: position,
                           row: CGFloat(row),
                           presence: CGFloat(presence),
                           dark: dark))
    }
}
