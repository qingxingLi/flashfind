import SwiftUI
import FlashFindCore

struct FFGlassSurface: View {
    var radius: CGFloat = 12

    var body: some View {
        #if compiler(>=6.2)
        if #available(macOS 26.0, *) {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
        } else {
            fallback
        }
        #else
        fallback
        #endif
    }

    private var fallback: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(.regularMaterial)
    }
}

/// 闪寻的基础组件。群晖、飞牛、绿联共用这一套，不为每个品牌各写一遍 UI。
/// 视觉原则：结构负责清晰，原生材质为表单分组提供轻盈的层次。

struct FFSettingsSection<Content: View, Trailing: View>: View {
    let title: String
    var footer: String?
    let trailing: Trailing
    @ViewBuilder var content: () -> Content

    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 标题行右侧可以挂控件（例：搜索位置列表的「全选 / 取消全选」）。
    /// 控件放在标题行而不是卡片里：卡片内每一行都是数据，混进操作会让
    /// 「这一行能不能勾」和「这一颗按下去干什么」看起来像同一类东西。
    init(title: String, footer: String? = nil,
         @ViewBuilder trailing: () -> Trailing,
         @ViewBuilder content: @escaping () -> Content) {
        self.title = title
        self.footer = footer
        self.trailing = trailing()
        self.content = content
    }

    /// 没有右侧控件的那种（大多数 Section）。
    init(title: String, footer: String? = nil, @ViewBuilder content: @escaping () -> Content)
    where Trailing == EmptyView {
        self.title = title
        self.footer = footer
        self.trailing = EmptyView()
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(title).ffFont(.sectionHeader).foregroundStyle(.secondary)
                Spacer(minLength: 0)
                trailing
            }
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background { sectionBackground }
            if let footer {
                Text(footer).ffFont(.footer).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }

    /// 分组底：与设置页卡片、搜索模块**同一套**（同一句 `glassEffect(.regular)`、
    /// 同一个 `SearchModuleLayout.moduleRadius`、同一道 0.5pt 描边）。
    ///
    /// ★ 2026-10-27 深夜用户定：「设置页 UI 界面跟着搜索这一块走」，向导一起跟随。
    ///   原来这里是 12 圆角、无描边 —— 同一产品里三种卡片圆角（12 / 12 / 20），
    ///   向导与设置页并排看就不是一套东西。
    /// ★ `.clipShape` 与设置页卡片同理：把玻璃自带的外阴影裁掉，免得边缘发灰。
    @ViewBuilder private var sectionBackground: some View {
        let radius = SearchModuleLayout.moduleRadius
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        #if compiler(>=6.2)
        if #available(macOS 26.0, *), SearchGlass.isAvailable, !reduceTransparency {
            shape
                .fill(.clear)
                .glassEffect(.regular, in: .rect(cornerRadius: radius))
                .overlay { shape.strokeBorder(strokeColor, lineWidth: 0.5) }
                .clipShape(shape)
        } else {
            sectionFallback(shape)
        }
        #else
        sectionFallback(shape)
        #endif
    }

    private func sectionFallback(_ shape: RoundedRectangle) -> some View {
        shape
            .fill(.regularMaterial)
            .overlay { shape.strokeBorder(strokeColor, lineWidth: 0.5) }
    }

    /// 描边：深色用亮边，浅色用极淡的黑边。纯白底上玻璃几乎没有边界。
    private var strokeColor: Color {
        scheme == .dark ? Color.white.opacity(0.10) : Color.black.opacity(0.07)
    }
}

struct FFErrorBanner: View {
    let message: String
    var action: (title: String, run: () -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).ffFont(.stateDetail).fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if let action {
                Button(action.title, action: action.run).controlSize(.small)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color.orange.opacity(0.12)))
    }
}

struct FFPrimaryButton: View {
    let title: String
    var systemImage: String? = nil
    var enabled = true
    let run: () -> Void
    init(_ title: String, systemImage: String? = nil, enabled: Bool = true, action: @escaping () -> Void) {
        self.title = title; self.systemImage = systemImage; self.enabled = enabled; self.run = action
    }
    var body: some View {
        Button(action: run) {
            HStack(spacing: 6) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
        }
        .buttonStyle(.borderedProminent).controlSize(.large).disabled(!enabled)
    }
}

struct FFSecondaryButton: View {
    let title: String
    var role: ButtonRole? = nil
    let run: () -> Void
    init(_ title: String, role: ButtonRole? = nil, action: @escaping () -> Void) {
        self.title = title; self.role = role; self.run = action
    }
    var body: some View {
        Button(role: role, action: run) { Text(title) }
            .controlSize(.large)
    }
}
