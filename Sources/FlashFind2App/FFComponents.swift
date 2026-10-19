import SwiftUI
import FlashFindCore

/// 闪寻的基础组件。群晖、飞牛、绿联共用这一套，不为每个品牌各写一遍 UI。
/// 视觉原则：结构负责清晰，玻璃负责氛围——设置页里的 Section 不做透明卡片，
/// 只在主搜索浮窗、侧栏、弹出层上使用材质。

struct FFSettingsSection<Content: View>: View {
    let title: String
    var footer: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.system(size: 13, weight: .semibold)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) { content() }
                .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 0.5))
            if let footer {
                Text(footer).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.bottom, 4)
    }
}

struct FFErrorBanner: View {
    let message: String
    var action: (title: String, run: () -> Void)?
    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(message).font(.callout).fixedSize(horizontal: false, vertical: true)
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
