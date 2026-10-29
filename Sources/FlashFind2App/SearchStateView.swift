import SwiftUI
import FlashFindCore

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
                Text(title).ffFont(.stateTitle)
                Text(detail).ffFont(.stateDetail).foregroundStyle(.secondary).lineLimit(3)
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
    /// 当前**显示**了几条（上限之内的那一批）。
    let count: Int
    /// 本次搜索总共匹配多少条（去重后）。`<= count` 表示没被上限截断。
    var total: Int = 0
    let updating: Bool
    var warnings: [String] = []
    /// 候选池里还有没显示的行（用户 2026-10-28：「对结果不满意，可以选择继续搜索」）。
    var canShowMore: Bool = false
    /// 点「继续搜索」：再放一批（`SearchResultLimit.step` 条）。
    var showMore: (() -> Void)? = nil
    var configureSources: (() -> Void)? = nil
    @State private var showWarnings = false
    private var truncated: Bool { total > count && count > 0 }
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
                                Text("搜索提示").ffFont(.sectionHeader)
                                if let configureSources { Button("打开搜索来源设置", action: configureSources) }
                                ForEach(Array(warnings.enumerated()), id: \.offset) { _, warning in
                                    Text(warning).ffFont(.stateDetail).textSelection(.enabled)
                                }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                        }.frame(width: 360).frame(maxHeight: 260)
                    }
            }
            // ★ 被上限截断时写「200 / 1374 项」而不是只写 200：
            //   只显示 200 会让用户以为目录里只有 200 个匹配，从而得出
            //   「我的文件丢了」这个结论。全句在悬停里说完整。
            Text(updating ? "搜索中…" : (truncated ? "\(count) / \(total) 项" : "\(count) 项"))
                .monospacedDigit().fixedSize()
                .help(truncated ? (SearchResultLimit.caption(totalMatched: total, shown: count) ?? "") : "")
            // ★ 上限不是死路：200 条只是**第一批**。
            //   按钮只在「池子里还有」时出现，取完自动消失——
            //   留着它会让人以为还能继续，点了却没反应。
            if canShowMore, let showMore {
                Button(action: showMore) {
                    Text(SearchResultLimit.continueTitle)
                }
                .buttonStyle(.plain)
                .foregroundStyle(.tint)
                .fixedSize()
                .help(SearchResultLimit.continueHelp(remaining: max(0, total - count)))
                .accessibilityIdentifier("search-continue-button")
            }
        }.ffFont(.statusBar).foregroundStyle(.secondary)
            .padding(.horizontal, 22).frame(height: 32)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(truncated
                ? "已显示 \(count) 条，共 \(total) 条匹配"
                : "\(count) 项")
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
                Text("无法打开文件").ffFont(.bannerTitle)
                Text(failure.message).ffFont(.stateDetail).foregroundStyle(.secondary)
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
