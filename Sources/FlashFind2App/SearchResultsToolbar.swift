import SwiftUI
import FlashFindCore

/// **结果模块顶部那条工具条**：文件类型条 + 「钉住」。
///
/// 用户 2026-10-28：「把文件类型和搜索结果模块放在一起，搜索结果顶部文件类型」。
/// 于是这条从搜索框模块搬到这里，成为结果模块的第一行；右侧多一枚「钉住」——
/// 用户要能把这一批结果钉到桌面上，钉完继续用搜索框搜下一组。
///
/// 圆角、内缩、选中底的圆角全部照旧取 Core 的常量：
/// `typeBarHeight` / `fieldInset` / `segmentRadius`，这里不许另写数字。
struct SearchResultsToolbar: View {
    /// 当前类型限定（`nil` = 全部）。
    let fileType: SearchFileTypeCatalog.FileType?
    /// 点了类型条的某一段（传的是段的 id，「全部」也在其中）。
    ///
    /// ★ 传 id 而不是类型：把「这一段是什么」的换算留在 Core 的 `SearchTypeBar`，
    /// 视图里才不用写 `if id == "type:all"`。
    let selectType: (String) -> Void
    let style: SearchGlassStyle
    /// 能不能钉：没有结果时置灰（钉一个空窗口没有意义）。
    let canPin: Bool
    /// 点「钉住」。**传 nil 就没有这枚按钮**——钉住的窗口自己不需要再钉一次。
    ///
    /// ★ 用可选闭包而不是一个 `showsPin` 布尔：布尔为 false 时按钮还在，
    ///   就会出现「钉住的窗口里有一枚按下去是空操作的图钉」。
    var pin: (() -> Void)? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Namespace private var segmentNamespace

    private var selectedTypeID: String { SearchTypeBar.selectedID(for: fileType) }

    var body: some View {
        HStack(spacing: 8) {
            HStack(spacing: 4) {
                ForEach(SearchTypeBar.entries) { entry in
                    segment(entry)
                }
            }
            // 类型段比输入行多缩 8pt，两行的左右边缘才对得齐（与搜索框模块同一口径）。
            .padding(.leading, SearchModuleLayout.fieldInset - 8)
            // 没有图钉时右边要自己留出同样的余白，否则最后一段会贴着模块边缘。
            .padding(.trailing, pin == nil ? SearchModuleLayout.fieldInset - 8 : 0)
            .animation(reduceMotion ? nil : .spring(response: 0.28, dampingFraction: 0.84),
                       value: selectedTypeID)

            // 细分隔线：类型是一组，钉住是另一件事。没有图钉时连分隔线一起省掉
            // （只留一条竖线在右边，看起来像没画完）。
            if let pin {
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.45))
                    .frame(width: 0.5, height: 16)
                    .accessibilityHidden(true)

                Button(action: { pin() }) {
                    Image(systemName: "pin")
                        .font(.system(size: 13))
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .disabled(!canPin)
                .help("钉在桌面上（保留这批结果，搜索框可以继续搜下一组）")
                .accessibilityLabel("钉在桌面上")
                .accessibilityIdentifier("search-pin-button")
                .padding(.trailing, SearchModuleLayout.fieldInset - 10)
            }
        }
        .frame(height: SearchModuleLayout.typeBarHeight)
    }

    private func segment(_ entry: SearchTypeBar.Entry) -> some View {
        let selected = entry.id == selectedTypeID
        return Button { selectType(entry.id) } label: {
            Text(entry.title)
                .font(.system(size: 12, weight: selected ? .medium : .regular))
                .lineLimit(1)
                // 「压缩包」三段字在 640pt 宽的窗口里也要放得下。
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity)
                .frame(height: 24)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(selected ? Color.primary : Color.secondary)
        .background {
            if selected {
                SearchSegmentLens(style: style)
                    .matchedGeometryEffect(id: "search-type-segment", in: segmentNamespace)
            }
        }
        .accessibilityLabel(entry.title)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
        .help(entry.isAll ? "不限类型" : "只看\(entry.title)")
    }
}
