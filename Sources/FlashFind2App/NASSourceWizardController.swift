import AppKit
import FlashFindCore

/// 管理 NAS 来源向导的草稿、连接与保存；状态变更由 AppModel 桥接到界面。
@MainActor
final class NASSourceWizardController: ObservableObject {

    /// 来源配置的持久化依赖必须在构造时注入。
    private let preferences: any ClientPreferences

    init(preferences: any ClientPreferences) {
        self.preferences = preferences
    }

    // MARK: - 来源清单与 Provider（界面也在读，AppModel 转发）

    @Published var nasSources: [NASSourceConfig] = []
    @Published var nasSourceStatus: [String: NASSourceStatus] = [:]
    @Published var nativeProviders: [String: NASSearchProvider] = [:]
    @Published var selectedSourceID: String?

    // MARK: - 向导这一次会话的状态

    /// 密码框与 OTP 框。连接成功后由成功路径清空（见 `finishLogin`），
    /// **不在点「连接」时清**——那时清会落到模型却落不到框里，失败后无法一键重试。
    @Published var nativeNASPassword = ""
    @Published var nativeNASOTP = ""
    /// 与重新登录共用动态码弹窗；failure 区分首次输入与被拒重试。
    var otpPrompter: ((String, OTPFailure?) -> String?)?
    /// 上一次因「设备要动态码」而失败的状态文本。弹窗被取消时补提示要用：
    /// 取消之后界面上只剩这一行，它必须仍然说清刚才到底怎么了。
    private var otpFailureStatus = ""

    /// 一次性浏览器授权码只用于当前连接，不写入来源配置。
    @Published var draftAuthorizeCode = ""
    /// 浏览器授权后用于将焦点移回授权码输入框。
    @Published var draftAwaitingAuthorizeCode = false
    /// 添加/编辑向导的草稿。只有点「保存」才写入正式配置。
    @Published var draftSource = NASSourceConfig()
    @Published var draftStatus = ""
    /// 明文重试仅由用户主动确认，不能自动降级。
    @Published var draftOffersPlainHTTPRetry = false
    @Published var draftBusy = false
    /// 等待上轮取消的范围回滚完成，期间不可编辑或保存。
    @Published private(set) var draftSettling = false
    @Published var draftAvailableShares: [String] = []
    @Published var draftConnected = false
    /// 向导状态提示的唯一出口。UI 不直接写这个字段，避免和连接流程抢状态。
    func setDraftStatus(_ message: String) { draftStatus = message }
    @Published var nasTrustCandidate: NASTrustCandidate?

    /// 凭据仅在握手期间暂存于内存，所有终态都要清理。
    private var pendingCredential: PendingCredential?
    /// 等待上一轮草稿收尾，避免新草稿复制即将回滚的范围。
    private var draftTeardownTask: Task<Void, Never>?
    private var draftSession: DraftSession = .none

    /// 防止等待期间失效的旧草稿回调覆盖当前状态。
    private var draftGeneration = 0

    /// 地址或账号变更后不能向新目标发送旧凭据。
    private var draftOriginalEndpoint: (host: String, username: String)?

    /// 仅允许最新连接尝试写入状态，并阻止双击并发连接。
    private let attemptGate = ConnectionAttemptGate()
    /// 来源配置的落盘 key。AppModel 载入配置时也用它，避免两处各写一份字面量。
    static let sourcesStorageKey = "ff2.nasSources.v1"

    /// 连接握手中暂存的凭据（只存在于内存，任何终态后立即销毁）。
    struct PendingCredential {
        let password: String
        let otp: String?
        /// 飞牛两段授权的第二段：用户从浏览器授权页抄回来的一次性码。
        /// 只在「重新带着 code 连接」时非空。
        var authorizeCode: String? = nil
    }

    // MARK: - 宿主注入的入口

    /// 核心进程桥接层。
    var makeBridge: () -> (any MyNASBridgeTransport)? = { nil }
    /// 挂载服务（打开结果时要用）。
    var resolveMountService: () -> SMBMountService = { SMBMountService() }
    /// 单次搜索的超时预算（秒）。
    var queryBudgetSeconds: () -> Int = { 60 }
    /// 确保 Provider 协调器已建好。
    var ensureCoordinator: () -> Void = {}
    /// 按当前配置重建 Provider 字典。
    var rebuildProviders: () -> Void = {}
    /// 作废当前结果（原 `invalidate()`）。
    var onInvalidate: () -> Void = {}
    /// 重新发起搜索（原 `changedQuery()`）。
    var onSearch: () -> Void = {}
    /// 给 Provider 装自动重连。
    var attachAutoReconnect: (NASSearchProvider) -> Void = { _ in }
    /// 清掉核心里某个 sourceID 的旧会话（否则回 SourceExists）。
    var resetCore: (String) async -> Void = { _ in }
    /// 保存来源后开启 NAS 搜索，使已连接来源参与搜索。
    var ensureNASSearchEnabled: () -> Void = {}
    /// 与 AppModel 共用连接意图，用户断开时令在途连接失效。
    var connectIntent = SourceConnectIntent()
    /// 由连接管理器持有已登录的 Provider。
    var installProvider: (NASSearchProvider) -> Void = { _ in }

    // MARK: - 承接注入的同名入口
    //
    // 下面这些只是把闭包包成与原代码同名的成员，
    // 这样搬过来的函数体**一个字都不用改**——改动面越小，走样的机会越少。

    private var sharedBridge: (any MyNASBridgeTransport)? { makeBridge() }
    private var mountService: SMBMountService { resolveMountService() }
    private var nativeSearchTimeoutSeconds: Int { queryBudgetSeconds() }
    private func ensureProviderCoordinator() { ensureCoordinator() }
    private func rebuildNativeProviders() { rebuildProviders() }
    /// 下面两个包装与原来的 `invalidate()` / `changedQuery()` 一一对应，
    /// 这样搬过来的函数体（有的调一个、有的调两个）一个字都不用改。
    private func invalidate() { onInvalidate() }
    private func changedQuery() { onSearch() }

    // MARK: - 以下为从 AppModel 逐字搬来的向导流程

    func addSource() {
        // 切换来源 = 离开上一个目标。密码框里可能还留着上一个来源的输入，
        // 不清掉的话，用户切走再切回来会发现密码还在——同一个密码框
        // 在不同来源之间「串味」，既不安全也让人以为程序记错了。
        endDraftInput()
        var draft = NASSourceConfig()
        draft.name = ""
        draftSource = draft; selectedSourceID = nil
        nasTrustCandidate = nil; draftAvailableShares = []; draftStatus = ""; draftConnected = false
        draftOriginalEndpoint = nil
        otpFailureStatus = ""
    }

    func editSource(_ id: String) {
        guard let source = nasSources.first(where: { $0.id == id }) else { return }
        // 同上：进入另一个来源前先清空输入框与在飞的连接尝试。
        endDraftInput()
        draftSource = source; selectedSourceID = id
        // 记下「进来时」的身份。之后用户改地址/账号，就说明钥匙串里的旧密码
        // 已经不属于这个目标了，不能再自动沿用（按当前地址与账号校验）。
        draftOriginalEndpoint = (source.hostName, source.username)
        nasTrustCandidate = nil
        draftAvailableShares = nativeProviders[id]?.availableShares ?? []
        draftStatus = ""; draftConnected = nativeProviders[id]?.ready ?? false
        draftUsesAdminAccount = nativeProviders[id]?.isManagerAccount ?? false
        otpFailureStatus = ""
        // ★ 借来之后不复制、不重建、不重新登录 —— 会话就是用户正在用的那一个，
        //   勾选直接作用在它身上。所有权记成 `.borrowed`，所以取消/返回都不会断开它。
        if let live = nativeProviders[id], live.ready {
            if live.hasPendingTeardown {
                // ★ 认领本轮代次：**在等待之前**就把它拿在手里。
                let generation = draftGeneration
                draftSettling = true
                draftStatus = "正在读取这台 NAS 的当前搜索位置…"
                Task { [weak self] in
                    await live.drainTeardown()
                    self?.adoptLiveSession(live, sourceID: id, generation: generation)
                }
            } else {
                adoptLiveSession(live, sourceID: id, generation: draftGeneration)
            }
        }
        if !draftConnected, source.rememberPassword {
            draftStatus = "点「连接」后使用已保存的密码，需要时系统会请求钥匙串授权"
        }
    }

