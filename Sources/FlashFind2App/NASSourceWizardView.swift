import SwiftUI
import FlashFindCore

/// 添加/编辑搜索来源的向导。
///
/// ★ **三步**（2026-10-28 用户报障，之前标题写「共 4 步」而实际只有三步）：
///   1. 选搜索来源 —— 这一页**只列来源**，点一张卡就翻页；
///   2. 连接信息 —— 整页给表单，字段随来源不同而不同（见 `SourceConnectionLabels`）；
///   3. 选搜索位置 —— 连接成功才到这里。
///
/// 为什么把「选来源」和「填地址」拆成两页：它们原来是同一屏的上下两块，
/// 用户点了「群晖」之后下面那块表单才变得有意义，可眼睛还得往下找；
/// 同屏也让进度显示没法自洽（选来源 + 填地址被算成两步，用户数出来是三步）。
struct NASSourceWizardView: View {
    @ObservedObject var model: AppModel
    /// 地址栏焦点。翻到连接信息那一页时自动落在它上面 ——
    /// 第 1 步已经选完来源了，进来就能直接敲地址。
    @FocusState private var addressFocused: Bool
    /// 是否把局域网里的电脑、打印机也列出来。
    ///
    /// 默认不列——用户要的是 NAS，混着同事的 Mac 与打印机反而找不到。
    /// 但**认不出的设备不在这里藏**：判不明的一律保留，由用户自己挑。
    @State private var showAllNearbyDevices = false
    /// 「附近的设备」小窗是否开着。
    @State private var showingNearbyDevices = false
    /// 局域网设备发现。跟着向导窗口的生命周期起停——
    /// 关窗就停掉浏览，免得窗口没了还在收广播。
    @StateObject private var discovery = LocalNetworkDiscovery()
    /// 端口输入框的文本。刻意用 `String` 而不是直接绑 `Int`：
    /// macOS 上 `TextField(value:format:)` 要等失焦或回车才写回，
    /// 用户敲完 `5001` 看着有值、按钮却还是灰的。见 `AppModel.setDraftPort`。
    @State private var portText = ""
    /// 连接路径输入框的文本（WebDAV 专用）。
    ///
    /// 与 `portText` 同样的理由：**不要在每次按键时把规范化结果写回输入框**。
    /// 用户敲 `/dav` 的过程中，`/` 单独出现时解析结果是「等价于没填」，
    /// 回写就会把他刚敲的字符擦掉，表现为「打不进去」。
    /// 所以输入框持自己的文本，只在解析得出结果时把意图交给模型。
    @State private var basePathText = ""
    /// 当前在第几页。页数、页码文案、翻页方向全部由 Core 的 `SourceWizardFlow` 出。
    @State private var page: SourceWizardPage = .source
    /// 翻页方向：真正翻之前先记下来，新页面才知道该从左边还是右边进来。
    @State private var forward = true

    private var hiddenDeviceCount: Int { discovery.devices.count - visibleDevices.count }

    /// 当前要列出来的设备。
    ///
    /// 默认只留**明确识别为 NAS / 文件服务器**的设备；判为电脑/外设/未知的收起，
    /// 但一个按钮就能翻出来——误判的成本不该由用户承担。
    /// （规则：未知设备只进「显示全部」。）
    private var visibleDevices: [DiscoveredDevice] {
        showAllNearbyDevices ? discovery.devices : NetworkDiscovery.shownByDefault(discovery.devices)
    }

