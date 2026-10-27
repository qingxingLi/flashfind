import SwiftUI
import UniformTypeIdentifiers
import Foundation
import FlashFindCore

/// 「设置 ▸ 搜索」里的**命令快捷键**：一段，两个页签点着切换。
///
/// ## 为什么是页签，不是并排两栏
///
/// 位置与文件类型是同一件事的两半（都在 `\` / `/` 面板里按数字就走），
/// 但并排一放，两栏都只能占半宽：名字长一点的来源被截断，右侧还留着
/// 大片空白。改成页签之后，**当前这一页独占整行宽度**，行名不必缩着写。
///
/// 切换时整块内容往左滑一下（`slide`），眼睛立刻知道「换页了」，
/// 而不是「同一张表被重排了」。
///
/// ## 一行的三种操作（2026-10-27 定稿）
///
/// * **挪位置**：按住整行拖 —— 拖起来的是**整行虚影**（行名才是身份，
///   只拖出去一个小把手图标，用户看不出自己拿的是哪一条）。放下之后
///   那一行从原位置**升/降**到新位置，不是凭空跳过去。
/// * **删掉**：右键 ▸ 删除该快捷方式。面板里不再出现它，也不会因为
///   「目录里还有这一条」下次刷新又长回来。
/// * **换掉**：右键 ▸ 替换为 ▸ 别的位置 / 别的格式。**在同一位次上换人**，
///   所以换完之后这一行旁边的数字不变。
///
/// ★ 行尾的号码是**只读**的：它就是这一行在面板里排第几，由顺序算出来。
/// 上一版那里是个下拉选择器（选个数字把行搬过去），与「拖」是同一件事的
/// 两种写法 —— 两套入口摆在一起，用户得先分辨哪个才是「排序」。现在只留拖，
/// 号码退成一句陈述：这一行按几。
///
/// ★ 这里不写任何解释性文字（不摆「拖动可排序」这类备注）：
/// 行首那个把手是操作入口，右键是菜单入口，右上那个回转箭头是恢复默认。
/// 三个都是控件，不靠说明让用户猜。
struct QuickPickSettingsSection: View {
    /// 可切换的页（第一页：搜索位置；第二页：文件类型）。
    ///
    /// 用「一页一份配置」而不是写死两个 kind：页数由调用方决定，
    /// 将来要加第三页（比如「搜索范围」）不必改这个视图。
    let columns: [QuickPickColumn]

    /// 当前显示第几页。默认第一页（位置）——`\` 面板给的就是位置。
    @State private var chosenIndex: Int
    /// 这次切换的方向：`true` = 新页在旧页右边（往左滑进）。
    ///
    /// ★ 方向必须**在改 `chosenIndex` 之前**定下来：`transition` 是在
    /// 动画那一帧求值的，那时 `chosenIndex` 已经是新值，拿它和谁比都比不出方向。
    @State private var forward = true
    /// 切换时内容平移的距离。
    ///
    /// ★ 不做「整屏宽度的推移」：Form 的行里拿不到可靠宽度
    /// （`GeometryReader` 在自适应高度的容器里只拿到 10pt），硬测宽度
    /// 要么留白要么裁字。这个距离的位移 + 交叉淡入，眼睛读到的
    /// 就是「整块往左挪了一下」。
    private let slide: CGFloat = 48

    init(columns: [QuickPickColumn]) {
        self.columns = columns
        _chosenIndex = State(initialValue: Self.previewIndex(in: columns))
    }

    /// 预览构建里可以直接停在某一页：`FF_UI_QUICKPICK_TAB=fileType`
    /// （取 `SearchCommandKind.rawValue`）。
    ///
    /// 与 `FF_UI_SETTINGS_PAGE` 同理：没有它，「切到类型页之后」的截图只能靠手点，
    /// 而手点的结果没法复现、也没法在改动前后各截一张来比。
    /// 正常启动（`AppEnvironment.isPreview == false`）永远落在第一页。
    private static func previewIndex(in columns: [QuickPickColumn]) -> Int {
        guard AppEnvironment.isPreview,
              let raw = ProcessInfo.processInfo.environment["FF_UI_QUICKPICK_TAB"],
              let kind = SearchCommandKind(rawValue: raw),
              let index = columns.firstIndex(where: { $0.kind == kind }) else { return 0 }
        return index
    }