    /// 等收尾完成后借用活会话，并用同一实例更新可选和已选范围。
    private func adoptLiveSession(_ live: NASSearchProvider, sourceID: String, generation: Int) {
        // ★ 忙碌只能由**自己这一轮**解除。
        //
        // 等待期间用户可能已经取消 / 切走并开始了新的一轮，那时「忙碌」属于新的
        // 那一轮（或已经由 `cancelDraft` 收掉）。旧回调顺手把标记清掉，
        // 等于让新的一轮在还没就绪时就被当成已就绪。
        defer {
            if draftGeneration == generation { draftSettling = false }
        }
        // ★ 三个条件缺一不可：
        //   · 代次：这一轮草稿还作数（没被取消 / 重开 / 切走）；
        //   · 身份：界面当前编辑的仍是同一台来源，且管理器里的实例没被换掉；
        //   · `live.ready`：**在 await 之后**复核 —— 等收尾这段时间里它可能已经掉线，
        //     拿一个已断开的实例把草稿标成「已连接」，用户看到的是假状态。
        guard draftGeneration == generation,
              selectedSourceID == sourceID,
              nativeProviders[sourceID] === live,
              live.ready else { return }
        draftSession = .borrowed(live)
        // 界面上「可选位置」与「已选位置」必须来自同一个实例：
        // 状态字典可能是上一次会话留下的，实例是活的，优先信实例。
        if !live.availableShares.isEmpty { draftAvailableShares = live.availableShares }
        draftSource.scopes = live.config.scopes
        draftConnected = true
    }

    /// 保存草稿；已有登录会话时可跳过重建 Provider。
    @discardableResult
    func saveDraft(rebuildProviders: Bool = true) -> Bool {
        // 必填项**必须在这里判掉**：`commitDraft` 要先把范围绑定等出结果才落盘，
        // 等到网络往返结束再说「请填写 NAS 地址」，用户已经白等了一轮。
        if let message = draftValidationMessage() { draftStatus = message; return false }
        var draft = draftSource
        draft.normalizeHost()
        // 这里**不再**因品牌而拒绝保存。
        // 之前的 `guard vendor.nativelySupported` 会让「其他 NAS」连存都存不下去，
        // 用户明确反馈「没必要卡这么死」。品牌只影响能不能真的连上，
        // 不该影响「允许用户先把配置留着」这件事。
        if let index = nasSources.firstIndex(where: { $0.id == draft.id }) {
            let previous = nasSources[index]
            // 服务器或账号变了，旧的证书确认与共享范围都不再适用。
            if previous.hostName != draft.hostName || previous.username != draft.username {
                draft.certificateSHA256 = ""; draft.allowExpiredCertificate = false; draft.scopes = []
                // **必须删掉旧凭据**：来源 ID 不变，钥匙串里的 key 也就不变。
                // 不删的话，以后点「用已保存的密码连接」会把 A 机器的密码发给 B 机器。
                // 清理之后需要重新认证——宁可多一步，也不能把密码发去错误的目标。
                if !AppEnvironment.isPreview {
                    SecureStorage.delete(account: previous.credentialAccount, reason: "地址或账号已改动，旧密码不再适用")
                }
                identityChangedForCredentialReset = true
            }
            nasSources[index] = draft
        } else {
            nasSources.append(draft)
        }
        selectedSourceID = draft.id
        draftSource = draft
        persistSources()
        ensureProviderCoordinator()
        if rebuildProviders { rebuildNativeProviders() }
        draftStatus = identityChangedForCredentialReset
            ? "已保存 \(draft.displayName)。服务器或账号变了，请重新输入密码连接。"
            : "已保存 \(draft.displayName)"
        identityChangedForCredentialReset = false
        return true
    }
    /// 使用 Core 校验品牌对应的必填项。
    private func draftValidationMessage() -> String? {
        draftSource.saveBlockingReason
    }

    /// 本次保存是否因为身份变更而清掉了钥匙串凭据（用于给出准确提示）。
    private var identityChangedForCredentialReset = false

    /// 当前草稿用的是管理员账号。管理员能看到这台 NAS 的全部共享，
    /// 搜索范围因此不再受「被授予哪些目录」限制——必须让用户知道这件事。
    @Published private(set) var draftUsesAdminAccount = false

    /// 管理员账号的风险说明（UI 直接展示，不要自己组织措辞）。
    var adminAccountWarning: String {
        "你正在用管理员账号搜索。管理员能看到这台 NAS 上的全部共享，因此闪寻能搜到的范围不受「你被授予了哪些目录」限制。如果这台机器上有你不希望被搜到的内容，请改用一个只授权了目标目录的普通账号。"
    }

    /// 编辑时地址或账号变更后不能继续使用原凭据。
    var draftIdentityChanged: Bool {
        guard let original = draftOriginalEndpoint else { return false }
        return original.host != draftSource.hostName || original.username != draftSource.username
    }

    /// 尚未解锁也允许尝试保存过的密码；地址或账号变化后必须重新输入。
    private var canRequestStoredPasswordForDraft: Bool {
        draftSource.rememberPassword && !draftIdentityChanged
    }

    /// 「连接」按钮是否可用。判定放在模型层，避免被视图重建牵着走。
    ///
    /// 端口用 `hasEffectivePort`：用户把 `192.0.2.96:5001` 写进地址栏时
    /// 端口字段是空的，只看字段会让按钮永远点不亮。
    var canConnectDraft: Bool {
        ConnectButtonState.canConnect(busy: draftBusy,
                                      host: draftSource.hostName,
                                      hasPort: draftSource.hasEffectivePort,
                                      username: draftSource.username,
                                      hasTypedPassword: !nativeNASPassword.isEmpty,
                                      hasStoredPassword: canRequestStoredPasswordForDraft,
                                      requiresCredential: draftSource.vendor.requiresAccountPassword)
    }

    /// 按钮不可用时说明缺什么。灰按钮不解释自己最容易被当成程序坏了。
    var connectDisabledReason: String? {
        ConnectButtonState.disabledReason(busy: draftBusy,
                                          host: draftSource.hostName,
                                          hasPort: draftSource.hasEffectivePort,
                                          username: draftSource.username,
                                          hasTypedPassword: !nativeNASPassword.isEmpty,
                                          hasStoredPassword: canRequestStoredPasswordForDraft,
                                          requiresCredential: draftSource.vendor.requiresAccountPassword)
    }

    /// 地址或账号改动过 → 旧的钥匙串密码不能用，按钮旁要说清楚原因。
    var draftCredentialResetHint: String? {
        draftIdentityChanged ? "地址或账号已改动，需要重新输入密码（旧密码属于原来的地址，不能拿过来用）。" : nil
    }

    func removeSource(_ id: String) {
        guard let index = nasSources.firstIndex(where: { $0.id == id }) else { return }
        let removed = nasSources.remove(at: index)
        nasSourceStatus.removeValue(forKey: id)
        if let provider = nativeProviders[id] { Task { await provider.disconnect() } }
        nativeProviders.removeValue(forKey: id)
        if selectedSourceID == id { selectedSourceID = nasSources.first?.id }
        // **无条件**清理钥匙串条目，不能看 `removed.rememberPassword`。
        // 用户可能先勾了「保存密码」、后来取消勾选——那时 flag 已是 false，
        // 但历史密码还躺在钥匙串里，跟着这个来源 ID 一起变成无人认领的孤儿。
        // 删除不存在的条目会返回 errSecItemNotFound，`SecureStorage.delete` 视作成功。
        if !AppEnvironment.isPreview {
            CredentialStore.removeSource(removed)
        }
        persistSources(); rebuildNativeProviders(); invalidate(); changedQuery()
    }

