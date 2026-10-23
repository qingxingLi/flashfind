import AppKit
import SwiftUI
import UniformTypeIdentifiers
import FlashFindCore

/// 搜索结果行。三层信息：文件名 / 路径 / 来源。
///
/// 刻意不显示 size、inode、owner、taskid、API 等技术字段——
/// 用户只需要知道「文件在哪里」。
struct SearchResultRow: View {
    let result: SearchResult
    var isSelected = false
    var showsFullPath = true
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var fileType: UTType { UTType(filenameExtension: (result.name as NSString).pathExtension) ?? .data }

    /// 是不是一个已安装的应用（应用搜索的结果行）。
    private var isApp: Bool { result.sourceID == SearchSource.apps.id }

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

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: rowIcon)
                .resizable().scaledToFit()
                .frame(width: SearchLayout.fileIconSize, height: SearchLayout.fileIconSize)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(result.name).font(.system(size: 14, weight: .medium))
                    .lineLimit(1).truncationMode(.middle)
                if showsFullPath {
                    Text(pathText).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                }
            }
            .layoutPriority(1)
            Spacer(minLength: 8)
            // 来源标签靠右，视觉上像 Spotlight 的来源分组。
            HStack(spacing: 4) {
                Image(systemName: badgeSymbol).font(.system(size: 10))
                Text(badge).font(.system(size: 11))
                    .lineLimit(1).truncationMode(.middle)
            }
            .foregroundStyle(.secondary)
            // 给来源保留可读空间，同时限制长 NAS 名称占用的宽度。
            .frame(maxWidth: 140, alignment: .trailing)
            .layoutPriority(2)
            .help("来源：\(badge)")
            .accessibilityLabel("来源 \(badge)")
        }
        .frame(height: SearchLayout.rowHeight - 8)
        .background {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(hovered && !isSelected ? Color(nsColor: .quaternaryLabelColor) : Color.clear)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration: 0.08), value: hovered)
        .help(pathText)
        .accessibilityElement(children: .combine)
    }
}
