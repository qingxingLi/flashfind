import SwiftUI
import FlashFindCore

/// 把 Core 的 `FlashFindTextStyle` 接到 SwiftUI 上。
///
/// ## 为什么要有这一层
///
/// 字号/字重/字距的唯一出处是 `FlashFindCore.FlashFindTypography`——放 Core 是为了
/// 能被测试锁住（App 层是 executableTarget，测不了）。但 Core 不能引 SwiftUI，
/// 所以字重在那里只存 `NSFont.Weight` 的原始数值，映射回 `Font.Weight` 的活在这里干。
///
/// ## 为什么用修饰器而不是 `Font`
///
/// 字距（`tracking`）不在 `Font` 里，是独立的视图修饰符。如果各处自己写
/// `.font(...)` 再补一个 `.tracking(...)`，「这个标题的字距是多少」就散成了两处，
/// 迟早出现「同一个标题在 A 页紧、在 B 页松」。`.ffFont(.xxx)` 一次给齐。
extension FlashFindTextStyle {
    /// 原始数值 → SwiftUI 字重。
    ///
    /// 只有三档（regular / medium / semibold）：再细分对中文（苹方）没有意义，
    /// 苹方的 light 与 thin 在 11pt 下几乎不可读。
    var swiftUIWeight: Font.Weight {
        switch weight {
        case ..<0.2: return .regular
        case ..<0.5: return .medium
        default: return .semibold
        }
    }

    var font: Font { .system(size: size, weight: swiftUIWeight) }
}

extension View {
    /// 套用一档文字样式（字号 + 字重 + 字距）。
    func ffFont(_ style: FlashFindTextStyle) -> some View {
        font(style.font).tracking(style.tracking)
    }
}