    /// 开关「把密码保存到钥匙串」。关闭时**立即**删除已存的凭据。
    ///
    /// 只改 flag 不删条目的话，用户以为「不保存了」，实际密码还在钥匙串里，
    /// 下次自动连接仍会用它——这是用户无法从界面上察觉的背离。
    func setDraftRememberPassword(_ value: Bool) {
        draftSource.rememberPassword = value
        guard !AppEnvironment.isPreview else { return }
        // 关掉就立刻删。「是否已经改过」不该参与判定——要求是布尔假值时本机没有这把密码。
        CredentialStore.applyRememberPassword(value, config: draftSource)
    }

    /// 端口输入框的回写（视图每次按键调用一次）。
    ///
    /// 端口字段绑定的是**字符串**而不是 `Int`：macOS 上 `TextField(value:format:)`
    /// 的写回要等失焦或回车，用户敲完端口看着有值、按钮却还是灰的。
    /// 改成每次按键即时解析，按钮状态就能实时跟上。
    func setDraftPort(_ text: String) {
        let value = PortField.parse(text) ?? 0
        if draftSource.port != value { draftSource.port = value }
    }

    /// 当前品牌是否允许填连接路径。只有 WebDAV（见 `Vendor.allowsBasePath`）。
    var draftAllowsBasePath: Bool { draftSource.vendor.allowsBasePath }

    /// 仅支持路径的品牌写入；空路径或单个斜杠表示站点根。
    func setDraftBasePath(_ text: String) {
        guard draftSource.vendor.allowsBasePath else { return }
        let parsed = BasePathField.parse(text)
        // 解析不出（空、纯 `/`）时置 nil = 走站点根，这是合法的用户意图。
        let value = parsed
        if draftSource.basePath != value { draftSource.basePath = value }
    }

    /// 切换品牌时取消旧连接，并恢复新品牌的默认协议。
    func setDraftVendor(_ vendor: NASSourceConfig.Vendor) {
        guard draftSource.vendor != vendor else { return }
        // 换类型等于放弃当前这次连接：已建立的会话、待确认的证书都属于原类型。
        cancelDraft()
        draftSource.adoptVendor(vendor)
    }

    /// 先切换品牌再预填地址和端口；连接由用户发起。
    func applyDiscoveredDevice(_ device: DiscoveredDevice) {
        if let vendor = device.vendorHint, draftSource.vendor != vendor {
            setDraftVendor(vendor)
        } else {
            // 品牌没变，但地址换了：上一次的连接尝试（会话、待确认的证书）
            // 都属于旧地址，必须一起收掉。
            cancelDraft()
        }
        draftSource.host = device.host
        draftSource.port = device.port
        draftSource.normalizeHost()
        // 设备名只在用户自己还没命名时填进去——不要覆盖他刚敲的名字。
        if draftSource.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           !device.name.isEmpty {
            draftSource.name = device.name
        }
        draftStatus = ""
    }

    /// 「使用明文 HTTP」的实际取值（模型层判定，视图只读）。
    var draftUsesPlainHTTP: Bool { draftSource.usesPlainHTTP }
    /// 当前品牌是否允许用户选协议。群晖不给选（见 `Vendor.allowsPlainHTTPChoice`）。
    var draftAllowsPlainHTTPChoice: Bool { draftSource.vendor.allowsPlainHTTPChoice }

    /// 只允许支持协议选择的品牌使用明文 HTTP。
    func setDraftPlainHTTP(_ value: Bool) {
        // 兜底：群晖走证书固定，明文过不了核心的 `UnsafeEndpoint` 校验。
        // 视图本就不给群晖显示这个开关，这里防的是「配置里残留了显式值」
        // 这种界面看不出来的状态——它会让连接以 UnsafeEndpoint 失败。
        guard draftSource.vendor.allowsPlainHTTPChoice else { return }
        draftSource.usePlainHTTP = value
    }

    func setSourceEnabled(_ id: String, _ value: Bool) {
        guard let index = nasSources.firstIndex(where: { $0.id == id }) else { return }
        nasSources[index].enabled = value
        // 逐来源打开而总开关关着时，用户看到的是「开了却搜不到」，与 R01 同一种困惑。
        if value { ensureNASSearchEnabled() }
        persistSources(); rebuildNativeProviders(); invalidate(); changedQuery()
    }

    func persistSources() {
        guard !AppEnvironment.isPreview, let data = try? JSONEncoder().encode(nasSources) else { return }
        preferences.set(data, forKey: Self.sourcesStorageKey)
    }

    /// 名称仅供展示；不重建 Provider 或重新搜索，以保留现有连接和结果。
    func renameSource(_ id: String, to rawName: String) {
        guard let index = nasSources.firstIndex(where: { $0.id == id }) else { return }
        guard NASSourceRename.isRename(stored: nasSources[index].name, to: rawName) else { return }
        let name = NASSourceRename.normalized(rawName)
        nasSources[index].name = name
        persistSources()
        // 结果行的来源徽标读 `provider.source`，它是构造时的快照，必须一起换。
        nativeProviders[id]?.updateDisplayName(name)
    }

    func setSourceStatus(_ id: String, _ mutate: (inout NASSourceStatus) -> Void) {
        var status = nasSourceStatus[id] ?? NASSourceStatus()
        mutate(&status)
        nasSourceStatus[id] = status
    }

    struct NASTrustCandidate: Identifiable {
        let candidateID: String
        let sha256: String
        let host: String
        let port: Int
        let expired: Bool
        var id: String { candidateID }
        /// 指纹按 2 字节一组显示，便于用户肉眼比对设备背面或管理页。
        var displayFingerprint: String {
            stride(from: 0, to: sha256.count, by: 2).compactMap { index -> String? in
                let start = sha256.index(sha256.startIndex, offsetBy: index)
                let end = sha256.index(start, offsetBy: min(2, sha256.distance(from: start, to: sha256.endIndex)))
                return String(sha256[start..<end]).uppercased()
            }.joined(separator: ":")
        }
    }
    // MARK: - 向导连接流程：探测端口 → 确认证书 → 登录 → 选共享

    /// 释放待提交会话的引用；断开由调用方负责。
    func discardPendingProvider() { draftSession = .none }

