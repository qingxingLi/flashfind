import AppKit
import SwiftUI
import FlashFindCore

/// 设置窗口的整窗外壳：白底、卡片、分隔线、行内边距。
///
/// 这里是**唯一**决定设置界面表面长什么样的地方。策略来自 Core
/// （`SettingsSurface`）：浅色纯白底 + **与搜索模块同一套 Liquid Glass 卡**，
/// 深色沿用毛玻璃底 + 材质卡。四个页面不许各自再写一遍配色。

// MARK: - 能力探测

/// 「这台机器此刻该用哪一套表面」：能力在 App 层问，长什么样由 Core 定。
///
/// ★ 与 `SearchGlass` 同一套两门探测（编译期 SDK + 运行期系统），
/// 但**多一条**：开了「降低透明度」时不铺真玻璃 —— 那会让文字漂在桌面上，
/// 搜索区也是同一条规矩（`SearchGlassStyle.resolve`）。
enum SettingsGlass {
    static func style(isDark: Bool, reduceTransparency: Bool) -> SettingsSurface.Style {
        SettingsSurface.style(isDark: isDark,
                              liquidGlassAvailable: SearchGlass.isAvailable && !reduceTransparency)
    }
}

// MARK: - 窗底

/// 窗口底：浅色**纯白**，深色沿用系统窗口毛玻璃。
///
/// 原来浅色也走 `WindowBackdrop`（`NSVisualEffectView` 的 `.underWindowBackground`），
/// 桌面颜色会透上来，整窗就是一片灰白；用户要的是纯白。
struct SettingsBackdrop: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let style = SettingsGlass.style(isDark: scheme == .dark, reduceTransparency: reduceTransparency)
        ZStack {
            switch style.backdrop {
            case .pureWhite: Color.white
            case .windowVibrancy: WindowBackdrop()
            }
            // 内容区之下的白是 SwiftUI 画的，标题栏还是 AppKit 画的：
            // 不把窗口自己的底色也换掉，顶上会留下一条灰。
            SettingsWindowTint()
        }
    }
}

/// 把窗口自己的底色与标题栏调成同一套（浅色纯白 / 深色维持系统窗口色）。
///
/// SwiftUI 的 `.background` 只能盖住内容区，红绿灯那一条标题栏归 `NSWindow` 管。
/// 外观随时可能变（「外观」那一项就在设置里），所以按 `effectiveAppearance`
/// 每次更新，而不是在创建窗口时定一次。
private struct SettingsWindowTint: NSViewRepresentable {
    @Environment(\.colorScheme) private var scheme

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        let dark = scheme == .dark
        DispatchQueue.main.async {
            guard let window = view.window else { return }
            if dark {
                // 深色维持现状：系统窗口底色 + 系统标题栏。
                window.backgroundColor = .windowBackgroundColor
                window.titlebarAppearsTransparent = false
            } else {
                window.backgroundColor = .white
                // 透明标题栏会用窗口底色作背景，整窗才是一整片白。
                window.titlebarAppearsTransparent = true
            }
        }
    }
}

// MARK: - 卡片

/// 一个分组：标题 + 一张卡片 +（需要时）一行页脚。
///
/// 取代之前的 `Section { } header: { }`：分组表单的卡片底色与投影由系统画，
/// 改不动；这次要的「纯白上只留玻璃遮罩」只能自己画。
struct SettingsCard<Content: View>: View {
    /// `nil` 表示不写标题：来源详情顶部那块「身份 + 名字」本身就是一段，
    /// 再给它安一个标题（「来源」/「名称」）只会多一行字。
    private let title: String?
    private let footer: String?
    private let content: Content

