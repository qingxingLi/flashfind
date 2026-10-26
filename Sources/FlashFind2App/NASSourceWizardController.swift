import AppKit
import FlashFindCore

/// 添加 / 编辑 NAS 来源的向导：填地址账号 → 连接（可能确认证书）→ 登录 → 选搜索位置 → 保存。
///
/// 从 AppModel 里切出来的理由和前几轮一样：这块的状态与方法都只围绕「向导这一次会话」，
/// 做成闭包注入后就能独立于 AppModel 那 20 多个 `@Published` 存在。
///
/// ★ 这一轮和前几轮不同：向导的状态本身就带二十个字段，光搬动作不够，
/// 所以**连状态一起搬了**（`nasSources` / `nativeProviders` / `draftSource` …）。
/// 界面写的是 `model.xxx`，AppModel 那里保留同名转发属性并桥接
/// `objectWillChange`——不桥接的话界面完全不刷新，而这种缺陷编译期看不出来。
///
/// ★ 搬移原则：**逐字搬，不优化**。这里每一句注释背后都是一次真实故障
/// （双击连接并行、证书确认后弹回、密码框清空后无法重试、看门狗把按钮锁死……），
/// 顺手"整理"一句就可能把那道闸删掉。
@MainActor
final class NASSourceWizardController: ObservableObject {

    /// 来源配置的落盘位置。**构造注入而非可选闭包**：
    /// 可选的话漏装配也能编译通过，后果是来源配置永远写不进磁盘，
    /// 而界面上看不出任何异常——只有重启应用才发现刚加的 NAS 不见了。
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
    /// 弹动态码输入框的那扇门。
    ///
    /// 由 AppModel 注入（`promptForOTP`）：弹窗要 `NSApp.activate` 才能在不进程序坞的
    /// 辅助型应用里前置，那是 AppModel 已经踩过并锁住的行为（见
    /// `testOTPPromptActivatesAppBeforeRunModal`）。向导**不自己再造一个弹窗**，
    /// 否则两条登录路径（向导 / 详情页「重新登录…」）会各弹各的、文案与行为走样。
    /// - Parameter failure: `nil` / `.required` = 还没填过码；`.rejected` = 刚填的被拒，
    ///   弹窗要用「动态码输入错误」的标题与正文（用户 2026-10-26 明确要求）。
    var otpPrompter: ((String, OTPFailure?) -> String?)?
    /// 上一次因「设备要动态码」而失败的状态文本。弹窗被取消时补提示要用：
    /// 取消之后界面上只剩这一行，它必须仍然说清刚才到底怎么了。
    private var otpFailureStatus = ""
    /// 添加/编辑向导的草稿。只有点「保存」才写入正式配置。
    @Published var draftSource = NASSourceConfig()
    @Published var draftStatus = ""
    /// 上一次连接失败是否值得提示「改用明文 HTTP 重试」。
    ///
    /// 判据在 `PlainHTTPRetryOffer.shouldOffer`（可单测）。界面据此显示一个按钮，
    /// 点它才会真的把协议改成明文——**降级仍由用户决定**，闪寻不自动换。
    @Published var draftOffersPlainHTTPRetry = false
    @Published var draftBusy = false
    /// 草稿正在等上一轮「取消」的收尾落定，还没收养到活会话。
    ///
    /// ★ 这段时间里「已连接 / 可勾选 / 可保存」都**还不成立**：
    ///   此刻活会话的范围正要被改回已保存值，草稿里那份是马上失效的快照。
    ///   不挡住的话，用户点下去改的是一个马上会被覆盖的草稿
    ///   （点「保存」就会写出「配置 A、实际搜 B」的来源）。
    @Published private(set) var draftSettling = false
    @Published var draftAvailableShares: [String] = []
    @Published var draftConnected = false
    /// 向导状态提示的唯一出口。UI 不直接写这个字段，避免和连接流程抢状态。
    func setDraftStatus(_ message: String) { draftStatus = message }
    @Published var nasTrustCandidate: NASTrustCandidate?