    func connectDraft() {
        ensureProviderCoordinator()
        // busy 时**不要静默 return**：静默就是用户口中的「点了没反应」。
        // 按钮此时通常已变灰，但万一状态没同步到界面，也要给人一句解释。
        guard !draftBusy else {
            draftStatus = "上一次连接还在进行中，请稍候……"
            return
        }
        // 收养还没落定时不许发起新连接：那会与「上一轮回滚」抢同一台来源的范围。
        guard !draftSettling else {
            draftStatus = "正在读取这台 NAS 的当前搜索位置，请稍候……"
            return
        }
        var config = draftSource
        config.normalizeHost()
        // 新的一次连接开始：上一轮「等用户粘码」的焦点请求到此为止。
        draftAwaitingAuthorizeCode = false
        // 端口一律用「有效端口」判定：地址里写了 `192.0.2.96:5001` 也算数。
        // 之前这里用的是只看端口字段的 `hasPort`，而按钮用的是 `hasEffectivePort`，
        // 两处判定不一致 → 按钮是亮的、点下去却被这里拦下并 return，
        // 用户看到的现象就是「连接按钮点不了」。
        guard !config.hostName.isEmpty else { draftStatus = "请填写 NAS 地址"; return }
        guard config.hasEffectivePort else {
            draftStatus = "请填写端口，或把端口直接写在地址里（如 192.0.2.96:5001）"
            return
        }
        // 账号只有「账号密码」这一档才必填。飞牛（fnOS）没有账号密码登录，
        // 拦在这里等于让一个本来能连的品牌永远连不上，而且提示还在教用户填一串用不上的东西。
        if config.vendor.requiresAccountPassword,
           config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            draftStatus = "请填写 NAS 账号"
            return
        }
        draftSource = config
        // 允许已接入但未验证的品牌连接；没有适配器时说明原因。
        guard config.vendor.hasAdapter else {
            draftStatus = config.vendor.supportMessage
            return
        }
        // 地址或账号变化后不使用旧凭据；密码与动态码由 NASCredentialPick 统一选择。
        let storedPassword: String? = (nativeNASPassword.isEmpty && config.rememberPassword && !draftIdentityChanged)
            ? SecureStorage.read(account: config.credentialAccount,
                                 identity: config.credentialIdentity, allowInteraction: true)
            : nil
        // 浏览器授权使用续期令牌，不走账号密码校验。
        let credential: PendingCredential
        if config.vendor.requiresAccountPassword {
            guard let picked = NASCredentialPick.pick(typedPassword: nativeNASPassword,
                                                      storedPassword: storedPassword,
                                                      otp: nativeNASOTP) else {
                draftStatus = draftIdentityChanged ? "地址或账号已改动，请重新输入密码"
                    : (CredentialStore.currentProblem?.summary ?? "请输入密码")
                return
            }
            credential = PendingCredential(password: picked.password, otp: picked.otp)
        } else {
            // 无续期令牌时请求浏览器授权；空授权码转为 nil。
            credential = PendingCredential(password: storedPassword ?? "", otp: nil,
                                           authorizeCode: AuthorizeCodeField.optional(draftAuthorizeCode))
        }
        // 失败时保留输入供重试，握手期间暂存凭据供确认证书后使用。
        pendingCredential = credential
        // 同步占位，防止双击启动并发连接。
        let attempt = beginAttempt()
        Task { await performConnect(config: config, credential: credential, attempt: attempt) }
    }

    /// 开始一次新的连接尝试：占位（防重复点击）并让之前所有在飞的尝试失效。
    @discardableResult
    private func beginAttempt() -> Int {
        // 序号由 ConnectionAttemptGate 发（可测）；「只有最新那次能写状态」
        // 这条语义在那里锁着，这里只负责连带的状态复位。
        let attempt = attemptGate.next()
        draftBusy = true
        // 新的一次尝试开始，上一次的失败提示立刻失效（否则按钮会指着一次早已过去的失败）。
        draftOffersPlainHTTPRetry = false
        // 看门狗只解除当前仍在进行的尝试，避免异常时按钮永久锁定。
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 90_000_000_000)   // 90 秒
            guard let self, self.isCurrentAttempt(attempt), self.draftBusy else { return }
            self.draftBusy = false
            self.clearPendingCredential()
            self.draftStatus = "连接超时。请检查地址、端口与网络，然后重试。"
        }
        return attempt
    }

    /// 只有最新那次尝试才允许写连接状态。取消、重连、改配置都会让旧尝试失效。
    private func isCurrentAttempt(_ attempt: Int) -> Bool { attemptGate.isCurrent(attempt) }

    /// 本次连接尝试的连接意图凭证（`performConnect` / `confirmDraftTrust` 里登记）。
    private var connectToken: SourceConnectIntent.Token?

    /// 过期尝试或被用户断开的来源不得安装 Provider 或回写状态。
    /// 草稿会在连接中自动更新，故此处只核对尝试与连接意图代次。
    private func attemptStillValid(_ attempt: Int) -> Bool {
        guard isCurrentAttempt(attempt) else { return false }
        guard let token = connectToken else { return true }
        return connectIntent.isCurrent(token)
    }

    /// 登记一轮连接意图并返回凭证。
    @discardableResult
    private func beginConnectIntent(_ config: NASSourceConfig) -> SourceConnectIntent.Token {
        let token = connectIntent.begin(config)
        connectToken = token
        return token
    }

    /// 所有连接路径统一装配超时、挂载服务和自动重连。
    private func makeProvider(_ bridge: any MyNASBridgeTransport,
                              config: NASSourceConfig, port: Int) -> NASSearchProvider {
        let provider = NASSearchProvider(bridge: bridge, config: config, port: port)
        provider.queryBudgetMs = max(1, min(120, nativeSearchTimeoutSeconds)) * 1000
        provider.mountService = mountService
        attachAutoReconnect(provider)
        return provider
    }

    /// 一次连接尝试的完整生命周期：discover →（可能确认证书）→ 登录 → 列共享。
    ///
    /// `credential` 一路显式传递，不从 `nativeNASOTP` 之类会被清空的输入框重新读取——
    /// 那是 OTP 之前完全不生效的原因。
    private func performConnect(config: NASSourceConfig, credential: PendingCredential, attempt: Int) async {
        guard let sharedBridge else {
            if isCurrentAttempt(attempt) {
                draftBusy = false
                draftStatus = "应用缺少搜索资源"
            }
            clearPendingCredential()
            return
        }
        // 入口已经被更新的一次尝试取代（用户双击、取消、改了配置）→ 直接放弃。
        guard isCurrentAttempt(attempt) else { clearPendingCredential(); return }
        // ★ 登记本轮连接意图。之后每一个 `await` 之后都要复核：
        // 用户可能在其他地方点了这台 NAS 的「断开」。
        beginConnectIntent(config)
        draftBusy = true
        // 复位只用 `isCurrentAttempt`（不看连接意图）：意图过期只代表「这次连接作废」，
        // 不该把「连接中」按钮永久锁灰（那种状态下用户连重试都点不了）。
        defer { if isCurrentAttempt(attempt) { draftBusy = false } }
        draftStatus = "正在连接…"
        // 端口兜底：端口字段为空但地址里带了端口时，用地址里那个。
        var effective = config
        effective.port = effective.effectivePort
        draftSource = effective
        do {
            // 同一端点继续 PKCE 授权时不得重置或重新发现，否则 verifier 会丢失。
            let resumingAuthorization = credential.authorizeCode != nil
                && pendingAuthorizationEndpoint.map {
                    $0.host == effective.hostName && $0.port == effective.port
                } == true
            if !resumingAuthorization {
                // 同上：discover 之前先清掉同 sourceID 的旧来源，否则回 SourceExists。
                await resetCoreSource(effective.sourceID)
                // 旧挑战对应的会话已经被清掉，标记必须一起失效。
                pendingAuthorizationEndpoint = nil
                guard attemptStillValid(attempt) else { clearPendingCredential(); return }
            }
            let provider = makeProvider(sharedBridge, config: effective, port: effective.port)

            if !resumingAuthorization {
                let discovered = try await provider.discover()
                // 探测期间用户取消、点了断开、或发起了新一次连接 → 本次作废，
                // 不弹证书对话框、不覆盖状态，也不留着那份暂存凭据。
                guard attemptStillValid(attempt) else { clearPendingCredential(); return }
                if let candidate = discovered["candidate"] as? [String: Any],
                   let candidateID = candidate["candidateID"] as? String, let digest = candidate["sha256"] as? String {
                    nasTrustCandidate = NASTrustCandidate(candidateID: candidateID, sha256: digest,
                                                          host: effective.hostName, port: effective.port,
                                                          expired: candidate["expired"] as? Bool ?? false)
                    draftStatus = "请核对证书指纹，确认后再登录"
                    // 凭据留在 pendingCredential 里，等用户确认证书后继续。
                    // 不能在这里销毁——界面上的密码框此时是隐藏的，用户没法再输一次。
                    return
                }
            }
            await finishLogin(config: effective, provider: provider, credential: credential, attempt: attempt)
        } catch {
            guard attemptStillValid(attempt) else { clearPendingCredential(); return }
            draftSession = .none
            draftConnected = false
            let reason = ConnectionFailureText.describe(error, host: effective.hostName, port: effective.port)
            finishFailedAttempt(error: error, config: effective, prefix: "连接失败：", reason: reason)
        }
    }

    /// 一次失败的收尾：给出人话，并在值得试的时候亮出「改用明文 HTTP 重试」。
    ///
    /// 抽成一处是因为失败有三条出口（握手 / 登录 / 登录后读共享），
    /// 三处各写一遍必然会漏掉其中一处，被丢掉的往往正是原因。
    private func finishFailedAttempt(error: Error, config: NASSourceConfig,
                                     prefix: String, reason: String) {
        // 这次连接已经结束（不管哪种失败），核心里那条待换令牌的挑战不再可信：
        // 下一次必须完整走一遍 discover，不能凭旧标记跳过它。
        pendingAuthorizationEndpoint = nil
        let flash = error as? FlashFindError
        var apiCode: Int?
        var isCoreFailure = false
        if case let .coreFailure(_, _, code)? = flash { isCoreFailure = true; apiCode = code }
        // Core 判定动态码失败类型；被拒时弹窗需明确提示输入错误。
        let otp = ConnectionFailureText.otpFailure(error)
        let offer = PlainHTTPRetryOffer.shouldOffer(
            allowsPlainHTTPChoice: config.vendor.allowsPlainHTTPChoice,
            usesPlainHTTP: config.usesPlainHTTP,
            coreApiCode: apiCode,
            isCoreFailure: isCoreFailure) && pendingCredential != nil && otp == nil
        draftOffersPlainHTTPRetry = offer
        if let otp {
            // 状态行只留事实（「登录失败：设备要求两步验证码…」）：
            // 怎么填是弹窗的事，同一句话不该在两处各说一遍。
            otpFailureStatus = prefix + reason
            draftStatus = otpFailureStatus
            promptForOTPThenReconnect(sourceName: config.displayName, failure: otp)
        } else {
            draftStatus = offer ? PlainHTTPRetryOffer.message(reason: reason) : prefix + reason
        }
        // 要弹一键重试，就得留住那份凭据——此刻密码框已清空，用户没法再输一次。
        // 这与「确认证书」保留凭据是同一个理由。
        if !offer { clearPendingCredential() }
    }

    /// 在独立任务中弹出动态码对话框，避免阻塞连接收尾；复用连接流程校验凭据。
    private func promptForOTPThenReconnect(sourceName: String, failure: OTPFailure?) {
        Task { [weak self] in
            guard let self else { return }
            guard let code = self.otpPrompter?(sourceName, failure), !code.isEmpty else {
                // 用户点取消：界面上只剩状态行，得把「下次怎么再来」说清楚。
                self.draftStatus = self.otpFailureStatus + " " + ConnectionFailureText.otpRetryHint()
                return
            }
            self.nativeNASOTP = code
            self.connectDraft()
        }
    }

    /// 用户点了「改用明文 HTTP 重试」。
    ///
    /// 直接把协议改成明文并立刻重连：**不经过** `connectDraft`，
    /// 因为那条路要求密码框里有输入或存储里有密码，而此刻密码只存在于内存暂存里。
    func retryDraftUsingPlainHTTP() {
        guard !draftBusy else { return }
        guard draftSource.vendor.allowsPlainHTTPChoice else { return }
        guard let credential = pendingCredential else {
            draftOffersPlainHTTPRetry = false
            draftStatus = "请重新输入密码后再试"
            return
        }
        draftOffersPlainHTTPRetry = false
        setDraftPlainHTTP(true)
        var config = draftSource
        config.usePlainHTTP = true
        config.normalizeHost()
        draftSource = config
        let attempt = beginAttempt()
        Task { await performConnect(config: config, credential: credential, attempt: attempt) }
    }

    /// 销毁暂存凭据。任何终态都必须调用，避免密码在内存里多留一刻。
    private func clearPendingCredential() { pendingCredential = nil }

    /// 同一端点保留 PKCE 会话；终态或端点变更时清除。
    private var pendingAuthorizationEndpoint: (host: String, port: Int)?

    /// 等待授权码不是连接失败。
    private enum LoginOutcome {
        case connected
        /// 浏览器已打开，表单里那一格在等用户粘码。界面不该显示任何失败文案。
        case awaitingAuthorizeCode
    }

    /// 授权码复用连接流程，保留证书确认与 PKCE 会话。
    func requestDraftAuthorizeCode() {
        guard AuthorizeCodeField.isInline(for: draftSource.vendor) else { return }
        connectDraft()
    }

    /// 浏览器授权后等待用户在表单粘贴一次性授权码，再继续登录。
    private func loginHandlingAuthorization(config: NASSourceConfig,
                                            provider: NASSearchProvider,
                                            credential: PendingCredential,
                                            attempt: Int) async throws -> LoginOutcome {
        try Task.checkCancellation()
        do {
            try await provider.login(account: config.username,
                                     password: credential.password,
                                     otp: credential.otp,
                                     authorizeCode: credential.authorizeCode)
            return .connected
        } catch FlashFindError.authorizationRequired(let url, let validFor, let rejected, _) {
            // 这次尝试已被取消/取代：浏览器都不该开，用户已经不在这个流程里了。
            guard attemptStillValid(attempt) else { return .awaitingAuthorizeCode }
            // 上一串码（被拒的、或刚用过的）不能留在框里：下次点「连接」还会拿它
            // 去撞同一个拒绝，而用户以为自己刚粘的是新的。
            draftAuthorizeCode = ""
            // 先聚焦再开浏览器：`NSWorkspace.open` 会把前台交给浏览器，
            // 焦点状态是给用户切回来那一刻用的。
            draftAwaitingAuthorizeCode = true
            // 记下这次挑战对应的端点：核心那个会话里现在存着 PKCE verifier，
            // 下一轮带码连接必须复用它（见 `performConnect` 的 resumed 分支）。
            pendingAuthorizationEndpoint = (config.hostName, config.port)
            draftStatus = ConnectionFailureText.authorizeInlinePrompt(
                sourceName: config.displayName, rejected: rejected, validFor: validFor)
            // 打开浏览器只能在这里做：Core 不依赖 AppKit。返回值不看 ——
            // 开不出来（没有默认浏览器）时，「获取授权码」按钮就在旁边，用户点它即可。
            NSWorkspace.shared.open(url)
            return .awaitingAuthorizeCode
        }
    }

    /// 登录 → 列共享 → 绑定搜索位置。
    ///
    /// 「确认证书」与「连接」两条路径都汇到这里，因此共用**同一个** Provider 实例。
    /// 这点很关键：sourceID 由 config 派生，新建实例若拿到不同 sourceID，
    /// 刚确认的 pin 就对不上，用户会看到「信任完又弹回请核对证书」。
    private func finishLogin(config: NASSourceConfig, provider: NASSearchProvider,
                             credential: PendingCredential, attempt: Int) async {
        guard attemptStillValid(attempt) else { clearPendingCredential(); return }
        do {
            let outcome = try await loginHandlingAuthorization(config: config, provider: provider,
                                                               credential: credential, attempt: attempt)
            guard outcome == .connected else {
                // 等用户粘授权码。**这不是失败**：状态行已经写成「去粘码」，
                // 这里绝不能覆盖它，也不能把 draftConnected 之类置成任何终态。
                // 下一次点「连接」是全新一轮，会带上框里那串码。
                clearPendingCredential()
                return
            }
            // 登录成功：核心里那个会话已经带着令牌了，它不再是「待换令牌的挑战」。
            pendingAuthorizationEndpoint = nil
            // 登录请求已发出，本地这份凭据没有用途了。
            // 注意：这里只是不再需要它，并**不代表可以丢弃**——
            // 下面保存到本机凭据文件时还要用，所以用局部常量留住，而不是提前清空。
            clearPendingCredential()
            guard attemptStillValid(attempt) else { return }

            // 读取共享列表。**不能用 `try?`**：网络失败、API 错误、协议错误
            // 会全部被折叠成空数组，界面于是显示「这个账号看不到任何共享目录」——
            // 一个纯粹的误诊。用户会跑去 NAS 上翻权限，而真正的问题在连接层。
            let shares: [String]
            do {
                shares = try await provider.loadShares()
            } catch {
                guard attemptStillValid(attempt) else { return }
                draftSession = .none
                draftConnected = false
                finishFailedAttempt(error: error, config: config, prefix: "已登录，但读取共享目录失败：",
                                    reason: ConnectionFailureText.describe(error, host: config.hostName, port: config.port))
                return
            }
            guard attemptStillValid(attempt) else { return }
            draftAvailableShares = shares
            if shares.isEmpty {
                // 「确实一个共享都没有」与「没取到」是两回事，必须分开说。
                draftStatus = "已登录，但这个账号确实没有任何共享目录。请检查账号权限。"
                draftSession = .none
                draftConnected = false
                return
            }
            // 已保存的位置仍有效就沿用；只有一个共享时自动选它。
            // 多个共享必须让用户自己勾——不能替用户决定搜索范围。
            let wanted = config.scopes.filter { shares.contains($0) }
            var scopes: [String] = []
            if !wanted.isEmpty {
                _ = try await provider.selectScopes(wanted); scopes = wanted
            } else if shares.count == 1 {
                _ = try await provider.selectScopes([shares[0]]); scopes = [shares[0]]
            }
            guard attemptStillValid(attempt) else { return }
            var effective = config
            effective.scopes = scopes
            draftSource = effective
            draftSession = .wizard(provider)
            draftConnected = true
            // 连接已成立：输入态的密码在这里才清（暂存凭据里已有副本供后续握手）。
            // 清空动作放在成功路径而不是点连接时——见 connectDraft 里的说明。
            nativeNASPassword = ""
            nativeNASOTP = ""
            // 码已经换成令牌了，留在框里只会让用户以为下次还得用它。
            draftAuthorizeCode = ""
            draftAwaitingAuthorizeCode = false
            var credentialSaveFailed = false
            if effective.rememberPassword {
                // ★ 核心给了「下次登录所需的那串东西」时存它，而不是用户刚敲的密码。
                //
                // 飞牛（fnOS）没有密码，那串东西是 OAuth 换来的 refresh token；
                // 存空串的后果是「界面显示已记住、下次照样连不上」，用户无从判断。
                // 账密品牌 `sessionSecret` 恒为 nil，行为与以前完全一致。
                // 判定在 Core（`NASCredentialSave`），可单测。
                do {
                    guard let secret = NASCredentialSave.pick(sessionSecret: provider.sessionSecret,
                                                              typedPassword: credential.password) else {
                        throw FlashFindError.message("核心没有返回可保存的凭据")
                    }
                    try await Task.detached {
                        try SecureStorage.save(secret, account: effective.credentialAccount,
                                               identity: effective.credentialIdentity,
                                               reason: "连接成功后保存（向导）")
                    }.value
                    // 刚才这次连通用的是**新后端**里的密码，等于间接证明迁移成功，
                    // 于是这一条旧明文可以删了（见 CredentialStore.confirmCredentialVerified）。
                    CredentialStore.confirmCredentialVerified(effective.credentialAccount)
                } catch {
                    // 关键：**不许再用 `try?` 吞掉**。吞掉之后文件里没有这把密码，
                    // 而界面一路显示「已记住」，下一次重连又要求输密码——
                    // 用户看到的只有「它又忘了」，无从判断是没存上还是被清了。
                    credentialSaveFailed = true
                }
            }
            draftUsesAdminAccount = provider.isManagerAccount
            let connected = scopes.isEmpty
                ? "已连接，共 \(shares.count) 个可用位置，请勾选"
                : "已连接，搜索位置：\(scopes.joined(separator: "、"))"
            draftStatus = credentialSaveFailed
                ? connected + "。密码没能写进本机凭据文件，下次重连需要重新输入。"
                : connected
        } catch {
            draftSession = .none
            draftConnected = false
            finishFailedAttempt(error: error, config: config, prefix: "登录失败：",
                                reason: ConnectionFailureText.describe(error, host: config.hostName, port: config.port))
        }
    }

    /// 清理核心中同一 sourceID 的旧会话，避免重新连接时出现 SourceExists。
    private func resetCoreSource(_ sourceID: String) async {
        await resetCore(sourceID)
    }

    func confirmDraftTrust() {
        guard let candidate = nasTrustCandidate, let sharedBridge else { return }
        guard !draftBusy else { return }
        // 凭据从上一次连接握手里取：此时密码框已被隐藏，让用户重填是不可能的。
        // 只有确实没有暂存凭据（例如应用重启后）才要求重新输入。
        var credential = pendingCredential
        if credential == nil, !nativeNASPassword.isEmpty {
            credential = PendingCredential(password: nativeNASPassword,
                                          otp: nativeNASOTP.isEmpty ? nil : nativeNASOTP)
            nativeNASPassword = ""
            nativeNASOTP = ""
            pendingCredential = credential
        }
        guard let credential else {
            draftStatus = "请先重新填写密码，确认证书后需要立即登录"
            return
        }
        var config = draftSource
        config.port = candidate.port
        let attempt = beginAttempt()
        // 确认证书是一次新的连接尝试：登记新一轮连接意图。
        beginConnectIntent(config)
        draftStatus = "正在确认证书…"
        Task {
            defer { if isCurrentAttempt(attempt) { draftBusy = false } }
            // 核心里这个 sourceID 可能已存在（旧连接、失败的尝试、之前确认过但没走完）。
            // 先断开，否则 confirmTrust 自己就会回 SourceExists。
            await resetCoreSource(draftSource.sourceID)
            guard attemptStillValid(attempt) else { clearPendingCredential(); return }
            let provider = makeProvider(sharedBridge, config: config, port: candidate.port)
            do {
                _ = try await provider.confirmTrust(candidateID: candidate.candidateID,
                                                    sha256: candidate.sha256,
                                                    allowExpired: candidate.expired)
                guard attemptStillValid(attempt) else { clearPendingCredential(); return }
                config.certificateSHA256 = candidate.sha256
                config.allowExpiredCertificate = candidate.expired
                draftSource = config
                if let index = nasSources.firstIndex(where: { $0.id == config.id }) {
                    nasSources[index].certificateSHA256 = candidate.sha256
                    nasSources[index].allowExpiredCertificate = candidate.expired
                    persistSources()
                }
                nasTrustCandidate = nil
                draftStatus = "证书已确认，正在登录…"
                // 用**同一个** provider 继续，绝不新建——sourceID 必须与
                // 刚才确认证书时完全一致，否则 pin 对不上。
                await finishLogin(config: config, provider: provider, credential: credential, attempt: attempt)
            } catch {
                guard attemptStillValid(attempt) else { clearPendingCredential(); return }
                clearPendingCredential()
                draftStatus = "证书确认失败：" + ConnectionFailureText.describe(
                    error, host: candidate.host, port: candidate.port)
            }
        }
    }

    /// 拒绝当前证书候选。不会把证书写进任何存储。
    func rejectDraftTrust() {
        nasTrustCandidate = nil
        clearPendingCredential()
        draftStatus = "已取消，请确认此 NAS 的地址后再试"
    }

    /// 预览包用 FF_UI_WIZARD 和 FF_UI_WIZARD_SHARES 构造位置选择，不连接设备。
    func loadPreviewWizardDraftIfRequested() {
        guard AppEnvironment.isPreview,
              ProcessInfo.processInfo.environment["FF_UI_WIZARD"] == "1" else { return }
        let raw = ProcessInfo.processInfo.environment["FF_UI_WIZARD_SHARES"]
        let pool = ["/Android", "/Android TV", "/IOS", "/MacOS", "/Other",
                    "/Switch", "/UTM", "/Windows", "/工具", "/影音",
                    "/照片", "/文档", "/归档", "/共享", "/备份"]
        let shares: [String]
        if raw == "whole" {
            // 根下上千个目录的真实站点（适配器只给这一个位置）长什么样。
            shares = [NASScopeLabel.wholeRoot]
        } else {
            let count = raw.flatMap(Int.init).map { max(1, min($0, 30)) } ?? 9
            shares = Array(pool.prefix(count))
        }
        draftAvailableShares = shares
        // 默认全勾上：这样一眼就能看出「取消全选」是亮的、「全选」是灰的。
        draftSource.scopes = shares
        draftSource.scopes.sort()
        draftConnected = true
        draftStatus = "已连接，可以搜索了"
        previewDraftLoaded = true
    }

    /// 预览草稿是否已装载：只有 `loadPreviewWizardDraftIfRequested` 会置真，
    /// 正常启动恒为假。置真时勾选只改界面、不向任何设备发请求（预览包里没有会话）。
    private var previewDraftLoaded = false

    /// 仅预览包使用 FF_UI_SOURCES 构造来源，不连接设备或持久化。
    func loadPreviewSavedSourcesIfRequested() {
        guard AppEnvironment.isPreview, !previewSavedSourcesLoaded else { return }
        guard let raw = ProcessInfo.processInfo.environment["FF_UI_SOURCES"],
              let count = Int(raw), count > 0 else { return }
        previewSavedSourcesLoaded = true
        let shares = ["/Book", "/Photo", "/Video", "/Project", "/Music"]
        var made: [NASSourceConfig] = []
        for index in 0..<min(count, 8) {
            var source = NASSourceConfig(
                id: "preview-source-\(index)",
                name: index == 0 ? "客厅 NAS" : "",
                host: "192.0.2.\(10 + index)",
                port: 5001,
                username: "demo",
                scopes: shares)
            source.vendor = .synology
            source.enabled = true
            made.append(source)
        }
        nasSources = made
    }

    /// 与 `previewDraftLoaded` 同理：只有预览钩子会置真。
    private var previewSavedSourcesLoaded = false

    /// 勾选 / 取消一个搜索位置（多选：用户可以同时选中多个共享）。
    func toggleDraftScope(_ scope: String) {
        guard mayEditDraftScopes() else { return }
        var scopes = draftSource.scopes
        if scopes.contains(scope) { scopes.removeAll { $0 == scope } } else { scopes.append(scope) }
        scopes.sort()
        applyDraftScopes(scopes)
    }

    /// 全选：这一屏所有位置一次勾上。
    ///
    /// 和单点勾选走**同一条**提交管线（`applyDraftScopes`），
    /// 所以「连点被串行化」「过期响应丢弃」「界面先动、底层后到」这三条对它同样成立。
    /// 集合本身由 Core 的 `ScopeBulkSelection` 算，界面与控制器都不许自己拼。
    func selectAllDraftScopes() {
        guard mayEditDraftScopes() else { return }
        applyDraftScopes(ScopeBulkSelection.selectAll(available: draftAvailableShares))
    }

    /// 取消全选：一个都不勾。
    ///
    /// 只清界面上的选择，**不**断开登录（与单点取消的既有约定一致：
    /// 用户的意图多半是「换一批」而不是「注销这台 NAS」）。底层也不提交空数组。
    func clearAllDraftScopes() {
        guard mayEditDraftScopes() else { return }
        applyDraftScopes(ScopeBulkSelection.clearAll())
    }

    /// 三个范围选择入口共用准入；借来的活会话也允许编辑。
    private func mayEditDraftScopes() -> Bool {
        // ★ 判定依据是「草稿里有没有可操作的会话」，而**不是**「有没有本次新连的会话」。
        // 用「本次新连的会话非空」那种写法时，编辑一个已连接的来源永远进不来：
        // 界面写着「已连接，可以搜索了」，点勾选却被一句「请先完成连接」挡回去。
        // 借来的活会话同样能改范围（`DraftSession.canEditScopes`）。
        // 预览草稿没有真实会话，但要让截图里能按得动这两颗按钮。
        if previewDraftLoaded { return true }
        guard draftSession.canEditScopes else { draftStatus = "请先完成连接"; return false }
        // ★ 上一轮收尾还没落定时不许改范围：此刻草稿里的范围是一份马上会被
        //   回滚覆盖的快照，勾了也白勾。
        guard !draftSettling else { draftStatus = "正在读取这台 NAS 的当前搜索位置…"; return false }
        return true
    }

    /// 串行提交范围变更，并用序号丢弃过期响应。
    private func applyDraftScopes(_ scopes: [String]) {
        // 界面立刻反映用户刚点的这一下，不等底层往返。
        draftSource.scopes = scopes
        if previewDraftLoaded {
            draftStatus = scopes.isEmpty
                ? "还没选搜索位置。至少要勾一个目录才能保存。"
                : "已选择 \(scopes.count) 个搜索位置"
            return
        }
        scopeSelectionSequence += 1
        pendingScopeTarget = scopes
        // **串行化**：同一时刻只允许一个 selectScopes 在飞。
        // 用户快速连点多个共享时，并发请求的返回顺序不保证与点击顺序一致，
        // 会出现「界面显示 A+B、核心实际只绑了 A」这种看不见的不一致。
        // 飞着的那次会把最新的选择带回来补一次，最终状态一定是用户最后点的那个。
        guard !scopeRequestInFlight else { return }
        draftBusy = true
        Task { await drainScopeRequests() }
    }

    /// 值不值得给出「全选 / 取消全选」（位置只有一个时没有意义）。
    var offersBulkDraftScopeSelection: Bool {
        ScopeBulkSelection.isOffered(available: draftAvailableShares)
    }

    /// 「全选」此刻可不可点：已经全勾完了就没得选。
    var canSelectAllDraftScopes: Bool {
        ScopeBulkSelection.canSelectAll(available: draftAvailableShares,
                                        selected: draftSource.scopes)
    }

    /// 「取消全选」此刻可不可点：一个可用位置都没勾时没得取消。
    var canClearAllDraftScopes: Bool {
        ScopeBulkSelection.canClearAll(available: draftAvailableShares,
                                       selected: draftSource.scopes)
    }

    /// 搜索位置选择的请求序号，用于丢弃过期响应。
    private var scopeSelectionSequence = 0
    /// 是否已有一个 selectScopes 请求在飞。
    private var scopeRequestInFlight = false
    /// 用户最新想要的位置集合，等当前请求回来后再提交。
    private var pendingScopeTarget: [String]?

    /// 串行提交搜索位置变更，直到没有待提交的目标为止。
    private func drainScopeRequests() async {
        scopeRequestInFlight = true
        defer { scopeRequestInFlight = false; draftBusy = false }
        while let target = pendingScopeTarget {
            pendingScopeTarget = nil
            let request = scopeSelectionSequence
            // 全部取消勾选时**不要**断开登录。
            // 用户的意图多半是「换一个共享」，而不是「注销这台 NAS」；
            // 之前这里直接 disconnect + draftConnected = false，用户被迫重新登录一次。
            // 底层也不提交空数组（核心会回 ScopeDenied），只清空界面上的选择，
            // 等用户再勾选时带着新集合一次提交。
            if target.isEmpty {
                guard request == scopeSelectionSequence else { continue }
                draftStatus = "还没选搜索位置。至少要勾一个目录才能保存。"
                continue
            }
            do {
                if try await draftSession.provider?.selectScopes(target) == true {
                    guard request == scopeSelectionSequence else { continue }
                    draftStatus = target.count == 1
                        ? "搜索位置：\(target[0])"
                        : "已选择 \(target.count) 个搜索位置"
                } else if request == scopeSelectionSequence {
                    draftStatus = "所选位置未通过共享准入校验"
                }
            } catch {
                if request == scopeSelectionSequence {
                    draftStatus = "无法使用所选位置：" + OpenFailureText.describe(error)
                }
            }
        }
    }

    /// 绑定成功后保存；调用方必须根据返回值决定是否关闭向导。
    @discardableResult
    func commitDraft() async -> Bool {
        // 上一轮收尾还没落定时不许保存：此刻草稿里的范围还不一定是活会话真在用的那份。
        guard !draftSettling else {
            draftStatus = "正在读取这台 NAS 的当前搜索位置，请稍候再保存"
            return false
        }
        // ★ 入口与「保存」按钮同一把锁：按钮用 `draftBusy || draftSettling` 禁用，
        //   但直接调用 / 双击绕得过按钮。放第二次提交进来，第一份还在确认中的草稿
        //   会被第二份顶掉：绑的是前一份、存的是后一份，两边都不一致。
        guard !draftBusy else {
            draftStatus = "正在处理上一次操作，请稍候再保存"
            return false
        }
        // 必填项先判掉，别让人等完网络才被告知没填地址。
        if let message = draftValidationMessage() { draftStatus = message; return false }
        let session = draftSession
        let target = draftSource.scopes
        // 绑定返回后需核对整份草稿，避免保存等待期间被修改的配置。
        let committedDraft = draftSource
        // ★ 本轮代次必须在**任何 await 之前**认领。
        let generation = draftGeneration
        if let provider = session.provider {
            // 仅检查新建会话的连接意图；过期时不安装或断开可能已被替换的会话。
            if session.disconnectsOnTeardown,
               let token = connectToken, !connectIntent.isCurrent(token) {
                draftSession = .none
                draftConnected = false
                draftStatus = "已断开，需要时请重新连接"
                return false
            }
            // 先确认范围绑定，再保存；失败不能显示保存成功。
            draftBusy = true
            defer { if draftGeneration == generation { draftBusy = false } }
            if let failure = await session.bindScopesForCommit(target) {
                // 等待期间这一轮可能已经被取消 / 重开：那这句失败说明属于新的一轮，
                // 不该由旧提交写上去（写了就是拿旧草稿的失败盖掉新草稿的状态）。
                guard draftGeneration == generation else { return false }
                draftStatus = failure
                return false
            }
            // 同上：绑定成功了，但若这一轮草稿已经作废，也**不许**落到新草稿上。
            guard draftGeneration == generation, draftSession.provider === provider else { return false }
            // ★ 往返期间草稿被改过：这次绑定确认的是出发时那一份，落盘读到的却是另一份。
            //   两份都不是用户确认过的组合，只能拒绝保存、也不发起搜索，
            //   让用户看一眼当前内容再按一次保存。
            guard draftSource == committedDraft else {
                draftStatus = "编辑内容已变化，请重新保存"
                return false
            }
        }
        // 先保存、但**不**重建 Provider：此刻 nativeProviders 里还没有那个
        // 「已经登录好」的实例，提前重建会新建一个空白 provider，
        // 已登录的那个则被搁置成孤儿（既没被使用，也没被断开）。
        guard saveDraft(rebuildProviders: false) else { return false }
        if let provider = session.provider {
            // 仅安装新建会话；借用的会话已由管理器持有。
            if session.disconnectsOnTeardown { installProvider(provider) }
            setSourceStatus(draftSource.id) {
                $0.health = provider.ready ? .ready : .offline
                // 这次登录通了，就不再是「需要动态码」的来源。
                // 不清的话，用户把账号换成不开两步验证的那一个之后，
                // 详情页的「重新登录…」仍会每次先弹 OTP 框问一遍。
                $0.needsOTP = false
                // 多选：把全部位置列出来，不要只显示第一个。
                let scopes = provider.config.scopes
                $0.message = provider.ready && !scopes.isEmpty
                    ? "搜索位置：\(scopes.joined(separator: "、"))"
                    : "已连接，请选择搜索位置"
                $0.selectedScope = scopes.joined(separator: "、")
                $0.availableShares = provider.availableShares
                $0.discoveredPort = provider.resolvedPort
            }
            if provider.ready { ensureNASSearchEnabled() }
        }
        // 提交不是退出：会话已经归管理器（新建的已 install、借来的本来就在），
        // 这里只把草稿的引用放掉，**不许**再 disconnect 一次。
        draftSession = .none
        draftConnected = false
        // 这一轮草稿到此为止：之后任何迟到的路径都不再属于它。
        draftGeneration += 1
        // installProvider 已经把新的 Provider 集合发布出去（含协调器重建）；
        // 不再 rebuild —— 那正是把已登录实例顶掉的动作。
        // ★ 只有绑定成功、配置也真的落盘之后才发起搜索，
        //   「先搜旧范围再补绑定」会让用户看到一次用错范围的结果。
        changedQuery()
        return true
    }

    func disconnectDraft() {
        let session = draftSession
        draftSession = .none
        // 断开同样让本轮作废：在飞的绑定 / 收养不许再写这台来源的状态。
        draftGeneration += 1
        draftSettling = false
        if let provider = session.provider {
            if session.isBorrowed {
                // 借来的是管理器里的活会话，而「断开」是用户明确要断这一台 ——
                // 所以要真断。但**必须同步改来源状态**：只断实例不改状态，
                // 卡片会继续写着「已连接」，用户点进去才发现搜索早就没了。
                setSourceStatus(provider.config.id) {
                    $0.health = .offline
                    $0.message = "已断开，配置已保留"
                    $0.requiredAction = .retry
                    $0.needsOTP = false
                }
            }
            Task { await provider.disconnect() }
        }
        clearPendingCredential()
        // 断开就该把密码框也清掉：留着相当于把上一次的密码暴露在界面上。
        nativeNASPassword = ""
        nativeNASOTP = ""
        draftConnected = false
        draftStatus = "已断开"
    }

    /// 切换或离开草稿时复用取消流程，清理凭据与在途连接。
    private func endDraftInput() { cancelDraft() }

    /// 取消在途操作、清除凭据，并按会话所有权断开或回滚范围。
    func cancelDraft() {
        // 递增序号 → 所有在飞的连接尝试回来时都会被判为过期，不再写任何状态。
        // 这里是「取消」而不是「再连一次」，所以用 invalidate 而不是 next：
        // 不留下一个「当前尝试」，免得界面以为还在连。
        attemptGate.invalidate()
        scopeSelectionSequence += 1
        pendingScopeTarget = nil
        // ★ 本轮草稿作废：所有还在等绑定 / 等收养的旧回调从此不再有归属，
        //   它们手里的 provider 与范围都属于上一轮，不许再落到界面上。
        draftGeneration += 1
        draftSettling = false
        // 新建会话要断开；借用的会话保留连接并回滚到已保存范围。
        let session = draftSession
        draftSession = .none
        if let provider = session.provider {
            let sourceID = session.provider?.config.id ?? draftSource.id
            let persisted = nasSources.first { $0.id == sourceID }?.scopes ?? []
            // 同步认领收尾，防止旧回滚覆盖后续编辑。
            let ticket = provider.beginTeardown()
            draftTeardownTask = Task { [weak self] in
                defer { provider.endTeardown() }
                guard let note = await session.release(persistedScopes: persisted, ticket: ticket) else { return }
                self?.setSourceStatus(sourceID) { $0.message = note }
            }
        }
        clearPendingCredential()
        nativeNASPassword = ""
        nativeNASOTP = ""
        // 授权码是一次性输入，与密码同理：离开这次编辑就不该留在界面上。
        draftAuthorizeCode = ""
        draftAwaitingAuthorizeCode = false
        // 核心里那条待换令牌的挑战属于这次编辑，取消后不再复用。
        pendingAuthorizationEndpoint = nil
        nasTrustCandidate = nil
        draftAvailableShares = []
        draftConnected = false
        draftBusy = false
        draftStatus = ""
        draftOriginalEndpoint = nil
        // 一键重试的提示属于**上一次**连接的失败，取消/重开就失效了。
        // 它同时意味着 `pendingCredential` 里还留着那份密码，必须一起收掉。
        draftOffersPlainHTTPRetry = false
        clearPendingCredential()
    }

    /// 打开已有来源的重连向导；reason 由凭据判定提供，此处不发起连接。
    func openReconnectWizard(_ id: String, reason: String) {
        guard nasSources.contains(where: { $0.id == id }) else { return }
        editSource(id)
        draftStatus = reason
    }
}
