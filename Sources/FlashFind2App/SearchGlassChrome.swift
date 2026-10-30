import SwiftUI
import FlashFindCore

/// 搜索区用哪套表面：动态玻璃，还是 macOS 15 的老方案。
///
/// 判定本身在 `FlashFindCore.SearchGlassStyle`（可回归），这里只负责
/// 「这台机器到底有没有玻璃能力」这一步运行时探测。
enum SearchGlass {

    /// 编译期 + 运行期双门。
    ///
    /// 两门缺一不可：`glassEffect` 是 SDK 27 才有的 API（旧工具链编译期没有），
    /// 而跑在 macOS 15 上的同一份二进制也调不到它（运行期没有）。
    /// 只判其中一门，就会出现「编得过但一跑就崩」或者「编不过」。
    static var isAvailable: Bool {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) { return true }
        #endif
        return false
    }

    static func style(reduceTransparency: Bool) -> SearchGlassStyle {
        SearchGlassStyle.resolve(liquidGlassAvailable: isAvailable,
                                 reduceTransparency: reduceTransparency)
    }
}

extension Color {
    /// Core 里的描边取值 → SwiftUI 颜色。
    ///
    /// 单独起名（而不是 `init(_:)`）是为了不跟 `Color(_ shapeStyle:)` 那一票重载打架。
    init(glassStroke stroke: SearchGlassEdge.Stroke) {
        self.init(.sRGB, red: stroke.red, green: stroke.green, blue: stroke.blue, opacity: stroke.alpha)
    }
}

/// 跟随鼠标 / 键盘选中项滑动的那块玻璃。
///
/// 用 `.clear`（更透明）而不是 `.regular`：它盖在结果行底下，
/// `.regular` 会把文字压暗、看着像一层雾；`.clear` 只留一点折射与高光。
/// `.interactive()` 让玻璃对指针有反应（macOS 26 起可用；27 上更明显）。
struct SearchGlassLens: View {
    var cornerRadius: CGFloat = SearchModuleLayout.rowLensRadius
    @Environment(\.colorScheme) private var colorScheme
    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: cornerRadius, style: .continuous) }
    private var isDark: Bool { colorScheme == .dark }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(.clear.interactive(), in: shape)
                // ★ 2026-10-30 按用户给的 iOS 26 实拍补两层（见 `SearchGlassEdge` 的说明）：
                //   色散环（蓝→青的彩边）+ 左下那点柔光。两者都画在**描边里面**，
                //   外面那条分界线仍然是最后画、最上面的一层。
                .overlay { rim }
                .overlay { specular }
                .overlay { edge }
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// 边缘那一圈：外分界线 + 上半段内高光（原有）。
    private var edge: some View {
        // 玻璃在纯色背景上几乎看不见边界，补一圈描边。
        // ★ 2026-10-28：原来只描白，白底上等于没画——外圈改由 Core 给
        //   （浅色外观是黑色、深色是白色），内圈仍是上亮下暗的高光。
        shape.strokeBorder(Color(glassStroke: SearchGlassEdge.lens(dark: isDark)),
                           lineWidth: SearchGlassEdge.lensStrokeWidth)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color(glassStroke: SearchGlassEdge.lensHighlight(dark: isDark)),
                                            .clear],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: SearchGlassEdge.lensStrokeWidth)
            }
    }

    /// 色散环：折射把不同波长掰到不同角度，边缘就露出一圈彩边。
    ///
    /// `blur` 一点点是必须的：一根纯粹的描线读起来像「又画了一条边」，
    /// 化开 0.5pt 之后才像光被掰散了。
    private var rim: some View {
        shape.strokeBorder(
            LinearGradient(colors: [Color(glassStroke: SearchGlassEdge.lensRim(dark: isDark)),
                                    Color(glassStroke: SearchGlassEdge.lensRimFar(dark: isDark))],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            lineWidth: SearchGlassEdge.lensRimWidth)
            .blur(radius: 0.5)
    }

    /// 左下那块柔光。用径向渐变而不是实心圆：边缘必须收到 0，
    /// 否则会看出一个圆的轮廓，像玻璃上贴了张圆纸片。
    private var specular: some View {
        GeometryReader { geo in
            let radius = SearchGlassEdge.lensSpecularRadius
            RadialGradient(colors: [Color(glassStroke: SearchGlassEdge.lensSpecular(dark: isDark)),
                                    .clear],
                           center: .center, startRadius: 0, endRadius: radius)
                .frame(width: radius * 2, height: radius * 2)
                .position(x: geo.size.width * 0.16, y: geo.size.height * 0.82)
        }
    }

    /// 没有 Liquid Glass 时的替身。正常走不到（`SearchGlass.style` 已经拦了），
    /// 但 `#available` 的 else 分支必须能编译。
    private var fallback: some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay { shape.strokeBorder(.white.opacity(0.25), lineWidth: 0.8) }
    }
}

