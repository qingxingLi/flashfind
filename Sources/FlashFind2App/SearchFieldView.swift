import SwiftUI
import FlashFindCore

struct SearchFieldView: View {
    @Binding var query: String
    let focused: FocusState<Bool>.Binding
    let searching: Bool
    let syncing: Bool
    let submit: () -> Void
    /// 用当前关键词**重跑一次**全部来源。
    ///
    /// 触发场景很具体：某台 NAS 偶发报
    /// 「设备返回的分页数据不完整（IncompleteResponse）」时，用户自己发现
    /// 「再搜一次就好了」——那就该有一个一键重来的入口，而不是逼他删掉关键词
    /// 重新敲一遍（删空会让 `changedQuery` 提前返回，反而更麻烦）。
    let research: () -> Void
    /// 搜索框最前面那排已选定的限定（位置 / 文件类型）。
    ///
    /// ★ 显示它是为了让用户知道**这次搜索被限成了什么样**——这是状态，
    /// 不是提示备注。蓝色、比正文小一号，与后面的关键词一眼分得开。
    let tokens: [SearchTokenBar.Token]
    /// 删掉一枚限定：**删被点的那一枚**，不带「关键词必须为空」的前提。
    ///
    /// 与键盘删除键不是同一条规则，别合并——合并的后果是有关键词时点标签没反应。
    let deleteToken: (SearchTokenBar.Slot) -> Void

    /// ★ 已选定的限定放在**关键词前面**：它是这次搜索的前提条件，
    /// 摆在后面会看成关键词的一部分。蓝色 + 小一号，与关键词区别开。
    ///
    /// 单独成块是因为整段塞进 `body` 会让调用侧的类型检查爆掉。
    @ViewBuilder private var tokenStrip: some View {
        ForEach(tokens) { token in
            Button { deleteToken(token.slot) } label: {
                Text(token.label)
                    .font(.system(size: 15))
                    .foregroundStyle(Color.accentColor)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.accentColor.opacity(0.12))
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("清除限定").accessibilityLabel("清除限定 \(token.label)")
        }
    }

    var body: some View {
        HStack(spacing: 14) {
            // 搜索框前导图标用**自家品牌字形**（圆环 + 闪电），不用系统放大镜
            // 。模板图跟随明暗自动着色，
            // 外层的 `.secondary` 负责把它压到与系统搜索框同档的灰度。
            // 22pt 那套素材是专为这个高度画的（Retina 要 44px，状态栏素材只有 36px）。
            Image(nsImage: StatusIcon.searchFieldGlyph())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            tokenStrip
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
            // 重新搜索放在最右侧。
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

        }
        .padding(.horizontal, 22).frame(height: SearchLayout.searchHeight)
    }
}
