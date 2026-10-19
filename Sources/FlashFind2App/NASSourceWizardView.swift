import SwiftUI
import FlashFindCore

/// 添加/编辑 NAS 的向导。分步而不是一整页输入框：
/// 选类型 → 填地址 → 确认证书 → 登录 → 选搜索位置。
struct NASSourceWizardView: View {
    @ObservedObject var model: AppModel
    @FocusState private var nameFocused: Bool
    @State private var showOTP = false
    /// 是否把局域网里的电脑、打印机也列出来。
    ///
    /// 默认不列——用户要的是 NAS，混着同事的 Mac 与打印机反而找不到。
    /// 但**认不出的设备不在这里藏**：判不明的一律保留，由用户自己挑。
    @State private var showAllNearbyDevices = false
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
    private var host: String { model.draftSource.hostName }

    private var step: Int {
        if model.nasTrustCandidate != nil { return 3 }
        if !model.draftConnected { return model.draftStatus.isEmpty ? 2 : 2 }
        return model.draftSource.scope.isEmpty ? 4 : 5
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView { VStack(alignment: .leading, spacing: 20) { sections }.padding(20) }
            Divider()
            footer
        }
        .frame(width: 520, height: 560)
        .onAppear {
            if !isEditing { nameFocused = true }
            portText = PortField.text(for: model.draftSource.port)
            basePathText = BasePathField.text(for: model.draftSource.basePath)
            // 编辑已有来源时不去扫局域网：用户是来改配置的，不是来找设备的，
            // 白白扫一遍网段还会让窗口弹出一串无关设备。
            if !isEditing { discovery.start(existing: model.nasSources) }
        }
        .onDisappear { discovery.stop() }
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
    }

    private var subtitle: String {
        if model.draftBusy { return "正在连接…" }
        if model.draftConnected && !model.draftSource.scope.isEmpty { return "已连接，可以搜索了" }
        if model.draftConnected { return "已连接，请选择搜索位置" }
        // 只有一种可选类型时不再有「选类型」这一步，步数表述跟着变，
        // 否则用户会去找一个不存在的第 1 步（UI 简化）。
        if model.selectableVendors.count > 1 && host.isEmpty { return "第 1 步，共 4 步" }
        return "第 2 步，共 4 步"
    }

    @ViewBuilder private var sections: some View {
        // 选类型这一步只在**确实有多种可选**时才有意义。默认只开放群晖，
        // 铺一个只有一项的网格等于让用户白点一次；这时改成直接给这一项的说明。
        // 想让其它类型重新可选，打开「高级 ▸ 实验性功能 ▸ 显示实验性搜索来源」。
        if model.selectableVendors.count > 1 {
            vendorSection
        } else {
            Text(model.draftSource.vendor.serviceHint)
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        // 证书确认已改为 alert，不再占页面位置。
        // 「附近的设备」只在**地址还空着、也还没连上**时出现：用户一旦选了
        // 一台或开始手填地址，这块列表就只剩占地方的作用。
        //
        // 扫描没结果时**仍然显示这一块**（只是写着「没找到」+ 一个「重新查找」），
        // 而不是整块消失——否则用户根本不知道有「自动找设备」这件事，
        // 只会以为地址必须自己去路由器后台翻。
        if !model.draftConnected, host.isEmpty, !isEditing {
            nearbySection
        }
        if model.nasTrustCandidate == nil { connectionSection }
        sharesSection
        if !model.draftStatus.isEmpty { statusSection }
    }

    // MARK: 附近的设备

    /// 同局域网里找到的候选设备。
    ///
    /// 这一块是为了**省掉「去路由器后台翻 IP」这一步**。列出的是
    /// `LocalNetworkDiscovery` 的结果：设备自己广播的（有名字）排在前面，
    /// 端口探测命中的排在后面（只有地址）。
    ///
    /// 选中只预填地址与端口，不自动连接——用户还要填账号密码，
    /// 也该先核对一眼这个地址对不对。
    private var nearbySection: some View {
        FFSettingsSection(title: "附近的设备",
                          footer: visibleDevices.isEmpty
                              ? discovery.statusMessage
                              : "选中一台会自动填好地址，再填账号密码即可。") {
            if discovery.devices.isEmpty, discovery.isScanning {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在查找…").font(.caption).foregroundStyle(.secondary)
                }
            }
            ForEach(visibleDevices) { device in
                Button {
                    model.applyDiscoveredDevice(device)
                } label: {
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
                        // 认不出类型的照实标出来——用户需要知道「这台是什么没人能替他判断」。
                        // 判成 NAS 的不标，那本来就是默认视图里该有的东西。
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
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .fill(Color(nsColor: .quaternaryLabelColor).opacity(0.25)))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityIdentifier("nearby-device-" + device.id)
            }
            if hiddenDeviceCount > 0 || showAllNearbyDevices {
                Button(showAllNearbyDevices ? "只看 NAS 与文件服务器" : "显示全部局域网设备（还有 \(hiddenDeviceCount) 台已隐藏）") {
                    showAllNearbyDevices.toggle()
                }
                .controlSize(.small)
                .accessibilityIdentifier("nearby-show-all")
            }
            if !discovery.isScanning {
                Button("重新查找") { discovery.rescan(existing: model.nasSources) }
                    .controlSize(.small)
                    .accessibilityIdentifier("nearby-rescan")
            }
        }
    }

    // MARK: Step 1 类型

    private var vendorSection: some View {
        FFSettingsSection(title: "你的 NAS 类型",
                          footer: model.draftSource.vendor.serviceHint) {
            LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 8) {
                ForEach(model.selectableVendors) { vendor in
                    Button {
                        // 换类型等于放弃当前这次连接：已建立的会话、待确认的证书
                        // 都属于原来那个类型，必须一起收掉。
                        // 明文 HTTP 的显式选择也一起清掉——它属于原品牌，
                        // 留着会盖住新品牌的默认协议（见 `setDraftVendor`）。
                        model.setDraftVendor(vendor)
                        if !vendor.nativelySupported { model.setDraftStatus(vendor.supportMessage) }
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: vendor.symbol).frame(width: 18)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(vendor.title).font(.callout)
                            }
                            Spacer(minLength: 0)
                            if model.draftSource.vendor == vendor { Image(systemName: "checkmark").font(.caption) }
                        }
                        .padding(.horizontal, 10).padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .fill(model.draftSource.vendor == vendor ? Color.accentColor.opacity(0.16) : Color(nsColor: .quaternaryLabelColor).opacity(0.35)))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: Step 2 地址与账号

    @ViewBuilder private var connectionSection: some View {
        if !model.draftConnected {
            // IP / 端口 / 账号 / 密码合并成一个「连接信息」模块，四项一次填完。
            // 分成两段会让用户以为要先弄地址、再弄账号，实际上它们是一组。
            FFSettingsSection(title: "连接信息", footer: "在浏览器打开 NAS 管理页面，地址栏里的就是 IP 和端口。群晖常见端口是 5001。") {
                VStack(spacing: 10) {
                    HStack(spacing: 10) {
                        labeledField("IP") {
                            TextField("192.168.1.96", text: $model.draftSource.host)
                                .textFieldStyle(.roundedBorder)
                        }
                        labeledField("端口") {
                            // 字符串绑定 + 每次按键即时解析：输入过程中按钮状态就跟着变，
                            // 不需要先点一下别处让输入框失焦。
                            TextField("5001", text: $portText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("nas-port")
                                .onChange(of: portText) { value in model.setDraftPort(value) }
                        }
                    }
                    // 连接路径（WebDAV 专用，见 `Vendor.allowsBasePath`）。
                    // 这类服务的 WebDAV 端点**不在站根上**：OpenList / Alist 在
                    // `/dav`，NextCloud 在 `/remote.php/dav`。没有这个框，
                    // 用户就没有任何办法表达这件事——只能看着「连不上」，
                    // 而不知道差在哪一段。
                    if model.draftAllowsBasePath {
                        labeledField("路径") {
                            TextField("/dav", text: $basePathText)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("nas-base-path")
                                .onChange(of: basePathText) { value in model.setDraftBasePath(value) }
                        }
                        rowHint("WebDAV 服务所在的路径。OpenList / Alist 填 /dav，NextCloud 填 /remote.php/dav；服务直接挂在根目录时留空。整条地址粘进「IP」栏也可以，这里会自动带出来。")
                    }
                    // 协议开关。品牌默认值不够用：WebDAV 的默认是 https，
                    // 但只开明文 HTTP 的设备并不少见（已真机验证的飞牛 5005 就是），
                    // 而端口是用户自填的，客户端无从猜测。没有这个开关，
                    // 这类设备在界面上就没有任何可用的接入方式。
                    // 群晖不给这个开关：它走证书固定，核心只接受 https。
                    if model.draftAllowsPlainHTTPChoice {
                        Toggle(isOn: Binding(get: { model.draftUsesPlainHTTP },
                                             set: { model.setDraftPlainHTTP($0) })) {
                            Text(model.draftUsesPlainHTTP
                                 ? "使用明文 HTTP（不加密）"
                                 : "使用加密连接 HTTPS")
                                .font(.callout)
                        }
                        .toggleStyle(.switch)
                        .accessibilityIdentifier("nas-plain-http")
                        if model.draftUsesPlainHTTP {
                            rowHint("明文 HTTP 下账号与密码不会被加密，同一网络内的其他人可能看到。仅在该设备只提供 http 时使用。")
                        } else {
                            // 只在「还没打开」时提示。原因：不少 NAS 的 WebDAV 端口
                            // 只讲明文 HTTP，端口填对也连不上，而失败信息（TLS 握手失败）
                            // 不会自己告诉用户「去打开那个开关」。
                            // 这是**提示**，不是自动降级——是否放行明文仍由用户自己决定。
                            rowHint("连不上时先看这里：不少 NAS 的 WebDAV 端口只提供明文 HTTP（浏览器里访问的是 http://）。那种情况下请打开这个开关；闪寻不会替你自动改用不加密的连接。")
                        }
                    }
                    // 失败之后的**一键重试**。上面的静态提示实测不够用：
                    // 切品牌会把协议开关清回新品牌的默认值（那是为修历史故障，
                    // 不能去掉），用户在飞牛上开过明文、再切到 WebDAV 时，
                    // 开关会被悄悄清成加密，于是「端口填对了却报 TLS 握手失败」。
                    // 与其让用户自己回头找那行提示，不如在失败现场给一个按钮。
                    if model.draftOffersPlainHTTPRetry {
                        FFPrimaryButton("改用明文 HTTP 重试", systemImage: "arrow.triangle.2.circlepath") {
                            model.retryDraftUsingPlainHTTP()
                        }
                        .accessibilityIdentifier("nas-retry-plain-http")
                    }
                    HStack(spacing: 10) {
                        labeledField("账号") {
                            TextField("nasuser", text: $model.draftSource.username)
                                .textFieldStyle(.roundedBorder)
                                .accessibilityIdentifier("nas-user")
                        }
                        labeledField("密码") {
                            VStack(alignment: .leading, spacing: 3) {
                                PlainSecureField(text: $model.nativeNASPassword, placeholder: "必填",
                                                accessibilityID: "nas-password")
                                    .frame(height: 22)
                                // 【不要在这里放依赖 nativeNASPassword 的条件视图。】
                                // 它会随每次按键增删子视图，导致 SwiftUI 重建整个 VStack、
                                // 销毁并重建 PlainSecureField——重建瞬间按钮可用性判断读到空值，
                                // 于是「填了密码却点不了连接」。
                                // 改成用 keychainHint（不随输入变化）做唯一条件。
                                if model.keychainHint != nil {
                                    Text(model.keychainHint!)
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    // OTP 默认收起：多数账号用不到，但开启两步验证时必须有入口，
                    // 否则用户只会看到一句「登录失败」。
                    DisclosureGroup("该账号需要动态口令？", isExpanded: $showOTP) {
                        PlainSecureField(text: $model.nativeNASOTP, placeholder: "OTP",
                                        accessibilityID: "nas-otp")
                            .frame(height: 22)
                            .padding(.top, 6)
                    }
                    .font(.callout)
                    if !model.draftSource.host.isEmpty, model.draftSource.hostName.isEmpty {
                        rowError("IP 格式不对，请填 IP 或主机名")
                    }
                    if model.draftSource.port != 0, !model.draftSource.hasPort {
                        rowError("端口需在 1～65535 之间")
                    }
                    // 端口是否缺失的提示统一放在「连接」按钮旁边
                    // （见 `connectDisabledReason`）：同一个问题只说一次，
                    // 而且要说在用户真正会去看的地方——按钮附近。
                    HStack(spacing: 8) {
                        // 关闭时立刻删掉已存的旧凭据，不能只改标记——
                        // 否则用户以为「不保存了」，密码其实还躺在文件里被自动使用。
                        Toggle("记住这台 NAS 的密码", isOn: Binding(
                            get: { model.draftSource.rememberPassword },
                            set: { model.setDraftRememberPassword($0) }))
                            .font(.callout)
                        Spacer()
                    }
                    if model.draftSource.rememberPassword {
                        // 落点必须如实写出来。以前这里写的是「保存到钥匙串」，
                        // 而钥匙串那套会因为每次重新构建而反复要求授权——
                        // 见 `CredentialStore` 的文档注释，那里有完整实测。
                        rowHint("密码存到本机凭据文件（~/Library/Application Support/FlashFind2/credentials.json，权限 600，磁盘上由 FileVault 加密）。闪寻不再向系统钥匙串索取，因此**不会再每次启动都弹授权框**。它的保护边界是：任何以你这个登录账户身份运行的进程都能读到——与你以前在钥匙串弹窗上点「允许」之后相当。")
                    } else {
                        rowHint("密码只用于本次会话，不写入本机文件。")
                    }
                    TextField("设备名称（可留空，默认用类型名）", text: $model.draftSource.name)
                        .textFieldStyle(.roundedBorder)
                    // 填了名字就告诉用户它会出现在哪里——
                    // 否则这个框既没人读也没人解释，很容易被当成垃圾输入框乱敲。
                    let named = model.draftSource.displayName
                    if named != model.draftSource.vendor.title {
                        rowHint("搜索结果里会标成「\(named)」，方便你区分多台 NAS。")
                    }
                }
            }
            // 按钮的可用性**只有一个来源**：`enabled:` 参数。
            //
            // 不要在视图外层再叠一个 `.disabled(...)`：组件内部本来就有一句
            // `.disabled(!enabled)`，两层判定会互相覆盖，谁说了算并不直观，
            // 表现就是「按钮看着能点却点不动」或「该灰的时候不灰」。
            // 判定统一在模型层（`AppModel.canConnectDraft`），这里只把结果传进去。
            FFPrimaryButton(model.draftBusy ? "正在连接…" : "连接",
                            systemImage: "bolt.horizontal.circle",
                            enabled: model.canConnectDraft) {
                model.connectDraft()
            }
            // 缺什么就说清楚，而且**一直说**。灰按钮不解释自己，
            // 是用户最容易理解成「程序坏了」的界面。
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

    /// 两列布局里的一个字段：左侧固定宽度的标签，右侧输入。
    private func labeledField<Content: View>(_ label: String,
                                             @ViewBuilder content: () -> Content) -> some View {
        HStack(spacing: 8) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 34, alignment: .leading)
            content()
        }
        .frame(maxWidth: .infinity)
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

    // MARK: Step 4 搜索位置

    @ViewBuilder private var sharesSection: some View {
        if model.draftConnected {
            // 管理员账号的代价必须说清楚，而不是让用户事后才发现搜到了别的东西。
            if model.draftUsesAdminAccount {
                FFErrorBanner(message: model.adminAccountWarning)
            }
            FFSettingsSection(title: "选择搜索位置", footer: model.draftSource.scopes.isEmpty ? "可以勾选多个。搜索会一次覆盖所有选中的目录。" : "已选 \(model.draftSource.scopes.count) 个目录") {
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
                                    Text(String(share.dropFirst())).font(.callout)
                                    Text(share).font(.caption).foregroundStyle(.secondary)
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

    private var statusSection: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: model.draftStatus.contains("失败") || model.draftStatus.contains("找不到") ? "exclamationmark.circle" : "info.circle")
                .foregroundStyle(.secondary)
            Text(model.draftStatus).font(.callout).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(Color(nsColor: .quaternaryLabelColor).opacity(0.3)))
    }

    private var footer: some View {
        VStack(spacing: 6) {
            HStack {
                if model.draftConnected {
                    FFSecondaryButton("断开", action: model.disconnectDraft)
                }
                Spacer()
                // 「取消」必须真的取消：关闭窗口的同时收掉这次连接留下的一切
                // （后台任务、暂存密码、待确认证书、已建立的 DSM 会话）。
                FFSecondaryButton("取消") {
                    model.cancelDraft()
                    NASWizardWindow.shared.close()
                }
                // 可用性同样只走 `enabled:`，不再在外层叠 `.disabled`——
                // 已连接但还没选搜索位置时不能保存，否则会存下一台
                // 「连得上却搜不了」的 NAS，用户以为加好了，实际搜不到。
                FFPrimaryButton(primaryActionTitle,
                                enabled: !(model.draftBusy || (model.draftConnected && model.draftSource.scopes.isEmpty)),
                                action: {
                    model.commitDraft(); NASWizardWindow.shared.close()
                })
            }
            if !isEditing, primaryActionTitle == "仅保存" {
                Text("还没连上或还没选搜索位置。现在保存只会记下地址与账号，之后还要回来点「连接」并勾选目录。")
                    .font(.caption).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    /// 底部主按钮的文案。
    ///
    /// 「完成」与「仅保存」是两件不同的事，不该共用一个词：
    /// 前者表示「这台 NAS 已经能用了」，后者只是「先把配置记下来」。
    private var primaryActionTitle: String {
        if isEditing { return "保存" }
        return model.draftConnected && !model.draftSource.scopes.isEmpty ? "完成" : "仅保存"
    }
}
