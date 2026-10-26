import SwiftUI

struct SearchStateView: View {
    let symbol: String
    let title: String
    let detail: String
    var loading = false
    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if loading { ProgressView().controlSize(.small).padding(.top, 3) }
            else { Image(systemName: symbol).font(.system(size: 19)).foregroundStyle(.secondary).padding(.top, 2) }
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.system(size: 14, weight: .medium))
                Text(detail).font(.callout).foregroundStyle(.secondary).lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true).help(detail)
            }
            Spacer(minLength: 0)
        }.padding(.horizontal, 22).padding(.vertical, 18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
    }
}

struct SearchStatusBar: View {
    let message: String
    let count: Int
    let updating: Bool
    var warnings: [String] = []
    var configureSources: (() -> Void)? = nil
    @State private var showWarnings = false
    var body: some View {
        HStack(spacing: 12) {
            Text(message.isEmpty ? "↑↓ 选择   Space 预览   ↵ 打开   ⌘↵ Finder   esc 隐藏" : message)
                .lineLimit(1).truncationMode(.middle).help(message)
            Spacer(minLength: 8)
            if !warnings.isEmpty {
                Button { showWarnings = true } label: {
                    Label("\(warnings.count) 项提示", systemImage: "exclamationmark.circle")
                }.buttonStyle(.plain).fixedSize().help("查看全部搜索提示")
                    .popover(isPresented: $showWarnings) {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 10) {
                                Text("搜索提示").font(.headline)
                                if let configureSources { Button("打开搜索来源设置", action: configureSources) }
                                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                    Text(warning).font(.callout).textSelection(.enabled)
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: 360).frame(maxHeight: 260)
                    }
            }
            Text(updating ? "搜索中…" : "\(count) 项").monospacedDigit().fixedSize()
        }.font(.system(size: 11)).foregroundStyle(.secondary)
            .padding(.horizontal, 22).frame(height: 32)
    }
}

/// 打开/定位失败时的提示条。
///
/// 规划书要求这类失败必须说清「发生了什么、接下来怎么办」，
/// 不允许只抛 `Open failed` / `Error -36` 这种技术文本。
///
/// NAS 文件打不开时，`failure.smbURL` 里带着可手动挂载的 smb:// 地址。
/// 闪寻**不会**自己弹访达的连接窗口（公网域名场景下那是必败的打扰），
/// 只有用户点这里这个按钮才弹。
struct OpenFailureBanner: View {
    let failure: AppModel.OpenFailure
    let onRetry: () -> Void
    var onConnectInFinder: (() -> Void)? = nil
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 3) {
                Text("无法打开文件").font(.system(size: 13, weight: .medium))
                Text(failure.message).font(.callout).foregroundStyle(.secondary)
                    // 高度是固定的（见 SearchLayout.openFailureBannerHeight）：
                    // 长句截断到两行，全文走悬停，不能让提示条自己长高把浮窗撑变形。
                    .lineLimit(2).fixedSize(horizontal: false, vertical: true).help(failure.message)
            }
            Spacer(minLength: 8)
            HStack(spacing: 8) {
                if let onConnectInFinder {
                    Button("在访达中连接", action: onConnectInFinder)
                        .controlSize(.small).help("用访达连接共享后再重试")
                }
                Button("重试", action: onRetry).controlSize(.small)
                Button("知道了", action: onDismiss).controlSize(.small)
            }
        }
        .padding(.horizontal, 22)
        .frame(height: SearchLayout.openFailureBannerHeight)
        .background(Color(nsColor: .controlBackgroundColor).opacity(0.96))
        .overlay(alignment: .top) { Divider() }
    }
}