/// 分段控件（搜索框下方的类型条）里**选中那一段**的底。
///
/// 与 `SearchGlassLens` 分开，是因为两者尺寸差一个量级：结果行的遮罩有 50pt 高，
/// `.clear` 能看出折射；而类型条一段只有 24pt 高，`.clear` 在白底上几乎看不见，
/// 选中的段必须一眼可辨（Finder 那条也是明确的一块亮底）。
struct SearchSegmentLens: View {
    let style: SearchGlassStyle
    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: SearchModuleLayout.segmentRadius, style: .continuous)
    }

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), style == .glass {
            shape.fill(Color.white.opacity(0.001))
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(.white.opacity(0.35), lineWidth: 0.6) }
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    /// 没有 Liquid Glass（或开了「降低透明度」）时的替身：一块实心浅底 + 细描边。
    private var fallback: some View {
        shape.fill(.regularMaterial)
            .overlay { shape.strokeBorder(.white.opacity(0.30), lineWidth: 0.6) }
    }
}

/// 让「遮罩滑过时字变大变小」真正逐帧发生。
///
/// ★ 关键点：它必须 `Animatable`。只在状态变了之后重算一次 `scaleEffect`，
/// 得到的只是「起点 → 终点」两个值——遮罩从第 1 行滑到第 6 行时，
/// 中间那几行的字**全程纹丝不动**，用户看不到「滑过去」的过程。
/// 把遮罩位置放进 `animatableData`，SwiftUI 会逐帧推进 `position`，
/// 每一行的缩放就跟着连续变化（放大 → 挤小 → 复原）。
struct SearchLensMagnification: ViewModifier, Animatable {
    /// 遮罩中心当前落在第几行（可为小数，动画中间值）。
    var position: CGFloat
    /// 这一行是第几行。
    var row: CGFloat
    /// 遮罩是否在场。不发光/老方案时为 false，缩放恒为 1。
    var isActive: Bool

    var animatableData: CGFloat {
        get { position }
        set { position = newValue }
    }

    func body(content: Content) -> some View {
        content
            .scaleEffect(isActive ? SearchLens.scale(rowDistance: row - position) : 1,
                         anchor: .leading)
    }
}

extension View {
    /// 结果行按「离遮罩多远」缩放。缩放的锚点在左侧，标题的左边缘不会跟着漂。
    func searchLensMagnification(position: CGFloat, row: Int, active: Bool) -> some View {
        modifier(SearchLensMagnification(position: position, row: CGFloat(row), isActive: active))
    }
}

/// 老方案（macOS 15 及以下）的两种底色，与 `List` 自己的画法对齐。
///
/// 换成自绘之后，选中蓝必须自己画：`List` 的选中是 `selectedContentBackgroundColor`
/// 填充 + 文字转白，两件事都得补上，否则「向下兼容保持原方案」就成了空话。
enum SearchLegacyHighlight {
    static var hover: Color { Color(nsColor: .quaternaryLabelColor) }
    static var selection: Color { Color(nsColor: .selectedContentBackgroundColor) }
}