    /// 当前连接握手中暂存的凭据。
    ///
    /// 为什么必须有它：连接是「填密码 → 点连接 → 可能先要确认证书 → 再登录」，
    /// 而密码输入框在进入证书确认时就从界面上消失了。如果密码只存在输入框里，
    /// 这一步就把它清空了，用户会陷入「点了信任 → 程序说请填密码 → 但输入框看不见」
    /// 的死路。OTP 同理：它在 performConnect 里被重新读取时早已清空，实际根本传不到 DSM。
    ///
    /// 安全约束：**只存在于内存**，不写 UserDefaults、不写磁盘、不写日志，
    /// 且在任何终态（成功 / 失败 / 取消 / 来源切换）后立即销毁。
    private var pendingCredential: PendingCredential?
    /// 草稿里那个可操作的登录会话，**带上它是谁建的**。
    ///
    /// 以前这里只是一个 `NASSearchProvider?`：能拿到引用，却没有地方记
    /// 「这个实例是本次向导新建的，还是从连接管理器借来的活会话」。
    /// 编辑一个已连接的来源时，五条离开路径（取消 / 返回 / 切换来源 / 断开 / 提交）
    /// 都按「我建的」处理，无条件断开 —— 用户点一下「取消」就把正在用的来源注销了。
    /// 详见 `DraftSession`。
    /// 上一次「取消 / 返回 / 切来源」的收尾任务。
    ///
    /// ★ 之前这里是 `Task { … }` 不保存引用：收尾一旦开始就没有人能等它，
    ///   于是「取消后立刻重新编辑同一台来源」时，新草稿会照着一份**即将失效**
    ///   的范围快照复制（见 `editSource` 里的 `hasPendingTeardown` 分支）。
    ///   保存引用不是为了能取消它，而是为了让下一草稿能**等它落定**。
    private var draftTeardownTask: Task<Void, Never>?
    private var draftSession: DraftSession = .none

    /// 草稿代次：每次「取消 / 切换来源 / 重开编辑 / 提交完成」都 +1。
    ///
    /// ★ 提交与收养都有 `await`（等绑定、等上一轮收尾）。等待期间用户完全可以
    ///   取消、切到别的来源、或重开同一台 —— 那时旧回调手里的 provider 与范围
    ///   都属于**上一轮**。落下去就是拿旧草稿的结论盖到新草稿上。
    ///   所以每个 `await` 之后都要先核对代次，再动状态。
    private var draftGeneration = 0

    /// 进入编辑时该来源的主机与账号。
    ///
    /// 凭据条目只按来源 ID 存，不含主机与账号。用户把 `.96` 改成 `.88`
    /// （或换账号）之后，条目 key 没变、里面还是旧密码——不拦住就会
    /// 把 A 机器的密码发给 B 机器。保存时会清凭据，但「保存前就点连接」这条路上
    /// 也必须有同样的保护。
    private var draftOriginalEndpoint: (host: String, username: String)?

    /// 一次连接尝试的序号。只有最新那次能写状态。
    ///
    /// 没有它就有两个后果：① 用户点「连接」后立刻改地址/取消，在飞的旧尝试
    /// 返回时仍会覆盖状态；② 「连接」按钮的繁忙标记是在异步流程里才置位的，
    /// 双击能同时起两条 discover→login 流程，互相冲掉会话与证书确认。
    private let attemptGate = ConnectionAttemptGate()
    /// 来源配置的落盘 key。AppModel 载入配置时也用它，避免两处各写一份字面量。
    static let sourcesStorageKey = "ff2.nasSources.v1"

    /// 连接握手中暂存的凭据（只存在于内存，任何终态后立即销毁）。
    struct PendingCredential {
        let password: String
        let otp: String?
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
    /// 保存成功后确保 NAS 总开关是开的（R01）。
    ///
    /// 不开的话会出现最迷惑的一种状态：来源卡片写着「已连接」，
    /// 搜索却一个 NAS 来源都不请求 —— 用户只会以为是 NAS 没搜到东西。
    var ensureNASSearchEnabled: () -> Void = {}
    /// 逐来源「连接意图」登记表。
    ///
    /// **与 AppModel 共用同一个实例**：用户在来源卡片上点「断开」时，
    /// AppModel 会推进该来源的代次，这里所有在飞的连接尝试立刻作废 ——
    /// 迟到的成功不许 install（install 会发布 Provider 变化，上层随即
    /// 整体重建搜索协调器，把其它来源在飞的查询一起取消）。
    var connectIntent = SourceConnectIntent()
    /// 把**已登录**的 Provider 交给连接管理器（R02）。
    ///
    /// 必须是闭包而不是直接写 `nativeProviders[id]`：管理器才是 Provider 的
    /// 唯一持有者，写界面字典会被下一次 rebuild 用空白实例覆盖。
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

