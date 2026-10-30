import SwiftUI
import FlashFindCore

/// 预览壳里「真鼠标第一次进入模块」只记一条，用来区分「涂层没画」和「hover 没触发」。
private nonisolated(unsafe) var veilHoverLogged = false

/// 鼠标滑进模块时盖上的那层**液态玻璃遮罩**。
///
/// 用户 2026-10-30：「搜索鼠标滑动时覆盖一层液态玻璃遮罩」。
///
/// 两层叠起来才像玻璃：铺满整块模块的极淡白膜（「鼠标进来了」整块看得见）+
/// 跟着光标走的一团柔光（「液态」感来自它）。取值全在 Core 的 `SearchGlassVeil`。
///
/// ★ `allowsHitTesting(false)`：它属于**表面**，一旦参与命中测试，模块空白处就又
///   拖不动窗口了——2026-10-28 那条「搜索框不能拖动」就是这么坏的。
/// ★ 用 `onContinuousHover` 而不是 `onHover`：膜要跟着光标走，`onHover` 只给一个布尔。
struct SearchHoverVeil: ViewModifier {
    let shape: RoundedRectangle
    let isDark: Bool

    @State private var pointer: CGPoint?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var isOn: Bool { pointer != nil || PreviewHover.isForced }

    func body(content: Content) -> some View {
        content
            .overlay {
                GeometryReader { geo in
                    // ★★ 光晕用 `overlay` 叠在膜上，**不用 `ZStack`**。
                    //
                    //   `ZStack` 的尺寸取各子视图的并集，而光晕是固定 440×440：
                    //   搜索框模块只有 52 高时，`ZStack` 会被撑到 440，
                    //   于是 `shape.fill` 跟着拉成 680×440——一块**比模块高 8 倍**的膜。
                    //   当前窗口恰好等于模块，多出来的部分被窗口边界挡在屏幕外，看不出来；
                    //   但这是「靠窗口兜住」的运气，不是设计。`overlay` 不参与父尺寸，
                    //   膜就老老实实等于模块大小。
                    film
                        .overlay(alignment: .topLeading) {
                            if let spot = pointer ?? forcedSpot(in: geo.size) {
                                specular
                                    .frame(width: SearchGlassVeil.radius * 2,
                                           height: SearchGlassVeil.radius * 2)
                                    .position(spot)
                            }
                        }
                    // ★★ 光晕必须裁到同一个圆角里 —— 这是 2026-10-30 用户报障的真因。
                    //
                    //   用户原话：「有很明显的矩形……只有鼠标放在搜索框搜索结果左侧边缘位置
                    //   顶部出现，也就是左上角和左下角」。
                    //
                    //   ★ 我一开始判成「不可能看见」，理由是「模块 ≡ 窗口，溢出落在窗口外」。
                    //   **那条推理错在一个地方**：窗口是**矩形**，圆角是画出来的。
                    //   所以「模块圆角外、窗口矩形内」的四个小三角**是窗口内的像素**，
                    //   而且默认是透明的——光晕画上去就直接可见。
                    //
                    //   实测（预览壳，钩子 `FF_UI_HOVER_AT=4,4` 把光晕钉在左上角）：
                    //   不加裁剪时，深浅两种外观的左上角都多出一块**直角**亮块，
                    //   边界被窗口矩形切得笔直；加上裁剪后干净。
                    //   证据：`04-测试与验收/UI-悬停光晕裁剪-20261030/`。
                        .clipShape(shape)
                    // 用透明度淡入淡出，而不是 `if isOn` 里外搬整棵子树：
                    // 后者是插入/移除，没有过渡，看着像闪一下。
                        .opacity(isOn ? 1 : 0)
                }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .onContinuousHover { phase in
                switch phase {
                case .active(let location):
                    pointer = location
                    #if DEBUG
                    // 取证时要能回答「真鼠标到底进没进来」——否则一张没有光晕的截图
                    // 分不清是「涂层的裁剪出了问题」还是「hover 压根没触发」。
                    if AppEnvironment.isPreview, !veilHoverLogged {
                        veilHoverLogged = true
                        NSLog("[veil] hover active at %@", NSStringFromPoint(location))
                    }
                    #endif
                case .ended: pointer = nil
                }
            }
            .animation(reduceMotion ? nil : .easeOut(duration: SearchGlassVeil.fade), value: isOn)
    }

    /// 铺满整块模块的极淡白膜。
    ///
    /// ★ 写显式 `Color.white`，别简写成 `.white`：这里的位置是泛型 `ShapeStyle`，
    ///   实测过一次 `.white.opacity(0.6)` 一个字都没画出来、换成
    ///   `Color.white.opacity(0.6)` 立刻正常（原因没查清，先按能用的写）。
    private var film: some View {
        shape.fill(Color.white.opacity(SearchGlassVeil.filmAlpha(dark: isDark)))
    }

    /// 光标下那团柔光。边缘必须是 0，否则会看出一个圆的轮廓。
    private var specular: some View {
        Circle()
            .fill(
                RadialGradient(colors: [Color.white.opacity(SearchGlassVeil.specularAlpha(dark: isDark)),
                                        Color.white.opacity(0)],
                               center: .center,
                               startRadius: 0,
                               endRadius: SearchGlassVeil.radius)
            )
    }

    /// 预览包里「强制悬停」时高光摆哪儿。
    ///
    /// * `FF_UI_HOVER_AT=x,y`：钉到具体一点（相对模块左上角，单位 pt）——
    ///   取证要看**四角**，而默认那个偏中间的落点永远测不到边缘。
    /// * 不指定时偏左上，落在标题那一带，最能看出观感。
    ///
    /// 真跑起来这个分支永远不走——`pointer` 一定先有值（`onContinuousHover` 一进来
    /// 就带着坐标）。它只服务于「没法搬动用户光标」的取证截图。
    private func forcedSpot(in size: CGSize) -> CGPoint? {
        guard PreviewHover.isForced else { return nil }
        if let point = PreviewHover.forcedPoint { return point }
        return CGPoint(x: size.width * 0.4, y: size.height * 0.35)
    }
}

extension View {
    /// 给一块模块表面挂上「悬停时那层液态玻璃」。
    func searchHoverVeil(shape: RoundedRectangle, isDark: Bool) -> some View {
        modifier(SearchHoverVeil(shape: shape, isDark: isDark))
    }
}

/// 预览包专用的强制悬停（`FF_UI_HOVER=1`）。
///
/// 为什么需要它：`onContinuousHover` 要有真鼠标移动才会触发，而取证时没法搬动
/// 用户的光标——只能把「悬停中」这个状态**按死**，再截图看观感。
/// 发布构建里这个值恒为 false（`isPreview` 与 `#if DEBUG` 双门）。
enum PreviewHover {
    static var isForced: Bool {
        #if DEBUG
        AppEnvironment.isPreview && ProcessInfo.processInfo.environment["FF_UI_HOVER"] == "1"
        #else
        false
        #endif
    }

    /// `FF_UI_HOVER_AT=4,4`：把光晕钉到模块坐标里的某一点（左上角为原点，单位 pt）。
    ///
    /// 为什么要它：`onContinuousHover` 只认真鼠标移动，而取证时既不能搬用户的光标、
    /// 也不该为了一张图去写合成事件。上一轮的四角取证就是吃了这个亏——光晕被
    /// 固定在 (0.4w, 0.35h)，永远进不到角里，「边缘有没有露出去」根本没被问到。
    static var forcedPoint: CGPoint? {
        #if DEBUG
        guard isForced,
              let raw = ProcessInfo.processInfo.environment["FF_UI_HOVER_AT"] else { return nil }
        let parts = raw.split(separator: ",").compactMap { Double($0.trimmingCharacters(in: .whitespaces)) }
        guard parts.count == 2 else { return nil }
        return CGPoint(x: parts[0], y: parts[1])
        #else
        return nil
        #endif
    }
}
