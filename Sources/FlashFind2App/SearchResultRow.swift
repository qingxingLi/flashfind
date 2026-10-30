import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FlashFindCore

/// 搜索结果行。三层信息：文件名 / 路径 / 来源。
///
/// 刻意不显示 size、inode、owner、taskid、API 等技术字段——
/// 用户只需要知道「文件在哪里」。
///
/// ## 高亮由外部给（2026-10-27）
///
/// 以前这一行自己 `@State hovered` 画一层灰底，选中交给 `List` 画蓝底。
/// 现在两种底色都换成「一块跟着鼠标滑动的玻璃遮罩」，遮罩是**整张列表共用**
/// 的一个视图（在 `SearchView` 里），所以「哪一行被指到」必须由外面告诉它，
/// 否则遮罩滑到第 5 行、第 3 行还自己亮着，看起来像两处同时选中。
struct SearchResultRow: View {
    let result: SearchResult
    var isSelected = false
    var showsFullPath = true
    /// 当前表面：玻璃模式下这一行不画任何底色（遮罩画在行下面）。
    var style: SearchGlassStyle = .legacy
    /// 指针是否停在这一行。由列表统一维护，见类型注释。
    var isHovered = false
    /// 遮罩中心在第几行（可为小数）与它是否在场——交给文字做放大/缩小。
    ///
    /// ★ 缩放**只作用在文字块**，不作用整行：整行放大 5.5% 会把行尾的
    /// 「此 Mac」推出可视区（第一版就是这样，截图上右侧被切掉一截）。
    /// 官方那套玻璃胶囊里变大的也是图标与标签本身，不是它们的容器。
    var lensPosition: CGFloat = 0
    var lensRow: Int = 0
    var lensActive = false
    /// 遮罩在场程度（0…1）。与 `lensActive` **不是一回事**：那个还带着「不许动」
    /// （开了「减少动态效果」时为 false），而染色是颜色不是运动——
    /// 那种情况下字照样该变蓝，只是不再跟手渐变。共用一处会让无障碍设置把染蓝一起关掉。
    var lensPresence: Double = 0
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorScheme) private var colorScheme

    private var fileType: UTType { UTType(filenameExtension: (result.name as NSString).pathExtension) ?? .data }

    /// 是不是一个已安装的应用（应用搜索的结果行）。
    private var isApp: Bool { result.sourceID == SearchSource.apps.id }

    /// 老方案的选中态：自绘时必须连文字颜色一起改，
    /// `List` 当年是把底色和字色一起换的（蓝底黑字看不清）。
    private var legacySelection: Bool { style == .legacy && isSelected }
    private var legacyHover: Bool { style == .legacy && isHovered && !isSelected }

    /// 来源标签。本机显示「此 Mac」，应用显示「应用程序」，NAS 显示来源名，
    /// 不带地址与协议。
    private var badge: String {
        if isApp { return SearchSource.apps.displayName }
        return result.sourceType == .local ? SearchSource.local.displayName
            : (result.connectionName ?? result.sourceName)
    }
    private var badgeSymbol: String {
        if isApp { return "app" }
        return result.sourceType == .local ? "desktopcomputer" : "externaldrive.connected.to.line.below"
    }

    /// 行首图标。应用用 **app 本体自带**的图标——访达里长什么样，这里就长什么样；
    /// 文件夹与其余文件按类型取系统图标。
    private var rowIcon: NSImage {
        if isApp, let url = result.localURL { return NSWorkspace.shared.icon(forFile: url.path) }
        return NSWorkspace.shared.icon(for: result.kind == "directory" ? .folder : fileType)
    }
    /// 路径展示：本机用真实路径，NAS 用共享内路径，不暴露 smb:// 与端口。
    private var pathText: String {
        result.sourceType == .local ? (result.localURL?.path ?? result.relativePath) : result.relativePath
    }

    /// 文件名那一行。
    ///
    /// 玻璃方案下**只有它在变蓝**：路径与来源标签保持灰色——用户给的参考图里
    /// 「最近通话」变蓝，下面那行「主号 手机」仍是灰的。全行都染色反而像报错。
    @ViewBuilder private var nameLabel: some View {
        let text = Text(result.name).ffFont(.resultName)
            .lineLimit(1).truncationMode(.middle)
        if style == .glass {
            // 染色曲线在 Core（`SearchSelectionInk`），这里只把遮罩位置交给它。
            text.resultInk(position: lensPosition, row: lensRow,
                           presence: lensPresence, dark: colorScheme == .dark)
        } else {
            text.foregroundStyle(legacySelection ? Color.white : Color.primary)
        }
    }

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: rowIcon)
                .resizable().scaledToFit()
                .frame(width: SearchLayout.fileIconSize, height: SearchLayout.fileIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                nameLabel
                if showsFullPath {
                    Text(pathText).ffFont(.resultPath)
                        .foregroundStyle(legacySelection ? Color.white.opacity(0.75) : Color.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            // 只有文字跟着遮罩缩放：字变大变小是用户点名要的效果，
            // 图标与来源标签保持原位（否则行尾标签会被挤出可视区）。
            .searchLensMagnification(position: lensPosition, row: lensRow, active: lensActive)
            Spacer(minLength: 8)
            // 来源标签靠右，视觉上像 Spotlight 的来源分组。
            HStack(spacing: 4) {
                Image(systemName: badgeSymbol).font(.system(size: 10))
                Text(badge).ffFont(.sourceBadge)
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(legacySelection ? Color.white.opacity(0.75) : Color.secondary)
            // 给来源保留可读空间，同时限制长 NAS 名称占用的宽度。
            .frame(maxWidth: 140, alignment: .trailing)
            .layoutPriority(2)
            .help("来源：\(badge)")
            .accessibilityLabel("来源 \(badge)")
        }
        // 右侧留出与遮罩一样的边距：文字左边缘在缩放锚点上，右边距只在行尾。
        .padding(.horizontal, 12)
        .frame(height: SearchLayout.rowHeight)
        .background {
            if legacySelection || legacyHover {
                // 圆角与内缩都取 Core 的值：模块 20、行内 14。
                // 行内再写一个数（比如 6/10）就又出现「同一个界面三种圆角」。
                RoundedRectangle(cornerRadius: SearchModuleLayout.rowLensRadius, style: .continuous)
                    .fill(legacySelection ? SearchLegacyHighlight.selection : SearchLegacyHighlight.hover)
                    .padding(.horizontal, SearchModuleLayout.rowLensInset)
                    .padding(.vertical, 2)
            }
        }
        .contentShape(Rectangle())
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: legacyHover)
        .help(pathText)
        .accessibilityElement(children: .combine)
    }
}
