import SwiftUI
import FlashFindCore

/// **结果模块左侧的位置侧边栏**（用户 2026-10-27 要求，抽屉式）。
///
/// 单独成文件，是因为它是结果模块里唯一「导航」性质的部件：
/// 列表、遮罩、空状态都属于「看结果」，而它决定**看哪个位置的结果**。
/// 以后要改导航（加分组、加折叠、换位置来源）只动这一个文件。
///
/// ## 为什么它不会把窗口撑宽
///
/// 用户原话：「侧边栏不要突出搜索框左右宽度，宽度保持一致」。
/// 它是 `SearchResultsModule` 里的**一列**（`HStack` 的第一个子视图），
/// 模块本身仍与搜索框等宽——多出来的这一列是从结果区里让出来的，
/// 窗口尺寸一点没变。
///
/// ## 行高与选中底
///
/// 行高 `SearchModuleLayout.sidebarRowHeight`，选中底是一块**会滑动**的胶囊
/// （`matchedGeometryEffect`）：点另一行时它从上一行滑下去。这是用户要的
/// 「抽屉式的感觉」里最要紧的一口气——底如果瞬移，看起来就是「两个列表」。
struct SearchResultsSidebar: View {
    let entries: [SearchSidebar.Entry]
    /// 当前高亮哪一行（`nil` = 当前位置不在列表里，谁都不点亮）。
    let selectedID: String?
    let style: SearchGlassStyle
    /// 点了第几行。传下标而不是 `Entry`：由 AppModel 统一换算成位置限定。
    let select: (Int) -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var selectionNamespace
    @State private var hoveredID: String?

    var body: some View {
        ScrollView(.vertical) {
            VStack(spacing: 2) {
                ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                    row(entry, index: index)
                }
            }
            .padding(.vertical, 8)
            .padding(.horizontal, 8)
        }
        .scrollIndicators(.never)
        .frame(width: SearchModuleLayout.sidebarWidth)
        .animation(reduceMotion ? nil : .spring(response: 0.30, dampingFraction: 0.84),
                   value: selectedID)
    }

    /// 哪些行要写副标题。
    ///
    /// ★★ 每一行都写（2026-10-29 报障：飞牛「存储空间 2」下面空着）。上一版只在
    /// 「同一个来源的第一行」写一次来源名，结果第二个存储空间只剩一个光秃秃的
    /// 位置名，连「未连接」这个状态都一并省掉了。
    /// 判定在 Core（`SearchSidebar.subtitleRows`）——「这行画不画第二行字」是语义。
    private var subtitleRows: [Bool] { SearchSidebar.subtitleRows(entries) }

    private func row(_ entry: SearchSidebar.Entry, index: Int) -> some View {
        let selected = entry.id == selectedID
        let showsSubtitle = subtitleRows.indices.contains(index) && subtitleRows[index]
        return Button { select(index) } label: {
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.title)
                    .ffFont(selected ? .sidebarTitleSelected : .sidebarTitle)
                    .lineLimit(1)
                if showsSubtitle, let subtitle = entry.subtitle, !subtitle.isEmpty {
                    // 副标题是**身份 + 状态**（来源名 / 「· 未连接」），不是说明文字：
                    // 光看根名分不清是哪台机器，也看不出它此刻连没连上。
                    Text(subtitle)
                        .ffFont(.sidebarSubtitle)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .frame(height: SearchModuleLayout.sidebarRowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background {
            if selected {
                SearchSegmentLens(style: style)
                    .matchedGeometryEffect(id: "search-sidebar-selection", in: selectionNamespace)
            } else if hoveredID == entry.id {
                RoundedRectangle(cornerRadius: SearchModuleLayout.segmentRadius, style: .continuous)
                    .fill(.primary.opacity(0.05))
            }
        }
        .onHover { inside in hoveredID = inside ? entry.id : (hoveredID == entry.id ? nil : hoveredID) }
        .accessibilityLabel(entry.subtitle.map { "\(entry.title)，\($0)" } ?? entry.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(entry.subtitle.map { "\(entry.title) · \($0)" } ?? entry.title)
    }
}