/// 一块**模块**的表面：搜索框一块、搜索结果一块，中间留一道空白。
///
/// 2026-10-27 用户定稿：原来是一整块玻璃，搜索框只是里面的一行，于是只有搜索框时
/// 外面还裹着一层壳、胶囊四周多出遮罩，很丑。现在每块模块自己就是一个完整的玻璃面，
/// 圆角统一由 `SearchModuleLayout.moduleRadius` 给（**不许**在视图里另写一个数）。
struct SearchModuleSurface: ViewModifier {
    let style: SearchGlassStyle
    var radius: CGFloat = SearchModuleLayout.moduleRadius

    @Environment(\.colorScheme) private var colorScheme

    private var isDark: Bool { colorScheme == .dark }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background {
                Group {
                    if style == .glass {
                        glassShape(shape)
                    } else {
                        shape.fill(.regularMaterial)
                            // 老方案没有玻璃自带的层次，用一层很浅的投影把它从桌面上分开。
                            // 窗口本身的阴影已关掉（见 SearchPanelController），否则会画出
                            // 一整块矩形阴影，把「两块模块」又糊回一块。
                            .shadow(color: .black.opacity(0.16), radius: 14, y: 5)
                    }
                }
                // ★★ 表面**不参与命中测试**（2026-10-28 报障：「闪寻搜索框不能拖动了」）。
                //
                // `NSPanel.isMovableByWindowBackground` 能不能真的拖，取决于光标下面
                // 那个视图是否「允许窗口背景拖动」。一块铺满整窗的 `shape.fill` 在
                // SwiftUI 看来就是**内容**，于是整块面板从「空白可拖」变成「实心不可拖」——
                // 这正是模块化之后拖动失效的原因：两块模块各自铺满，连 10pt 缝隙
                // 都在窗口透明区之外，一个可抓的位置都不剩。
                // 让背景不参与命中测试，光标落空处就仍然是「窗口背景」，照样能拖；
                // 按钮、输入框、结果行、滚动区都在前景层，一个都没让出去。
                //
                // ★ 实测（2026-10-28，预览包 + 合成拖动 + CGWindowList 对坐标）：
                //   · 去掉这一句：留白处 `hitTest` 命中 `TransparentHostingView`，
                //     `mouseDownCanMoveWindow` 虽是 true，窗口从 620,30 **纹丝不动**；
                //   · 留着这一句：同一处 `hitTest` 返回 nil，窗口跟着光标走 89,69。
                //   ⇒ 判据不是「那个属性返回什么」，而是「这一处有没有被 SwiftUI 认领」。
                //   证据：`04-测试与验收/ui-search-modules-pin-20261028/`。
                .allowsHitTesting(false)
            }
            // 内容（尤其是结果列表的滚动内容）不许溢出圆角。
            .clipShape(shape)
            // ★★ 描边必须画在 `clipShape` **之后**（2026-10-28 报障：
            //   「动态玻璃效果如果屏幕是纯白背景时显示效果不好，建议增强一下边框」）。
            //
            //   之前这块玻璃只有材质、**一圈描边都没有**：Liquid Glass 靠背景折射出
            //   层次，背景也是白的就没层次可折，整块白玻璃在白桌面上直接消失
            //   （用户截图里只剩一点阴影）。描边是唯一能保证边界的东西。
            //
            //   三层都写在这里：外描边（浅色外观黑 12% / 深色白 18%）
            //   + 上半段内高光（玻璃的厚边）。取值全在 Core 的 `SearchGlassEdge`，
            //   视图里不再出现「0.25 的白」这种看不出意图的数字。
            //
            //   仍然 `allowsHitTesting(false)`：描边是表面的一部分，
            //   它一旦参与命中测试，空白处就又拖不动窗口了（见上面那段注释）。
            .overlay { edge(shape) }
            // 鼠标滑进来时盖上的那层液态玻璃（2026-10-30 用户：「搜索鼠标滑动时
            // 覆盖一层液态玻璃遮罩」）。同样只是表面，不参与命中测试——
            // 否则悬停反馈会把「空白处能拖窗口」这件事一起吃掉。
            .searchHoverVeil(shape: shape, isDark: isDark)
    }

    /// 模块边缘那一圈：外分界线 + 上半段内高光。
    private func edge(_ shape: RoundedRectangle) -> some View {
        shape
            .strokeBorder(Color(glassStroke: SearchGlassEdge.outer(dark: isDark)),
                          lineWidth: SearchGlassEdge.strokeWidth)
            .overlay {
                shape.strokeBorder(
                    LinearGradient(colors: [Color(glassStroke: SearchGlassEdge.innerHighlight(dark: isDark)),
                                            Color(glassStroke: SearchGlassEdge.innerHighlight(dark: isDark))
                                                .opacity(SearchGlassEdge.innerHighlightBottomAlpha)],
                                   startPoint: .top, endPoint: .bottom),
                    lineWidth: SearchGlassEdge.highlightWidth)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)
    }

    @ViewBuilder private func glassShape(_ shape: RoundedRectangle) -> some View {
        if isDark {
            #if compiler(>=6.2)
            if #available(macOS 26.0, *) {
                shape.fill(Color.white.opacity(0.001))
                    .glassEffect(.regular, in: shape)
                    .overlay { tint(shape) }
            } else {
                shape.fill(.regularMaterial)
            }
            #else
            shape.fill(.regularMaterial)
            #endif
        } else {
            // 浅色：**背景真高斯模糊** + 一层薄白膜。
            //
            // ★ 2026-10-30 用户：「浅色模式改成底部背景高斯模糊质感」。
            //   原来浅色也走 `.glassEffect(.regular)`，它把背景洗成一片白——
            //   糊掉的是颜色，看不到质感。现在改成系统的 behindWindow 模糊，
            //   壁纸的形状与颜色都还在，只是一片糊；白膜（`SearchGlassTint.lightAlpha`）
            //   只负责把文字从小花壁上按住。
            ZStack {
                // ★ 半径照样传下去：外层 `clipShape` 基本能裁住这块 AppKit 材质
                //   （2026-10-30 用 `FF_UI_BACKDROP_NO_ROUND=1` 验过，边缘只剩 1–2pt 泄漏），
                //   所以这里是双保险。见 `SearchBackdropBlur` 的说明。
                SearchBackdropBlur(cornerRadius: radius)
                tint(shape)
            }
        }
    }

    /// 压在底面之上的那层「调子」：深色是黑（把玻璃压暗），浅色是白（把文字按住）。
    ///
    /// 2026-10-30 用户拿聚焦搜索对标：「暗色模式下闪寻的颜色和聚焦搜索不一样，
    /// 聚焦搜索更暗一些，感觉更舒服」。`.glassEffect(.regular)` 在浅色壁纸上会被
    /// 折射得发白，压一层半透明黑才靠近系统那块深灰玻璃。数值在 Core
    /// （`SearchGlassTint`）。
    ///
    /// 画在 `background` 里（`content` 之前），所以正文、图标、结果行不受影响。
    @ViewBuilder private func tint(_ shape: RoundedRectangle) -> some View {
        let alpha = SearchGlassTint.alpha(dark: isDark)
        if alpha > 0 {
            shape.fill(Color(isDark ? .black : .white).opacity(alpha)).allowsHitTesting(false)
        }
    }
}

extension View {
    /// 把当前视图包成一块模块（自带圆角表面，圆角取 Core 的值）。
    func searchModuleSurface(_ style: SearchGlassStyle) -> some View {
        modifier(SearchModuleSurface(style: style))
    }
}
