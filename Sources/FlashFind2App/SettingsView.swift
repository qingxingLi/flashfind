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
///    分段控件；
/// 2. **来源列表只显示名称 / 状态 / 位置 / 启用**，点整行进详情页，
///    只有出问题时才出现一个按钮；
/// 3. **视觉走系统原生**：`Form` + `.formStyle(.grouped)`，不再自绘卡片；
/// 4. **页脚只在有问题时出现**：本机那一段的说明
///    只在「没选文件夹 / 系统索引关着」时说，「Spotlight 已启用」这类正常态
///    不再占一行；「网络存储」下面那句解释「附近设备」会自动查找的话也删了——
///    点进向导第一屏就摆着「附近的设备」。
///
/// 判定逻辑尽量不在这一层：来源行的呈现来自 `NASSourceRowModel`，
/// 页面集合来自 `SettingsPane`，诊断汇总来自 `ConnectionDiagnostics`。
struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var pane: SettingsPane
    /// 搜索页当前打开的来源详情。`nil` 表示停在列表。
    @State private var detailSourceID: String?

    init(model: AppModel, initialPage: SettingsPane = .search) {
        self.model = model
        _pane = State(initialValue: initialPage)
    }

    var body: some View {
        VStack(spacing: 0) {
            panePicker
            Divider()
            content
        }
        .frame(minWidth: 520, idealWidth: 640, minHeight: 520, idealHeight: 620)
        .onChange(of: pane) { _ in detailSourceID = nil }
        .onAppear {
            model.refreshLaunchAtLogin()
            // 本机搜索的提示只在打开设置时才有意义，检查也就在这时候做。
            // 少了这一句，「Spotlight 索引被关掉」这类必须让用户知道的提醒
            // 永远不会出现，本机那一段会变成一行等不到结果的「正在检查本机搜索状态」。
            model.refreshLocalSearchAvailability()
        }
    }

    /// 一级导航。三页用顶部横向分段控件，不放左侧栏——
    /// 三页配一条永久侧栏，窗口拉高时左栏会留下大片空白，
    /// 还要白占 170–230pt 的宽度。分段控件是 macOS 原生控件
    ///（`NSSegmentedControl`），Tab 聚焦 + 方向键与 VoiceOver 天然可用。
    private var panePicker: some View {
        Picker("设置页面", selection: $pane) {
            ForEach(SettingsPane.allCases) { item in
                Text(item.rawValue)
                    .tag(item)
                    // 每一段都挂标识：键盘导航与 VoiceOver 靠它定位。
                    .accessibilityIdentifier("settings-nav-" + item.rawValue)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("settings-pane-picker")
        .padding(.horizontal, 16)
        .padding(.vertical, 11)
    }

    /// 内容区：限宽并居中，窗口拉宽时表单不再无限横向拉伸。
    private var content: some View {
        detail
            .frame(maxWidth: SettingsLayout.contentMaxWidth)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// 打开来源向导的独立窗口。
    private func openWizard() {
        NSApp.activate(ignoringOtherApps: true)
        NASWizardWindow.shared.show(model: model)
    }

    // MARK: - 字号阶梯

    /// 分段标题：「启动」「快捷键」「外观」「权限」「关于」。
    ///
    /// 字号走 Core 的 `SettingsTypography`。标题只靠字重区分看不出来，
    /// 所以这里显式给大一档的字号加半粗，不再依赖系统默认那套
    /// 几乎看不出区别的排版。
    private func sectionHeader(_ text: String) -> some View {
        Text(text).font(.system(size: SettingsTypography.sectionHeader, weight: .semibold))
    }

    /// 分段页脚（辅助说明）：比正文小一档，且不抢注意力。
    private func sectionFooter(_ text: String) -> some View {
        Text(text).font(.system(size: SettingsTypography.caption))
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    /// 「外观」选择。双向绑定到模型——`.constant(...)` 那种点了不改模型的写法
    /// 正是 R01 的成因，不能在新的选择器上重犯。
    private var appearanceBinding: Binding<AppearanceChoice> {
        Binding(get: { model.appearanceChoice }, set: { model.appearanceChoice = $0 })
    }

    @ViewBuilder private var detail: some View {
        switch pane {
        case .general: generalForm
        case .search: searchPane
        case .ai: aiForm
        case .advanced: advancedForm
        }
    }

    // MARK: - 通用

    private var generalForm: some View {
        Form {
            // 正式界面不摆禁用的假开关。「登录时启动」真接了系统；
            // 「启动后驻留菜单栏」是应用固有行为（LSUIElement），不需要开关。
            Section {
                Toggle("登录时启动闪寻", isOn: Binding(get: { model.launchAtLogin },
                                                    set: { model.setLaunchAtLogin($0) }))
                    .accessibilityIdentifier("launch-at-login")
                if let message = model.launchAtLoginMessage {
                    Text(message).font(.system(size: SettingsTypography.caption)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                sectionHeader("启动")
            }

            Section {
                ShortcutSettingRow(model: model)
            } header: {
                sectionHeader("快捷键")
            } footer: {
                sectionFooter("再次按下快捷键可隐藏搜索窗口。")
            }

            // 外观三选一，选了立即生效（`AppearanceController.set` 里直接应用）。
            //
            // 排版参考 macOS 系统设置「外观与语言」页：
            // 左标签「外观」+ 右侧分段选择器（跟随系统 | 浅色 | 深色）一行排布，
            // 不是竖排单选组——三段竖着摆太占地方，也跟系统里同一功能的样子对不上。
            Section {
                LabeledContent("外观") {
                    Picker("外观", selection: appearanceBinding) {
                        ForEach(AppearanceChoice.allCases) { choice in
                            Text(choice.title).tag(choice)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance-choice")
                }
            } header: {
                sectionHeader("外观")
            }

            Section {
                LabeledContent("完全磁盘访问") {
                    HStack(spacing: 8) {
                        Text(FullDiskAccess.isGranted ? "已授权" : "未授权")
                            .foregroundStyle(FullDiskAccess.isGranted ? .secondary : .primary)
                        if !FullDiskAccess.isGranted {
                            Button("授权…") { FullDiskAccess.openSettings() }
                        }
                    }
                }
            } header: {
                sectionHeader("权限")
            } footer: {
                sectionFooter("搜索桌面、文档这类受保护的位置需要「完全磁盘访问」。网络访问只在添加了 NAS 来源时才用到。")
            }

            // 版本号落在「通用」末尾：用户要报问题时会先来这里找，
            // 不必再去状态栏菜单翻一次「关于」面板。值来自 Core 的
            // `AppVersion`，与「关于」面板同源，不会出现两个说法。
            Section {
                LabeledContent("版本") { Text(AppVersion.current) }
            } header: {
                sectionHeader("关于")
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section {
                Picker("本地搜索范围", selection: localScopeBinding) {
                    ForEach(LocalScopeChoice.allCases) { choice in
                        Text(choice.title).tag(choice)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .accessibilityIdentifier("local-search-scope")

                if localScope == .selectedFolders {
                    ForEach(model.localFolders, id: \.path) { folder in
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
                    }
                    Button("添加文件夹…") { model.addLocalFolder() }
                        .accessibilityIdentifier("local-add-folder")
                }
            } header: {
                sectionHeader("本地搜索范围")
            } footer: {
                // 只有**这样设置会搜不到东西**时才说话（没选文件夹、系统索引关着）。
                // 正常态的「已启用 Spotlight」「仅搜索已选的 N 个文件夹」不再占这一行：
                // 上面刚列出来的东西，用户已经亲眼看到了。
                if !model.localSearchAvailabilityMessage.isEmpty {
                    sectionFooter(model.localSearchAvailabilityMessage)
                }
            }

            Section {
                if model.nasSources.isEmpty {
                    Text("还没有添加网络存储。")
                        .foregroundStyle(.secondary)
                }
                ForEach(model.nasSources) { source in
                    if let row = model.sourceRow(source.id) {
                        sourceRowView(source, row)
                    }
                }
                Button {
                    model.addSource(); openWizard()
                } label: {
                    Label("添加搜索来源…", systemImage: "plus")
                }
                .accessibilityIdentifier("add-search-source")
            } header: {
                sectionHeader("网络存储")
            }

            // 总开关被关掉是**异常状态**：下面有来源、却一台都不会被搜索。
            // 按「异常时才出现操作」的原则，只在关着的时候给一个入口。
            // （正常使用时开关由添加来源自动打开，用户不需要看见它。）
            if !model.enabled && !model.nasSources.isEmpty {
                Section {
                    Label {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("NAS 搜索已关闭，下面这些来源不会被搜索。")
                            Button("打开 NAS 搜索") { model.enabled = true; model.toggleNetwork() }
                        }
                    } icon: {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                }
            }

            if !model.status.isEmpty {
                Section {
                    Text(model.status).font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
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
            sourceDetail(source)
        } else {
            searchForm
        }
    }

    /// 来源列表里的一行。整行点击进详情，异常时旁边多一个按钮，最右是启用开关。
    private func sourceRowView(_ source: NASSourceConfig, _ row: NASSourceRowModel) -> some View {
        HStack(spacing: 10) {
            Button { detailSourceID = source.id } label: {
                HStack(spacing: 10) {
                    Image(systemName: source.vendor.symbol)
                        .font(.system(size: 17)).foregroundStyle(.secondary).frame(width: 22)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(row.title).lineLimit(1)
                        HStack(spacing: 5) {
                            if row.health == .needsAttention {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.caption2).foregroundStyle(.orange)
                            }
                            Text(row.detail).font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary).lineLimit(1)
                        }
                        if !row.locations.isEmpty {
                            Text(row.locations).font(.system(size: SettingsTypography.caption)).foregroundStyle(.tertiary).lineLimit(1)
                        }
                    }
                    Spacer(minLength: 8)
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
        .padding(.vertical, 2)
    }

    /// 来源详情：名称 / 状态 / 搜索位置 / 账号 / 连接 / 高级 / 移除。
    private func sourceDetail(_ source: NASSourceConfig) -> some View {
        let status = model.sourceStatus(source.id)
        return Form {
            Section {
                Button { detailSourceID = nil } label: {
                    Label("搜索", systemImage: "chevron.left")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .accessibilityIdentifier("source-detail-back")

                HStack(spacing: 12) {
                    Image(systemName: source.vendor.symbol)
                        .font(.system(size: 26)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(source.displayName)
                            .font(.system(size: SettingsTypography.pageTitle, weight: .semibold))
                        Text(model.sourceRow(source.id)?.detail ?? "")
                            .font(.system(size: SettingsTypography.body)).foregroundStyle(.secondary)
                    }
                    Spacer(minLength: 0)
                    // 这里不能加 `.fixedSize()`：macOS 15 的 grouped `Form` 里，
                    // 带标签的 Toggle 一旦双向固定尺寸，所在 Section 的行高计算
                    // 会爆炸（每行被撑到几十倍高，整张卡片拉开一大片空白）。
                    // NSSwitch 本身宽度固定，不需要它；开关的语义说明靠这行标签与
                    // accessibilityIdentifier 兜底。列表页（sourceRowView）从来没加过。
                    Toggle("参与搜索", isOn: Binding(get: { source.enabled },
                                                   set: { model.setSourceEnabled(source.id, $0) }))
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
                .padding(.vertical, 4)

                if !status.message.isEmpty {
                    Text(status.message).font(.system(size: SettingsTypography.caption)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Section {
                if source.scopes.isEmpty {
                    Text("还没有选择搜索位置，这台 NAS 现在搜不到文件。")
                        .foregroundStyle(.orange)
                } else {
                    ForEach(source.scopes, id: \.self) { scope in
                        Text(NASSourceRowModel.scopeDisplayName(scope))
                    }
                }
                Button("修改搜索位置…") { model.editSource(source.id); openWizard() }
            } header: {
                sectionHeader("搜索位置")
            }

            Section {
                LabeledContent("账号") { Text(source.username.isEmpty ? "未填写" : source.username) }
                Button("重新登录…") { model.reconnectSource(source.id) }
                    .accessibilityIdentifier("source-relogin")
            } header: {
                sectionHeader("账号")
            }

            Section {
                LabeledContent("地址") { Text(source.host.isEmpty ? "未填写" : source.host) }
            } header: {
                sectionHeader("连接")
            }

            // 协议 / 端口 / 证书这类实现细节默认折叠——普通用户不需要读到它们。
            Section {
                DisclosureGroup("协议与证书") {
                    VStack(alignment: .leading, spacing: 6) {
                        LabeledContent("协议") { Text(source.vendor.title) }
                        LabeledContent("端口") {
                            Text(source.effectivePort > 0 ? "\(source.effectivePort)" : "未检测")
                        }
                        if !source.certificateSHA256.isEmpty {
                            LabeledContent("证书") {
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
            }

            Section {
                Button("移除此搜索来源…", role: .destructive) {
                    model.removeSource(source.id)
                    detailSourceID = nil
                }
                .accessibilityIdentifier("source-detail-remove")
            }
        }
        .formStyle(.grouped)
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
        return Form {
            Section {
                Toggle("允许 AI 使用闪寻",
                       isOn: Binding(get: { model.aiAccess.draft.isEnabled },
                                     set: { model.aiAccess.setEnabled($0) }))
                    .accessibilityIdentifier("ai-access-enabled")
            } header: {
                sectionHeader("AI 访问")
            } footer: {
                sectionFooter(model.aiAccess.draft.isEnabled
                              ? "关掉后 AI 立刻失去连接，正在进行的搜索也会停下。"
                              : "打开后，Claude、Codex、Cursor 这类 AI 工具才能通过闪寻查找文件。默认关闭，也不会预先勾选任何位置。")
            }

            // 关着的时候不摆一排灰掉的勾选框：那既点不动，又像是在暗示
            // 「你已经授权了这些」。关着就只留上面那句说明。
            if model.aiAccess.draft.isEnabled {
                Section {
                    ForEach(model.aiAccessCandidates) { candidate in
                        Toggle(candidate.name,
                               isOn: Binding(get: { model.aiAccess.draft.allowedSources.contains(candidate.id) },
                                             set: { model.aiAccess.setSource(candidate.id, allowed: $0) }))
                            .accessibilityIdentifier("ai-access-source-\(candidate.id)")
                    }
                    if model.aiAccess.draft.allowedSources.isEmpty {
                        Text("至少选择一个位置才能保存。")
                            .font(.system(size: SettingsTypography.caption))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
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
                            Text("未保存")
                                .font(.system(size: SettingsTypography.caption))
                                .foregroundStyle(.secondary)
                        }
                    }
                    if let message = model.aiAccess.message {
                        Text(message)
                            .font(.system(size: SettingsTypography.caption))
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } header: {
                    sectionHeader("允许 AI 搜索的位置")
                } footer: {
                    sectionFooter("AI 只能看到你在这里勾选的来源。没有勾选的来源，连名字都不会告诉 AI。")
                }
            }

            Section {
                LabeledContent("状态") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.mcpHelperStatus.isHealthy ? Color.green : Color.secondary)
                            .frame(width: 7, height: 7)
                        Text(model.mcpHelperStatus.title)
                    }
                }
                .accessibilityIdentifier("ai-helper-status")
                Text(model.mcpHelperStatus.detail)
                    .font(.system(size: SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } header: {
                sectionHeader("MCP Helper")
            } footer: {
                // 这里不写「已连接 N 个客户端」之类的数字：闪寻只知道自己这边在监听，
                // 谁连上来、连了几个它并不跟踪。编一个数字比不写更糟。
                //
                // ★ 必须补最后那句：上面可能写着「正常运行」而 AI 访问是关着的
                //（socket 一直在监听，判定在服务里）。不说明的话，用户会以为
                //「正常运行」等于「AI 现在能用」，然后去问为什么搜不到。
                sectionFooter("这一行说的是闪寻这一侧在不在等待连接。AI 客户端什么时候连上来，由你在那边决定；AI 访问关着时，连上来也会被拒绝。")
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
                Section {
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

                    HStack(spacing: 10) {
                        Button(MCPIntegrationText.copyButton) { copyPrompt(integration.text) }
                            .accessibilityIdentifier("ai-prompt-copy")
                        if promptCopied {
                            Text(MCPIntegrationText.copied)
                                .font(.system(size: SettingsTypography.caption))
                                .foregroundStyle(.secondary)
                        }
                    }

                    // 刻意不给「Claude / Codex / Cursor」三选一：填进去的永远是同一个路径，
                    // 选客户端只会让人以为选错了就接不上。这里真正的分支只有
                    // 「它的配置写法长什么样」，而那件事该由它自己的文档回答。
                    DisclosureGroup(MCPIntegrationText.otherClientsTitle) {
                        Text(MCPIntegrationText.otherClientsDetail)
                            .font(.system(size: SettingsTypography.caption))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(.top, 4)
                    }
                    .accessibilityIdentifier("ai-prompt-other-clients")
                } header: {
                    sectionHeader(MCPIntegrationText.title)
                } footer: {
                    sectionFooter(MCPIntegrationText.footer)
                }
            } else if model.aiAccess.draft.isEnabled {
                Section {
                    Text(MCPIntegrationText.saveFirst)
                        .font(.system(size: SettingsTypography.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("ai-prompt-save-first")
                }
            }

            Section {
                LabeledContent("记录") { Text(history.title) }
                    .accessibilityIdentifier("ai-history-title")
                Text(history.detail)
                    .font(.system(size: SettingsTypography.caption))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Button(AIHistoryText.clearButton) { confirmingHistoryClear = true }
                    .disabled(!history.canClear)
                    .accessibilityIdentifier("ai-history-clear")
                if let historyMessage {
                    Text(historyMessage)
                        .font(.system(size: SettingsTypography.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } header: {
                sectionHeader("AI 历史")
            } footer: {
                sectionFooter("历史只记在本机：谁在什么时候看过哪个文件。不记文件内容，不上传。清空不影响 AI 已经拿到的文件编号。")
            }
        }
        .formStyle(.grouped)
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
        Form {
            Section {
                Button("运行连接诊断…") {
                    model.runConnectionDiagnostics()
                    diagnosticsShown = true
                }
                .accessibilityIdentifier("run-diagnostics")
                Button("导出诊断报告…") { model.exportDiagnostics() }

                if diagnosticsShown {
                    ForEach(model.nasSources) { source in
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
                        .padding(.vertical, 2)
                    }
                }
            } header: {
                sectionHeader("诊断")
            } footer: {
                sectionFooter("诊断会刷新所有来源的状态，并用已保存的密码把能连的来源连起来。报告里没有查询词、文件名与密码。")
            }

            // 连接生命周期不交给用户手动管：「重连所有 NAS」「刷新已挂载的 SMB 共享」
            // 这类按钮已收进「运行连接诊断」。
            Section {
                Button("清除搜索缓存…") { model.status = "本版搜索不落地缓存，无需清理" }
            } header: {
                sectionHeader("缓存")
            }

            Section {
                Toggle("显示实验性搜索来源",
                       isOn: Binding(get: { model.showExperimentalSources },
                                     set: { model.setShowExperimentalSources($0) }))
                    .accessibilityIdentifier("experimental-sources")
            } header: {
                sectionHeader("实验性功能")
            } footer: {
                sectionFooter("打开后，「添加搜索来源」里会出现尚未在真机上验证过的类型（威联通 / 绿联 / 飞牛 / WebDAV）。它们当中有的是已知连不上的，仅供自行尝试。")
            }

            // AI 访问已搬到独立的「AI」页（Phase 9-lite，2026-10-22）：
            // 1.1.2 唯一的新增主功能，藏在「高级」里与产品定位冲突（§14.3.1）。
            // ★ 这里**不要**再放一份入口。两处入口必然分叉——一处改了另一处没改，
            //   用户看到的就是「设置里有两个 AI 开关，说的话还不一样」。

            // 检查更新放在高级页末尾：它不改任何设置，只是「看看有没有新版」。
            //
            // 只判断、不自动装：更新包没有 Developer ID 签名与公证，自动替换 App
            // 这一步在不签名的前提下要么必然失败、要么得关掉验签。所以这里只把
            // 用户送到发版页，下载与拖动由他自己来，出问题也看得见。
            Section {
                LabeledContent("当前版本") {
                    HStack(spacing: 10) {
                        Text(AppVersion.current)
                        Button(UpdateCheckText.button(checking: model.updateChecking)) {
                            model.checkForUpdates()
                        }
                        .disabled(model.updateChecking)
                        .accessibilityIdentifier("check-for-updates")
                    }
                }
                if model.updateChecking {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("正在读取 GitHub 上的最新发布…")
                            .font(.system(size: SettingsTypography.caption))
                            .foregroundStyle(.secondary)
                    }
                    .padding(.vertical, 2)
                } else if let outcome = model.updateOutcome {
                    updateResultRow(outcome)
                }
            } header: {
                sectionHeader("更新")
            } footer: {
                sectionFooter("从 GitHub 的发布页读取最新版本号后比对，只发一个查询请求，不上传任何信息。")
            }
        }
        .formStyle(.grouped)
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
        .padding(.vertical, 2)
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
    /// 表单行被拉到 800pt 宽时，标签与控件之间会空出一大片，
    /// 跟系统设置的观感就对不上了。
    static let contentMaxWidth: CGFloat = 560
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
