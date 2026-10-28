import SwiftUI
import FlashFindCore

/// **搜索框模块**（文件边界 = 模块边界）。
///
/// 2026-10-27 用户要求把搜索窗拆成模块：搜索框一块、搜索结果一块，中间留一道空白；
/// 代码上也分开成文件，以后单改某一块不会牵动另一块。
///
/// 这一块自己就是**完整的玻璃面**（圆角由 `SearchModuleLayout.moduleRadius` 给）。
/// 以前它是一整块大玻璃里的第一行，还在里面又套了一枚胶囊，于是只有搜索框时
/// 外面裹着一层壳、胶囊四周多出遮罩——这次全部去掉。
///
/// ## 这一块里只剩输入行（2026-10-28）
///
/// 曾经它住着两行：输入行 + **文件类型条**。用户同一天又改了主意——
/// 「把文件类型和搜索结果模块放在一起，搜索结果顶部文件类型」——
/// 类型条于是搬到 `SearchResultsToolbar`（结果模块顶部那条）。
/// 这里只留输入行与首屏那次性的键位提示。
///
/// ★ 输入行开头那排蓝色限定标签在 2026-10-27 晚被删掉（用户：「蓝色标签是
///   `\` / `/` 输入的命令相关的功能？可以删除」）。限定的**状态**没变
///   （仍由 `SearchTokenBar` 持有），只是不再在输入行里画出来。
struct SearchFieldModule: View {
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
    /// 点品牌图标 = 打开设置（用户 2026-10-27：「闪寻图标设计成可以点击的」）。
    let openSettings: () -> Void
    /// 首屏那次性的键位提示（只在没有关键词时出现，几秒后自己消失）。
    let showsHint: Bool
    let hintLines: [String]
    let hintHeight: CGFloat
    /// 表面：玻璃（macOS 26+）或材质（15 及以下）。整块模块共用一套。
    let style: SearchGlassStyle

    /// 这一块的总高：输入行（+ 首屏提示）。
    ///
    /// ★ 与 `SearchView.fieldModuleHeight` 必须同式：那一边算窗口高度、
    /// 这一边约束自己，差一个常量就多出一条空白或被裁掉一截。
    static func height(showsHint: Bool, hintHeight: CGFloat) -> CGFloat {
        SearchLayout.searchHeight + (showsHint ? hintHeight : 0)
    }

    var body: some View {
        VStack(spacing: 0) {
            row
            if showsHint {
                HStack(spacing: 14) {
                    ForEach(hintLines, id: \.self) { line in
                        Text(line).font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, SearchModuleLayout.fieldInset)
                .frame(height: hintHeight)
                .accessibilityIdentifier("search-hint-guide")
            }
        }
        // 整块模块就是一块玻璃面；圆角来自 Core，两个模块必须同值。
        .searchModuleSurface(style)
        .frame(height: Self.height(showsHint: showsHint, hintHeight: hintHeight))
    }

    /// 输入行本体（不带任何背景：背景由模块给）。
    private var row: some View {
        HStack(spacing: 14) {
            // 搜索框前导图标用**自家品牌字形**（圆环 + 闪电），不用系统放大镜。
            // 模板图跟随明暗自动着色，外层的 `.secondary` 负责把它压到与系统搜索框同档的灰度。
            // 22pt 那套素材是专为这个高度画的（Retina 要 44px，状态栏素材只有 36px）。
            //
            // ★ 它是一个**按钮**（用户 2026-10-27：「闪寻图标设计成可以点击的，
            //   点击后进入设置界面」）。所以不能再标 `accessibilityHidden`：
            //   装饰性图标对读屏隐藏，入口按钮必须能读出来。
            Button(action: openSettings) {
                Image(nsImage: StatusIcon.searchFieldGlyph())
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("打开设置")
            .accessibilityLabel("打开设置")
            TextField("搜索文件与文件夹", text: $query)
                .textFieldStyle(.plain).font(.system(size: 20, weight: .regular))
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
        .padding(.horizontal, SearchModuleLayout.fieldInset)
        .frame(height: SearchLayout.searchHeight)
    }
}