    /// 切页的位移+淡入：旧页往**反方向**滑走，新页从另一边滑进来。
    private var slideTransition: AnyTransition {
        .asymmetric(
            insertion: .offset(x: forward ? slide : -slide).combined(with: .opacity),
            removal: .offset(x: forward ? -slide : slide).combined(with: .opacity)
        )
    }

    var body: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                tabs

                // 只渲染**当前这一页**：段的高度就是这一页的高度。
                // 位置页通常只有两三条，没必要按类型页的九条撑开、
                // 在下面留一大块空白。切页时旧页滑出、新页滑入，
                // 高度在同一次动画里跟着收放。
                ZStack(alignment: .topLeading) {
                    page(chosenIndex)
                        // ★ `transition` 只在视图**插入/移除**时求值。
                        //   少了这一行，`ZStack` 里永远是同一段结构里的同一个
                        //   `QuickPickColumnView`，换页只是把它的参数改掉：
                        //   内容会变、高度会变，但整页的出入场过渡一次都不会触发
                        //   （2026-10-27 审查 F02）。身份绑到页签上，换页才是一次
                        //   真正的「旧页移除 + 新页插入」。
                        //   顺带把页内 `@State`（正拖的那行、落点）也按页隔开。
                        .id(columns[chosenIndex].kind)
                        .transition(slideTransition)
                }
                .frame(maxWidth: .infinity, alignment: .topLeading)
                // 滑出去的那一页必须裁掉，否则会压到段落外面。
                .clipped()
            }
            .padding(.vertical, 2)
            .task { await switchPageInPreviewIfRequested() }
        } header: {
            // 与设置页其它段标题同一档字号（`SettingsTypography.sectionHeader`）。
            Text("命令快捷键")
                .font(.system(size: SettingsTypography.sectionHeader, weight: .semibold))
        }
    }

    private var tabs: some View {
        Picker("", selection: Binding(get: { chosenIndex },
                                      set: { select($0) })) {
            ForEach(columns.indices, id: \.self) { index in
                Text(columns[index].title).tag(index)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .accessibilityIdentifier("quickpick-tabs")
    }

    /// 换到第 `next` 页。
    ///
    /// 页签点击与预览钩子都走这一条：钩子要是自己写一份切换，
    /// 验到的就是钩子而不是用户按下去的那个动作了。
    private func select(_ next: Int) {
        guard columns.indices.contains(next), next != chosenIndex else { return }
        // 先定方向，再换页：`transition` 求值时
        // `chosenIndex` 已经是新值了。
        forward = next > chosenIndex
        withAnimation(.easeOut(duration: 0.22)) {
            chosenIndex = next
        }
    }

    /// 预览构建里可以让程序**定时切一次页**：`FF_UI_QUICKPICK_SWITCH=<秒>`。
    ///
    /// 为什么需要这个钩子：过渡只存在于插入/移除的那几帧里，靠人手点完再截图
    /// 只能拿到结束态 —— 而「切页前」和「切页后」两张图都正常，既证明不了有动画，
    /// 也证明不了没有（2026-10-27 审查 F02 就是这么被漏掉的）。
    /// 要拿到中间帧，切页必须能被定时触发，然后由外部连续截帧。
    ///
    /// 与其它 `FF_UI_*` 一样，只在 `AppEnvironment.isPreview` 下有效：
    /// 正式版用户设了这个变量也不会让设置页自己换页。
    private func switchPageInPreviewIfRequested() async {
        guard AppEnvironment.isPreview, columns.count > 1,
              let raw = ProcessInfo.processInfo.environment["FF_UI_QUICKPICK_SWITCH"],
              let delay = Double(raw), delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
        select((chosenIndex + 1) % columns.count)
    }

    /// 第 `index` 页。
    private func page(_ index: Int) -> some View {
        QuickPickColumnView(column: columns[index])
    }
}

/// 一页的配置：哪个面板 + 标题 + 已排好序的行 + 四个动作。
struct QuickPickColumn {
    /// 这一页对应哪个面板。页签初始选中哪一页、恢复默认落到哪个面板，都看它。
    let kind: SearchCommandKind
    let title: String
    /// 这一面板的行（已排好序、已算好编号，不含「打开设置」）。
    let rows: [SearchQuickPickRow]
    /// 有没有被改过（决定恢复默认那个按钮可不可点）。
    let canReset: Bool
    /// 拖动排序：`from` / `to` 都是行下标。
    let onMove: (_ from: Int, _ to: Int) -> Void
    /// 右键 ▸ 删除该快捷方式。
    let onDelete: (_ id: String) -> Void
    /// 右键 ▸ 替换为 ▸ 别的候选：`(原 id, 新 id)`。
    let onReplace: (_ id: String, _ newID: String) -> Void
    /// 这一行能换成哪些候选（右键菜单「替换为」的子项）。
    ///
    /// 由 Core 判定（`SearchCommandReplacement`），界面只负责画：
    /// 「换成一个已经显示在同一页里的条目」是唯一要防的重复，规则不该写在视图里。
    let replacements: (_ id: String) -> [SearchCommandItem]
    let onReset: () -> Void
}

/// 单页的呈现。拖动状态（正拖的那一行、当前落点）放在这里而不是外面：
/// 两页各拖各的，共用一个 `dropTarget` 会把位置页的落点高亮画到类型页去。
private struct QuickPickColumnView: View {
    let column: QuickPickColumn

    /// 本窗口内排序专用的私有类型。
    ///
    /// ★ 拖拽载荷**不许**装 `row.id`。位置行的 id 是 `target:<来源>:<根路径>`，
    ///   里面就是完整的 NAS 搜索根（部门、客户、项目文件夹名）。拖拽是**跨应用**
    ///   的通道：用 `NSString` 造 provider，系统会同时注册 `public.utf8-plain-text`
    ///   和 `public.url` 两种表示，拖到任何一个接受文本的地方，对方都能读出这份路径
    ///   （2026-10-27 审查 F01）。
    ///   这里排序只靠内存里的 `draggingID`（起拖那一刻同步写入），载荷只需要
    ///   「这件事发生在闪寻自己的排序行之间」这一点，所以类型用私有 UTI、
    ///   内容放常量标记 —— 谁读都读不出位置信息。
    ///
    /// 类型标识与 `Resources/Packaging/Info.plist` 的 `UTExportedTypeDeclarations`
    /// 必须一致（`AppLayerStructureTests` 会比对，写错一边编译也能过，运行时才静默失效）。
    static let reorderType = UTType(exportedAs: "com.flashfind.quickpick-row")

    /// 载荷内容：一个常量标记。不含 id、不含路径、不含任何能拼回来源的信息。
    private static let reorderMarker = Data("flashfind-quickpick-reorder".utf8)

    /// 正在拖的那一行。
    ///
    /// ★ 用 `@State` 自己记，而不是从 `NSItemProvider` 里异步读回来：
    /// 起拖那一刻就同步知道是谁，落点判定不必等一次异步加载（等的话
    /// 掉在缝隙里的那一下会静默失败，表现为「拖了没反应」）。
    /// 正因为标识在内存里，载荷才可以退化成常量。
    @State private var draggingID: String?
    /// 当前指到的落点行（画一条落点底色）。
    @State private var dropTarget: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            header
            ForEach(Array(column.rows.enumerated()), id: \.element.id) { index, row in
                self.row(row, index: index)
            }
        }
        // 整行宽度：行名能写多长就写多长，行尾的号码永远贴右边。
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 页内只有「恢复默认」这一个控件：页名已经由上面的页签写着，
    /// 这里再写一遍就是同一句话出现两次。
    private var header: some View {
        HStack(spacing: 0) {
            Spacer(minLength: 0)
            Button { column.onReset() } label: {
                Image(systemName: "arrow.counterclockwise")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(!column.canReset)
            .help("恢复默认顺序与快捷键")
            .accessibilityLabel("恢复默认顺序与快捷键")
            .accessibilityIdentifier("quickpick-reset-\(column.title)")
        }
        .padding(.bottom, 2)
    }

    private func row(_ row: SearchQuickPickRow, index: Int) -> some View {
        // 替换候选在菜单展开前算一次：右键的那一刻列表就是它，
        // 不会出现「菜单里点到的项其实已经不在列表里」。
        let alternatives = column.replacements(row.id)
        return HStack(spacing: 8) {
            // 把手只是「这一行能拖」的视觉提示：真正的拖拽挂在**整行**上。
            // 上一版挂在把手上，拖出去的是一个小图标，看不出拿的是哪一条。
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
                .frame(width: 16, height: 22)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                    .font(.system(size: SettingsTypography.body))
                    .lineLimit(1)
                    .truncationMode(.tail)
                if let subtitle = row.item.subtitle {
                    Text(subtitle)
                        .font(.system(size: SettingsTypography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            Spacer(minLength: 8)

            // 只读号码：面板上这一行排第几，这里就写几。
            // 第十行起没有数字键（面板上那些行也不写号），留空对齐。
            Text(row.key.map(String.init) ?? "")
                .font(.system(size: SettingsTypography.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
                .accessibilityIdentifier("quickpick-number-\(row.id)")
        }
        .padding(.vertical, 2)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(dropTarget == index ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
        // ★ 整行起拖：虚影是整行（`preview:`），不是把手图标。
        //   载荷仍然只是那个常量标记（见 `reorderType` 的说明）。
        .onDrag {
            draggingID = row.id
            return NSItemProvider(item: Self.reorderMarker as NSSecureCoding,
                                  typeIdentifier: Self.reorderType.identifier)
        } preview: {
            QuickPickDragPreview(row: row)
        }
        // 落点判定也挂在**整行**上：拖着东西回来要能整行命中。
        // 只接受本视图自己注册的私有类型：别人拖一段文字经过这里不会高亮，
        // 也就不会拿一个过期的 `draggingID` 去重排。
        .onDrop(of: [Self.reorderType], isTargeted: targeting(index)) { (_: [NSItemProvider]) in
            drop(at: index)
        }
        // 右键：删掉 / 换成别的位置或格式。两个都是**这一行**的动作，
        // 挂在整行上比藏在某个按钮里更容易发现。
        .contextMenu {
            Button("删除该快捷方式", role: .destructive) {
                column.onDelete(row.id)
            }
            Menu("替换为") {
                if alternatives.isEmpty {
                    Button("没有可替换的项") {}.disabled(true)
                } else {
                    ForEach(alternatives) { candidate in
                        Button(Self.menuTitle(for: candidate)) {
                            column.onReplace(row.id, candidate.id)
                        }
                    }
                }
            }
        }
        .accessibilityIdentifier("quickpick-row-\(row.id)")
    }

    /// 替换项在菜单里的字样：位置页把来源名缀在后面，同名的搜索根才分得开
    /// （两台 NAS 上都有「照片」是常态）。
    private static func menuTitle(for item: SearchCommandItem) -> String {
        guard let subtitle = item.subtitle, !subtitle.isEmpty else { return item.title }
        return "\(item.title) — \(subtitle)"
    }

    private func targeting(_ index: Int) -> Binding<Bool> {
        Binding(get: { dropTarget == index },
                set: { inside in
                    if inside { dropTarget = index }
                    else if dropTarget == index { dropTarget = nil }
                })
    }

    private func drop(at index: Int) -> Bool {
        defer { draggingID = nil; dropTarget = nil }
        guard let draggingID,
              let from = column.rows.firstIndex(where: { $0.id == draggingID }),
              from != index else { return false }
        // ★ 放下之后那一行要从**原位置升/降到新位置**，而不是凭空跳到新位置：
        //   数据变化必须在动画事务里，且 `ForEach` 的 id 稳定（= 行 id），
        //   SwiftUI 才会给这一行做位置插值。上一版没包这一层，落手就是瞬移，
        //   眼睛读到的是「列表被打乱了」而不是「我把它挪到了这儿」。
        withAnimation(.spring(response: 0.32, dampingFraction: 0.82)) {
            column.onMove(from, index)
        }
        return true
    }
}

/// 拖动时浮在指针下的那一块：**整行**的样子，不是一个小把手。
///
/// 行名才是身份 —— 只拖一个 16pt 的图标出去，用户看不出自己拿的是哪一条。
/// 这里把标题、副标题、行尾号码都和列表里那一行同构地画一遍，
/// 尺寸固定是为了虚影不随窗口宽度跳来跳去。
private struct QuickPickDragPreview: View {
    let row: SearchQuickPickRow

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "line.3.horizontal")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.item.title)
                    .font(.system(size: SettingsTypography.body))
                    .lineLimit(1)
                if let subtitle = row.item.subtitle {
                    Text(subtitle)
                        .font(.system(size: SettingsTypography.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            Text(row.key.map(String.init) ?? "")
                .font(.system(size: SettingsTypography.caption).monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 16, alignment: .trailing)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .frame(width: 360, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.10))
        )
        .opacity(0.96)
    }
}
