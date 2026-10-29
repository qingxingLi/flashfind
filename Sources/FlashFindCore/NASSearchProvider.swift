import Foundation

/// 一台 NAS 一个 Provider。地址、端口、账号、搜索位置全部来自 `config`，
/// 本类型不含任何写死的主机或共享名。
@MainActor public final class NASSearchProvider: SearchProvider {
    /// 对外的来源描述。名字是展示字段，可在会话存活期间变（见 `updateDisplayName(_:)`）。
    public private(set) var source: SearchSource
    public let bridge: any MyNASBridgeTransport
    public private(set) var ready = false
    public var queryBudgetMs = 60_000
    public var requestBudgetMs = 30_000

    /// 本 Provider 负责的配置。scope 可为空（尚未选定搜索位置）。
    public private(set) var config: NASSourceConfig
    /// 实际使用的端口（探测结果）。
    public private(set) var resolvedPort: Int
    public var availableShares: [String] = []

    /// 定位所需的不可变快照。
    ///
    /// 路径核验跑在后台线程，不能读 MainActor 上的 `config`；因此在配置变化时
    /// 同步刷新这份值类型副本，由 Swift 的独占访问保证读取一致。
    internal nonisolated(unsafe) var locatorSnapshot: NASLocator = .empty

    private let now: () -> Date
    private var discovered = false
    /// 我是在**第几代核心**上连好的。核心一重启，这个登录态就必然失效。
    ///
    /// 背景（BUG-002）：核心进程重启后，进程里的 sources 与 session 全空，
    /// 但 Swift 侧的 `ready` 还是 `true`。不校验就发搜索，等于发给一个
    /// 「根本没有这台 NAS」的新核心 —— 必失败，而且界面还显示已连接。
    private var connectedGeneration = 0
    /// 当前活跃搜索的**状态机**（P1-01 / P1-02）。
    ///
    /// `active` 改为它的只读投影：散落在下面的 `active == queryID` 判断
    /// 因此全部自动落到同一份身份上，不需要逐个改——也就不可能再出现
    /// 「某一处用的是另一套 ID」。
    private var activeMachine: SearchSessionMachine?
    private var active: UUID? { activeMachine?.session.queryID }
    /// 当前活跃搜索是**谁**发起的（P3：GUI / MCP 会话隔离）。
    ///
    /// 只有同一 owner 的新查询才允许取代旧查询。跨 owner 一律排队，
    /// 排队由 `SearchScheduler` 负责；这里守的是「万一没排队也不许互相取消」。
    private var activeOwner: SearchOwner = .ui
    /// 刚刚结束的那次查询的 `queryID`（正常完成、失败、超时都算）。
    ///
    /// 为什么需要它：搜索一结束就必须把 `activeMachine` 摘掉 —— 否则下一次
    /// **换 owner** 的搜索会被上面那条不变量检查当成「另一个调用方还在搜索」，
    /// 而实际上这个来源早就空了（实测症状：GUI 与 MCP 互相把对方挡在门外，
    /// 文案是「这个来源正在被另一个调用方搜索」）。
    ///
    /// 但结果行的**可打开性**是事后补发的：解析挂载路径可能阻塞到 3 秒，
    /// 那时 `active` 已经是 nil。所以留一个只对「刚结束的那一次」开放的窗口，
    /// 下一次搜索一开始就关掉 —— 否则旧查询的元数据会污染新查询的结果行。
    private var completedQueryID: UUID?
    /// 建立搜索状态机前暂存请求归属。
    private var pendingOwner: SearchOwner?
    /// 断开时通过此通道补发一次取消终态，避免搜索界面一直等待。
    private var activeEmit: (@MainActor (ProviderEvent) -> Void)?
    private var activeEmitQueryID: UUID?
    /// 上一次搜索的状态轨迹与被拒转移，供诊断读取（非法转移是缺陷的直接证据）。
    public private(set) var lastSessionTrail: [String] = []
    public private(set) var lastSessionRejected: [RejectedTransition] = []
    private var degradedUntil: Date?
    private var failures = 0
    private var malformedSeen = false
    private var retryInFlight = false
    /// 用户断开后保持离线，直到显式连接成功。
    private var sessionClosed = false
    /// 断开时递增，防止旧登录或选范围请求迟到后恢复会话。
    private var sessionEpoch: UInt64 = 0
    /// 自动重连的就绪状态由 attemptAutoReconnect 统一收尾。
    private var autoReconnectInFlight = false

    // MARK: - 改搜索范围的在途请求（取消/返回必须有确定的收束顺序）

    /// 取消编辑前需等待在途范围变更落定，才能判断是否回滚。
    private var scopeMutationDepth = 0
    /// 等「在途请求落定」的调用方（取消 / 返回 / 切换来源）。
    private var scopeMutationWaiters: [CheckedContinuation<Void, Never>] = []
    /// 防止迟到的范围变更覆盖之后发起的保存。
    private var scopeMutationSequence = 0

    /// 是否仍有范围变更在途。
    public var hasScopeMutationInFlight: Bool { scopeMutationDepth > 0 }
    /// 等待范围变更完成的调用方数量。
    public var scopeMutationWaiterCount: Int { scopeMutationWaiters.count }