    init(_ title: String? = nil, footer: String? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.footer = footer
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            if let title {
                Text(title)
                    .font(.system(size: SettingsTypography.sectionHeader, weight: .semibold))
                    .padding(.leading, 2)
            }

            VStack(spacing: 0) { content }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background { SettingsCardSurface() }

            if let footer {
                Text(footer)
                    .font(.system(size: SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            }
        }
    }
}

/// 卡片本体的表面。
///
/// 浅色：**与搜索模块同一套 Liquid Glass**（`SearchModuleSurface` 那一句照抄），
/// 加一道 0.5pt 描边 —— 纯白底上玻璃几乎没有边界，没描边就看不出卡片在哪。
/// 深色：材质 + 描边 + 投影，与这次改动之前的样子一致。
///
/// ★ 2026-10-27 深夜改口（用户：「设置页 UI 界面跟着搜索这一块走」）：
///   浅色卡片原来用 `.ultraThinMaterial` 手搓一层「玻璃遮罩」，理由是实测
///   `NSGlassEffectView` 会在卡片四周画一圈外阴影（`v4-search-light.png`
///   与 `probe-noglass.png` 两张对照，高卡右缘约 8pt 灰边）。
///   现在按要求换成真玻璃，那道外阴影用 **`.clipShape(shape)` 裁掉** ——
///   搜索模块一直是这么做的（`SearchModuleSurface` 里 `.background{glass}` +
///   `.clipShape`），所以它没有灰边。像素采样见
///   `04-测试与验收/ui-settings-glass-follow-20261027/`。
struct SettingsCardSurface: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    var body: some View {
        let style = SettingsGlass.style(isDark: scheme == .dark, reduceTransparency: reduceTransparency)
        surface(style)
    }

    @ViewBuilder private func surface(_ style: SettingsSurface.Style) -> some View {
        let shape = RoundedRectangle(cornerRadius: style.cardRadius, style: .continuous)
        switch style.card {
        case .liquidGlass:
            liquidGlass(shape, style)

        case .glassMask:
            glassMask(shape, style)

        case .elevatedMaterial:
            // 深色沿用原来的层次：卡片比窗底**亮一点**，再加一层很淡的投影。
            // ★ 这里不用 `.regularMaterial`：材质在深色模式下是「压暗」的，
            //   铺在深色窗底上会比背景更黑，卡片反而陷下去了（实测 54 vs 71）。
            shape
                .fill(Color.white.opacity(0.06))
                .overlay { shape.strokeBorder(Color.white.opacity(style.cardStroke), lineWidth: 0.5) }
                .compositingGroup()
                .shadow(color: .black.opacity(style.cardShadow ? 0.28 : 0), radius: 7, y: 2)
        }
    }

    /// 与搜索模块同一句 `glassEffect(.regular, in:)`。
    ///
    /// ★ `.clipShape` 不是可有可无的收尾：玻璃会往自己外面画一圈暗边，
    ///   在纯白窗底上就是一条脏边。实测（2026-10-27 深夜，同一页同一张卡）：
    ///   不裁时描边外侧多出 1–3px、亮度 187–234 的暗边；裁掉之后是
    ///   `237 → 220（描边）→ 255`，边缘干净。搜索模块一直带着这个裁切。
    @ViewBuilder private func liquidGlass(_ shape: RoundedRectangle,
                                         _ style: SettingsSurface.Style) -> some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            shape
                .fill(Color.white.opacity(0.001))
                .glassEffect(.regular, in: shape)
                .overlay { shape.strokeBorder(Color.black.opacity(style.cardStroke), lineWidth: 0.5) }
                .clipShape(shape)
        } else {
            glassMask(shape, style)
        }
        #else
        glassMask(shape, style)
        #endif
    }

    /// 玻璃用不了时的替身（macOS 15 / 降低透明度）：材质 + 极浅的膜 + 上沿高光 + 描边。
    private func glassMask(_ shape: RoundedRectangle, _ style: SettingsSurface.Style) -> some View {
        shape
            .fill(.ultraThinMaterial)
            .overlay { shape.fill(Color.black.opacity(0.02)) }
            .overlay {
                // 上亮下暗的极淡竖渐变：有玻璃的「面」，但不像投影。
                shape.fill(
                    LinearGradient(colors: [.white.opacity(0.55), .white.opacity(0.0)],
                                   startPoint: .top, endPoint: .bottom)
                )
            }
            .overlay { shape.strokeBorder(Color.black.opacity(style.cardStroke), lineWidth: 0.5) }
    }
}

/// 卡片内部的行：左右 14、上下 8。
///
/// 之前这些内边距是 `Form` 给的；自己画卡片之后必须显式写，否则行会贴着边框。
///
/// ★ 顺序不能反：`frame` 必须在 `padding` **之前**。`Form` 的行是「标签在左、
///   控件贴右」的，靠的就是把这一行撑满；先加内边距再 `frame`，撑大的是
///   内边距那层壳，里面的 Toggle 仍是自然宽度，开关就会紧贴在文字后面。
extension View {
    func settingsRow(inset: CGFloat = 14) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, inset)
            .padding(.vertical, 8)
            .contentShape(Rectangle())
    }
}

