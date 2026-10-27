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
    /// 面板一次画得下多少行候选。
    ///
    /// ★ 它同时是「数字键能按到哪」的上界：1–9 给前九条、0 给「打开设置」，
    /// 十条正好全在屏幕上。候选比这多时**不截断**，改成滚动 ——
    /// 截断会把用户配过的位置彻底藏起来（`\` 面板只显示第一个 OpenList 文件夹）。
    let maximumVisible: Int

    /// 鼠标移到第几行 ⇒ 选中就是那一行（先高亮、再决定点不点）。
    let onHover: (Int) -> Void
    /// 鼠标点了第几行 ⇒ 执行它（与按数字键同一条路径）。
    ///
    /// ★ 键盘与鼠标必须是**同一件事**：只做键盘的话，习惯用鼠标的用户
    /// 在这个面板里一条都选不了（面板本身不是列表控件，没有原生点击行为）。
    let onPick: (Int) -> Void

    /// 候选多到画不下时，面板固定这么高并允许滚动。
    private var needsScrolling: Bool { items.count > maximumVisible }

    private var rowList: some View {
        // ★ 渲染**全部**候选，不 `prefix`。`maximumVisible` 只用来定高度。
        //
        // 之前是 `Array(items.prefix(maximumVisible))`，于是 A0002 之后的搜索根
        // 连画都不画：按 7/8/9 能选中，屏幕上却一条都没有 —— 用户看到的
        // 是「面板里只有第一个文件夹」。
        ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
            row(item, index: index,
                number: index < numbers.count ? numbers[index] : nil,
                selected: index == selection)
        }
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
            } else if needsScrolling {
                // 超出行数上限：固定高度 + 滚动，选中项始终滚进可视区。
                // 上下键翻到第 11 条时，面板不会「看起来没反应」。
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: true) {
                        VStack(spacing: 0) { rowList }
                    }
                    .frame(height: CGFloat(maximumVisible) * rowHeight)
                    .onChange(of: selection) { value in
                        guard items.indices.contains(value) else { return }
                        proxy.scrollTo(items[value].id, anchor: .center)
                    }
                }
            } else {
                rowList
            }
        }
        .padding(.vertical, 4)
        .background(.regularMaterial)
    }

    private func row(_ item: SearchCommandItem, index: Int, number: Int?, selected: Bool) -> some View {
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
        // ★ 鼠标：移上来就选中（先看清会点中哪一条），点下去就执行。
        //   两者都走模型的同一个 `commandSelection`，与上下键/数字键不打架。
        .onHover { inside in
            if inside { onHover(index) }
        }
        .onTapGesture { onPick(index) }
        // 滚动到选中项要用这个 id（候选超过一屏时）。
        .id(item.id)
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