    /// 等待范围变更落定再决定回滚；请求自身有超时，收尾不另设短时限。
    public func drainScopeMutations() async {
        guard scopeMutationDepth > 0 else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            scopeMutationWaiters.append(continuation)
        }
    }

    /// 记录收尾开始时的序号，防止旧回滚覆盖后续保存。
    @discardableResult
    public func beginScopeTeardown() -> Int { scopeMutationSequence }

    /// 从 `beginScopeTeardown()` 那个时刻之后，是否又有人发起了新的改范围请求。
    public func hasScopeMutationNewer(than ticket: Int) -> Bool { scopeMutationSequence > ticket }

    // MARK: - 收尾边界（取消/返回 与 下一草稿 之间必须有先后）

    /// 一次「取消 / 返回 / 切换来源」的收尾正挂着，还没落定。
    private var teardownPending = false
    private var teardownWaiters: [CheckedContinuation<Void, Never>] = []

    /// 下一草稿借用会话前须等待未完成的收尾。
    public var hasPendingTeardown: Bool { teardownPending }
    /// 供调用方和测试观察下一草稿是否已开始等待。
    public var hasTeardownWaiters: Bool { !teardownWaiters.isEmpty }

    /// 同步认领收尾，避免异步任务迟到后覆盖新一轮编辑。
    @discardableResult
    public func beginTeardown() -> Int {
        teardownPending = true
        return scopeMutationSequence
    }

    /// 收尾落定（无论成功回滚、如实失败还是让位）。
    public func endTeardown() {
        teardownPending = false
        let waiters = teardownWaiters
        guard !waiters.isEmpty else { return }
        teardownWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    /// 等收尾真正完成后再借用会话，不另设短时限。
    public func drainTeardown() async {
        guard teardownPending else { return }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            teardownWaiters.append(continuation)
        }
    }

    @discardableResult
    private func beginScopeMutation() -> Int {
        scopeMutationSequence += 1
        scopeMutationDepth += 1
        return scopeMutationSequence
    }

    private func endScopeMutation() {
        scopeMutationDepth = max(0, scopeMutationDepth - 1)
        guard scopeMutationDepth == 0 else { return }
        resumeScopeMutationWaiters()
    }

    /// 唤醒所有等待者。**先清空再逐个 resume**：同一条 continuation
    /// 被 resume 两次会直接崩，所以「取出 → 清空 → resume」必须是原子的。
    private func resumeScopeMutationWaiters() {
        let waiters = scopeMutationWaiters
        guard !waiters.isEmpty else { return }
        scopeMutationWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    public var onConnectionEvent: (([String: Any]) -> Void)?
    /// 由持有凭据的上层重连，Provider 不保存密码。
    public var autoReconnect: ((NASSearchProvider) async -> Bool)?
    /// 避免设备退化时重复登录，加重负载。
    public static let autoReconnectCooldown: TimeInterval = 10
    private var lastAutoReconnectAt: Date?
    private var autoReconnectCount = 0
    /// 后台挂载服务。未注入时定位行为与原来一致（只用已存在的挂载）。
    public var mountService: SMBMountService?
    /// 本次登录使用的账号是否为 DSM 管理员。
    ///
    /// 允许管理员登录（「一律拒绝管理员」只是为了让验收对象固定成普通账号，
    /// 从未在真机上验证过）。但管理员在 `list_share` 里能看到**全部**共享，
    /// 所以用它搜索时范围不再等于「被授予的目录」而是「这台 NAS 的全部目录」——
    /// 这是权限边界的实质性放宽，必须让用户知情。
    public private(set) var isManagerAccount = false

    /// 登录成功后核心交上来的「下次登录所需的那一串东西」。
    ///
    /// 只有**没有密码的品牌**才会给（飞牛 fnOS：refresh token）。账密品牌
    /// 这里是 nil，密码由界面自己保管——适配器不该把它再抄一份出来。
    ///
    /// ★ 界面必须优先存这个，而不是用户刚敲进密码框的那串（对飞牛来说那串是空的）。
    ///   存空的后果是「界面显示已记住、下次照样连不上」，而且用户无从判断。
    public private(set) var sessionSecret: String?

    /// SMB 不可达时的网页兜底地址（飞牛的**站点首页**，核心拼好）。
    /// 打开链（2026-10-29 用户定）：SMB 可达走 SMB，不可达开浏览器，
    /// 下载只是右键选项。地址由核心用**已核验的 origin** 拼，Swift 不自己猜。
    ///
    /// ★ 飞牛没有「路径级」网页入口：`/app/*` 是 App 容器（301 到 `:5667`，
    ///   要 `ticket`），反代/外网必然 404；桌面 SPA 也不接受定位参数。
    ///   所以这个地址只到桌面，别再往里拼路径（2026-10-29 真机 Not Found）。
    public private(set) var webFileURL: URL?

    /// 设备自报的账号名（飞牛 `user.info` 的 `userInfo.user`）。
    ///
    /// ★ 飞牛的来源配置里**没有账号**（OAuth 授权码登录，`username` 恒为空串），
    ///   而打开链要拿「SMB 登录账号」去认本机已有的挂载。没有它，来源填域名、
    ///   访达用局域网 IP 挂同一共享时，双击结果只能打开登录网页
    ///   （2026-10-29 真机：`/Volumes/共享文档/示例发票.pdf` 明明可读）。
    ///   只在运行时用，**不写回配置**：它是设备事实，不是用户设置。
    public private(set) var deviceAccount: String?

    /// 设备侧**已经解析出几条 SMB 共享**（飞牛 `file.share.list` + `info`）；
    /// 核心还没问过时为 nil。
    ///
    /// ★ 纯诊断，不参与打开判定：打开退到网页时，只有这个数能分清是
    ///   「共享表压根是空的」（0 —— 重启后没刷、或设备拒了）还是
    ///   「共享表有内容、只是这条路径不在任何共享前缀下」（>0）。
    ///   2026-10-29 两次真机报障都卡在这两种情况的区分上。
    public private(set) var deviceSmbShareCount: Int?

    public init(bridge: any MyNASBridgeTransport, config: NASSourceConfig, port: Int, now: @escaping () -> Date = Date.init) {
        self.bridge = bridge
        self.config = config
        self.resolvedPort = port > 0 ? port : config.port
        self.now = now
        source = SearchSource(id: config.sourceID, name: config.displayName, type: .nas, displayName: config.displayName)
        locatorSnapshot = Self.makeLocator(sourceID: source.id, config: config)
    }

    private static func makeLocator(sourceID: String, config: NASSourceConfig,
                                    deviceAccount: String? = nil) -> NASLocator {
        // 多位置时每条结果按「属于哪个共享」判定，不能只留一个前缀。
        let prefixes = config.scopes.map { $0.hasSuffix("/") ? $0 : $0 + "/" }
        // ★ `smbUsername` 从来没被任何界面写过（恒 nil），而它想表达的「用哪个账号连 SMB」
        //   在群晖/飞牛上就是 DSM 账号本身。直接取 `config.username` 兜底，否则
        //   「按登录账号认挂载」这条判据（见 `SMBMountCandidate.matching`）永远拿到 nil。
        // ★ 再兜一层「设备自报的账号」：飞牛的表单账号是空串，只有设备知道
        //   （`deviceAccount`，登录后才有）。
        let smbUser = config.smbUsername.flatMap { $0.isEmpty ? nil : $0 }
            ?? (config.username.isEmpty ? nil : config.username)
            ?? deviceAccount
        return NASLocator(sourceID: sourceID, host: config.hostName,
                          shares: Set(config.scopes.map { String($0.dropFirst()) }),
                          scopePrefixes: prefixes, preferredSMBUser: smbUser,
                          exposesSMBShares: config.vendor.exposesSMBShares,
                          smbSharesFromDevice: config.vendor == .fnos)
    }

    /// 配置变化后刷新定位快照。scope 改动必须走这里，否则后台核验仍用旧范围。
    public func updateConfig(_ newValue: NASSourceConfig) {
        config = newValue
        locatorSnapshot = Self.makeLocator(sourceID: source.id, config: newValue,
                                           deviceAccount: deviceAccount)
    }

    /// 用户在设置里给这台 NAS 改名。
    ///
    /// 名字只影响展示（结果行的来源徽标、状态文案、动态码弹窗里的称呼），
    /// **不是连接身份**：会话、搜索位置、钥匙串条目都挂在 `sourceID` 上，
    /// 而 `sourceID` 由 `id` 派生、与名字无关。所以这里既不 disconnect 也不重登，
    /// 当前结果也不清空 —— 改个名字把用户已经搜出来的东西清掉是没道理的。
    ///
    /// `source` 必须一起换：它是**构造时算出来的**快照，
    /// 结果行读的 `result.sourceName` 就来自这里。只改 `config` 会让设置页显示新名、
    /// 结果行还挂着旧名，直到下次重启。
    public func updateDisplayName(_ name: String) {
        var updated = config
        updated.name = name
        guard updated != config else { return }
        updateConfig(updated)
        source = SearchSource(id: updated.sourceID, name: updated.displayName,
                              type: .nas, displayName: updated.displayName)
    }

    /// 协议 endpoint。
    ///
    /// 群晖与 WebDAV 走 https；qnap / fnos / ugreen 的管理口出厂就是明文 http
    /// （实测飞牛的 5666 是明文），按 https 连会直接失败。
    /// 明文只对**用户显式配置过的局域网来源**开放，绝不隐式降级。
    ///
    /// 末尾拼上路径前缀（WebDAV 专用，见 `Vendor.allowsBasePath`）：
    /// OpenList / Alist 的 WebDAV 端点在 `/dav`，NextCloud 在 `/remote.php/dav`，
    /// 不带这一段就会连到站点根，拿回 404 或一个 HTML 首页。
    public var endpoint: String {
        let scheme = config.usesPlainHTTP ? "http" : "https"
        return "\(scheme)://\(config.hostName):\(resolvedPort)\(config.effectiveBasePath)"
    }

    // MARK: - 连接生命周期

    private var connectionFields: [String: Any] {
        var fields: [String: Any] = ["mode": "live", "endpoint": endpoint,
                                     "vendor": config.vendor.rawValue,
                                     "trust": ["mode": "sourcePin"],
                                     "requestBudgetMs": requestBudgetMs, "queryBudgetMs": queryBudgetMs,
                                     "sourceName": config.displayName]
        // 品牌来源不做证书固定：它们多是明文局域网设备。
        // 这里显式把「这台就是明文」的意图传给核心，而不是让它默默降级。
        if config.vendor != .synology {
            fields["trust"] = ["mode": "system"]
            fields["allowInsecureHTTP"] = config.usesPlainHTTP
        }
        // 首次连接不传 scope：先握手拿证书、拿共享列表，用户选完再 selectScope。
        if !config.scopes.isEmpty { fields["scopes"] = config.scopes }
        return fields
    }

    /// 能力协商与证书握手。
    ///
    /// 这一步**不代表可搜索**：搜索至少还需要身份通过（login）与范围绑定
    /// （selectScope）。握手成功只把 `discovered` 置位，`ready` 保持原值——
    /// 否则一个「探测到设备」的动作就会让界面显示成「已连接可搜索」。
    @discardableResult
    public func discover() async throws -> [String: Any] {
        if discovered { return ["event": "capabilities"] }
        let response = try await bridge.command("discover", sourceID: source.id, fields: connectionFields)
        discovered = response["event"] as? String == "capabilities"
        return response
    }

    public func confirmTrust(candidateID: String, sha256: String, allowExpired: Bool) async throws -> [String: Any] {
        var fields = connectionFields
        fields["candidateID"] = candidateID; fields["sha256"] = sha256
        fields["userConfirmed"] = true; fields["allowExpired"] = allowExpired
        let response = try await bridge.command("confirmTrust", sourceID: source.id, fields: fields)
        discovered = response["event"] as? String == "capabilities" || (response["event"] as? String == "trustState")
        return response
    }

    public func login(account: String, password: String, otp: String? = nil,
                      authorizeCode: String? = nil, optionalScopes: [String]? = nil) async throws {
        // ★ 发起时记下代次。`await` 期间用户可能点断开 —— 那之后这次登录的成功
        // 已经不属于当前会话了，绝不能解闸门、更不能抬 ready。
        let epoch = sessionEpoch
        var fields: [String: Any] = ["account": account, "password": password]
        if let otp { fields["otp"] = otp }
        if let authorizeCode { fields["authorizeCode"] = authorizeCode }
        // 用户在授权弹窗里勾选的可选权限（fnOS）。核心只对支持的适配器生效。
        if let optionalScopes { fields["optionalScopes"] = optionalScopes }
        let result = try await bridge.command("login", sourceID: source.id, fields: fields)
        // ★ 需要浏览器授权：**不是失败**，是登录流程的第一段。
        //
        // 飞牛（fnOS）官方协议没有账号密码登录，只有 OAuth 授权码 + PKCE，
        // 而且授权 URL 里没有 `redirect_uri` ⇒ 授权页不回跳，一次性 code
        // 只能由用户从页面上抄下来交回来。核心在这种情况下发 `authChallenge`
        // 事件（已登记为终止事件），把地址与有效期交上来。
        //
        // 这里必须抛一个**专门的错误**而不是 `.message`：界面要拿那个 URL
        // 去开浏览器，压成一句文案地址就丢了，用户只看到「登录未成功」。
        if result["event"] as? String == "authChallenge" {
            guard let raw = result["authorizationUrl"] as? String,
                  let url = URL(string: raw) else {
                throw FlashFindError.message("核心没有给出可用的授权地址")
            }
            let validForMs = result["validForMs"] as? Int ?? 300_000
            var scopes: [NASAuthorizationScope] = []
            if let rawScopes = result["scopes"] as? [[String: Any]] {
                scopes = rawScopes.compactMap { item in
                    guard let id = item["id"] as? String,
                          let label = item["label"] as? String else { return nil }
                    return NASAuthorizationScope(id: id, label: label,
                                                 required: (item["required"] as? Bool) ?? false)
                }
            }
            throw FlashFindError.authorizationRequired(
                url: url,
                validFor: TimeInterval(validForMs) / 1000,
                rejected: (result["rejected"] as? Bool) ?? false,
                scopes: scopes
            )
        }
        // 两种成功态都要认：
        //   scopeReady   —— 核心已连同已选范围一起就绪（旧流程）；
        //   authenticated —— 身份已通过，范围随后由 selectScope 绑定（新流程）。
        // 除此之外一律视为登录失败，不能凭「没抛异常」就当成功。
        guard let state = result["state"] as? String, state == "scopeReady" || state == "authenticated" else {
            throw FlashFindError.message("登录未成功")
        }
        // 断开已作废这次登录 ⇒ 什么都不写就返回：ready 保持 false，闸门保持合上，
        // 调用方随后会被连接意图守卫拦下（App 层），或由 attemptAutoReconnect 收尾。
        guard epoch == sessionEpoch else { return }
        // 显式登录成功 = 用户重新连接了这台 NAS，解除断开闸门。
        // 自动重连路径也会走到这里，但那条路不得解闸（就绪由 attemptAutoReconnect 收尾决定）。
        if !autoReconnectInFlight { sessionClosed = false }
        isManagerAccount = (result["isManager"] as? Bool) ?? false
        // 「下次还能连上」的凭据：核心给了就用它的（飞牛 = refresh token），
        // 没给就保持 nil，由界面沿用用户输入的密码。
        let secret = result["sessionSecret"] as? String
        sessionSecret = (secret?.isEmpty == false) ? secret : nil
        // 设备自报的账号名：拿到就**立刻重建定位快照**——打开链读的是快照里的
        // `preferredSMBUser`，晚一步重建，这次会话里的结果就还是按「不知道账号」
        // 去认挂载（飞牛的表单账号是空串，登录前这里是 nil）。
        if let account = result["signedInAccount"] as? String, !account.isEmpty,
           account != deviceAccount {
            deviceAccount = account
            locatorSnapshot = Self.makeLocator(sourceID: source.id, config: config,
                                               deviceAccount: account)
        }
        // 设备侧共享表的条数：只在诊断里用，跟打开链判定无关。
        if let count = result["smbShareCount"] as? Int {
            deviceSmbShareCount = count
        }
        // 网页兑底地址：核心给了才存，每次会话刷新覆盖。
        if let web = result["webFileURL"] as? String, let url = URL(string: web),
           url.scheme == "http" || url.scheme == "https" {
            webFileURL = url
        } else {
            webFileURL = nil
        }
        // 就绪判据只能是**核心确认的范围**，不能读 Swift 侧的 config：
        // 新流程是「先 login 拿到 shares，再 selectScopes 绑定范围」，
        // login 这一刻 config.scopes 必然还是空的——若据此置 ready，
        // 界面会在范围尚未绑定时就显示「已连接」，搜索却被 core 拒绝。
        // 真正的就绪点由 selectScopes() 在范围绑定成功后置位。
        markReadyOnCurrentCore(state == "scopeReady")
    }

    /// 置位 `ready` 的同时记下**当前核心代次**。
    ///
    /// 两件事必须一起做：只置 `ready` 不记代次，就回到了「核心重启了还以为已连接」。
    ///
    /// ★ 两道额外闸门：
    ///   * 用户已显式断开 ⇒ 不许再抬 `ready`；
    ///   * 自动重连在飞 ⇒ 不许在重连流程中途抬 `ready`。重连的 login/selectScopes
    ///     会先拿到成功，但「这次恢复到底算不算数」只有 `attemptAutoReconnect`
    ///     收尾时才知道（那时才看得出用户有没有中途断开）。原来在这里直接抬
    ///     `ready`，再在钩子结束时复位 —— 中间那段窗口里界面显示的是「已连接」。
    private func markReadyOnCurrentCore(_ value: Bool) {
        guard value else { ready = false; return }
        guard !sessionClosed, !autoReconnectInFlight else { return }
        ready = true
        connectedGeneration = bridge.processGeneration
    }

    /// 核心已经重启过 ⇒ 本 Provider 的登录态必然已经失效，必须重新连接。
    ///
    /// 只在**已就绪**时为真：没连上时谈「失效」没有意义，
    /// 也就不会把一次从未成功的连接误判成「被核心重启打断」。
    public var needsReconnectAfterCoreRestart: Bool {
        ready && bridge.processGeneration != connectedGeneration
    }

    /// 列出该账号可见的共享，供「选择搜索位置」使用。
    public func loadShares() async throws -> [String] {
        let result = try await bridge.command("listShares", sourceID: source.id)
        availableShares = Self.decodeShares(result["shares"])
        return availableShares
    }

    /// 解「共享/存储列表」。**两种形状都要认**，这不是防御性编程，是两个真实契约：
    ///
    /// - 群晖原生路径回 `["/共享A", "/共享B"]`（纯路径字符串）；
    /// - 品牌适配器（`BrandSession`）回对象数组
    ///   `[{"name": "A0002", "path": "/A0002", "sourceID": …, "sourceName": …}]`
    ///   —— 一条共享除了路径，还要带它属于哪个来源。
    ///
    /// ★ 只认 `[String]` 的后果不是「少显示一条」，而是**品牌来源永远拿到空数组**，
    /// 界面于是显示「已登录，但这个账号确实没有任何共享目录。请检查账号权限」。
    /// 这句把责任推给了用户的账号设置，而真实原因是解码形状不匹配 ——
    /// 2026-10-24 在 App 内实测 OpenList 时就是这么被误导的（核心明明回了 6 个存储）。
    static func decodeShares(_ raw: Any?) -> [String] {
        if let plain = raw as? [String] { return plain }
        if let objects = raw as? [[String: Any]] {
            return objects.compactMap { ($0["path"] as? String) ?? ($0["name"] as? String) }
        }
        return []
    }

    /// 绑定用户选择的搜索位置。只有通过共享准入校验才生效。
    /// 绑定一个或多个搜索位置。每个都必须在共享列表里真实存在。
    @discardableResult
    public func selectScopes(_ scopes: [String]) async throws -> Bool {
        guard !scopes.isEmpty else { return false }
        // ★ 本轮改范围**发起**时登记：取消/返回要等它落定才能判断范围；
        //   序号用来挡住「迟到的旧应答覆盖新的那次」。
        let sequence = beginScopeMutation()
        defer { endScopeMutation() }
        // 同上：发起时记下代次，`await` 之后核对。
        let epoch = sessionEpoch
        let result = try await bridge.command("selectScope", sourceID: source.id, fields: ["scopes": scopes])
        guard result["state"] as? String == "scopeReady" else { return false }
        // 这次绑范围是「断开之前」发起的 ⇒ 已过期：不解闸、不抬 ready、也不返回 true
        // （返回 true 等于告诉调用方「恢复成功」，那是谎话）。
        guard epoch == sessionEpoch else { return false }
        // ★ 这次应答已经不是最新发起的那次（用户在它飞的时候又发了一次）：
        //   范围归后发起的那次，这条不改 `config.scopes`，否则旧值会盖掉新值。
        guard sequence == scopeMutationSequence else { return true }
        // 显式绑定范围 = 重新连接流程的一部分，解除断开闸门（见 `sessionClosed`）。
        // 自动重连路径同样不得解闸。
        if !autoReconnectInFlight { sessionClosed = false }
        config.scopes = scopes
        locatorSnapshot = Self.makeLocator(sourceID: source.id, config: config)
        markReadyOnCurrentCore(true)
        // 返回值表达的是「**核心**确认了范围」，不是本实例的 `ready`：
        // 自动重连期间 `markReadyOnCurrentCore` 刻意不抬 ready（见其说明），
        // 若这里跟着返回 ready，`NASAutoReconnect.recover` 会把一次成功的恢复
        // 判成失败 —— 自动重连就再也不会成功了。
        return true
    }

    /// 单个位置的便捷入口（内部转成数组）。
    @discardableResult
    public func selectScope(_ scope: String) async throws -> Bool {
        try await selectScopes([scope])
    }

    /// 断开本来源。
    ///
    /// ★ 三件事必须**同步**先做，再发核心命令：
    /// 1. 终结并清掉活跃查询的状态机 —— 否则断开期间在飞的搜索回来时
    ///    `active` 还等于它的 queryID，迟到结果会继续涌进界面，
    ///    用户已经断开的来源看起来还在出结果（BUG-NAS-DISCONNECT-01）；
    /// 2. **补发恰好一次取消终态** —— 只摘状态机不报终态的话，上层
    ///    「请求过的来源全部落终态才停止转圈」的判据永远不成立，
    ///    界面会在这次搜索上永久转圈。用 `activeEmit`
    ///    存的那条通道发，发完立刻清掉，因此重复断开不会重复发；
    /// 3. 推进 `sessionEpoch` 并合上 `sessionClosed` 闸门 —— 断开**之前**
    ///    发起的 login / selectScopes 迟到成功时不许解闸、不许抬 `ready`；
    ///    断开之后发起的显式重连拿到的是新代次，正常放行。
    ///
    /// 设备侧任务若已经建起来，清理结果未知，按 orphaned 记，不装作干净。
    public func disconnect() async {
        if let machine = activeMachine {
            machine.forceTerminal(machine.state.holdsRemoteTask ? .orphaned : .cancelled)
            lastSessionTrail = machine.trail; lastSessionRejected = machine.rejected
            // 恰一次取消终态。`activeEmitQueryID` 必须与该查询一致：否则
            // 这条通道属于一次已被取代的旧查询，发出去只会污染新查询的界面。
            if let emit = activeEmit, activeEmitQueryID == machine.session.queryID {
                emit(ProviderEvent(queryID: machine.session.queryID, sourceID: source.id,
                                   state: .cancelled,
                                   message: "\(config.displayName)：已断开，本次搜索已取消"))
            }
        }
        activeMachine = nil
        activeEmit = nil; activeEmitQueryID = nil
        sessionEpoch &+= 1
        sessionClosed = true
        ready = false; discovered = false; availableShares = []
        _ = try? await bridge.command("disconnect", sourceID: source.id)
    }

    // MARK: - 搜索

    /// 这次查询的**迟到元数据补发**还该不该被放行。
    ///
    /// 两个合法窗口：
    /// 1. 它还是当前查询（`activeMachine` 就是它）；
    /// 2. 它刚刚结束、且还没有新查询接手（`completedQueryID == queryID`）。
    ///
    /// 为什么必须有第 2 条：搜索正常结束会把 `activeMachine` 摘掉（否则会挡住
    /// 下一个调用方），而「结果行能不能直接打开」是搜索返回**之后**才补发的。
    /// 只按第 1 条判，NAS 结果就会永远停在「不可打开」。
    ///
    /// 不带 `private` 是给测试留的观察点：这条窗口没有别的外部可观察效果
    /// （要等真实的挂载解析），只能直接锁边界。
    func acceptsLateMetadata(for queryID: UUID) -> Bool {
        if active == queryID { return true }
        return completedQueryID == queryID
    }

    public func cancel(queryID: UUID) {
        guard let machine = activeMachine, machine.session.queryID == queryID else { return }
        // 取消发生在设备任务已建之后 ⇒ 记 orphaned（不知道设备侧有没有清掉），
        // 记成 cancelled 会让这类遗留永远不出现在诊断里。
        let alreadyTerminal = machine.isTerminal
        machine.forceTerminal(machine.state.holdsRemoteTask ? .orphaned : .cancelled)
        lastSessionTrail = machine.trail; lastSessionRejected = machine.rejected
        // ★ 补发恰好一次取消终态（与 `disconnect()` 同一条纪律）。
        // 只摘状态机不报终态的话，`search()` 后续分支全被 `guard active == queryID`
        // 挡住，上层 `SearchCompletionTracker` 会把这个来源一直记在 pending 里，
        // 界面永久「正在搜索」。`alreadyTerminal` 防的是「完成之后又被取消一遍」。
        if !alreadyTerminal, let emit = activeEmit, activeEmitQueryID == queryID {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .cancelled))
        }
        activeMachine = nil
        activeEmit = nil; activeEmitQueryID = nil
        Task { _ = try? await bridge.command("cancel", sourceID: source.id, queryID: queryID.uuidString) }
    }

    /// 带发起方的搜索入口（P3）。
    ///
    /// **跨 owner 并发时拒绝，不取消对方。** 正常情况下 `SearchScheduler` 已经
    /// 按来源排好队，不会出现两个 owner 同时进来；走到这里说明调度层被绕过了
    /// （或有人新增了调用路径没走调度器）。此时正确的反应是**保护正在跑的那一个**：
    /// 取消它会让 GUI 或某个 Agent 的搜索突然消失，而它们什么都没做错。
    /// 所以这里回一个明确的失败，并在 stderr 留一行——这是不变量违规，不是业务错误。
    public func search(_ text: String, queryID: UUID, owner: SearchOwner,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        await search(text, queryID: queryID, owner: owner, rootLimit: nil, emit: emit)
    }

    /// 带位置限定的搜索入口。
    ///
    /// ★ 这一条**必须**是协议要求并由本类覆写：走 `any SearchProvider` 调用时，
    /// 非要求的扩展方法走静态派发，这里的实现根本不会被调用 ——
    /// 编译期毫无提示，运行时表现为「界面显示限定在照片，设备却仍在扫全部共享」。
    ///
    /// ★ `rootLimit` 只在**属于自己**时才应用：一次搜索可能同时打多个来源
    /// （不限位置时），限定只对那一个来源生效，其余照旧按各自授权范围搜。
    public func search(_ text: String, queryID: UUID, owner: SearchOwner,
                       rootLimit: SearchRootLimit?,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        if let running = activeMachine, running.session.queryID != queryID, activeOwner != owner {
            FileHandle.standardError.write(Data(
                "[nasuser] owner-invariant-violation source=\(source.id) running=\(activeOwner.label) incoming=\(owner.label)\n".utf8))
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                               message: "\(config.displayName)：这个来源正在被另一个调用方搜索，请稍后重试"))
            return
        }
        pendingOwner = owner
        defer { pendingOwner = nil }
        // ★ 只有「限定说的就是这一个来源」时才把限定带下去。
        //
        // 限定里的根还必须与**本来源已授权的根**有交集：Swift 侧已经查过一遍，
        // 这里再查一次是因为客户端与核心之间还隔着协议这一层 ——
        // 两道门比一道门可靠（Dart 侧还有第三道）。
        let effectiveRoots: [String]? = {
            guard let limit = rootLimit, limit.sourceID == source.id else { return nil }
            let granted = Set(config.scopes)
            let usable = limit.roots.filter { granted.contains($0) }
            return usable.isEmpty ? nil : usable
        }()
        await search(text, queryID: queryID, rootLimit: effectiveRoots.map { SearchRootLimit(sourceID: source.id, roots: $0) }, emit: emit)
    }

    /// 结果是否落在已授权的共享之下。多位置时任一命中即可。
    nonisolated private var isInScope: Bool { locatorSnapshot.contains(path: nil) }

    /// 尝试自动恢复（P1-03）：核心重启后把这台 NAS 重新连上，用户无需动手。
    ///
    /// 重放顺序必须与手工连接一致：discover → login → 重新绑定此前选好的范围。
    /// 凭据由注入方提供，本类型不持有密码。
    ///
    /// ★ 第一步必须先把 `discovered` 清掉：`discover()` 在 `discovered == true`
    /// 时会直接返回而不真正发请求，而**新核心进程里根本没有这个 source** ——
    /// 不清就等于跳过握手，后面的 login 必然失败。
    private func attemptAutoReconnect() async -> Bool {
        // 用户已经断开这台 NAS ⇒ 任何自动恢复都必须停手：
        // 恢复成功只会把用户刚刚断开的来源重新变成在线。
        guard !sessionClosed else { return false }
        guard let autoReconnect else { return false }
        if let last = lastAutoReconnectAt, now().timeIntervalSince(last) < Self.autoReconnectCooldown { return false }
        ready = false; discovered = false; availableShares = []
        lastAutoReconnectAt = now()
        autoReconnectCount += 1
        // ★ 记下本次恢复的代次。`disconnect()` 会推进它 —— 那就说明这次恢复
        // 在飞期间用户断开了，钩子留下的登录态一律作废。
        let epoch = sessionEpoch
        autoReconnectInFlight = true
        let recovered = await autoReconnect(self)
        autoReconnectInFlight = false
        // 在飞期间用户断开了这台 NAS（或用别的方式作废了这次恢复）⇒ 过期：
        // 登录态必须一并清掉，不许把刚断开的来源复活成在线。
        if sessionClosed || sessionEpoch != epoch {
            sessionClosed = true
            ready = false; discovered = false; availableShares = []
            return false
        }
        if recovered {
            // ★ 就绪在这里**才**提交。重连期间 `markReadyOnCurrentCore` 一律不抬
            // ready —— 否则「重连进行到一半被断开」的那段窗口里，界面显示的是已连接。
            ready = true
            connectedGeneration = bridge.processGeneration
            // 一次成功恢复不该让这台设备继续背着核心重启前的失败次数被限流。
            failures = 0; degradedUntil = nil; malformedSeen = false
        }
        return recovered
    }

    public func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        await search(text, queryID: queryID, rootLimit: nil, emit: emit)
    }

    /// 搜索主实现。
    ///
    /// - Parameter rootLimit: 本次搜索限定在哪些根里。`nil` = 按本来源
    ///   已授权的全部根搜（从前就是这个行为）。非 nil 时**只**把限定后的根
    ///   下发给设备 —— 少一个根就少一次设备侧扫描，检索时间因此真的下降。
    public func search(_ text: String, queryID: UUID, rootLimit: SearchRootLimit?,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        guard NASQueryPolicy.accepted(text) else {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .blocked,
                               message: "继续输入以搜索 \(config.displayName)"))
            return
        }
        // 「名称 + 格式」：`测试报告 ppt` 里的 ppt 不是名字的一部分，
        // 而是**格式限制**。名字关键词照旧发 pattern，格式单独走 extensions。
        let parsed = SearchQueryParser.parse(text)
        // 只给了格式、没给名字时，设备侧需要一个「全部」的名字模式。
        // 空 pattern 在 DSM 上的语义从未真机验证过，`*` 与 File Station 网页版一致。
        let pattern = parsed.keywords.isEmpty && parsed.hasFormatFilter ? "*" : parsed.keywords
        // ★ 核心重启过 ⇒ 这次「已连接」是假的。
        // P1-03：先试着自己恢复（discover → login → 重新绑定范围），
        // 恢复成功就继续这次搜索，用户不需要手动重连；恢复不了才如实报。
        if needsReconnectAfterCoreRestart {
            if await attemptAutoReconnect() {
                // 重连在飞期间用户断开了这台 NAS ⇒ 那个「成功」已经过期，
                // 不许据此继续搜索、更不许发连接恢复事件。
                guard !sessionClosed else {
                    emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                                       message: "\(config.displayName) 已断开"))
                    return
                }
                onConnectionEvent?(["event": "coreRestartedAutoRecovered", "sourceID": source.id])
            } else {
                // 没恢复成 ⇒ 这个「已连接」是假的，必须复位，不许继续显示已连接。
                ready = false; discovered = false; availableShares = []
                connectedGeneration = bridge.processGeneration
                onConnectionEvent?(["event": "coreRestarted", "sourceID": source.id])
                emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                                   message: "搜索核心已重启，\(config.displayName) 需要重新连接"))
                return
            }
        }
        // sessionClosed 在这里拦两件事：断开之后发起的新搜索（不许搜一台已断开的
        // NAS），以及断开瞬间在飞的重连/登录把 ready 抬回去后的继续执行。
        guard ready, !config.scope.isEmpty, !sessionClosed else {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                               message: sessionClosed ? "\(config.displayName) 已断开" : "\(config.displayName) 尚未连接"))
            return
        }
        if let until = degradedUntil, until > now() {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .degraded, message: "\(config.displayName) 暂时不可用，请稍后重试")); return
        }
        if degradedUntil != nil && retryInFlight {
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .degraded, message: "正在等待 \(config.displayName) 重试完成")); return
        }
        // 同一来源只保留一个活跃任务：新查询先取消旧的，避免两个 Search Task 互相 stop/clean。
        // ★ 只对**同一 owner** 成立。跨 owner 的取消会表现为「用户搜着搜着结果没了」
        // 或「Agent 突然拿到 cancelled」，而且重试一次就好，极难复现（P3）。
        if let running = activeMachine, running.session.queryID != queryID,
           activeOwner == (pendingOwner ?? .ui) {
            let superseded = running.session.queryID
            // 被取代的那次是**被打断**的：设备侧任务若已建起来，就记 orphaned，
            // 不能装作正常结束——否则「打断遗留的任务」在诊断里永远看不见。
            running.forceTerminal(running.state.holdsRemoteTask ? .orphaned : .cancelled)
            lastSessionTrail = running.trail; lastSessionRejected = running.rejected
            cancel(queryID: superseded)
            emit(ProviderEvent(queryID: superseded, sourceID: source.id, state: .cancelled, message: "已被新搜索取代"))
        }
        let machine = SearchSessionMachine(session: SearchSession(queryID: queryID, sourceID: source.id,
                                                                 attempt: 1 + autoReconnectCount))
        activeMachine = machine
        activeOwner = pendingOwner ?? .ui
        // 新查询一开始，上一次的迟到补发窗口就关了（见 `completedQueryID` 的说明）。
        completedQueryID = nil
        // 记下这条 emit 通道：断开时靠它补发取消终态（见 `disconnect()`）。
        activeEmit = emit; activeEmitQueryID = queryID
        retryInFlight = true
        machine.transition(to: .starting)
        defer {
            retryInFlight = false
            // 走到这里仍未终结 ⇒ 这是一次异常退出（取消 / guard 失败 / 提前 return）。
            // 若设备侧任务已经建起来，必须记 orphaned：「不知道清没清掉」
            // 绝不能记成 finished，否则泄漏永远不会出现在诊断里。
            if !machine.isTerminal {
                machine.forceTerminal(machine.state.holdsRemoteTask ? .orphaned : .failed)
            }
            lastSessionTrail = machine.trail
            lastSessionRejected = machine.rejected
            // ★ **释放槽位**：只置终态不摘状态机，下一个换 owner 的调用方就会撞上
            //   「这个来源正在被另一个调用方搜索」，而这时设备侧其实早就空了。
            //   用 `===` 而不是比 queryID：本次可能已被新查询取代，那时
            //   `activeMachine` 已经是新查询的，绝不能顺手摘掉。
            if activeMachine === machine {
                activeMachine = nil
                // 留给「结果行可打开」的迟到补发（解析挂载路径最多 3 秒）。
                completedQueryID = queryID
            }
            // 只清**属于这次查询**的那条通道：本次搜索已被新查询取代时，
            // `activeEmit` 已经是新查询的，不能顺手清掉。
            if activeEmitQueryID == queryID { activeEmit = nil; activeEmitQueryID = nil }
        }
        emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
        var count = 0
        var terminalState: ProviderSearchState?
        var terminalIncomplete = false
        do {
            // ⚠️ 这里**没有** `extensions` 字段：核心（Dart）目前不消费它，
            // 格式过滤在下面客户端侧完成。等核心能重编并真的把格式下推给 DSM
            // 时，再把字段加回来（同时要升协议修订号）——在那之前发一个没人读的
            // 字段，只会让「到底有没有下推」变成一笔糊涂账。
            //
            // ★ `roots` 是**可选**字段：只有真正限定了位置才发。
            // 不限定时一个字都不发，行为与从前逐字节一致 ——
            // 这样「没限定」与「限定」在协议上是两种可区分的状态，
            // 而不是靠「发了个空的 roots」来表达。
            var fields: [String: Any] = ["query": pattern, "queryBudgetMs": queryBudgetMs]
            if let rootLimit, !rootLimit.roots.isEmpty {
                fields["roots"] = rootLimit.roots
            }
            let response = try await bridge.command("search", sourceID: source.id, queryID: queryID.uuidString,
                                                    fields: fields) { [weak self] message in
                guard let self, self.active == queryID, message["queryID"] as? String == queryID.uuidString,
                      message["sourceID"] as? String == self.source.id, message["event"] as? String == "batch" else { return }
                let rows = (message["files"] as? [[String: Any]] ?? []).compactMap { self.result($0, query: parsed.keywords) }
                    // 兜底过滤：**不是所有品牌都能把格式下推给设备**
                    // （只有群晖的 Search API 有 extension 参数）。设备已经过滤过
                    // 时这一步是幂等的；设备没过滤时，它保证结果仍然是对的。
                    .filter { parsed.matches($0.name) }
                count += rows.count
                // 收到第一批结果 = 设备任务已经在跑。此后异常退出必须记 orphaned。
                self.activeMachine?.transition(to: .fetching)
                emit(ProviderEvent(queryID: queryID, sourceID: self.source.id, results: rows, state: .searching))
                // 精确文件定位（挂载发现 + 路径边界校验 + 存在性）可能阻塞在 SMB 上，
                // 因此放到后台：既不拖慢 UI，也不拖慢本地查询。
                //
                // 「挂载候选每次查询只解析一次」的前提是**核心按批发布**：
                // 每批只起一个后台任务、只读一次挂载表。核心曾经一文件发一个 batch，
                // 于是这里实际退化成了「一文件读一次挂载表」——结果上千条时
                // 会派发几百个后台任务、扫描几百次挂载表。
                // 改动任何一侧时必须同时确认另一侧仍是批量的。
                //
                // canOpen 的含义是「此刻能定位」，因此只用已存在的挂载，
                // 不在这里触发挂载——否则每来一批结果就挂一次共享。
                // 没挂载时保持 canOpen=false：点「打开」会走挂载流程。
                Task { [weak self] in
                    guard let self else { return }
                    // ★ 这个来源压根没有 SMB 这一路（OpenList）：连挂载表都不读。
                    //   放在最外层是**成本**考虑——读一次挂载表要 `getmntinfo` 加一遍
                    //   statfs 解析，而这类来源的每批结果都会走这里。
                    // 取值必须在这层拿：`self.config` 是 MainActor 隔离的，
                    // 进了下面的 detached 任务就变成一次 async 访问。
                    let exposesSMB = self.config.vendor.exposesSMBShares
                    guard exposesSMB else { return }
                    let resolved = await Task.detached(priority: .utility) { [self] () -> [SearchResult] in
                        let candidates = self.mountCandidates()
                        guard !candidates.isEmpty else { return [] }
                        return Self.localizedRows(rows, mounts: candidates,
                                                  exposesSMBShares: exposesSMB,
                                                  resolve: { try self.resolve($0, in: candidates) })
                    }.value
                    guard self.acceptsLateMetadata(for: queryID), !resolved.isEmpty else { return }
                    emit(ProviderEvent(queryID: queryID, sourceID: self.source.id, results: resolved,
                                       state: terminalState ?? .searching,
                                       resultsIncomplete: terminalIncomplete,
                                       isMetadataUpdate: true))
                }
            }
            guard active == queryID, !Task.isCancelled else { return }
            // 核心已返回 ⇒ 它在内部走了 stop/clean，这里同步走到 cleaning 窗口。
            machine.transition(to: .stopping)
            machine.transition(to: .cleaning)
            let rawState = response["resultState"] as? String
            let state = ProviderSearchState.fromCore(rawState)
            terminalState = state
            // 核心的 `isComplete` 说的是「结果收全了吗」，与本事件是否终态无关：
            // 收全 → 未截断；没明说 → 按收全处理（只有明确 false 才算截断）。
            terminalIncomplete = (response["isComplete"] as? Bool) == false
            let errorBody = response["error"] as? [String: Any]
            let error = errorBody?["kind"] as? String
            let apiCode = (errorBody?["apiCode"] as? NSNumber)?.intValue
            // 核心写好的那句话（品牌适配器给的原因）。有了它就不必按 kind 猜 ——
            // 同一个 kind 底下可能是「密码错」，也可能是「协议/端口不对」。
            let reason = errorBody?["reason"] as? String
            // ★ 核心为「部分搜索位置没搜通」写的那句话（`partialNote`）。
            //
            // 这种情况下 `resultState` 仍是 `completed`（那部分结果确实有效），
            // 于是 `failureMessage` 返回 nil —— 若不在这里把这句话接上，
            // 界面只会显示「没有找到」，而真相是**有一个位置压根没搜**。
            let partialNote = response["partialNote"] as? String
            let failedRoots = response["failedRoots"] as? [String] ?? []
            switch state {
            case .timedOut:
                failures += 1; degradedUntil = now().addingTimeInterval(15)
            case .needsAuth:
                // 设备侧的会话已经失效。这是**连接**问题，不是搜索问题：
                // 不把 ready 清掉，下一次搜索就会拿着一个已知无效的会话再撞一次，
                // 而界面只会继续说 "failed"。
                ready = false
                failures += 1
                if failures >= 2 { degradedUntil = now().addingTimeInterval(15) }
            case .failed:
                failures += 1; malformedSeen = malformedSeen || error == "ProtocolViolation" || error == "DirectoryUnstable"
                if failures >= 2 || malformedSeen { degradedUntil = now().addingTimeInterval(15) }
            case .completed:
                if count == 0 && malformedSeen && failures > 0 {
                    degradedUntil = now().addingTimeInterval(15)
                    // 结果已发布，完整性存疑，但没有任务泄漏的证据 ⇒ 记 finished，
                    // 由界面上的 degraded 提示承担「待复核」的含义。
                    machine.forceTerminal(.finished)
                    emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .degraded, message: "此前 API 异常后出现空结果，完整性待复核")); return
                }
                failures = 0; degradedUntil = nil; malformedSeen = false
            case .truncated, .limitedTraversal:
                // 都拿到了可用结果，只是不完整。**不能算失败**：
                // 否则连续两次「结果偏多」就会把来源打成「暂时不可用」，
                // 把正常查词也一并拦掉。
                failures = 0; degradedUntil = nil; malformedSeen = false
            case .deviceBusy:
                // 设备没把结果算出来（`finished` 有、`total` 没有）。
                // 这**要计入失败**，理由不是为了"惩罚"设备，而是为了**刹车**：
                // 记录过连续搜索会触发设备侧数分钟的退化窗口，
                // 而快速重试只会往这个窗口里继续丢新任务。
                // 连续两次未就绪就暂停 15 秒，让设备把内部资源放掉。
                // 提示文案必须说清是「设备没准备好」而不是「搜索失败」。
                failures += 1
                if failures >= 2 { degradedUntil = now().addingTimeInterval(15) }
            case .cancelled, .searching, .degraded, .blocked:
                break
            }
            if error == "NeedsAuth" || error == "SessionExpired" { ready = false }
            let cleanupState = response["cleanupState"] as? String
            // 终结态只看两件事：界面状态，以及设备侧任务有没有真的清掉。
            // cleanup 没成功 ⇒ orphaned，即使结果全部拿到了 —— 这是泄漏，不是成功。
            machine.forceTerminal(SearchSessionState.terminal(providerState: state, cleanupState: cleanupState))
            let unparsed = (response["unparsedCount"] as? NSNumber)?.intValue ?? 0
            let duplicates = (response["duplicateCount"] as? NSNumber)?.intValue ?? 0
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: state,
                               message: failureMessage(state: state, kind: error, apiCode: apiCode, reason: reason)
                                        ?? partialNote
                                        ?? skippedNote(unparsed: unparsed, duplicates: duplicates),
                               resultsIncomplete: terminalIncomplete || !failedRoots.isEmpty,
                               reportedTotal: response["reportedTotal"] as? Int,
                               cleanupState: cleanupState))
        } catch {
            guard active == queryID else { return }
            // 传输层出错时设备侧任务大概率已经建起来了 ⇒ orphaned 而非 failed：
            // 前者会让人去看设备上的遗留任务，后者会让人以为是登录/参数问题。
            machine.forceTerminal(machine.state.holdsRemoteTask ? .orphaned : .failed)
            failures += 1
            if failures >= 2 { degradedUntil = now().addingTimeInterval(15) }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                               message: "\(config.displayName)：搜索没有完成——\(error.localizedDescription)"))
        }
    }

    /// 把状态与核心错因拼成一句用户能读懂、并能据此行动的话。
    ///
    /// `completed` 返回 nil（正常结束不需要提示）。其余每个状态都必须给出
    /// 「发生了什么」，`failed` 还要带上核心的 kind 与设备错误码——
    /// 否则界面又回到只显示一个 "failed" 的状态，等于没有信息。
    func failureMessage(state: ProviderSearchState, kind: String?, apiCode: Int?, reason: String? = nil) -> String? {
        switch state {
        case .completed, .searching: return nil
        case .cancelled: return "\(config.displayName)：搜索已取消"
        case .truncated: return "\(config.displayName)：结果超过上限，只显示了前一部分；把搜索词写得更具体可以看全"
        case .limitedTraversal: return "\(config.displayName)：该设备没有服务端搜索，已改为逐层查找（较慢，可能不完整）"
        case .needsAuth: return "\(config.displayName)：登录已过期，请在「搜索来源」里重新连接后再搜"
        case .timedOut: return "\(config.displayName)：搜索超时（超过 \(queryBudgetMs / 1000) 秒）；可在设置里调大「NAS 搜索等待上限」"
        case .degraded: return "\(config.displayName)：暂时不可用，请稍后重试"
        case .blocked: return "继续输入以搜索 \(config.displayName)"
        case .deviceBusy:
            // 关键：**不能说成「搜索失败」**，更不能让用户以为设备上没这些文件。
            // 事实是设备报了 finished 却没有 total —— 它还没把结果算出来。
            return "\(config.displayName)：设备暂时没有给出结果（搜索服务未就绪，短时间内连续搜索后常见）。请等十几秒再搜一次。"
        case .failed:
            return "\(config.displayName)：搜索失败——\(NASSearchFailureText.describe(kind: kind, apiCode: apiCode, reason: reason))"
        }
    }

    /// 有结果行被跳过、或被合并时的如实告知。
    ///
    /// 静默丢行会让用户以为「设备上就是没有这些文件」，而这恰恰是出问题时
    /// 最需要被看见的数字。完成状态下 `failureMessage` 返回 nil，所以这个提示
    /// 只在真的跳过了行、或真的合并过重复行时才会出现。
    ///
    /// 两类分开说：
    ///   * `unparsed` —— 设备给了行、我们看不懂（字段形态超出预期）；
    ///   * `duplicates` —— 设备把同一条结果给重了（DSM 的 `Search.list` 不保证
    ///     返回集合严格唯一，实测第一页内部就会出现重复 path）。
    /// 处置完全不同，混成一句话会让下一次排查无从下手。
    func skippedNote(unparsed: Int, duplicates: Int) -> String? {
        var parts: [String] = []
        if unparsed > 0 { parts.append("有 \(unparsed) 条结果因格式异常被跳过") }
        if duplicates > 0 { parts.append("有 \(duplicates) 条重复的结果已合并") }
        guard !parts.isEmpty else { return nil }
        return "\(config.displayName)：\(parts.joined(separator: "；"))（其余结果不受影响）"
    }

    // MARK: - 结果解析与定位

    /// 本来源的网页 origin（协议 + 主机 + 实际连接端口）。
    ///
    /// 协议取**实际连接用的那个**（`config.usesPlainHTTP`），端口取 `resolvedPort`
    /// （连接时真正用的端口，不是配置里那个可能为 0 的原始字段）。
    /// 校验必须对着「这条连接实际连到哪」比，而不是对着用户当时在地址栏里的写法比——
    /// 两者在「端口写进地址栏」「按品牌默认协议」这些情形下并不相同。
    var webOrigin: WebOrigin? {
        WebOrigin(scheme: config.usesPlainHTTP ? "http" : "https",
                  host: config.hostName, port: resolvedPort)
    }

    public func result(_ m: [String: Any], query: String = "", now: Date = Date()) -> SearchResult? {
        guard let path = m["path"] as? String, locatorSnapshot.contains(path: path),
              let name = m["name"] as? String, let id = m["id"] as? String,
              m["sourceID"] as? String == source.id else { return nil }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !parts.dropFirst().contains(where: { $0.isEmpty || $0 == "." || $0 == ".." || $0 == "@eaDir" || $0 == "#recycle" || $0 == "@Recycle" }),
              !path.contains("\0") else { return nil }
        var row = SearchResult(id: id, name: name, relativePath: path, sourceID: source.id,
                               sourceName: source.displayName,
                               kind: m["fileType"] as? String == "folder" ? "directory" : "file",
                               size: (m["size"] as? NSNumber)?.int64Value, localURL: nil)
        row.fileType = m["fileType"] as? String ?? "file"
        row.sourceType = .nas; row.isOnline = true
        // ★ 时间戳走 `DeviceTimestamp`，**不许**在这里新建 `ISO8601DateFormatter`：
        //   这个函数是**一行一次**调用的，而且整段跑在主线程上。每行新建一个
        //   formatter 实测要 261 ms / 2000 行（见 `DeviceTimestamp` 里的表），
        //   表现就是「搜到的东西一多，界面先卡半秒」。
        if let date = m["modifiedDate"] as? String {
            row.modifiedDate = DeviceTimestamp.parse(date)
        }
        // ★ rank 与综合分**一起**算，且必须在 `modifiedDate` 之后：
        //   同一份 `SearchMatch` 结果既给档位又给分值，两处各算一遍的话
        //   （旧写法是 rank 一个函数、时间一个字段）会出现「排序用的分数
        //   和界面上标的档位不是同一个口径」。归一化也只做一次。
        let evaluation = SearchMatch.evaluate(name: name, path: path, query: query)
        row.rank = evaluation.grade.legacyRank
        row.score = SearchRanking.score(match: evaluation.value, modified: row.modifiedDate, now: now)
        // openTarget 来自 Dart 侧。SMB 行的校验分两档：
        // · 常规品牌（群晖等）：share 必须在本来源已授权共享集合里；
        // · fnOS：共享名是核心用 file.share.list/info 映射出来的设备事实，
        //   不在授权 scopes 集合里（那是卷根）；host 一致 + 共享名非空即可。
        if let target = m["openTarget"] as? [String: Any], target["kind"] as? String == "smbLocation",
           target["host"] as? String == config.hostName,
           let share = target["share"] as? String, !share.isEmpty,
           let segments = target["relativeSegments"] as? [String],
           locatorSnapshot.smbSharesFromDevice || locatorSnapshot.shares.contains(share) {
            var c = URLComponents()
            c.scheme = "smb"; c.host = config.hostName
            c.path = "/" + share + "/" + segments.joined(separator: "/")
            if let url = c.url { row.openTarget = .smbLocation(url) }
        }
        // 网页打开目标（OL-OPEN）。这个 URL 会被 `NSWorkspace.open` **直接交给系统**，
        // 所以三条都要卡住，一条都不能省：
        //   ① 只接受 http/https —— 少这条，`file://` 或自定义 scheme 就能借结果行
        //      触发任意本地动作；
        //   ② 必须与本来源**同源**：协议、主机、有效端口三项全等 —— 只比主机会放行
        //      「同主机另一个端口上的别的服务」，也只比主机会让 HTTPS 来源的地址
        //      降到 HTTP（中间人随便看）。判定统一走 `WebOrigin`，见那边的说明；
        //   ③ 解码后的路径必须**逐字等于**这条结果的逻辑路径 —— 少这条，
        //      同一个主机上也能把「打开 /a.pdf」做成「打开 /b.pdf」。
        // 另外不许带查询串、片段或 user@ 凭据：网页地址里不该有任何秘密。
        //
        // fnOS 例外（仅第 ③ 条）：它的网页兜底是**站点首页**（桌面），飞牛
        // 没有能定位到文件的网页地址（`/app/*` 是 App 容器入口，要 ticket、
        // 且容器在 :5667；桌面 SPA 只认 uniqueDeviceId/theme/state 三个 query），
        // 天然不等于结果路径。地址由核心用已核验的 origin 拼出，①②④ 原样
        // 保留 —— 同源卡住「换主机」的口子，路径级那道卡对它没有意义。
        let pathEqualityRequired = !locatorSnapshot.smbSharesFromDevice
        if let target = m["openTarget"] as? [String: Any], target["kind"] as? String == "webLocation",
           let raw = target["url"] as? String, let url = URL(string: raw),
           let scheme = url.scheme?.lowercased(), scheme == "https" || scheme == "http",
           webOrigin?.admits(url) == true,
           url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
           !pathEqualityRequired || url.path == path {
            row.openTarget = .webURL(url)
            // 网页目标已经指向确切的路径，不需要先挂载再核对文件存在性。
            // `canOpen` 由 openTarget 决定，**不读** Dart 的 `canOpen` 字段：
            // SMB 行那边恒为 false（Dart 也看不到挂载状态），信它反而会误判。
            row.canOpen = true
        }
        return row
    }

    /// 后台元数据补全里**唯一**会改写结果行的那一步：给能靠挂载定位的行补本地路径。
    ///
    /// 抽成静态函数不是为了好看，是因为它连着出过一个真机级别的错，而那个错
    /// 在真实挂载表面前才显形、在测试里根本造不出来 —— 除非把「挂载候选」
    /// 作为参数传进来（测试可以用临时目录造出**真的能解析成功**的候选）。
    ///
    /// ## 两条不许松的规则
    ///
    /// 1. **已经拿到网页目标的行，一律不进 SMB 解析。**
    ///    OpenList 可以部署在任意一台主机上，包括「同一台同时也开着 SMB 的 NAS」。
    ///    那种情况下挂载表里会有一条 host、共享名都匹配的候选，`resolve` 会
    ///    真的解析出**另一个同路径文件**，然后把 `.webURL` 覆盖成 `.mountedFile`
    ///    并写上 `localURL`。用户看到的是结果自己变了，点开的是另一份内容 ——
    ///    没有共享挂载的本地模拟服务永远覆盖不到这一条。
    /// 2. **这个来源不通过 SMB 暴露文件时，一条都不许动。**
    ///    网页目标缺失或校验失败的行会停在 `.unavailable`；如果这时允许 SMB
    ///    兜底，它就变成「先挂上再说」，把「网页打不开」悄悄翻译成「挂载了个
    ///    不知道什么东西」。宁可让 `canOpen` 保持 false、由界面说清原因。
    ///
    /// - Parameters:
    ///   - rows: 本批结果。
    ///   - mounts: 已按本来源过滤过的挂载候选。
    ///   - exposesSMBShares: 来源是否走 SMB（见 `NASSourceConfig.Vendor.exposesSMBShares`）。
    ///   - deadline: 整批的解析预算（秒）。超出即停，不再补后面的行。
    ///   - resolve: 解析一条行的本地路径。用真实 `resolve(_:in:)` 或测试替身。
    /// - Returns: **被补上本地路径的行**（新的值），没补上的行不在返回里。
    nonisolated static func localizedRows(_ rows: [SearchResult],
                                          mounts: [SMBMountCandidate],
                                          exposesSMBShares: Bool,
                                          deadline: TimeInterval = 3,
                                          resolve: (SearchResult) throws -> URL) -> [SearchResult] {
        guard exposesSMBShares, !mounts.isEmpty else { return [] }
        let expiresAt = ProcessInfo.processInfo.systemUptime + deadline
        var checked = [SearchResult]()
        for var row in rows {
            if ProcessInfo.processInfo.systemUptime > expiresAt || Task.isCancelled { break }
            guard !row.hasWebOpenTarget else { continue }
            if let url = try? resolve(row) {
                row.localURL = url; row.openTarget = .mountedFile(url); row.canOpen = true
                checked.append(row)
            }
        }
        return checked
    }

    /// 本来源可用的 SMB 挂载候选。
    ///
    /// 判定只有一处：`SMBMountCandidate.matching`（主机精确优先，其次「共享名 + 登录账号
    /// 且只落在一台主机上」）。**不要在调用点自己写 `host ==` 过滤**——来源填域名、
    /// Finder 里用局域网 IP 挂是真实存在的组合（2026-10-29 报障），只比主机名会把它判成
    /// 「没挂载」，然后静默改用浏览器打开。
    ///
    /// 这些方法全部是 `nonisolated`：路径核验在后台线程执行，
    /// 只能读一份不可变的配置快照，不能碰 MainActor 上的 Provider 状态。
    nonisolated func mountCandidates() -> [SMBMountCandidate] {
        let snapshot = locatorSnapshot
        return SMBMountCandidate.matching(host: snapshot.host, shares: snapshot.shares,
                                          preferredUser: snapshot.preferredSMBUser,
                                          in: (try? SMBMountCandidate.discover()) ?? [])
    }

    /// 定位并返回可打开的本地 URL。
    ///
    /// 优先使用已存在的挂载；没有挂载时通过 `mountService` 发起后台挂载，
    /// 再解析一次。因此调用方需要 `await`——挂载可能耗时数秒。
    /// 下载一条结果到本机临时目录（fnOS 的 RemoteDownload，协议 9）。
    ///
    /// 核心侧负责：范围校验 → multiple-download 拿临时 token → GET 拉 zip
    /// → 解包到 `Directory.systemTemp`。这里只信任回包里的 `localPath`，
    /// 并且**落盘存在性必须复核**——核心说「解好了」不等于文件真在。
    ///
    /// static 是为了测试能注入替身桥：不用为一个下载动作起真进程。
    public nonisolated static func downloadRowToTemp(_ row: SearchResult,
                                              bridge: MyNASBridgeTransport,
                                              sourceID: String) async throws -> URL {
        let reply = try await bridge.command("download", sourceID: sourceID,
                                             fields: ["path": row.path])
        guard let local = reply["localPath"] as? String, !local.isEmpty,
              FileManager.default.fileExists(atPath: local) else {
            throw FlashFindError.message("从 NAS 下载文件没有成功，请稍后重试")
        }
        return URL(fileURLWithPath: local)
    }

    /// 445 端口是否可达。只回答「有没有 SMB 服务」，不做认证——
    /// 身份交给现有挂载链。1 秒超时；结果缓存 60 秒，避免连续打开
    /// 多个文件时每次都白等一轮（不可达时 1 秒 × N 次很难受）。
    nonisolated(unsafe) private static var reachabilityCache: (host: String, reachable: Bool, at: Date)?
    nonisolated static func smbPortReachable(host: String, timeout: TimeInterval = 1.0) async -> Bool {
        if let cache = reachabilityCache, cache.host == host,
           Date().timeIntervalSince(cache.at) < 60 {
            return cache.reachable
        }
        let reachable = await Task.detached(priority: .utility) { () -> Bool in
            var info: UnsafeMutablePointer<addrinfo>?
            guard getaddrinfo(host, "445", nil, &info) == 0, let first = info else { return false }
            defer { freeaddrinfo(info) }
            var current: UnsafeMutablePointer<addrinfo>? = first
            while let p = current {
                let sock = socket(p.pointee.ai_family, p.pointee.ai_socktype, p.pointee.ai_protocol)
                if sock >= 0 {
                    let flags = fcntl(sock, F_GETFL, 0)
                    _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
                    let result = connect(sock, p.pointee.ai_addr, p.pointee.ai_addrlen)
                    var ok = result == 0
                    if !ok, errno == EINPROGRESS {
                        var fds = pollfd(fd: sock, events: Int16(POLLOUT), revents: 0)
                        if poll(&fds, 1, Int32(timeout * 1000)) > 0 {
                            var err: Int32 = 0
                            var len = socklen_t(MemoryLayout<Int32>.size)
                            getsockopt(sock, SOL_SOCKET, SO_ERROR, &err, &len)
                            ok = err == 0
                        }
                    }
                    close(sock)
                    if ok { return true }
                }
                current = p.pointee.ai_next
            }
            return false
        }.value
        reachabilityCache = (host, reachable, Date())
        return reachable
    }

    /// 按**设备侧映射**的共享挂载并解析（fnOS）。与 `resolveAfterMount` 的差别：
    /// 共享名与相对路径直接取自结果行的 smbLocation（核心用
    /// `file.share.list`/`file.share.info` 映射），不走「卷根=共享名」的旧约定。
    nonisolated private static func mountDeviceShareResult(
        _ smb: URL, snapshot: NASLocator, service: SMBMountService) async throws -> URL {
        let parts = smb.path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count >= 2, let share = parts.first, !share.isEmpty else {
            throw FlashFindError.message("这条结果的共享位置无法解析")
        }
        let relative = parts.dropFirst().joined(separator: "/")
        let target = SMBMountService.Target(host: snapshot.host, share: String(share),
                                            username: snapshot.preferredSMBUser)
        let root = try await service.mount(target)
        let file = try await service.resolve(relativePath: relative, under: root)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw FlashFindError.message("文件可能已被移动或删除。")
        }
        return file
    }

    /// 这一行「点开之后去哪」，**保留目标类型**（2026-10-29 审查）：
    /// SMB 不可达时飞牛回退到网页文件管理器 —— 那是个网页地址，
    /// 不能包成 `.mountedFile` 冒充本地文件，否则「在访达中显示」
    /// 会拿浏览器地址当文件路径去碰 Finder。
    public func verifiedOpenTarget(_ row: SearchResult) async throws -> SearchOpenTarget {
        let snapshot = locatorSnapshot
        // 非 fnOS 品牌没有「回退网页」这一路：沿用本地文件口径。
        guard snapshot.smbSharesFromDevice else {
            return .mountedFile(try await verifiedFileURL(row))
        }
        try Self.validate(row: row, against: snapshot)
        // ★ 先认「本机已经挂着的共享」（2026-10-29 三线统一）：来源填域名、Finder 里用
        //   局域网 IP 挂着**同一个共享同一个账号**时，旧实现会照着域名再挂一次
        //   （公网下更慢，还可能弹系统认证框），而文件其实早就在 `/Volumes` 下可读。
        //   认亲规则与群晖同一处 `SMBMountCandidate.matching` —— 调用点不许自己写 `host ==`。
        let localMounts = (try? SMBMountCandidate.discover()) ?? []
        if let local = NASResultOpening.localMountedTarget(
            for: row, locator: snapshot, smbMounts: localMounts,
            // 走到这里必然是 fnOS（上面那道 guard 放行的）：它没有账号证据，
            // 网页出口只是站点首页，所以允许「只按共享名认」这一档。
            allowShareNameOnly: true) {
            return .mountedFile(local)
        }
        // ★ 第二条：设备侧共享表按**账号可见性**过滤（实测一台 14 个共享的机器只回 1 个），
        //   没覆盖这条路径时，退回「按本机挂载的共享名认」——判据见
        //   `mountedShareMatchingPathSegment`。不加这一条，共享表看不全的账号
        //   双击结果只能开飞牛登录页（2026-10-29 真机）。
        if let local = NASResultOpening.mountedShareMatchingPathSegment(for: row, smbMounts: localMounts) {
            return .mountedFile(local)
        }
        if case .smbLocation(let smb) = row.openTarget,
           await Self.smbPortReachable(host: snapshot.host) {
            guard let service = mountService else {
                throw FlashFindError.message("尚未配置 SMB 挂载服务，无法就地打开。可改用右键「下载后打开」。")
            }
            return .mountedFile(try await Self.mountDeviceShareResult(smb, snapshot: snapshot, service: service))
        }
        guard let web = webFileURL else {
            throw FlashFindError.message("这台 NAS 的文件共享（SMB）连不上，网页入口也没有拿到。请重新连接后再试，或用右键「下载后打开」。")
        }
        return .webURL(web)
    }

    public func verifiedFileURL(_ row: SearchResult) async throws -> URL {
        let snapshot = locatorSnapshot
        // fnOS 打开链（2026-10-29 用户定）：**SMB 可达走 SMB**（秒开、可编辑、
        // 不占下载流量），不可达开网页文件管理器；下载只是右键菜单里的显式动作，
        // 不再是默认打开方式。
        //
        // ★ 判定集中在 `verifiedOpenTarget`（它保留目标类型）；这里只负责
        //   解包本地目标 —— 网页目标到达这一层说明调用方明确要本地文件，
        //   如实说清「只能用浏览器打开」。
        if snapshot.smbSharesFromDevice {
            let target = try await verifiedOpenTarget(row)
            guard case let .mountedFile(url) = target else {
                throw FlashFindError.message("SMB 连不上，这个文件只能用浏览器打开；可改用右键「下载后打开」。")
            }
            return url
        }
        // ★ 这个来源**没有 SMB 这一路**（OpenList）：不许发现、更不许发起挂载。
        //   走到这里只有一种情形——这条结果的网页目标缺失或没通过同源校验
        //   （否则动作层在 `.webURL` 那一支就返回了）。这时正确的回答是
        //   「它在网页上，重新搜一次或直接打开网页」，而不是去挂一个
        //   和它没有关系的共享：那会弹系统连接窗口、最后打开一个同名文件。
        guard snapshot.exposesSMBShares else {
            throw FlashFindError.message("这个来源的文件在网页上（没有 SMB 共享可挂载）。请在结果上按 Return 用浏览器打开。")
        }
        // 安全校验必须在**挂载之前**完成：不属于本来源、或路径含穿越形态的结果，
        // 绝不能因为「先挂上再说」而去动用户的文件系统。
        try Self.validate(row: row, against: snapshot)
        let mounts = prioritized(SMBMountCandidate.matching(host: snapshot.host, shares: snapshot.shares,
                                                            preferredUser: snapshot.preferredSMBUser,
                                                            in: (try? SMBMountCandidate.discover()) ?? []),
                                 by: snapshot.preferredSMBUser)
        // 已挂载时直接解析，不必打扰用户。
        if let mounted = try? resolve(row, in: mounts, snapshot: snapshot) { return mounted }
        guard let service = mountService else {
            throw FlashFindError.message("尚未连接共享 \(snapshot.shares.sorted().joined(separator: "、"))。请先在 Finder 里连接，或在设置中挂载。")
        }
        return try await resolveAfterMount(row, snapshot: snapshot, service: service)
    }

    /// 授权范围与路径形态的静态校验。不涉及文件系统。
    private static func validate(row: SearchResult, against snapshot: NASLocator) throws {
        guard row.sourceID == snapshot.sourceID else { throw FlashFindError.message("目标不属于此来源") }
        guard !snapshot.scopePrefixes.isEmpty else { throw FlashFindError.message("尚未选择搜索位置") }
        // 落在**任一**已授权共享之下即可；否则连文件系统都不该碰。
        guard snapshot.contains(path: row.path) else { throw FlashFindError.message("目标不在授权共享") }
        let root = snapshot.owningRoot(path: row.path)!
        // 必须用 RelativePath.relative 剥掉根前缀后的那个前导斜杠：
        // `owningRoot` 返回的根以 "/" 开头，直接 dropFirst 会留下 "/…"，
        // 而 validate 拒绝前导斜杠 → 所有 NAS 文件都打不开。
        try RelativePath.validate(RelativePath.relative(row.path, under: root))
    }

    /// 挂载后重新解析。挂载动作可能耗时，必须异步。
    private func resolveAfterMount(_ row: SearchResult, snapshot: NASLocator, service: SMBMountService) async throws -> URL {
        // 挂载这条结果**实际所属**的共享，而不是「随便哪个」。
        guard let owningRoot = snapshot.owningRoot(path: row.path),
              let share = snapshot.owningShare(root: owningRoot) else {
            throw FlashFindError.message("目标不在授权共享")
        }
        let target = SMBMountService.Target(host: snapshot.host, share: share, username: snapshot.preferredSMBUser)
        let root = try await service.mount(target)
        // 同上：切掉授权根后要把残留的前导斜杠一并剥掉，否则 mount 侧会拒收。
        let inside = RelativePath.relative(row.path, under: owningRoot)
        let file = try await service.resolve(relativePath: inside, under: root)
        guard FileManager.default.fileExists(atPath: file.path) else {
            throw FlashFindError.message("文件可能已被移动或删除。")
        }
        return file
    }

    /// 非挂载态的定位入口（供结果行的 canOpen 判定使用，不触发挂载）。
    public nonisolated func verifiedFileURLWithoutMounting(_ row: SearchResult) throws -> URL {
        let snapshot = locatorSnapshot
        // fnOS：文件在设备上，打开要么走 SMB（可达时）、要么开浏览器；
        // 都不是「本机路径」，别把用户引去找一个不存在的本地文件。
        guard !snapshot.smbSharesFromDevice else {
            throw FlashFindError.message("这个来源的文件在 NAS 上：SMB 可达时双击就地打开，不可达时用浏览器打开；也可用右键「下载后打开」。")
        }
        // 与 `verifiedFileURL` 同一条理由：没有 SMB 的来源连挂载表都不该读。
        guard snapshot.exposesSMBShares else {
            throw FlashFindError.message("这个来源的文件在网页上，没有本地路径")
        }
        let mounts = prioritized(SMBMountCandidate.matching(host: snapshot.host, shares: snapshot.shares,
                                                            preferredUser: snapshot.preferredSMBUser,
                                                            in: (try? SMBMountCandidate.discover()) ?? []),
                                 by: snapshot.preferredSMBUser)
        return try resolve(row, in: mounts, snapshot: snapshot)
    }

    private nonisolated func prioritized(_ mounts: [SMBMountCandidate], by preferred: String?) -> [SMBMountCandidate] {
        guard let preferred, !preferred.isEmpty else { return mounts }
        return mounts.sorted { lhs, rhs in
            (lhs.username == preferred ? 0 : 1) < (rhs.username == preferred ? 0 : 1)
        }
    }

    public nonisolated func resolve(_ row: SearchResult, in mounts: [SMBMountCandidate], snapshot: NASLocator? = nil) throws -> URL {
        let locator = snapshot ?? locatorSnapshot
        guard row.sourceID == locator.sourceID, let root = locator.owningRoot(path: row.path) else {
            throw FlashFindError.message("目标不在授权共享")
        }
        // 相对段必须相对「这条结果所属的那个共享」算，多位置下不能用统一前缀。
        // 同样要剥掉 dropFirst 残留的前导斜杠。
        let inside = RelativePath.relative(row.path, under: root)
        try RelativePath.validate(inside)
        // ★ 「这台 NAS 的这个共享」只有 `matching` 一处判定。`mounts` 是调用方给的，
        //   可能是整张挂载表（直接调用点 / 测试），所以这里按同一规则再筛一次——
        //   判据重写一份的后果是「canOpen 说有、打开却说没有」这类前后矛盾。
        let share = locator.owningShare(root: root)
        let scoped = SMBMountCandidate.matching(host: locator.host,
                                                shares: Set([share].compactMap { $0 }),
                                                preferredUser: locator.preferredSMBUser,
                                                in: mounts)
        for mount in scoped {
            let mountRoot = mount.mountRoot.resolvingSymlinksInPath().standardizedFileURL
            let target = mountRoot.appendingPathComponent(inside).resolvingSymlinksInPath().standardizedFileURL
            if target.path.hasPrefix(mountRoot.path + "/"),
               FileManager.default.fileExists(atPath: target.path) { return target }
        }
        throw FlashFindError.message("未找到安全且存在的 SMB 文件，请先连接共享")
    }
}

