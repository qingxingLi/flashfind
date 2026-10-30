import Foundation

/// 结果行「被遮罩盖住」时文字的颜色：**蓝**。
///
/// ## 由来（2026-10-30，用户给了两张 iOS 26 电话 App 的实拍）
///
/// 用户原话：「选中不动时字体变成天蓝色，移动时字体慢慢变蓝色」。
/// 拆开是两件事，而且都不该用「两个布尔值切两套颜色」来做：
///
/// 1. **有遮罩的那一行**文字转蓝（底子仍是玻璃，不是铺一块蓝色块）；
/// 2. 颜色不是一瞬间跳过去的——遮罩从上一行滑过来时，这条路上的每一行
///    都按「离遮罩多远」逐帧加深；遮罩停稳之后，蓝从 `moving`（深一点）
///    过渡到 `settled`（天蓝）。
///
/// 所以这里给出来的是**一张按行距算的连续曲线**，不是开关：
/// 曲线由已经带着动画的遮罩位置驱动，天然跟手，也不需要第二套动画。
///
/// ## 为什么底色也要写进来
///
/// 纯逻辑层不认 SwiftUI，但「从正常字色渐变到蓝」必须知道正常字色是多少。
/// 2026-10-30 实测系统 `labelColor`：**浅色是纯黑、深色是纯白，两边的 alpha 都是 0.847**。
/// 把它写死在这里，比在视图里 `.foregroundStyle(weight > 0 ? .blue : .primary)`
/// 可靠——后者在跨界那一刻是**硬切**（`Color` 不是 `Animatable`），
/// 正是「慢慢变蓝」想要避免的样子。
public enum SearchSelectionInk {

    /// 一档颜色（0…1 三个通道）。Core 只 import Foundation，不引 SwiftUI。
    public struct Blue: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double

        public init(red: Double, green: Double, blue: Double) {
            self.red = red
            self.green = green
            self.blue = blue
        }

        static func hex(_ value: UInt32) -> Blue {
            Blue(red: Double((value >> 16) & 0xFF) / 255,
                 green: Double((value >> 8) & 0xFF) / 255,
                 blue: Double(value & 0xFF) / 255)
        }

        static let white = Blue(red: 1, green: 1, blue: 1)
        static let black = Blue(red: 0, green: 0, blue: 0)

        /// 两档之间插值（`t` 会被夹到 0…1）。
        public func mixed(with other: Blue, _ t: Double) -> Blue {
            let k = min(max(t, 0), 1)
            return Blue(red: red + (other.red - red) * k,
                        green: green + (other.green - green) * k,
                        blue: blue + (other.blue - blue) * k)
        }
    }

    /// 最终落到文字上的颜色（含 alpha）。
    public struct Ink: Equatable, Sendable {
        public let red: Double
        public let green: Double
        public let blue: Double
        public let alpha: Double
    }

    /// 遮罩**停稳**之后那一档蓝。
    ///
    /// * 深色 `#64D2FF`（天蓝）——用户参考图里的调子，压在深玻璃上又亮又干净；
    /// * 浅色 `#0A84FF`（系统蓝）——★ **浅色不能用天蓝**。2026-10-30 第一版就是
    ///   浅色也给了天蓝，截图一看字像被冲掉一层：天蓝压在浅玻璃上的对比度约
    ///   **1.7:1**，而系统蓝约 **3.7:1**。参考图是深色截图，浅色下照抄会读不出来。
    ///   下限由 `testLightInkIsReadableOnLightGlass` 钉住。
    public static func settled(dark: Bool) -> Blue {
        dark ? .hex(0x64D2FF) : .hex(0x0A84FF)
    }

    /// 遮罩**还在赶路**时的蓝：比停稳那一档更深，停下之后自动亮起来。
    ///
    /// 两种外观都遵守同一条方向（移动 → 更深，停稳 → 更亮），
    /// 这样「慢慢变蓝，停住变天蓝」在深浅色下读起来是同一件事。
    public static func moving(dark: Bool) -> Blue {
        dark ? .hex(0x0A84FF) : .hex(0x0055C8)
    }

    /// 正常字色（系统 `labelColor`）。实测：浅色纯黑 / 深色纯白。
    public static func base(dark: Bool) -> Blue {
        dark ? .white : .black
    }

    /// 正常字色的不透明度。**实测 0.847**，不是 1 —— 照着 1 写，未选中的字会突然变实。
    public static let baseAlpha: Double = 0.847

    /// 染色的作用窗口（行）。比缩放的 `SearchLens.falloff`（1.8）窄得多：
    /// 缩放讲究「边缘被挤一下」，染色讲究「哪一行是当前行」，
    /// 铺到 1.8 行会让上下三行一起发蓝，像整列坏了。
    public static let inkFalloff: CGFloat = 1.0

    /// 从「移动蓝」过渡到「天蓝」的距离（行）。
    ///
    /// 连续函数，不是阈值开关：阈值（`distance < 0.06 ? 天蓝 : 深蓝`）会在
    /// 遮罩落位那一帧从 #0A84FF 直接跳到 #64D2FF，看得见。
    public static let settleFalloff: CGFloat = 0.35

    /// 遮罩中心离这一行 `rowDistance` 行时，这一行文字染到什么程度（0…1）。
    ///
    /// 前半行满色（顶在遮罩正中），之后线性收到 0：两行之间是**交叉染色**，
    /// 一行亮起来的同时另一行退下去，没有「同时两行全蓝」也没有「中间空一拍」。
    public static func weight(rowDistance: CGFloat) -> Double {
        guard rowDistance.isFinite else { return 0 }
        let distance = abs(rowDistance)
        guard distance < inkFalloff else { return 0 }
        if distance <= 0.5 { return 1 }
        return Double((inkFalloff - distance) / (inkFalloff - 0.5))
    }

    /// 这一行的蓝「熟了」多少（0 = 移动蓝，1 = 天蓝）。
    public static func settleFraction(rowDistance: CGFloat) -> Double {
        guard rowDistance.isFinite else { return 0 }
        let distance = abs(rowDistance)
        guard distance < settleFalloff else { return 0 }
        return Double(1 - distance / settleFalloff)
    }

    /// 这一行此刻该用的字色。
    ///
    /// - Parameters:
    ///   - rowDistance: 本行序号 − 遮罩中心（行，可为小数）。
    ///   - presence: 遮罩在场程度 0…1（淡出时整行一起退色）。
    ///   - dark: 深色外观。只影响「正常字色」是白还是黑。
    public static func ink(rowDistance: CGFloat, presence: Double = 1, dark: Bool) -> Ink {
        let shown = min(max(presence.isFinite ? presence : 0, 0), 1)
        let amount = weight(rowDistance: rowDistance) * shown
        let base = self.base(dark: dark)
        guard amount > 0 else {
            return Ink(red: base.red, green: base.green, blue: base.blue, alpha: baseAlpha)
        }
        let target = moving(dark: dark).mixed(with: settled(dark: dark),
                                              settleFraction(rowDistance: rowDistance) * shown)
        let rgb = base.mixed(with: target, amount)
        // alpha 同步走向实色：蓝字要比灰字更"实"，否则压在玻璃上会发灰。
        return Ink(red: rgb.red, green: rgb.green, blue: rgb.blue,
                   alpha: baseAlpha + (1 - baseAlpha) * amount)
    }
}