    /// 把管理器里那个活会话借进草稿（界面选项与已选位置都取自同一个实例）。
    ///
    /// ★ 抽成方法是因为**借的时机**不再只有一处：上一轮收尾还在飞时，
    ///   这一步必须排在收尾之后（见 `editSource`）。写成方法，两条路用的是同一份语义。
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

    /// 把草稿写入正式配置。同 ID 覆盖。
    ///
    /// - Parameter rebuildProviders: 是否顺带重建 Provider 字典。
    ///   `commitDraft` 传 `false`：它手里已经有一个**已登录**的 provider，
    ///   先重建会凭空多造一个——新造的没人用，已登录的那个则被搁置，
    ///   等于白白浪费一次登录，还得靠后面的重建重新接回来。
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
    /// 保存前的必填校验（地址、账号）。返回要在状态栏显示的那句话。
    ///
    /// 抽出来是因为**保存的入口不止一个**：`saveDraft` 直接用它；
    /// `commitDraft` 要在发起异步绑定**之前**就用它判一次——那是唯一一个
    /// 「用户点完还得等网络」的入口，晚一步报错等于让人白等。
    private func draftValidationMessage() -> String? {
        var draft = draftSource
        draft.normalizeHost()
        if draft.hostName.isEmpty { return "请填写 NAS 地址" }
        if draft.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 NAS 账号" }
        return nil
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

    /// 草稿的「主机 + 账号」是否相对**进入编辑时**发生了变化。
    ///
    /// 新增来源没有原始身份，永远算未变化。编辑已有来源时，
    /// 只要地址或账号被改过，钥匙串里的旧密码就不再属于这个目标——
    /// 要么让用户重输，要么这次连接就当作「没有可用密码」。
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
                                      hasStoredPassword: canRequestStoredPasswordForDraft)
    }

