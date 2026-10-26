import SwiftUI
import FlashFindCore

/// 命令面板：输入 `/` 之后浮在搜索框下方的候选列表。
///
/// ★ 它是**指令入口**：每一条候选都对应一个能立刻执行的动作
/// （限定位置 / 打开设置），不是「换个词再搜一次」。
///
/// ★ 这里不放任何说明性文字。位置名与来源名就是全部信息；
/// 多写一句「在这里搜索可以更快」之类的解释，就是界面上的噪音。
struct SearchCommandPaletteView: View {
    let items: [SearchCommandItem]
    let selection: Int
    /// 已选定的当前位置名。命令模式下显示，好让用户知道现在限在哪儿。
    let activeTargetLabel: String?
    /// 每条候选对应的数字键（没有则 nil），与 `items` 一一对应。
    ///
    /// ★ 编号由 Core 的 `SearchCommandNumbering` 决定：1–9 按顺序，
    /// 0 固定给「打开设置」。界面只负责画出来。
    let numbers: [Int?]
    private var rowHeight: CGFloat { 34 }
    /// 最多显示多少条候选。
    /// 只显示六条的话，数字 7/8/9/0 指向的全是**看不见的项** ——
    /// 用户按了数字，选中的却是列表外的东西。数字能按到哪，就得显示到哪。
    let maximumVisible: Int

    private var visibleItems: [SearchCommandItem] {
        Array(items.prefix(maximumVisible))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let activeTargetLabel {
                // 已限定的当前位置：不是提示备注，是**状态**——
                // 面板浮在搜索框上时，用户得知道这次会限在哪儿。
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 11))
                    Text(activeTargetLabel).font(.system(size: 12))
                    Spacer(minLength: 0)
                }
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .frame(height: 28)
                Divider().opacity(0.45)
            }
            if items.isEmpty {
                Text("没有匹配的选项")
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 16)
                    .frame(height: rowHeight)
            } else {
                ForEach(Array(visibleItems.enumerated()), id: \.element.id) { index, item in
                    row(item, number: index < numbers.count ? numbers[index] : nil,
                        selected: index == selection)
                }
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private func row(_ item: SearchCommandItem, number: Int?, selected: Bool) -> some View {
        HStack(spacing: 8) {
            // ★ 数字写在最前：手指就在数字键上，看到编号直接按，
            // 不必先用方向键挪过去再回车。没有编号的位置留空对齐。
            Text(number.map(String.init) ?? "")
                .font(.system(size: 12).monospacedDigit())
                .frame(width: 12, alignment: .trailing)
                .foregroundStyle(selected ? Color.primary : Color.secondary)
            Image(systemName: icon(for: item))
                .font(.system(size: 12))
                .frame(width: 16)
            Text(item.title).font(.system(size: 14))
            if let subtitle = item.subtitle {
                Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .padding(.horizontal, 16)
        .frame(height: rowHeight)
        .background(selected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .accessibilityIdentifier("command-item-\(item.id)")
    }

    private func icon(for item: SearchCommandItem) -> String {
        switch item.action {
        case .openSettings: return "gearshape"
        // 类型用文档图标：它筛的是「什么格式的文件」，不是某个目录。
        case .filterFileType: return "doc"
        case .search(let target):
            switch target {
            case .unrestricted: return "square.grid.2x2"
            case .local: return "desktopcomputer"
            case .sourceRoot: return "folder"
            }
        }
    }
}