    private var isEditing: Bool { model.selectedSourceID != nil && model.nasSources.contains { $0.id == model.selectedSourceID } }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            pages
            Divider()
            footer
        }
        .frame(width: 560, height: 620)
        .background(WindowBackdrop())
        .onAppear {
            portText = PortField.text(for: model.draftSource.port)
            basePathText = BasePathField.text(for: model.draftSource.basePath)
            // 打开时落在哪一页由 Core 判：新建 → 选来源；编辑 → 连接信息；
            // 已连接 → 搜索位置（预览钩子造的草稿就是这一种）。
            page = SourceWizardFlow.enteringPage(isEditing: isEditing, isConnected: model.draftConnected)
            // 预览钩子：`FF_UI_WIZARD_PAGE=1|2|3` 直接停在某一页。
            // 翻页要靠点卡片，而截图流程不许发合成事件（会打到用户其它窗口上），
            // 所以只能在这里指定。正常启动读不到这个变量。
            if AppEnvironment.isPreview,
               let raw = ProcessInfo.processInfo.environment["FF_UI_WIZARD_PAGE"],
               let forced = SourceWizardPage(rawValue: Int(raw) ?? 0) {
                page = forced
            }
            // 预览钩子：`FF_UI_WIZARD_VENDOR=openlist` 换一个来源，看它的字段长什么样
            // （各来源的连接信息本来就不一样，见 `SourceConnectionLabels`）。
            if AppEnvironment.isPreview,
               let raw = ProcessInfo.processInfo.environment["FF_UI_WIZARD_VENDOR"],
               let vendor = NASSourceConfig.Vendor(rawValue: raw) {
                model.setDraftVendor(vendor)
            }
        }
        .onDisappear { discovery.stop() }
        // 「附近的设备」放在小窗里：列表可能几十台（含电脑与打印机），
        // 铺在主界面上会把「填地址 + 填账号」这个主任务挤出第一屏。
        // 选中一台就自动关窗并翻到连接信息，主流程一步没多。
        .sheet(isPresented: $showingNearbyDevices, onDismiss: { discovery.stop() }) {
            NearbyDevicesSheet(
                devices: visibleDevices,
                hiddenCount: hiddenDeviceCount,
                showingAll: showAllNearbyDevices,
                isScanning: discovery.isScanning,
                message: discovery.statusMessage,
                onPick: { device in
                    model.applyDiscoveredDevice(device)
                    showingNearbyDevices = false
                    go(to: .connection)
                },
                onToggleAll: { showAllNearbyDevices.toggle() },
                onRescan: { discovery.rescan(existing: model.nasSources) },
                onClose: { showingNearbyDevices = false }
            )
        }
        // 切换来源（新建 ↔ 编辑另一台）时端口文本要跟着换。
        .onChange(of: model.draftSource.id) { _ in
            portText = PortField.text(for: model.draftSource.port)
            basePathText = BasePathField.text(for: model.draftSource.basePath)
        }
        // 换品牌时路径会被清空（见 `adoptVendor`），输入框要跟着清，
        // 否则 WebDAV 上填过 `/dav` 的用户切到群晖后，框里还留着一段
        // 已经不起作用的文字。
        .onChange(of: model.draftSource.vendor) { _ in
            basePathText = BasePathField.text(for: model.draftSource.basePath)
        }
        // 路径被别处改动（例如地址栏里粘贴的整条 URL 被搬运过来）→ 同步到输入框。
        // 只在确实不一致时写，否则会把用户正在输入的光标顶到末尾。
        .onChange(of: model.draftSource.basePath) { value in
            let expected = BasePathField.text(for: value)
            if basePathText != expected { basePathText = expected }
        }
        // 端口值被别处改动（例如证书确认时回填真实端口）→ 同步到输入框。
        // 只在确实不一致时写，否则会把用户正在输入的光标顶到末尾。
        .onChange(of: model.draftSource.port) { value in
            let expected = PortField.text(for: value)
            if portText != expected { portText = expected }
        }
        // 连上了就翻到选位置那一页：第 3 步是这条流程的终点。
        // 不翻的话用户按了「连接」之后界面看起来毫无变化（地址栏还在眼前），
        // 要么再按一次、要么以为没连上。
        .onChange(of: model.draftConnected) { connected in
            // 连上 → 去选位置；断开 → 退回连接信息（位置列表会整块消失，
            // 停在原页只剩一片空白，见 `SourceWizardFlow.page(afterDisconnectingFrom:)`）。
            go(to: connected ? .scope : SourceWizardFlow.page(afterDisconnectingFrom: page))
        }
        // 证书确认必须以弹窗打断：这是整个流程里唯一需要用户「停下来核对」的地方，
        // 埋在长页面里会被当成普通提示直接划过去。
        .alert("确认这台 NAS 的证书", isPresented: trustAlertBinding) {
            Button("取消", role: .cancel) { model.rejectDraftTrust() }
            Button("信任并继续") { model.confirmDraftTrust() }
        } message: {
            if let candidate = model.nasTrustCandidate {
                Text("设备 \(candidate.host):\(candidate.port)\n\n证书指纹\n\(candidate.displayFingerprint)\n\n\(candidate.expired ? "这张证书已过期，家用 NAS 常见。确认无误再继续。" : "请核对指纹后再继续。")\n\n闪寻不会把证书装进系统信任库。")
            }
        }
    }

    private var trustAlertBinding: Binding<Bool> {
        Binding(get: { model.nasTrustCandidate != nil && !model.draftBusy },
                set: { if !$0 && !model.draftBusy { model.rejectDraftTrust() } })
    }

    // MARK: 翻页

    /// 翻到某一页。方向由两页的先后决定，新页面据此从侧边滑进来。
    ///
    /// 用 `withAnimation` 而不是 `contentTransition`：这里换的是整页内容，
    /// 需要「旧页退、新页进」两条动画同时走，那只有 `transition` 能做到。
    private func go(to target: SourceWizardPage) {
        guard target != page else { return }
        forward = SourceWizardFlow.direction(from: page, to: target) >= 0
        withAnimation(.easeInOut(duration: 0.24)) { page = target }
    }

    private var pageTransition: AnyTransition {
        let entering: Edge = forward ? .trailing : .leading
        let leaving: Edge = forward ? .leading : .trailing
        return .asymmetric(
            insertion: .move(edge: entering).combined(with: .opacity),
            removal: .move(edge: leaving).combined(with: .opacity)
        )
    }

    /// 三页内容叠在同一个位置上做翻页。
    ///
    /// `.clipped()` 必须有：滑动的页面在动画途中会超出这块区域，
    /// 不裁就会压到标题栏与底部按钮上。
    private var pages: some View {
        ZStack {
            switch page {
            case .source:
                sourcePage.transition(pageTransition)
            case .connection:
                connectionPage.transition(pageTransition)
            case .scope:
                scopePage.transition(pageTransition)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }

    // MARK: 页头 / 页脚

    private var header: some View {
        HStack(spacing: 10) {
            if isEditing {
                Button { model.addSource() } label: { Label("搜索来源", systemImage: "chevron.left") }
                    .buttonStyle(.plain).foregroundStyle(.secondary)
            }
            Image(systemName: model.draftSource.vendor.symbol).font(.system(size: 20)).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(isEditing ? "编辑 \(model.draftSource.displayName)" : "添加搜索来源")
                    .font(.headline).lineLimit(1)
                Text(subtitle).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    private var subtitle: String {
        if model.draftBusy { return "正在连接…" }
        if model.draftConnected && !model.draftSource.scopes.isEmpty { return "已连接，可以搜索了" }
        if model.draftConnected { return "已连接，请选择搜索位置" }
        // ★ 「第 N 步，共 M 步」只由 Core 出。写在这里就又会写出「共 4 步」。
        return SourceWizardFlow.subtitle(for: page)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if SourceWizardFlow.canGoBack(from: page, isEditing: isEditing) {
                FFSecondaryButton("上一步") { go(to: .source) }
                    .accessibilityIdentifier("wizard-back")
            }
            if page == .scope, model.draftConnected {
                FFSecondaryButton("断开", action: model.disconnectDraft)
            }
            Spacer()
            // 「取消」必须真的取消：关闭窗口的同时收掉这次连接留下的一切
            // （后台任务、暂存密码、待确认证书、已建立的 DSM 会话）。
            FFSecondaryButton("取消") {
                model.cancelDraft()
                NASWizardWindow.shared.close()
            }
            // 「仅保存」只在新建时出现：编辑已有来源时「保存」本身就是它。
            // 两者是两件事，不共用一个词——前者是「先记下来，之后再连」，
            // 后者是「这台来源已经能用了」。
            if page == .connection, !isEditing {
                FFSecondaryButton("仅保存") { commitAndClose() }
                    .disabled(model.draftBusy || model.draftSettling)
                    .help("先记下配置，之后再连接")
            }
            primaryButton
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
        .background(.ultraThinMaterial)
    }

    /// 底部主按钮。**每页只有一个**主按钮，并且只在这一页真正有事可做时出现。
    ///
    /// 可用性一律只走 `enabled:` 参数，不在外层再叠 `.disabled`：
    /// 组件内部本来就有一句 `.disabled(!enabled)`，两层判定会互相覆盖。
    @ViewBuilder private var primaryButton: some View {
        switch page {
        case .source:
            // 第 1 步点卡片即翻页，底下不需要按钮。
            EmptyView()
        case .connection:
            if isEditing {
                FFPrimaryButton("保存", enabled: !(model.draftBusy || model.draftSettling)) {
                    commitAndClose()
                }
            } else if model.draftConnected {
                // 已连上却还停在这一页（极少数：连接成功但翻页被跳过）——
                // 主按钮该是「完成」，而不是再连一次。
                FFPrimaryButton("完成", enabled: !model.draftSource.scopes.isEmpty) {
                    commitAndClose()
                }
            } else {
                FFPrimaryButton(model.draftBusy ? "正在连接…" : "连接",
                                systemImage: "bolt.horizontal.circle",
                                enabled: model.canConnectDraft) {
                    model.connectDraft()
                }
            }
        case .scope:
            // 已连接但还没选搜索位置时不能保存，否则会存下一台
            // 「连得上却搜不了」的来源，用户以为加好了，实际搜不到。
            FFPrimaryButton("完成",
                            enabled: !(model.draftBusy || model.draftSettling
                                       || model.draftSource.scopes.isEmpty)) {
                commitAndClose()
            }
        }
    }

    /// 保存并在**真的保存成功**之后关窗口。
    ///
    /// `commitDraft` 回 false（绑定被核心拒绝、落盘失败）时窗口必须留在原地，
    /// 让用户看到原因并重试——「点了就关」会留下一份配置与实际不一致的来源。
    private func commitAndClose() {
        Task { @MainActor in
            if await model.commitDraft() { NASWizardWindow.shared.close() }
        }
    }

    // MARK: 第 1 步 搜索来源（整页只有这一块）

    /// 首页：**只列搜索来源**，下面留白。
    ///
    /// 来源暂时只有三个，铺满一屏只会让每一块都变得很小；
    /// 以后新增来源直接往这里加一块，不必再改布局。
    @ViewBuilder private var sourcePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                if !model.draftConnected, !isEditing {
                    typeEntrySection
                } else if page == .source {
                    // 理论到不了这里（已连接 / 编辑时首页就被跳过了），
                    // 留一句话防呆，免得出现「一整页空白」。
                    Text("请从搜索来源里选一台设备。")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 24)
            .padding(.top, 24)
            .padding(.bottom, 24)
        }
    }

    /// 群晖 / OpenList / 附近的设备。
    ///
    /// 前两块决定**走哪套接口**（品牌一换，下面的表单、默认协议、端口全跟着换），
    /// 后一块是一次动作：打开小窗挑一台设备，挑完自动关窗并回填地址。
    /// 把「附近的设备」从一整块列表压成一个入口，是因为那串设备名会把
    /// 「填地址 + 填账号」这个主任务挤到第一屏之外。
    private var typeEntrySection: some View {
        FFSettingsSection(title: "搜索来源") {
            LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: 3),
                      spacing: 10) {
                ForEach(entryVendors) { vendor in
                    vendorEntry(vendor)
                }
                nearbyEntry
            }
        }
    }

    /// 要画成入口的品牌。
    ///
    /// 通常是 `model.selectableVendors`（群晖 + OpenList，开了实验开关再多个别的）。
    /// 但「附近的设备」里可能选到一台**不在这个列表里**的机器（局域网里有台威联通，
    /// 而实验开关关着）——那一刻 `applyDiscoveredDevice` 已经把品牌换过去了，
    /// 下面的表单也换成了那一套。此时若入口里没有这一项，界面上就没有任何一处
    /// 显示「现在选的是哪一种」，用户只会看到三块全是灰的。
    /// 所以补一块进去，不改变可选集合，只补上当前真实在用的那一个。
    private var entryVendors: [NASSourceConfig.Vendor] {
        let list = model.selectableVendors
        return list.contains(model.draftSource.vendor) ? list : list + [model.draftSource.vendor]
    }

    private func vendorEntry(_ vendor: NASSourceConfig.Vendor) -> some View {
        let picked = model.draftSource.vendor == vendor
        return Button {
            // 换品牌会清掉上一类型的地址/端口/账号（见 `adoptVendor`）：
            // 那些值对新品牌只有误导作用。重复点同一块是空操作。
            model.setDraftVendor(vendor)
            if !vendor.nativelySupported { model.setDraftStatus(vendor.supportMessage) }
            // ★ 选完就翻页：这一页的职责到「选好来源」为止。
            go(to: .connection)
        } label: {
            entryLabel(vendor.symbol, vendor.shortTitle, picked: picked)
        }
        .buttonStyle(.plain)
        .help(vendor.title)
        .accessibilityIdentifier("source-type-" + vendor.rawValue)
    }

    private var nearbyEntry: some View {
        Button(action: openNearby) {
            entryLabel("antenna.radiowaves.left.and.right", "附近的设备", picked: false)
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("nearby-open")
    }

    /// 一个入口块。选中态靠描边与淡底，不再加一行「已选」的文字。
    ///
    /// **不写第二行说明**：块里只放图标与名字。品牌全称对「群晖 / 群晖 Synology」
    /// 是重复，对 OpenList 更是同一个词写两遍；而这些块的下一次变化是「再加一块」，
    /// 多一行只能靠编一句文案去填，不值得。
    private func entryLabel(_ symbol: String, _ title: String, picked: Bool) -> some View {
        VStack(spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 26))
                .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                .frame(height: 30)
            Text(title).font(.callout)
        }
        .frame(maxWidth: .infinity, minHeight: 88)
        .padding(.horizontal, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(picked ? Color.accentColor.opacity(0.14)
                         : Color(nsColor: .quaternaryLabelColor).opacity(0.3)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .stroke(picked ? Color.accentColor : Color.clear, lineWidth: 1.5))
        .contentShape(Rectangle())
    }

    /// 打开「附近的设备」。
    ///
    /// 扫描只在窗口开着的时候跑：它是一次 UDP 广播，用户还在填账号密码时
    /// 没必要占着网络。关窗即停（见 `.sheet` 的 `onDismiss`）。
    private func openNearby() {
        showingNearbyDevices = true
        discovery.start(existing: model.nasSources)
    }

    // MARK: 第 2 步 连接信息（整页给表单）

    private var connectionPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                connectionSection
                if !model.draftStatus.isEmpty { statusSection }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        // 翻到这一页就把焦点放到地址栏：来源已经选完，进来就能敲地址。
        .onAppear { if !isEditing { addressFocused = true } }
        .transition(pageTransition)
    }

    /// 连接信息。字段**随来源不同**：名字取自 Core 的 `SourceConnectionLabels`，
    /// 路径框只给 WebDAV，协议选择只给允许选明文的品牌（群晖不给，见 `Vendor`）。
    @ViewBuilder private var connectionSection: some View {
        if !model.draftConnected {
            let labels = SourceConnectionLabels.forVendor(model.draftSource.vendor)
            FFSettingsSection(title: "连接信息") {
                VStack(spacing: 16) {
                    // 地址与端口**同一行**：它们是同一件事的两段（连到哪台机的哪个门），
                    // 拆成两行会让地址显得孤零零。端口固定 120pt——四位数端口够了，
                    // 剩下的全给地址（OpenList 要填整条 `https://…`）。
                    HStack(alignment: .center, spacing: 14) {
                        fieldRow(labels.addressLabel) {
                            TextField(labels.addressPlaceholder, text: $model.draftSource.host)
                                .textFieldStyle(.roundedBorder)
                                .focused($addressFocused)
                                .accessibilityIdentifier("nas-host")
                        }
                        fieldRow("端口") {
                            // 字符串绑定 + 每次按键即时解析：输入过程中按钮状态就跟着变，
                            // 不需要先点一下别处让输入框失焦。
                            TextField(labels.portPlaceholder, text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("nas-port")
                                .onChange(of: portText) { value in model.setDraftPort(value) }
                        }
                        .frame(width: 120)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    // 路径与协议同排：两者都是「端点怎么拼」的一部分，一起填完才连得上。
                    // 只有 WebDAV 有路径、群晖没有协议（见 `Vendor.allowsBasePath` /
                    // `allowsPlainHTTPChoice`），所以这一行的组合是会变的：
                    //   WebDAV = 路径 + 协议；OpenList = 只有协议；群晖 = 整行不出现。
                    if model.draftAllowsBasePath || model.draftAllowsPlainHTTPChoice {
                        HStack(alignment: .center, spacing: 14) {
                            if model.draftAllowsBasePath {
                                fieldRow("路径") {
                                    TextField("/dav", text: $basePathText)
                                        .textFieldStyle(.roundedBorder)
                                        .accessibilityIdentifier("nas-base-path")
                                        .onChange(of: basePathText) { value in model.setDraftBasePath(value) }
                                }
                            }
                            // 协议选择。**不能做成开关**：开关天生是「某项功能开着/关着」，
                            // 而协议是二选一，两边都是有效状态、只是安全性不同。
                            // 原来这里用 Toggle，标签在关着时写「使用加密连接 HTTPS」，
                            // 于是「勾上」被读成「启用加密」，实际却是切到明文——
                            // 与用户预期正好相反，且界面看上去一切正常。
                            // 现在两段并列，两个选项都写在脸上、当前生效的被选中。
                            if model.draftAllowsPlainHTTPChoice {
                                fieldRow("协议") {
                                    Picker("协议", selection: protocolChoiceBinding) {
                                        ForEach(NASProtocolChoice.allCases) { choice in
                                            Text(choice.title).tag(choice)
                                        }
                                    }
                                    .pickerStyle(.segmented)
                                    .labelsHidden()
                                    .accessibilityIdentifier("nas-protocol-choice")
                                }
                                .frame(width: 210)
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    Divider().padding(.vertical, 2)
                    HStack(alignment: .bottom, spacing: 14) {
                        fieldRow("账号") {
                            TextField("nasuser", text: $model.draftSource.username)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("nas-user")
                        }
                        fieldRow("密码") {
                            // 这里**只有**输入框。
                            //
                            // 原来下面还挂着一句「将使用本机保存的密码」——
                            // 那是提示备注，2026-10-24 用户明确要求删掉。
                            // 删掉它顺带把「依赖 `nativeNASPassword` 的条件视图」这一整类风险消掉了：
                            // 条件视图会随每次按键增删子视图，导致 SwiftUI 重建整个 VStack、
                            // 销毁并重建 PlainSecureField——重建瞬间按钮可用性判断读到空值，
                            // 于是「填了密码却点不了连接」。
                            // 现在这个位置没有任何条件子视图，按钮可用性只看模型层。
                            PlainSecureField(text: $model.nativeNASPassword, placeholder: "必填",
                                            accessibilityID: "nas-password")
                                .frame(height: 22)
                        }
                    }
                    // 【这里不要再放 OTP 输入框。】
                    //
                    // 动态码是**一次性**的：它不属于「这台 NAS 的配置」，
                    // 摆在表单里只会让人以为那是这台 NAS 的一个属性。
                    // 现在所有登录路径统一在「设备要求动态码」时弹窗问一次，
                    // 填完自动接着连（见 `promptForOTPThenReconnect`）。
                    // 表单里放了，用户就会先去填它；而多数账号根本用不到。
                    if !model.draftSource.host.isEmpty, model.draftSource.hostName.isEmpty {
                        rowError("格式不对，请填 IP 或域名")
                    }
                    if model.draftSource.port != 0, !model.draftSource.hasPort {
                        rowError("端口需在 1～65535 之间")
                    }
                    // 关闭时立刻删掉已存的旧凭据，不能只改标记——
                    // 否则用户以为「不保存了」，密码其实还躺在文件里被自动使用。
                    HStack(spacing: 8) {
                        Toggle("记住密码", isOn: Binding(
                            get: { model.draftSource.rememberPassword },
                            set: { model.setDraftRememberPassword($0) }))
                            .font(.callout)
                        Spacer()
                    }
                    .padding(.top, 2)
                    fieldRow("名称") {
                        TextField("可留空，默认用类型名", text: $model.draftSource.name)
                            .textFieldStyle(.roundedBorder)
                            .accessibilityIdentifier("nas-name")
                    }
                    // 失败之后的**一键重试**。上面的静态提示实测不够用：
                    // 切品牌会把协议开关清回新品牌的默认值（那是为修历史故障，
                    // 不能去掉），用户在飞牛上开过明文、再切到 WebDAV 时，
                    // 开关会被悄悄清成加密，于是「端口填对了却报 TLS 握手失败」。
                    // 与其让用户自己回头找那行提示，不如在失败现场给一个按钮。
                    if model.draftOffersPlainHTTPRetry {
                        HStack {
                            FFPrimaryButton("改用明文 HTTP 重试", systemImage: "arrow.triangle.2.circlepath") {
                                model.retryDraftUsingPlainHTTP()
                            }
                            .accessibilityIdentifier("nas-retry-plain-http")
                            Spacer()
                        }
                    }
                }
            }
            // 缺什么就说清楚，而且**一直说**。灰按钮不解释自己，
            // 是用户最容易理解成「程序坏了」的界面。
            // 判定统一在模型层（`AppModel.canConnectDraft`），这里只把结果说出来。
            if let reason = model.connectDisabledReason {
                rowHint(reason)
            }
            // 没有适配器的类型才提示；「已接入但未在真机验证」的照样能点连接。
            if !model.draftSource.vendor.hasAdapter {
                rowHint("\(model.draftSource.vendor.title) 尚未接入原生搜索。点「连接」会说明原因，配置可以先保存。")
            } else if model.draftSource.vendor.adapterStatus == .portedUnverified {
                // **必须走 supportMessage**，不能在这里另写一句话：
                // supportMessage 是 knownBlocker 的唯一出口（fnos 的「现在必然连不上」
                // 就挂在那里）。在这里另写一句话，
                // 就会把「已知连不上」盖成「可以试」。
                rowHint(model.draftSource.vendor.supportMessage)
            }
            // 地址/账号改过 → 钥匙串里的旧密码不能用，说清楚原因，
            // 否则用户会以为「我明明保存过密码，为什么还要再输」。
            if let hint = model.draftCredentialResetHint {
                rowHint(hint)
            }
        }
    }

    /// 标签放在输入框上方，给地址和账号保留更充足的输入空间。
    private func fieldRow<Content: View>(_ label: String,
                                        @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .font(.system(.caption, weight: .medium))
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 协议选择器的绑定。
    ///
    /// 这里有一处**方向相反**的转换：界面选的是「协议」（加密 / 明文），
    /// 而模型存的是「是否用明文」（`usePlainHTTP`）。
    ///
    /// 转换必须收在这一处 —— 反过来写成 `get: { model.draftUsesPlainHTTP }`
    /// 就会让「加密」这一段去写 `usePlainHTTP = true`，也就是选加密反而变明文。
    /// 那种错在界面上完全看不出来（两段都点得动），只能靠这条绑定守着。
    private var protocolChoiceBinding: Binding<NASProtocolChoice> {
        Binding(
            get: { NASProtocolChoice(usesPlainHTTP: model.draftUsesPlainHTTP) },
            set: { model.setDraftPlainHTTP($0.usesPlainHTTP) })
    }

    private func rowError(_ text: String) -> some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.caption).foregroundStyle(.orange)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func rowHint(_ text: String) -> some View {
        Label(text, systemImage: "info.circle")
            .font(.caption).foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: 第 3 步 搜索位置

    /// 位置列表下方那行状态。
    ///
    /// 「已选 1 个目录」对**整根**是错的：`"/"` 不是某一层目录，
    /// 而是「根下全部」（OpenList 根下有上千个文件夹时适配器只给这一个位置）。
    /// 所以整根时直接说名字，不报数量。
    private var scopeFooter: String {
        let scopes = model.draftSource.scopes
        if scopes.isEmpty { return "可以勾选多个。搜索会一次覆盖所有选中的目录。" }
        if scopes == [NASScopeLabel.wholeRoot] { return "已选：\(NASScopeLabel.wholeRootName)" }
        return "已选 \(scopes.count) 个目录"
    }

    private var scopePage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                sharesSection
                if !model.draftStatus.isEmpty { statusSection }
            }
            .padding(.horizontal, 24)
            .padding(.top, 22)
            .padding(.bottom, 24)
        }
        .transition(pageTransition)
    }

    @ViewBuilder private var sharesSection: some View {
        if model.draftConnected {
            // 管理员账号的代价必须说清楚，而不是让用户事后才发现搜到了别的东西。
            if model.draftUsesAdminAccount {
                FFErrorBanner(message: model.adminAccountWarning)
            }
            FFSettingsSection(
                title: "选择搜索位置",
                footer: scopeFooter,
                trailing: {
                    // 位置只有一两个时不给这两颗：那时「全选」和「勾上那一个」是同一件事。
                    if model.offersBulkDraftScopeSelection {
                        // 用 plain + 主题色而不是 `.link`：`.link` 会把无障碍角色变成
                        // AXLink（旁白读成「链接」），而这两颗是动作，不是跳转。
                        HStack(spacing: 14) {
                            Button("全选") { model.selectAllDraftScopes() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(!model.canSelectAllDraftScopes)
                                .accessibilityIdentifier("scopes-select-all")
                            Button("取消全选") { model.clearAllDraftScopes() }
                                .buttonStyle(.plain)
                                .foregroundStyle(Color.accentColor)
                                .disabled(!model.canClearAllDraftScopes)
                                .accessibilityIdentifier("scopes-clear-all")
                        }
                        .font(.callout)
                    }
                }
            ) {
                VStack(alignment: .leading, spacing: 8) {
                    if model.draftAvailableShares.isEmpty {
                        Label("这个账号看不到任何共享目录。请检查账号权限。", systemImage: "exclamationmark.circle")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    // 多选：用户可以同时勾选多个共享目录。
                    // 底层 DSM 的 Search.start 本就接受 folder_path 数组，
                    // 多目录一次搜索覆盖，不需要为每个目录各搜一次。
                    ForEach(model.draftAvailableShares, id: \.self) { share in
                        let picked = model.draftSource.scopes.contains(share)
                        Button {
                            model.toggleDraftScope(share)
                        } label: {
                            HStack(spacing: 10) {
                                Image(systemName: picked ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(picked ? Color.accentColor : Color.secondary)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text(NASScopeLabel.text(for: share)).font(.callout)
                                    // 整根授权的原始路径就是 "/"，再画一行只是噪声。
                                    if !NASScopeLabel.isWholeRoot(share) {
                                        Text(share).font(.caption).foregroundStyle(.secondary)
                                    }
                                }
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                        .accessibilityIdentifier("scope-" + share)
                    }
                }
            }
        }
    }

    /// 连接结果。
    ///
    /// ★ 这一段**必须保留**：连接失败时它是界面上唯一的反馈，删掉就成了
    /// 「点了一下，什么也没发生」——用户会反复点，或者以为程序坏了。
    /// 也不做精简裁剪：里面那句原因与错误类型，是用户报障时唯一能提供的线索。
    private var statusSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.draftStatus.contains("失败") || model.draftStatus.contains("找不到") ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(.secondary)
            Text(model.draftStatus).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3)))
    }
}

/// 「附近的设备」小窗。
///
/// ## 为什么独立成窗
///
/// 局域网里可能几十台设备（同事的 Mac、打印机、电视盒子都在广播），
/// 铺在向导第一屏会把「填地址 + 填账号」这个主任务挤到看不见的地方。
/// 收成一个小窗之后，选一台就自动关窗回填地址，主流程一步没多。
///
/// 扫描随窗口开关：开着才跑，关掉就停（见调用点的 `onDismiss`）。
private struct NearbyDevicesSheet: View {
    let devices: [DiscoveredDevice]
    let hiddenCount: Int
    let showingAll: Bool
    let isScanning: Bool
    let message: String
    let onPick: (DiscoveredDevice) -> Void
    let onToggleAll: () -> Void
    let onRescan: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Text("附近的设备").font(.headline)
                if isScanning { ProgressView().controlSize(.small) }
                Spacer()
                Button("关闭", action: onClose)
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(.ultraThinMaterial)

            Divider()

            ScrollView {
                VStack(spacing: 6) {
                    if devices.isEmpty {
                        Text(isScanning ? "正在查找…" : message)
                            .font(.callout).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 6)
                    }
                    ForEach(devices) { device in
                        Button { onPick(device) } label: { row(device) }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("nearby-device-" + device.id)
                    }
                }
                .padding(16)
            }

            Divider()

            HStack(spacing: 10) {
                if hiddenCount > 0 || showingAll {
                    Button(showingAll ? "只看 NAS 与文件服务器" : "显示全部（还有 \(hiddenCount) 台）",
                           action: onToggleAll)
                        .controlSize(.small)
                        .accessibilityIdentifier("nearby-show-all")
                }
                Spacer()
                Button("重新查找", action: onRescan)
                    .controlSize(.small)
                    .disabled(isScanning)
                    .accessibilityIdentifier("nearby-rescan")
            }
            .padding(.horizontal, 16).padding(.vertical, 10)
            .background(.ultraThinMaterial)
        }
        .frame(width: 440, height: 420)
        .background(.regularMaterial)
    }

    private func row(_ device: DiscoveredDevice) -> some View {
        HStack(spacing: 8) {
            Image(systemName: device.vendorHint?.symbol ?? "server.rack")
                .frame(width: 18).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(device.name.isEmpty ? device.host : device.name)
                    .font(.callout).lineLimit(1)
                Text(device.addressText)
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            // 认不出类型的照实标出来——判成 NAS 的不标，那本来就是默认该有的。
            if device.kind != .nas {
                Text(device.kind.title)
                    .font(.caption2).foregroundStyle(.secondary)
                    .accessibilityIdentifier("nearby-kind-" + device.id)
            }
            // 已在来源列表里的照实说，但**不禁用**：
            // 同一台 NAS 用另一个账号再添加一次是合理需求。
            if device.alreadyAdded {
                Text("已添加").font(.caption2).foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
        .contentShape(Rectangle())
    }
}