    /// 按钮不可用时说明缺什么。灰按钮不解释自己最容易被当成程序坏了。
    var connectDisabledReason: String? {
        ConnectButtonState.disabledReason(busy: draftBusy,
                                          host: draftSource.hostName,
                                          hasPort: draftSource.hasEffectivePort,
                                          username: draftSource.username,
                                          hasTypedPassword: !nativeNASPassword.isEmpty,
                                          hasStoredPassword: canRequestStoredPasswordForDraft)
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

    /// 设置连接路径。
    ///
    /// **只有在能解析出结果时才写模型**：用户在 `/dav` 的输入过程中，
    /// `/` 单独出现时解析结果是「等价于没填」，此时若把 `nil` 写进去，
    /// 输入框会被同步回空串、把他刚敲的字符擦掉——表现为「打不进去」。
    /// 视图那边同样保留自己的文本（见 `NASSourceWizardView.basePathText`）。
    ///
    /// 兜底：非 WebDAV 品牌一律不写（`effectiveBasePath` 也会挡，但少留一份
    /// 界面无法解释的残留值更省事）。
    func setDraftBasePath(_ text: String) {
        guard draftSource.vendor.allowsBasePath else { return }
        let parsed = BasePathField.parse(text)
        // 解析不出（空、纯 `/`）时置 nil = 走站点根，这是合法的用户意图。
        let value = parsed
        if draftSource.basePath != value { draftSource.basePath = value }
    }

    /// 切换品牌。**必须把明文 HTTP 的选择清回「按品牌默认」**。
    ///
    /// `usePlainHTTP` 是显式值，一旦写过就会盖住新品牌的默认值：
    /// 用户在飞牛（默认明文）上开过这个开关，再切到群晖时它会一直生效，
    /// 于是「https 的设备被按 http 连」——界面看不出任何异常，只是连不上。
    /// 复位逻辑在 `NASSourceConfig.adoptVendor`，那里可以单独测。
    func setDraftVendor(_ vendor: NASSourceConfig.Vendor) {
        guard draftSource.vendor != vendor else { return }
        // 换类型等于放弃当前这次连接：已建立的会话、待确认的证书都属于原类型。
        cancelDraft()
        draftSource.adoptVendor(vendor)
    }

    /// 从「附近的设备」里选中一台。
    ///
    /// 只**预填**地址与端口，不自动发起连接：接下来还要填账号密码，而且用户
    /// 可能只是想先核对一眼这个地址对不对。下一步由他自己点「连接」。
    ///
    /// ## 顺序不能反
    ///
    /// **先切品牌、再写地址**。`adoptVendor` 会清空 host / port / username
    /// （换类型等于换一种服务，旧字段留着只会误导），反过来写就会被它清掉，
    /// 表现为「点了一台设备，地址栏还是空的」。
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

    /// 开关「使用明文 HTTP」。
    ///
    /// 这个开关是**必需的**：WebDAV 的默认协议是 https，但真实设备里有
    /// 只开明文 HTTP 的（已真机验证的飞牛 5005 就是），且 WebDAV 的
    /// 端口是用户自己填的，客户端无从猜测。没有这个开关，这类设备
    /// 在界面上就没有任何可用的接入方式。
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

    /// 探测可达的 DSM 入口端口并登录。
    ///
    /// 端口由用户显式填写：自签名证书的 NAS 在标准 URLSession 下无法完成探测
    /// （TLS 阶段就失败，会把 5001 这种真正可达的端口判成不通），自动探测在这里
    /// 只会制造假失败。`probePort` 仅用于**给出精确错误提示**（区分「端口不通」
    /// 与「证书不受信」），不再参与连接决策。
    /// 关闭搜索 provider 时连带清掉向导手里那个待提交的实例。
    ///
    /// 只置 nil、不 disconnect：与原来 `closeSearchProviders` 的行为一致
    /// （断开由调用方各自负责，这里不抢）。
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
        // 端口一律用「有效端口」判定：地址里写了 `192.0.2.96:5001` 也算数。
        // 之前这里用的是只看端口字段的 `hasPort`，而按钮用的是 `hasEffectivePort`，
        // 两处判定不一致 → 按钮是亮的、点下去却被这里拦下并 return，
        // 用户看到的现象就是「连接按钮点不了」。
        guard !config.hostName.isEmpty else { draftStatus = "请填写 NAS 地址"; return }
        guard config.hasEffectivePort else {
            draftStatus = "请填写端口，或把端口直接写在地址里（如 192.0.2.96:5001）"
            return
        }
        guard !config.username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { draftStatus = "请填写 NAS 账号"; return }
        draftSource = config
        // 已经有适配器的品牌（含「已接入但未在真机验证」的四个）都**放行连接** ——
        // 未验证不等于不能用，而且真机结果正是校准适配器唯一的数据来源。
        // 只有连适配器都还没有的品牌才拦下来，并说明原因。
        //
        // 注意措辞：这不是「闪寻只支持群晖」，而是「这个品牌的适配器还没移植过来」。
        // MyNAS 上游 lib/nas_adapters/ 下这些实现是现成的，移植后即可使用。
        guard config.vendor.hasAdapter else {
            draftStatus = config.vendor.supportMessage
            return
        }
        // 密码来源二选一：本次输入的，或本机保存的。
        // 已知来源以前者优先（用户可能刚改了密码）；已保存来源后者优先——
        // 否则每次编辑都要把密码重新敲一遍，正是用户反馈的「很麻烦」。
        // 但**地址或账号改过之后就不许用钥匙串里的**：那把密码属于原来的目标。
        //
        // ★ 取值规则本身住在 Core（`NASCredentialPick`），因为它藏过一个死循环：
        // 钥匙串那条路若把动态码丢了 ⇒ 重连不带码 ⇒ 服务端再回 402 ⇒ 又弹一次 OTP。
        // 「手输密码」那条路带码、「钥匙串」那条路不带码，于是现象像「只有空密码才死循环」，
        // 实际是两路的差别。规则搬进 Core 后有单元测试守着，不再靠人工点一遍才发现。
        let storedPassword: String? = (nativeNASPassword.isEmpty && config.rememberPassword && !draftIdentityChanged)
            ? SecureStorage.read(account: config.credentialAccount,
                                 identity: config.credentialIdentity, allowInteraction: true)
            : nil
        guard let picked = NASCredentialPick.pick(typedPassword: nativeNASPassword,
                                                  storedPassword: storedPassword,
                                                  otp: nativeNASOTP) else {
            draftStatus = draftIdentityChanged ? "地址或账号已改动，请重新输入密码"
                : (CredentialStore.currentProblem?.summary ?? "请输入密码")
            return
        }
        let credential = PendingCredential(password: picked.password, otp: picked.otp)
        // 密码**留在框里**，凭据同时暂存进内存供「确认证书」之后继续登录。
        //
        // 曾经的做法是点「连接」就立刻清空（意图是不把密码留在界面上），
        // 但密码框此刻往往还是第一响应者，`SecureFieldEcho.shouldWrite`
        // 在编辑中不回写——清空只落在模型、落不到框里。连接一旦失败：
        //
        //   框里有圆点、模型是空 → 「连接」判「请输入密码」→ 只能删掉重敲
        //
        // 用户撞上的正是这个（429 限流后无法一键重试）。
        // 改为失败后原样保留：显示与模型一致，改个配置就能再点连接；
        // 密码只在**连接成功**后由成功路径统一清掉。
        pendingCredential = credential
        // **同步**占位，这一步不能挪进异步流程。
        // 之前 draftBusy 是在 performConnect 里置位的，中间存在一个窗口期：
        // 用户双击时第二次点击读到的 draftBusy 仍是 false，
        // 于是两条 discover→login 流程同时在跑，互相覆盖会话与证书确认，
        // 表现就是「偶发登录失败 / 证书弹两次 / 连上又断」。
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
        // 兜底看门狗：任何一次连接尝试都不该把「连接中」锁死。
        //
        // 之前没有这层保护：若某次 `await` 因底层进程异常、管道半开等原因
        // 永远不返回，那条路径上的 `defer { draftBusy = false }` 就永远不会执行，
        // `draftBusy` 一直是 true ——「连接」按钮永久变灰，用户只能重启应用。
        //
        // 只在**这次尝试仍是当前尝试、且仍在 busy**时才复位：
        // 已经正常结束（成功或失败都会把 draftBusy 置回 false）的不受影响。
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

    /// 这次连接尝试现在还有效吗。
    ///
    /// 两件事一起判：
    ///   1. 仍是**当前尝试**（`attemptGate`：取消 / 重连 / 改配置都会让旧尝试失效）；
    ///   2. 连接意图**没被作废** —— 用户在来源卡片上点了这台 NAS 的「断开」时，
    ///      AppModel 会让该来源的代次 +1，这里立刻为 false。
    ///
    /// 每一个 `await` 之后、以及 install / 状态回写之前都必须过这一关：
    /// 过期连接不许 install、不许回写状态（install 会发布 Provider 变化 →
    /// 上层整体重建协调器 → 其它来源在飞的查询被一起取消）。
    ///
    /// 这里**只核对代次**，不比对配置指纹：向导的 `draftSource` 在连接过程中
    /// 会被自己写回（端口兜底、`scopes` 回填、证书确认时改写端口），拿它当
    /// 「配置有没有变」的基准只会把正常流程自己判成过期。配置变化由
    /// `attemptGate`（取消/重连）负责；AppModel 的静默自动连接那条路才是
    /// 拿「已保存配置」当基准、可以安全比对指纹的地方。
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

    /// 建 Provider 的唯一入口：超时预算、挂载服务、自动重连，三件套一次装齐。
    ///
    /// 证书确认那条路曾经自己 `NASSearchProvider(bridge:…)` 了一个，漏装
    /// `mountService`：结果是这台 NAS **能搜、点开却报「尚未连接共享」**，
    /// 而证书正常的另一台一切正常——差别只在走了哪条连接路径。
    /// 只要还留着第二处手写构造，这个洞就会再开一次，所以两条路都走这里。
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
            // 同上：discover 之前先清掉同 sourceID 的旧来源，否则回 SourceExists。
            await resetCoreSource(effective.sourceID)
            guard attemptStillValid(attempt) else { clearPendingCredential(); return }
            let provider = makeProvider(sharedBridge, config: effective, port: effective.port)

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
        let flash = error as? FlashFindError
        var apiCode: Int?
        var isCoreFailure = false
        if case let .coreFailure(_, _, code)? = flash { isCoreFailure = true; apiCode = code }
        // ★ 设备要求动态口令 → 直接弹输入框，填完自动接着连。
        //
        // 这一条换过三版，每一版都是同一个现象改头换面：
        //   1. 输入框是视图私有的 `@State`，**没有任何路径会打开它**
        //      → 状态行说「请填写 OTP」，界面上没有能填的地方；
        //   2. 改成模型持有折叠开关，失败时自动展开
        //      → 但用户得自己回表单点第二次「连接」；
        //   3. 现在：**弹窗**问码，拿到就自动续连，与详情页「重新登录…」
        //      那条路走同一扇门（`otpPrompter`）。
        // 判据不变：失败里到底是不是 OTP，由 Core 的 `otpFailure` 说了算。
        // ★ 但必须带上是**哪一种**：`.rejected` 要在弹框里直说「动态码输入错误」，
        // 否则用户码填错一次，看到的仍是「这台设备需要两步验证」——他会以为
        // 码根本没发出去（2026-10-26 报障原话）。
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

    /// 设备要动态码 → 弹窗问码 → 拿到就自动接着连。
    ///
    /// ## 为什么弹窗要放到一个独立的 Task 里
    ///
    /// 失败收尾是 `performConnect` 的最后一步，而弹窗是**模态**的（同步阻塞主线程）。
    /// 就地弹会把这次连接尝试的 `defer`、状态刷新全卡在半路；放进 Task 则是在
    /// 本次尝试彻底结束（按钮已解锁、`draftBusy` 已复位）之后才问用户。
    ///
    /// ## 为什么拿到码之后走 `connectDraft()` 而不是把码塞进 `pendingCredential`
    ///
    /// `connectDraft()` 里已经把「密码从框里来还是从本机存的那把来」、
    /// 「改过地址/账号就不许沿用旧密码」这类判定写全了；再抄一遍必然会漏一条，
    /// 而漏的那条往往是安全相关的。密码此刻仍在框里（连接失败不清框，
    /// 详见 `connectDraft` 的注释），所以这条路对「手输密码」与「已保存密码」都成立。
    /// - Parameter failure: 上一次为什么失败。`.rejected` 让弹框直说「动态码输入错误」，
    ///   而不是把码错说成「这台设备需要两步验证」。
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

    /// 登录 → 列共享 → 绑定搜索位置。
    ///
    /// 「确认证书」与「连接」两条路径都汇到这里，因此共用**同一个** Provider 实例。
    /// 这点很关键：sourceID 由 config 派生，新建实例若拿到不同 sourceID，
    /// 刚确认的 pin 就对不上，用户会看到「信任完又弹回请核对证书」。
    private func finishLogin(config: NASSourceConfig, provider: NASSearchProvider,
                             credential: PendingCredential, attempt: Int) async {
        guard attemptStillValid(attempt) else { clearPendingCredential(); return }
        do {
            try await provider.login(account: config.username, password: credential.password, otp: credential.otp)
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
            var credentialSaveFailed = false
            if effective.rememberPassword {
                // 必须用 credential.password。
                // 不能裸写 `password`：那会解析到旧索引服务那个同名属性，
                // 存进凭据的一直是空串或无关值——
                // 表现为「明明勾了保存密码，每次还是得重输」。
                let secret = credential.password
                do {
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

    /// 把底层错误翻译成用户能理解的一句话，并区分「网络不通」与「证书不受信」。
    ///
    /// 这两种失败在原始报错里长得很像（都是 `NSURLErrorDomain`），
    /// 但用户要做的处理完全不同：前者去查网络/地址，后者去核对证书。

    /// 证书确认。确认后需要重新登录（凭据不跨会话保留）。
    /// 确认证书并**接着完成登录**。
    ///
    /// 之前这里是两件事：确认证书后丢掉会话，让用户再输一次密码点「连接」。
    /// 实测表现为「点信任并继续 → 又弹回请核对证书」，因为新 Provider 的
    /// sourceID 与确认时那一个不同，pin 记不上，等于白确认一次。
    ///
    /// 现在把「确认 → 登录 → 列共享」做成一条链，中间不丢状态。
    /// 断开 Dart 进程里该来源的旧会话。
    ///
    /// 核心按 sourceID 维护 `sources`，一个 sourceID 只能存在一份。
    /// 任何「重新连接 / 再次 discover / 确认证书」之前都必须先清掉旧的，
    /// 否则核心直接回 `SourceExists`——表现为用户什么都没改却连不上。
    ///
    /// 失败不阻塞后续流程：清不掉时让后续命令自己报错，避免这里造出第二个故障。
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

    /// 勾选 / 取消一个搜索位置（多选：用户可以同时选中多个共享）。
    ///
    /// 两个防护：
    /// 1. `defer` 必须写在 Task **内部**。写在外面的话，函数创建完 Task 就返回、
    ///    立刻把 `draftBusy` 复位，用户可以连点多个共享；
    /// 2. 用递增序号丢弃过期响应——即使两个请求都在飞，最终生效的也是用户**最后点**的那个，
    ///    而不是碰巧**最后返回**的那个。
    func toggleDraftScope(_ scope: String) {
        // ★ 判定依据是「草稿里有没有可操作的会话」，而**不是**「有没有本次新连的会话」。
        // 用「本次新连的会话非空」那种写法时，编辑一个已连接的来源永远进不来：
        // 界面写着「已连接，可以搜索了」，点勾选却被一句「请先完成连接」挡回去。
        // 借来的活会话同样能改范围（`DraftSession.canEditScopes`）。
        guard draftSession.canEditScopes else { draftStatus = "请先完成连接"; return }
        // ★ 上一轮收尾还没落定时不许改范围：此刻草稿里的范围是一份马上会被
        //   回滚覆盖的快照，勾了也白勾。
        guard !draftSettling else { draftStatus = "正在读取这台 NAS 的当前搜索位置…"; return }
        var scopes = draftSource.scopes
        if scopes.contains(scope) { scopes.removeAll { $0 == scope } } else { scopes.append(scope) }
        scopes.sort()
        // 界面立刻反映用户刚点的这一下，不等底层往返。
        draftSource.scopes = scopes
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

    /// 保存并把向导已建立的会话接入搜索。
    /// - Returns: 是否真的保存成功。
    ///
    /// ★ 调用方**必须**用这个结果决定要不要关窗口、要不要说「已保存」。
    ///   之前是 `commitDraft(); close()`：绑定失败时窗口照样关、界面照样当成功，
    ///   留下的却是一台「配置写着 A、实际搜 B」的来源。
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
        // ★ 出发前把**整份草稿**拍下来。
        //
        // 只记 `target`（范围）是不够的：落盘走的是 `saveDraft()`，它读的是
        // 此刻可变的 `draftSource`。绑定要等一次网络往返，往返期间用户照样能改
        // 勾选、改账号（勾选不会推进代次，所以代次守卫抓不到）。旧写法于是
        // 变成「绑 B、存 C、搜 B」——保存下来的是一份用户从没确认过的值。
        // 往返结束后必须确认「现在这份」仍是出发时的那一份才准落盘。
        let committedDraft = draftSource
        // ★ 本轮代次必须在**任何 await 之前**认领。
        let generation = draftGeneration
        if let provider = session.provider {
            // ★ 断开守卫：用户可能在向导开着的时候，在来源卡片上点了这台
            // NAS 的「断开」。那次连接已经作废 —— 这里绝不能把它的实例 install 回来：
            // install 会发布 Provider 变化，上层随即整体重建搜索协调器，
            // 把其它来源在飞的查询一起取消（就是用户看到的「断开一台，全部断开」）。
            // 过期连接也不去给核心发 disconnect：那会误伤此刻可能已经建立的新会话。
            //
            // 只对「本次新建」的会话成立：借来的活会话不参与连接意图，
            // 拿它去对 `connectToken` 只会误判成过期、把好好的编辑丢掉。
            if session.disconnectsOnTeardown,
               let token = connectToken, !connectIntent.isCurrent(token) {
                draftSession = .none
                draftConnected = false
                draftStatus = "已断开，需要时请重新连接"
                return false
            }
            // ★ 顺序：先拿到「范围绑定」的结果，再落盘。
            //
            // 反过来的旧写法（先 `saveDraft` 再 `Task { _ = try? await … }`）把这一次
            // 提交拆成了「先斩后奏」：配置已经写进磁盘、状态已经显示旧范围、
            // 搜索已按旧范围发出，绑定那次请求才刚出发；而 `false` 与 `throw`
            // 都被丢掉 ⇒ 绑定失败时界面照样说「已保存」，只有搜索在悄悄用旧范围。
            // 那不叫修好，那叫把「配置与实际不一致」推迟成静默不一致。
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
            // ★ 只有本次新建的会话需要交给管理器（R02）。
            // 写字典的版本会被随后的 rebuild 用「配置相等」的空白实例顶掉，
            // 保存完立刻变未连接——而核心里那次登录其实已经成功了。
            //
            // 借来的会话**不 install**：它本来就在管理器的表里，
            // 再 install 一次会发布一次 Provider 变化，等于让所有来源重建一遍
            // 搜索协调器、把别的来源在飞的查询一起取消。
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

    /// 离开当前草稿输入（切换来源、重新开始添加）时，把这次输入留下的一切收回。
    ///
    /// 真实现象：用户在密码框里敲了密码，点「返回」再进另一台 NAS，
    /// 密码框里还是上一次的密码——`nativeNASPassword` 是模型状态，
    /// 视图重建后会把它读回输入框。同一个密码框在不同来源之间「串味」，
    /// 既不安全，也让人以为程序记错了目标。
    ///
    /// 实现直接复用 `cancelDraft`：断开在飞的连接、销毁暂存凭据、清空输入框，
    /// 调用方随后设置新的 `draftSource` 即可。
    private func endDraftInput() { cancelDraft() }

    /// 取消整个添加/编辑流程，把这次连接留下的一切都收回。
    ///
    /// 之前「取消」只是 `window.close()`：后台的 discover/login Task 照跑，
    /// 几秒后还会回来改状态；已建立的 DSM 会话、暂存的内存密码也一直留着。
    /// 关闭窗口 / 点取消 / 重新开始添加 / 切换 NAS 类型都必须走这里。
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
        // ★ 交还会话 —— 这里是「取消」与「提交」的分水岭。
        //   · 本次向导新建的：断开（核心里那份会话没人认领了）；
        //   · 借来的活会话：**只放引用，绝不断开**，并把范围回滚到已保存的配置。
        //     借的那一个是用户正在用的连接，取消编辑不该让它掉线；
        //     而编辑期间每点一下勾选都直接改了活会话的范围，不回滚就会出现
        //     「界面退回去了、搜索还在用新范围」。
        let session = draftSession
        draftSession = .none
        if let provider = session.provider {
            let sourceID = session.provider?.config.id ?? draftSource.id
            let persisted = nasSources.first { $0.id == sourceID }?.scopes ?? []
            // ★ 归属票号必须在**这里同步**拿到，不能等 Task 起来再取。
            //
            // 「取消」是同步返回的：按钮点了、界面已经退回去了，收尾 Task 才被调度。
            // 这中间用户完全可以立刻重新点开同一台来源并勾一个位置。
            // 若票号在 Task 内部才取，晚出发的旧收尾取到的是「最新」那个序号，
            // 于是它反而成了归属者 —— 拿上一轮的已保存值盖掉用户刚勾的位置。
            // 同步认领后，任何后发生的编辑都会把序号推过去，旧收尾因此让位。
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

    /// 用本机保存的密码重连，不打扰用户。
    /// 打开重连向导（需要用户输密码）。
    ///
    /// 注意：这个方法**不做任何连接**，只是把来源载进编辑草稿。
    /// 之前它叫 `reconnect()`，被「刷新状态 / 测试所有 NAS 连接 / 重新连接」三个按钮共用，
    /// 结果那几个按钮都只是在反复装载草稿、什么都没连接——是名副其实的假动作。
    /// 现在三个入口语义明确分开，见 `refreshStatuses()` 与 `reconnectUsingStoredCredential(_:)`。
    /// 打开「重新连接」向导。
    ///
    /// - Parameter reason: **为什么还要输一次密码**，由 `ReconnectEntryState` 判定后传入。
    ///   之前这里写死了一句「请输入密码以重新连接」：本机凭据文件里就存着密码时
    ///   也这么说，用户于是以为必须重输。
    ///   现在这句话必须来自「到底有没有已保存的密码」的判定，不许在这里另写一套。
    func openReconnectWizard(_ id: String, reason: String) {
        guard nasSources.contains(where: { $0.id == id }) else { return }
        editSource(id)
        draftStatus = reason
    }
}