/// 「左边一句开关名、右边一个开关」的一行。
///
/// `.toggleStyle(.switch)` 的 Toggle 只占自己那么大，`.frame(maxWidth: .infinity)`
/// 撑开的是外层壳、开关仍然紧跟在文字后面（设置页第一版就是这样，开关停在句子中间）。
/// 所以这里用 `Spacer` 把开关顶到行尾，标签另挂 `accessibilityLabel`
/// ——视觉上分成两截，VoiceOver 仍读成「登录时启动闪寻，开关」。
struct SettingsSwitchRow: View {
    private let label: String
    @Binding private var isOn: Bool

    init(_ label: String, isOn: Binding<Bool>) {
        self.label = label
        _isOn = isOn
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: SettingsTypography.body))
            Spacer(minLength: 12)
            Toggle("", isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .accessibilityLabel(label)
        }
    }
}

/// 卡片内部的分隔线：与文字左缘对齐。
struct SettingsRowDivider: View {
    var inset: CGFloat = 14

    var body: some View {
        Divider()
            .padding(.leading, inset)
            .opacity(0.55)
    }
}

/// 「左边一句标签、右边一个控件」的一行。
///
/// ★ 不用 `LabeledContent`：它是为 `Form` 写的。离开 `Form` 之后，
///   一是标签与控件会**紧挨着**排（右边空出一大片），二是它内部要问父视图
///   要一条基线对齐信息——`Form` 给得出来，普通 `VStack` 给不出来，
///   整页直接在这一步崩（2026-10-27 实测 `_FlexFrameLayout.placement` SIGTRAP）。
///   这个组件只做一件事：标签靠左、控件贴右，中间用 `Spacer` 顶开。
struct SettingsLabeledRow<Content: View>: View {
    private let label: String
    private let content: Content

    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }

    var body: some View {
        HStack(spacing: 12) {
            Text(label).font(.system(size: SettingsTypography.body))
            Spacer(minLength: 12)
            content
        }
    }
}

// MARK: - 顶部导航

