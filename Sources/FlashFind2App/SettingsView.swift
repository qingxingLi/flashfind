import AppKit
import SwiftUI
import FlashFindCore

/// 设置窗口。
///
/// 它的定位是**调搜索行为的地方**，不是一个 NAS 管理器 —— 每台 NAS 都配
/// 一行按钮、每页都自绘卡片，会让设置看起来像另一个产品。因此：
///
/// 1. **一级页面四页**：「搜索来源」并入「搜索」——它们回答的是同一个
///    问题（搜哪些地方），分成两页只会让用户在「调整搜索」和「管理 NAS」
///    之间来回跳；「AI」独立成页（1.1.2 唯一的新增主功能，藏在「高级」里
///    与产品定位冲突，§14.3.1）。四页撑不起一条常驻侧栏，所以导航是顶部横向
///    玻璃分段控件（`SettingsPanePicker`）；
/// 2. **来源列表只显示名称 / 状态 / 位置 / 启用**，点整行进详情页，
///    只有出问题时才出现一个按钮；
/// 3. **表面走 `SettingsCard`**（2026-10-27 用户定稿）：浅色**纯白底 +
///    玻璃遮罩卡**，深色沿用毛玻璃底 + 带层次的材质卡；
/// 4. **页脚只在有问题时出现**：本机那一段的说明
///    只在「没选文件夹 / 系统索引关着」时说，「Spotlight 已启用」这类正常态
///    不再占一行；「网络存储」下面那句解释「附近设备」会自动查找的话也删了——
///    点进向导第一屏就摆着「附近的设备」。
///
/// ★ 为什么不再用 `Form` + `.formStyle(.grouped)`：分组表单的卡片底色与
///   投影是系统画的，改不动。用户要的是「去掉那片灰白阴影、换成玻璃遮罩」，
///   唯一的办法是自己画卡片（`SettingsCard` / `SettingsCardSurface`）。
///   代价是行内边距与分隔线要显式写，规则收在 `settingsRow()` 与
///   `SettingsRowDivider` 里，四个页面共用一套。
///
/// 判定逻辑尽量不在这一层：来源行的呈现来自 `NASSourceRowModel`，
/// 页面集合来自 `SettingsPane`，诊断汇总来自 `ConnectionDiagnostics`。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pane: SettingsPane
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 图标底色要分深浅：10% 的强调色压在深色玻璃上几乎等于没有（截图上只剩一点色偏）。
    @Environment(\.colorScheme) private var colorScheme
    /// 搜索页当前打开的来源详情。`nil` 表示停在列表。
    @State private var detailSourceID: String?

    init(model: AppModel, initialPage: SettingsPane = .search) {
        self.model = model
        _pane = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            panePicker
            content
        }
        .background(SettingsBackdrop())
        .frame(minWidth: 520, idealWidth: 640, minHeight: 520, idealHeight: 620)
        .onChange(of: pane) { _ in
            detailSourceID = nil
        }
        .onAppear {
            model.refreshLaunchAtLogin()
            // 本机搜索的提示只在打开设置时才有意义，检查也就在这时候做。
            // 少了这一句，「Spotlight 索引被关掉」这类必须让用户知道的提醒
            // 永远不会出现，本机那一段会变成一行等不到结果的「正在检查本机搜索状态」。
            model.refreshLocalSearchAvailability()
            // `FF_UI_SOURCE_DETAIL=1`：预览截图直接进第一台来源的详情。
            // 没有它，这一屏只能靠手点，改动前后各截一张的对比就做不成。
            #if DEBUG
            if AppEnvironment.isPreview,
               ProcessInfo.processInfo.environment["FF_UI_SOURCE_DETAIL"] == "1",
               let first = model.nasSources.first {
                detailSourceID = first.id
            }
            #endif
        }
    }

    /// 四个页面共用顶部玻璃分段控件；宽度跟内容走，不被窗口拉宽。
    /// 选中块会在四段之间滑过去（见 `SettingsPanePicker`）。
    private var panePicker: some View {
        SettingsPanePicker(selection: $pane)
            .fixedSize(horizontal: true, vertical: false)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.clear)
            .overlay(alignment: .bottom) { Divider().opacity(0.35) }
    }

    /// 内容区：限宽并居中，窗口拉宽时卡片不再无限横向拉伸。
    ///
    /// ★★ 切页时内容「漂移」有三条成因（2026-10-28 用户报，前两条已修、
    ///   第三条在 `SettingsPanePicker.select` 里也一并改掉了）：
    ///   1. `ScrollView` 的滚动偏移被下一页继承 —— 四页高度不同，从滚到一半的
    ///      搜索页切到较短的高级页，偏移先被夹紧、切回来又跳一次；
    ///   2. 四个页面直接展开在**同一个** `VStack` 里，`pane` 一变，SwiftUI 会把
    ///      新旧两页的卡片按位置做**隐式布局插值**，看得见的就是卡片从旧位置滑过去；
    ///   3. 切页是 `withAnimation(.spring(0.34))` 包着写的，那个隐式事务会把
    ///      内容替换、滚动位置、卡片高度**全部**做成弹簧插值 —— 0.34s 里内容
    ///      一边淡一边长高变矮，肉眼看就是「飘」。
    /// 于是：内容带 `.id(pane)`（是替换而不是插值）、切页新内容不吃动画
    /// （`.animation(nil, value: pane)`）、滚动位置显式回顶（无动画事务）。
    private var content: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                VStack(alignment: .leading, spacing: 22) { detail }
                    .padding(.horizontal, 24)
                    .padding(.top, 18)
                    .padding(.bottom, 26)
                    .frame(maxWidth: SettingsLayout.contentMaxWidth)
                    .frame(maxWidth: .infinity)
                    .id(SettingsLayout.topAnchor)
            }
            .onChange(of: pane) { _ in scrollToTop(proxy) }
            .onChange(of: detailSourceID) { _ in scrollToTop(proxy) }
            // ★ 滚动条不占宽度：否则「内容超一屏的页」比别的页窄 15pt、左移 7.5pt，
            //   切页时看着就是内容在漂（见 `SettingsOverlayScrollers`）。
            .background(SettingsOverlayScrollers())
            // ★ 切页**不给内容做动画**：选中块自己滑（`matchedGeometryEffect`），
            //   内容是瞬间替换 —— 系统设置切页也是这个手感，且不会「一边淡一边长高」。
            .animation(nil, value: pane)
            .animation(reduceMotion ? nil : .easeInOut(duration: 0.16), value: detailSourceID)
        }
    }

    /// 切页 / 进出来源详情都回顶部。
    ///
    /// 四页高度不同，留着上一页的偏移就是用户看到的「内容漂移」；
    /// 这里不加动画 —— 回顶和交叉淡入同时做动画会变成「一边滑一边淡」。
    private func scrollToTop(_ proxy: ScrollViewProxy) {
        var transaction = Transaction()
        transaction.animation = nil
        withTransaction(transaction) {
            proxy.scrollTo(SettingsLayout.topAnchor, anchor: .top)
        }
    }

    /// 打开来源向导的独立窗口。
    private func openWizard() {
        NSApp.activate(ignoringOtherApps: true)
        NASWizardWindow.shared.show(model: model)
    }

    // MARK: - 字号阶梯

    /// 分段页脚（辅助说明）：比正文小一档，且不抢注意力。
    private func sectionFooter(_ text: String) -> some View {
        Text(text).font(.system(size: SettingsTypography.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, 2)
    }

    /// 一行提示文字（反馈，不是备注）：比正文小一档。
    private func noteText(_ text: String, tint: Color = .secondary) -> some View {
        Text(text).font(.system(size: SettingsTypography.caption))
            .foregroundStyle(tint)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「外观」选择。双向绑定到模型——`.constant(...)` 那种点了不改模型的写法
    /// 正是 R01 的成因，不能在新的选择器上重犯。
    private var appearanceBinding: Binding<AppearanceChoice> {
        Binding(get: { model.appearanceChoice }, set: { model.appearanceChoice = $0 })
    }

    /// 四个页面。
    ///
    /// ★ `.id(pane)` 不是多余的：没有它，切页时 SwiftUI 会把新旧两页当作
    ///   同一棵树的不同取值，按位置插值（卡片从旧页的位置滑到新页的位置），
    ///   看起来就是「里面的内容在漂移」。给了 id 才是替换。
    /// 四个页面。
    ///
    /// ★ `.id(pane)` 不是多余的：没有它，SwiftUI 会把新旧两页当作同一棵树的
    ///   不同取值，按位置插值（卡片从旧页的位置滑到新页的位置），
    ///   看起来就是「里面的内容在漂移」。给了 id 才是**替换**。
    /// ★ 也不再挂 `.transition(.opacity)`：切页不给内容做过渡（见 `content`），
    ///   交叉淡入在 0.16s 里就是一层「重影」，快得只让人觉得「晃了一下」。
    @ViewBuilder private var detail: some View {
        Group {
            switch pane {
            case .general: generalForm
            case .search: searchPane
            case .ai: aiForm
            case .advanced: advancedForm
            }
        }
        .id(pane)
    }

    // MARK: - 通用

    private var generalForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 正式界面不摆禁用的假开关。「登录时启动」真接了系统；
            // 「启动后驻留菜单栏」是应用固有行为（LSUIElement），不需要开关。
            SettingsCard("启动") {
                SettingsSwitchRow("登录时启动闪寻", isOn: Binding(get: { model.launchAtLogin },
                                                              set: { model.setLaunchAtLogin($0) }))
                    .settingsRow()
                    .accessibilityIdentifier("launch-at-login")
                if let message = model.launchAtLoginMessage {
                    SettingsRowDivider()
                    noteText(message, tint: .orange).settingsRow()
                }
            }

            SettingsCard("快捷键") {
                ShortcutSettingRow(model: model).settingsRow()
            }

            // 外观三选一，选了立即生效（`AppearanceController.set` 里直接应用）。
            //
            // 排版参考 macOS 系统设置「外观与语言」页：
            // 左标签「外观」+ 右侧分段选择器（跟随系统 | 浅色 | 深色）一行排布，
            // 不是竖排单选组——三段竖着摆太占地方，也跟系统里同一功能的样子对不上。
            SettingsCard("外观") {
                SettingsLabeledRow("外观") {
                    Picker("外观", selection: appearanceBinding) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    // 分段控件默认会被拉满整行（行里它是最宽的东西），
                    // 与左标签之间留出一大片空白——按内容取自然宽度就对了。
                    .fixedSize()
                    .accessibilityIdentifier("appearance-choice")
                }
                .settingsRow()
            }

            SettingsCard("权限") {
                SettingsLabeledRow("完全磁盘访问") {
                    HStack(spacing: 8) {
                        Text(FullDiskAccess.isGranted ? "已授权" : "未授权")
                            .foregroundStyle(FullDiskAccess.isGranted ? .secondary : .primary)
                        if !FullDiskAccess.isGranted {
                            Button("授权…") { FullDiskAccess.openSettings() }
                        }
                    }
                }
                .settingsRow()
            }

            // 版本号落在「通用」末尾：用户要报问题时会先来这里找，
            // 不必再去状态栏菜单翻一次「关于」面板。值来自 Core 的
            // `AppVersion`，与「关于」面板同源，不会出现两个说法。
            SettingsCard("关于") {
                SettingsLabeledRow("版本") {
                    HStack(spacing: 10) {
                        Text(AppVersion.current).foregroundStyle(.secondary)
                        Button(UpdateCheckText.button(checking: model.updateChecking)) {
                            model.checkForUpdates()
                        }
                        .disabled(model.updateChecking)
                        .accessibilityIdentifier("check-for-updates")
                    }
                }
                .settingsRow()
                if model.updateChecking {
                    SettingsRowDivider()
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        noteText("正在读取 GitHub 上的最新发布…")
                        Spacer(minLength: 0)
                    }
                    .settingsRow()
                } else if let outcome = model.updateOutcome {
                    SettingsRowDivider()
                    updateResultRow(outcome).settingsRow()
                }
            }
        }
    }

    // MARK: - 搜索

    /// 搜索页回答的是**「搜哪些地方」**：本机范围在上，网络存储在下。
    ///
    /// 「调整搜索行为」和「管理 NAS」是同一个问题的两半，所以合到一页：
    /// 分成两页，加完一台 NAS 还得跳到另一页去改搜索设置，排查「为什么搜不到」
    /// 也要来回看。
    ///
    /// 页内不再单独摆一行「此 Mac」——它和上面的「本地搜索范围」是同一件事的
    /// 两种说法，摆两遍只会让人怀疑它们不一致。
    ///
    /// 更早的那版这里还塞过「搜索本机文件」「此 Mac ☑ / NAS ☑」与
    /// 「NAS 输入规则：至少输入 2 个字符」——前三项与来源列表重复，
    /// 最后一项是内部策略（搜索窗里会提示「再输入 1 个字符以搜索网络存储」）。
    private var searchForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            // 只有**这样设置会搜不到东西**时才说话（没选文件夹、系统索引关着）。
            // 正常态的「已启用 Spotlight」「仅搜索已选的 N 个文件夹」不再占这一行：
            // 上面刚列出来的东西，用户已经亲眼看到了。
            SettingsCard("本地搜索范围",
                         footer: model.localSearchAvailabilityMessage.isEmpty
                            ? nil : model.localSearchAvailabilityMessage) {
                Picker("本地搜索范围", selection: localScopeBinding) {
                    ForEach(LocalScopeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                // 单选组自己排三行、行距很紧；给上下多留一点，三条选项才不黏在一起。
                .padding(.vertical, 3)
                .settingsRow()
                .accessibilityIdentifier("local-search-scope")

                if localScope == .selectedFolders {
                    ForEach(model.localFolders, id: \.path) { folder in
                        SettingsRowDivider()
                        HStack {
                            Image(systemName: "folder").foregroundStyle(.secondary)
                            Text(folder.path).lineLimit(1).truncationMode(.middle)
                            Spacer()
                            Button { model.removeLocalFolder(folder) } label: {
                                Image(systemName: "minus.circle")
                            }
                            .buttonStyle(.borderless)
                            .help("从搜索范围里移除")
                        }
                        .settingsRow()
                    }
                    SettingsRowDivider()
                    Button("添加文件夹…") { model.addLocalFolder() }
                        .settingsRow()
                        .accessibilityIdentifier("local-add-folder")
                }
            }

            SettingsCard("网络存储") {
                if model.nasSources.isEmpty {
                    Text("还没有添加网络存储。")
                        .foregroundStyle(.secondary)
                        .settingsRow()
                }
                ForEach(model.nasSources) { source in
                    if let row = model.sourceRow(source.id) {
                        if source.id != model.nasSources.first?.id { SettingsRowDivider() }
                        sourceRowView(source, row)
                    }
                }
                SettingsRowDivider()
                Button {
                    model.addSource(); openWizard()
                } label: {
                    Label("添加搜索来源…", systemImage: "plus")
                }
                .settingsRow()
                .accessibilityIdentifier("add-search-source")
            }

            // 总开关被关掉是**异常状态**：下面有来源、却一台都不会被搜索。
            // 按「异常时才出现操作」的原则，只在关着的时候给一个入口。
            // （正常使用时开关由添加来源自动打开，用户不需要看见它。）
            if !model.enabled && !model.nasSources.isEmpty {
                SettingsCard("网络存储搜索") {
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        VStack(alignment: .leading, spacing: 6) {
                            Text("已关闭，下面这些来源不会被搜索。")
                            Button("打开 NAS 搜索") { model.enabled = true; model.toggleNetwork() }
                        }
                    }
                    .settingsRow()
                }
            }

            if !model.status.isEmpty {
                noteText(model.status).padding(.horizontal, 2)
            }
        }
    }

    /// 三种选择与 `localEnabled` / `localSearchMode` 的映射住在 Core
    /// （`LocalScopeChoice`）——首次启动引导要用同一套，两处各写一份必然分叉。
    private var localScope: LocalScopeChoice {
        LocalScopeChoice.resolve(localEnabled: model.localEnabled, mode: model.localSearchMode)
    }

    private var localScopeBinding: Binding<LocalScopeChoice> {
        Binding(get: { localScope }, set: { choice in
            switch choice {
            case .wholeMac:
                model.localEnabled = true
                model.setLocalSearchMode(.spotlight)
            case .selectedFolders:
                model.localEnabled = true
                model.setLocalSearchMode(.selectedFolders)
            case .off:
                model.localEnabled = false
                model.localSettingsChanged()
            }
        })
    }

    // MARK: - 来源详情

    /// 搜索页的两种形态：停在列表时是 `searchForm`，点进某一台时是详情。
    ///
    /// 详情不另开一页导航，而是把同一个内容区换掉——这样「返回」就回到刚才
    /// 那一页，与 macOS 系统设置里点进某个具体项目的体感一致。
    @ViewBuilder private var searchPane: some View {
        if let id = detailSourceID, let source = model.nasSources.first(where: { $0.id == id }) {
            sourceDetail(source).transition(.opacity)
        } else {
            searchForm.transition(.opacity)
        }
    }

    /// 来源列表里的一行。整行点击进详情，异常时旁边多一个按钮，最右是启用开关。
    private func sourceRowView(_ source: NASSourceConfig, _ row: NASSourceRowModel) -> some View {
        HStack(spacing: 12) {
            Button { detailSourceID = source.id } label: {
                HStack(spacing: 12) {
                    Image(systemName: source.vendor.symbol)
                        .font(.system(size: 20)).foregroundStyle(.secondary).frame(width: 28)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title)
                            .font(.system(size: SettingsTypography.body, weight: .medium))
                            .lineLimit(1).help(row.title)
                        HStack(spacing: 5) {
                            if row.health == .needsAttention {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Text(row.detail).font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !row.locations.isEmpty {
                            Text(row.locations).font(.system(size: SettingsTypography.caption))
                                .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                                .help(row.locations)
                        }
                    }
                    Spacer(minLength: 8)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.tertiary)
                        .accessibilityHidden(true)
                }
                // 内容区整块可点，但**不包住**右侧的开关与按钮。
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityIdentifier("source-open-" + source.id)

            // 只有出问题时才画这个按钮（`row.action == nil` 时界面里根本没有它）。
            if let action = row.action {
                Button(action.buttonTitle) { model.runSourceAction(source.id, action) }
                    .controlSize(.small)
                    .accessibilityIdentifier("source-action-" + source.id)
            }

            Toggle("", isOn: Binding(get: { row.enabled },
                                     set: { model.setSourceEnabled(source.id, $0) }))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .help("参与搜索")
                .accessibilityIdentifier("source-enabled-" + source.id)
        }
        .settingsRow()
    }

    /// 来源详情：名称 / 状态 / 搜索位置 / 账号 / 连接 / 高级 / 移除。
    private func sourceDetail(_ source: NASSourceConfig) -> some View {
        VStack(alignment: .leading, spacing: 22) {
            VStack(alignment: .leading, spacing: 12) {
                Button { detailSourceID = nil } label: {
                    Label("搜索", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("source-detail-back")

                // 身份、名字、状态回答的是同一件事——「这是一台什么设备」——
                // 所以放进同一张卡。拆成两张，名字那一行会孤零零飘在白底上。
                SettingsCard {
                    identity(source)
                }
            }

            SettingsCard("搜索位置") {
                if source.scopes.isEmpty {
                    Label("还没有选择搜索位置，这台 NAS 现在搜不到文件。", systemImage: "exclamationmark.circle")
                        .foregroundStyle(.orange)
                        .settingsRow()
                } else {
                    ForEach(Array(source.scopes.enumerated()), id: \.element) { index, scope in
                        if index > 0 { SettingsRowDivider() }
                        Label(NASSourceRowModel.scopeDisplayName(scope), systemImage: "folder")
                            .settingsRow()
                    }
                }
                SettingsRowDivider()
                Button { model.editSource(source.id); openWizard() } label: {
                    Label("修改搜索位置…", systemImage: "slider.horizontal.3")
                }
                .settingsRow()
            }

            SettingsCard("账号") {
                SettingsLabeledRow("账号") { Text(source.username.isEmpty ? "未填写" : source.username) }
                    .settingsRow()
                SettingsRowDivider()
                Button("重新登录…") { model.reconnectSource(source.id) }
                    .settingsRow()
                    .accessibilityIdentifier("source-relogin")
            }

            SettingsCard("连接") {
                SettingsLabeledRow("地址") { Text(source.host.isEmpty ? "未填写" : source.host) }
                    .settingsRow()
            }

            // 协议 / 端口 / 证书这类实现细节默认折叠——普通用户不需要读到它们。
            SettingsCard("高级") {
                DisclosureGroup("协议与证书") {
                    VStack(alignment: .leading, spacing: 6) {
                        SettingsLabeledRow("协议") { Text(source.vendor.title) }
                        SettingsLabeledRow("端口") {
                            Text(source.effectivePort > 0 ? "\(source.effectivePort)" : "未检测")
                        }
                        if !source.certificateSHA256.isEmpty {
                            SettingsLabeledRow("证书") {
                                Text(String(source.certificateSHA256.prefix(16)) + "…")
                                    .font(.system(.caption, design: .monospaced))
                            }
                        }
                        if model.nativeProviders[source.id]?.isManagerAccount == true {
                            Label("使用管理员账号搜索，范围包含这台 NAS 的全部共享",
                                  systemImage: "exclamationmark.triangle.fill")
                                .font(.system(size: SettingsTypography.caption)).foregroundStyle(.orange)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary).padding(.top, 4)
                }
                .settingsRow()
            }

            // 移除不是一个「设置项」，所以不放进卡片里：它不该看起来和上面那些行一样。
            Button("移除此搜索来源…", role: .destructive) {
                model.removeSource(source.id)
                detailSourceID = nil
            }
            .padding(.horizontal, 2)
            .accessibilityIdentifier("source-detail-remove")
        }
    }

    /// 详情页顶部那块：图标 + 名称 + 参与搜索开关，下面接名称输入与状态。
    @ViewBuilder private func identity(_ source: NASSourceConfig) -> some View {
        let status = model.sourceStatus(source.id)
        HStack(spacing: 12) {
            Image(systemName: source.vendor.symbol)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Color.accentColor.opacity(colorScheme == .dark ? 0.22 : 0.12),
                            in: RoundedRectangle(cornerRadius: 12))
            VStack(alignment: .leading, spacing: 3) {
                Text(source.displayName)
                    .font(.system(size: SettingsTypography.pageTitle, weight: .semibold))
                    .lineLimit(1).truncationMode(.middle).help(source.displayName)
                Text(model.sourceRow(source.id)?.detail ?? "")
                    .font(.system(size: SettingsTypography.body)).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Toggle("参与搜索", isOn: Binding(get: { source.enabled },
                                           set: { model.setSourceEnabled(source.id, $0) }))
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .settingsRow()

        SettingsRowDivider()

        // 「连上以后就没地方改名字」是用户报的障：名称只在添加向导里出现过一次。
        // 这一行就是那个缺口的补丁——名字是这台设备的属性，详情页理应有。
        //
        // ★ 逐键落盘，**不设「保存」按钮**：改名不是一次要确认的提交，
        //   多一个按钮等于多一个「改了没生效」的疑点。代价只是写一次偏好设置，
        //   因为名字不参与连接身份（见 `NASSourceWizardController.renameSource`）。
        // ★ `get` 里**现取**模型，不用闭包捕获的 `source`：后者是这次 body 求值时的
        //   值拷贝，写入后要等整页重算才更新，中间那一帧会把用户刚敲的字符盖回去。
        // ★ 用 `TextField(text:prompt:)` 而不是 `TextField("标题", text:)`：
        //   后者把标题当**标签**渲染，会变成框外右侧的第二个标签
        //   （截图里就是「名称 [ ] 默认：群晖 Synology」三截）。
        //   走 prompt 才是框内的灰字占位——留空时它正好显示默认名，
        //   用户不用被告知「留空会用默认名」就能看见结果。
        SettingsLabeledRow("名称") {
            TextField(text: Binding(
                get: { model.nasSources.first(where: { $0.id == source.id })?.name ?? "" },
                set: { model.renameSource(source.id, to: $0) }),
                      prompt: Text(source.vendor.title)) { EmptyView() }
                .textFieldStyle(.roundedBorder)
                .multilineTextAlignment(.leading)
                .frame(width: 220)
                .accessibilityIdentifier("source-detail-name")
        }
        .settingsRow()

        if !status.message.isEmpty {
            SettingsRowDivider()
            noteText(status.message).settingsRow()
        }
    }

    // MARK: - AI

    /// 「清空历史」的二次确认。清空不可恢复，所以不提供「不再提示」。
    @State private var confirmingHistoryClear = false
    /// 清空之后的那一句结果。★ **失败也要说**——只说成功的话，删失败时界面一片安静，
    /// 用户会以为已经清掉了。
    @State private var historyMessage: String?
    /// 刚点过「复制接入提示词」。只用来显示一下「已复制」，不参与任何判定。
    @State private var promptCopied = false

    /// AI 页回答的是「AI 现在能做什么、我给它开了什么」。
    ///
    /// 五段，顺序就是用户心里的顺序：先决定开不开 → 再说给哪些位置 →
    /// 确认它在跑 → 拿到怎么接 → 最后是「我记了什么、怎么清掉」。
    ///
    /// 判定与文案全在 Core（`AIAccessSettings` / `MCPHelperStatus` / `AIHistorySummary` /
    /// `MCPIntegrationPrompt`），这一段只做绑定：拨开关 → 草稿变；点保存 → 落盘。
    /// ★ 「助手状态」与「历史」读的都是**事实**（socket 有没有在监听、库里几条），
    ///   不是估计值；读不到就如实说读不到。
    private var aiForm: some View {
        let history = model.aiHistorySummary
        let integration = model.aiIntegrationPrompt
        return VStack(alignment: .leading, spacing: 22) {
            SettingsCard("AI 访问") {
                SettingsSwitchRow("允许 AI 使用闪寻",
                                  isOn: Binding(get: { model.aiAccess.draft.isEnabled },
                                                set: { model.aiAccess.setEnabled($0) }))
                    .settingsRow()
                    .accessibilityIdentifier("ai-access-enabled")
            }

            // 关着的时候不摆一排灰掉的勾选框：那既点不动，又像是在暗示
            // 「你已经授权了这些」。关着就只留上面那句说明。
            if model.aiAccess.draft.isEnabled {
                SettingsCard("允许 AI 搜索的位置") {
                    ForEach(Array(model.aiAccessCandidates.enumerated()), id: \.element.id) { index, candidate in
                        if index > 0 { SettingsRowDivider() }
                        SettingsSwitchRow(candidate.name,
                                          isOn: Binding(get: { model.aiAccess.draft.allowedSources.contains(candidate.id) },
                                                        set: { model.aiAccess.setSource(candidate.id, allowed: $0) }))
                            .settingsRow()
                            .accessibilityIdentifier("ai-access-source-\(candidate.id)")
                    }
                    SettingsRowDivider()
                    VStack(alignment: .leading, spacing: 8) {
                        if model.aiAccess.draft.allowedSources.isEmpty {
                            noteText("至少选择一个位置才能保存。", tint: .orange)
                        }
                        HStack(spacing: 10) {
                            Button("保存") {
                                model.aiAccess.save(existing: model.aiAccessExistingSourceIDs)
                            }
                            .disabled(!model.aiAccess.canSave)
                            .accessibilityIdentifier("ai-access-save")
                            Button("撤销修改") { model.aiAccess.discard() }
                                .disabled(!model.aiAccess.isDirty)
                                .accessibilityIdentifier("ai-access-revert")
                            if model.aiAccess.isDirty {
                                noteText("未保存")
                            }
                        }
                        if let message = model.aiAccess.message {
                            noteText(message, tint: .orange)
                        }
                    }
                    .settingsRow()
                }
            }

            SettingsCard("MCP Helper") {
                SettingsLabeledRow("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.mcpHelperStatus.isHealthy ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(model.mcpHelperStatus.title)
                    }
                }
                .settingsRow()
                .accessibilityIdentifier("ai-helper-status")
                // 健康时不写解释：那一行「正常运行」已经说完了。
                // 只有真的没在跑才需要第二行说明发生了什么。
                if !model.mcpHelperStatus.isHealthy {
                    SettingsRowDivider()
                    noteText(model.mcpHelperStatus.detail, tint: .orange).settingsRow()
                }
            }

            // 「怎么接」——这一段是 AI 页里唯一能直接解决用户问题的东西。
            //
            // ★ 只给**已保存且已开启**的状态看。草稿开着但没保存就给出可复制的一段话，
            //   用户复制过去必然连不上（权威端还认为 AI 访问是关的），
            //   那比不给更糟——所以未保存时只留一行字说明。
            //
            // ★ 正文、按钮、折叠说明全部来自 Core（`MCPIntegrationText`），
            //   这里不写任何字面量：一段要给人复制的话，最怕两处各写一份。
            if model.isAIAccessGranted {
                SettingsCard(MCPIntegrationText.title) {
                    Text(integration.text)
                        // ★ 用 `body` 而不是 `caption`：这一段是本页**要用户照做**的内容，
                        //   不是备注。用 11pt 会让整页看起来「重点在别处」。
                        .font(.system(size: SettingsTypography.body, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                        .accessibilityIdentifier("ai-prompt-text")
                        .settingsRow()

                    SettingsRowDivider()
                    HStack(spacing: 10) {
                        Button(MCPIntegrationText.copyButton) { copyPrompt(integration.text) }
                            .accessibilityIdentifier("ai-prompt-copy")
                        if promptCopied {
                            noteText(MCPIntegrationText.copied)
                        }
                        Spacer(minLength: 0)
                    }
                    .settingsRow()
                }
            } else if model.aiAccess.draft.isEnabled {
                Text(MCPIntegrationText.saveFirst)
                    .font(.system(size: SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
                    .accessibilityIdentifier("ai-prompt-save-first")
            }

            SettingsCard("AI 历史") {
                SettingsLabeledRow("记录") { Text(history.title) }
                    .settingsRow()
                    .accessibilityIdentifier("ai-history-title")
                // 正常态不写「每次成功找到都会记一条，目前 N 条」这类说明。
                // 只有历史库打不开时才必须说话——那时 recent 会返回空，
                // 用户看到的「查不到」需要一句解释。
                if history.isUnavailable {
                    SettingsRowDivider()
                    noteText(history.detail, tint: .orange).settingsRow()
                }
                SettingsRowDivider()
                VStack(alignment: .leading, spacing: 8) {
                    Button(AIHistoryText.clearButton) { confirmingHistoryClear = true }
                        .disabled(!history.canClear)
                        .accessibilityIdentifier("ai-history-clear")
                    if let historyMessage {
                        noteText(historyMessage)
                    }
                }
                .settingsRow()
            }
        }
        .alert(AIHistoryText.clearTitle, isPresented: $confirmingHistoryClear) {
            Button("清空", role: .destructive) { clearHistory() }
            Button("取消", role: .cancel) {}
        } message: {
            Text(AIHistoryText.clearDetail)
        }
    }

    /// 清空历史，并把三种结局都翻译成一句话。
    private func clearHistory() {
        switch model.clearAIHistory() {
        case .cleared(let count): historyMessage = AIHistoryText.cleared(count)
        case .failed: historyMessage = AIHistoryText.clearFailed
        case .unavailable: historyMessage = AIHistoryText.clearUnavailable
        }
    }

    /// 复制接入提示词。
    ///
    /// ★ 复制的是**当前这一段文本本身**，不是重新拼一遍：界面看到什么、剪贴板里就是什么。
    ///   重新拼会出现「屏幕上是一句、粘出来是另一句」这种只能靠人眼发现的分叉。
    private func copyPrompt(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        promptCopied = true
    }

    // MARK: - 高级

    @State private var diagnosticsShown = false

    private var advancedForm: some View {
        VStack(alignment: .leading, spacing: 22) {
            SettingsCard("诊断") {
                Button("运行连接诊断…") {
                    model.runConnectionDiagnostics()
                    diagnosticsShown = true
                }
                .settingsRow()
                .accessibilityIdentifier("run-diagnostics")
                SettingsRowDivider()
                Button("导出诊断报告…") { model.exportDiagnostics() }
                    .settingsRow()

                if diagnosticsShown {
                    ForEach(model.nasSources) { source in
                        SettingsRowDivider()
                        VStack(alignment: .leading, spacing: 4) {
                            Text(source.displayName)
                                .font(.system(size: SettingsTypography.body, weight: .medium))
                            ForEach(ConnectionDiagnostics.summary(
                                config: source,
                                status: model.sourceStatus(source.id),
                                ready: model.nativeProviders[source.id]?.ready == true), id: \.title) { line in
                                HStack(spacing: 6) {
                                    Image(systemName: line.ok ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                                        .font(.caption2)
                                        .foregroundStyle(line.ok ? .green : .orange)
                                    Text(line.title).font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary)
                                        .frame(width: 64, alignment: .leading)
                                    Text(line.value).font(.system(size: SettingsTypography.caption))
                                }
                            }
                        }
                        .settingsRow()
                    }
                }
            }

            // 连接生命周期不交给用户手动管：「重连所有 NAS」「刷新已挂载的 SMB 共享」
            // 这类按钮已收进「运行连接诊断」。
            SettingsCard("缓存") {
                Button("清除搜索缓存…") { model.status = "本版搜索不落地缓存，无需清理" }
                    .settingsRow()
            }

            SettingsCard("实验性功能") {
                SettingsSwitchRow("显示实验性搜索来源",
                                  isOn: Binding(get: { model.showExperimentalSources },
                                                set: { model.setShowExperimentalSources($0) }))
                    .settingsRow()
                    .accessibilityIdentifier("experimental-sources")
            }

            // AI 访问已搬到独立的「AI」页（Phase 9-lite，2026-10-22）：
            // 1.1.2 唯一的新增主功能，藏在「高级」里与产品定位冲突（§14.3.1）。
            // ★ 这里**不要**再放一份入口。两处入口必然分叉——一处改了另一处没改，
            //   用户看到的就是「设置里有两个 AI 开关，说的话还不一样」。

        }
    }

    /// 检查结果一行：图标 + 一句话 +（需要时）一个按钮。
    @ViewBuilder private func updateResultRow(_ outcome: UpdateCheck.Outcome) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: updateSymbol(outcome))
                .font(.system(size: SettingsTypography.caption))
                .foregroundStyle(updateTint(outcome))
            Text(UpdateCheckText.message(for: outcome))
                .font(.system(size: SettingsTypography.caption))
                .fixedSize(horizontal: false, vertical: true)
            if let title = UpdateCheckText.linkTitle(for: outcome) {
                Button(title) { model.openReleasePage(for: outcome) }
                    .controlSize(.small)
            }
        }
    }

    private func updateSymbol(_ outcome: UpdateCheck.Outcome) -> String {
        switch outcome {
        case .upToDate: return "checkmark.circle.fill"
        case .updateAvailable: return "arrow.down.circle.fill"
        case .incomparable: return "info.circle.fill"
        case .failed: return "exclamationmark.circle.fill"
        }
    }

    private func updateTint(_ outcome: UpdateCheck.Outcome) -> Color {
        switch outcome {
        case .upToDate: return .green
        case .updateAvailable: return .accentColor
        case .incomparable: return .secondary
        case .failed: return .orange
        }
    }
}

private enum SettingsLayout {
    /// 内容区最大宽度。
    ///
    /// 卡片被拉到 800pt 宽时，标签与控件之间会空出一大片，
    /// 跟系统设置的观感就对不上了。
    static let contentMaxWidth: CGFloat = 560

    /// 内容区顶部的锚点。切页时 `scrollTo` 它，把滚动位置拉回顶端。
    static let topAnchor = "settings-content-top"
}

/// 完全磁盘访问的判定与入口。
///
/// 判定方式：尝试列出一个只有完全访问才能读到的系统目录。
/// 读得到即已授权；读不到就是未授权。这里**不能**用 `|| true` 之类的占位，
/// 否则界面会一直显示「已授权」，用户按提示去授权也看不出变化。
enum FullDiskAccess {
    static var isGranted: Bool {
        let probe = URL(fileURLWithPath: "/Library/Application Support/com.apple.TCC")
        guard FileManager.default.fileExists(atPath: probe.path) else {
            // 探针路径不存在（系统版本差异）时不做乐观假设。
            return false
        }
        let contents = try? FileManager.default.contentsOfDirectory(atPath: probe.path)
        return contents != nil
    }
    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles") {
            _ = NSWorkspace.shared.open(url)
        }
    }
}
