import SwiftUI

struct SearchFieldView: View {
    @Binding var query: String
    @Binding var scope: SearchScope
    let focused: FocusState<Bool>.Binding
    let searching: Bool
    let syncing: Bool
    let canSync: Bool
    let submit: () -> Void
    let sync: () -> Void
    let showSettings: () -> Void
    let close: () -> Void
    /// 用当前关键词**重跑一次**全部来源。
    ///
    /// 触发场景很具体：某台 NAS 偶发报
    /// 「设备返回的分页数据不完整（IncompleteResponse）」时，用户自己发现
    /// 「再搜一次就好了」——那就该有一个一键重来的入口，而不是逼他删掉关键词
    /// 重新敲一遍（删空会让 `changedQuery` 提前返回，反而更麻烦）。
    let research: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // 搜索框前导图标用**自家品牌字形**（圆环 + 闪电），不用系统放大镜
            // 。模板图跟随明暗自动着色，
            // 外层的 `.secondary` 负责把它压到与系统搜索框同档的灰度。
            // 22pt 那套素材是专为这个高度画的（Retina 要 44px，状态栏素材只有 36px）。
            Image(nsImage: StatusIcon.searchFieldGlyph())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField("搜索文件与文件夹", text: $query)
                .textFieldStyle(.plain).font(.system(size: 22, weight: .regular))
                .focused(focused).onSubmit(submit)
                .accessibilityLabel("搜索文件与文件夹")
            if searching || syncing { ProgressView().controlSize(.small).accessibilityLabel(searching ? "正在搜索" : "正在同步") }
            if !query.isEmpty {
                Button { query = ""; focused.wrappedValue = true } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        .frame(width: 28, height: 28)
                        .contentShape(Rectangle())
                }.buttonStyle(.plain).help("清除搜索").accessibilityLabel("清除搜索")
            }
            // 重新搜索：放在清除按钮与「更多」菜单之间——用户报障时指的就是这一角。
            // 图标而非文字，是为了不挤占关键词输入框的宽度；名字走 help 与读屏。
            Button(action: research) {
                Image(systemName: "arrow.clockwise").font(.system(size: 17))
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            // 关键词为空时重搜没有意义（changedQuery 会直接清空返回），
            // 所以置灰，别给一个点了没反应的按钮。
            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            .help("重新搜索").accessibilityLabel("重新搜索")
            Menu {
                Picker("搜索范围", selection: $scope) {
                    ForEach(SearchScope.allCases) { Text($0.rawValue).tag($0) }
                }
                Divider()
                Button("同步网络索引", action: sync).disabled(!canSync)
                Button("设置…", action: showSettings)
                Button("隐藏搜索", action: close)
            } label: {
                HStack(spacing: 4) {
                    if scope != .all { Text(scope.rawValue).font(.caption) }
                    Image(systemName: "ellipsis.circle").font(.system(size: 17))
                        .frame(width: 28, height: 28)
                }.foregroundStyle(.secondary)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            .help("搜索范围与设置").accessibilityLabel("搜索范围与设置")
        }
        .padding(.horizontal, 22).frame(height: SearchLayout.searchHeight)
    }
}