/// 一级导航：四段玻璃胶囊，选中块是**会滑过去**的那一小块玻璃。
///
/// 之前是系统 `Picker(.segmented)`：宽度紧、选中态只是一个白底方块，
/// 换页时没有任何过渡。用户要的是「间距拉开 + 切换页面出现动态玻璃的切换效果」，
/// 系统控件给不了滑动的选中块，所以这里自绘——但**页面集合仍然只来自 Core**
/// （`SettingsPane.allCases`），每段的无障碍标识也照旧。
struct SettingsPanePicker: View {
    @Binding var selection: SettingsPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorScheme) private var scheme
    @Namespace private var indicator

    var body: some View {
        HStack(spacing: 3) {
            ForEach(SettingsPane.allCases) { item in
                segment(item)
            }
        }
        .padding(5)
        .background { track }
        .overlay {
            // 胶囊外圈：深色下才需要一道亮边，浅色只有极淡的一圈。
            Capsule(style: .continuous)
                .strokeBorder(borderColor, lineWidth: 0.5)
        }
        // 容器自身不接收点击：点在两段之间的空隙上不该有反应，也不该抢走键盘焦点。
        .accessibilityElement(children: .contain)
        .accessibilityLabel("设置页面")
        .accessibilityIdentifier("settings-pane-picker")
        .task { await switchPaneInPreviewIfRequested() }
    }

    /// 预览构建里可以让程序**定时切一次页**：`FF_UI_PANE_SWITCH=<秒>`。
    ///
    /// 与 `FF_UI_QUICKPICK_SWITCH` 同一个理由：滑动只存在于那几帧里，
    /// 手点完再截图只能拿到结束态——「切之前」和「切之后」两张都正常，
    /// 既证明不了有动画，也证明不了没有（2026-10-27 审查 F02 就是这么漏的）。
    /// 有了这个钩子，外部可以连续截帧，验「选中块确实停在两段之间」。
    ///
    /// 与其它 `FF_UI_*` 一样只在预览构建里生效，且走的是**用户点下去的同一条**
    /// `select(_:)`——钩子另写一份切换，验到的就是钩子而不是产品。
    private func switchPaneInPreviewIfRequested() async {
        #if DEBUG
        guard AppEnvironment.isPreview,
              let raw = ProcessInfo.processInfo.environment["FF_UI_PANE_SWITCH"],
              let delay = Double(raw), delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        let all = SettingsPane.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        select(all[(index + 1) % all.count])
        #endif
    }

    private func segment(_ item: SettingsPane) -> some View {
        let isSelected = item == selection
        return Button {
            select(item)
        } label: {
            Text(item.rawValue)
                // 「间距拉开」：段本身就有 26pt 的左右留白，
                // 不再是系统分段控件那种挤在一起的样子。
                .font(.system(size: SettingsTypography.body, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? AnyShapeStyle(.primary) : AnyShapeStyle(.secondary))
                .padding(.horizontal, 26)
                .padding(.vertical, 6)
                .frame(minWidth: 76)
                .contentShape(.rect)
                .background {
                    if isSelected { selectedGlass }
                }
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("settings-nav-" + item.rawValue)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        // 系统分段控件能用左右方向键换段，自绘之后这层要自己补：
        // 焦点在这一段上时按 ← → 就切到相邻页，与原来的手感一致。
        .onMoveCommand { direction in
            if direction == .left { step(-1) } else if direction == .right { step(1) }
        }
    }

    /// 往左/右挪一页。到头就停住（不循环：循环会让「已经在最后」的人以为没动）。
    private func step(_ delta: Int) {
        let all = SettingsPane.allCases
        guard let index = all.firstIndex(of: selection) else { return }
        let next = index + delta
        guard all.indices.contains(next) else { return }
        select(all[next])
    }

    /// 选中块：同一小块玻璃在四段之间滑过去（`matchedGeometryEffect`）。
    ///
    /// 圆角取 `SearchModuleLayout.segmentRadius`：类型条选中那段就是它，
    /// 两处选中的「一块亮底」必须同一个形状，否则并排看会像两代设计。
    @ViewBuilder private var selectedGlass: some View {
        let shape = RoundedRectangle(cornerRadius: SearchModuleLayout.segmentRadius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesGlass {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: SearchModuleLayout.segmentRadius))
                .overlay { shape.fill(Color.white.opacity(isDark ? 0.13 : 0.55)) }
                .overlay { shape.strokeBorder(pillStroke, lineWidth: 0.5) }
                .matchedGeometryEffect(id: "settings-pane-indicator", in: indicator)
        } else {
            fallbackIndicator(shape)
        }
        #else
        fallbackIndicator(shape)
        #endif
    }

    private func fallbackIndicator(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(Color(nsColor: .controlBackgroundColor))
            .overlay { shape.strokeBorder(pillStroke, lineWidth: 0.5) }
            .matchedGeometryEffect(id: "settings-pane-indicator", in: indicator)
    }

    @ViewBuilder private var track: some View {
        let capsule = Capsule(style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), usesGlass {
            capsule
                .fill(.clear)
                .glassEffect(.regular, in: .capsule)
                .overlay { capsule.fill(isDark ? Color.white.opacity(0.05) : Color.black.opacity(0.03)) }
        } else {
            capsule.fill(.ultraThinMaterial)
        }
        #else
        capsule.fill(.ultraThinMaterial)
        #endif
    }

    private var isDark: Bool { scheme == .dark }

    /// 铺不铺真玻璃。与卡片同一条判据：拿不到玻璃、或开了「降低透明度」就退回材质。
    ///
    /// ★ 之前这里只判 `#available`：用户打开「降低透明度」之后，四段导航和选中块
    ///   仍是真玻璃，而同一窗口里的卡片已经退回实心——同一屏两套材质。
    private var usesGlass: Bool { SearchGlass.isAvailable && !reduceTransparency }

    /// 胶囊外圈：深色靠亮边，浅色只有极淡的一圈。
    private var borderColor: Color {
        isDark ? Color.white.opacity(0.10) : Color.black.opacity(0.06)
    }

    private var pillStroke: Color {
        isDark ? Color.white.opacity(0.12) : Color.black.opacity(0.05)
    }

    /// 换页。动画只在这一处：选中块滑过去 + 内容淡入淡出（见 `SettingsView.content`）。
    ///
    /// 「减少动态效果」打开时不滑，直接落位——系统设置里这一档也是这么做的。
    private func select(_ next: SettingsPane) {
        guard next != selection else { return }
        if reduceMotion {
            selection = next
        } else {
            withAnimation(.spring(response: 0.34, dampingFraction: 0.80)) {
                selection = next
            }
        }
    }
}
