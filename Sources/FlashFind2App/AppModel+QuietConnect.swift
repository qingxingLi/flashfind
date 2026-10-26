import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「静默自动连接」分区（Stage 3A）。
//
// 启动后对所有「已启用 + 记住密码 + 本机有密码」的来源后台连接，不抢焦点、
// 不弹窗；失败只更新状态卡片上的说明。
//
// ★ 这一块真正的难点是**作废判定**（`quietConnectStillValid`）：连接是
// 「先建 Provider → discover → login → selectScopes → 最后才 install」的长流程，
// 用户在半路改了配置或点了断开，那条在飞的连接必须认账——否则它晚到的成功
// 照样会 install，于是刚断开的来源复活、其它来源在飞的查询被一起取消。
// 判据集中在 `SourceConnectIntent`，这里只负责在每一步之前问一次。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    /// 对所有「已启用 + 记住密码 + 本机有密码」的来源自动连接。
    ///
    /// 只在后台静默进行，不抢焦点、不弹窗；失败只更新状态卡片上的说明，
    /// 用户点开「管理…」时能看到原因并决定是否手动重连。
    func autoConnectSavedSources() {
        guard !AppEnvironment.isPreview else { return }
        let candidates = nasSources.filter {
            $0.enabled && $0.isConnectConfigured && $0.rememberPassword
        }
        guard !candidates.isEmpty else {
            // 没记住密码的来源要明确告诉用户「为什么还要手动连」。
            for source in nasSources where source.enabled && source.isConnectConfigured && !source.rememberPassword {
                setSourceStatus(source.id) {
                    $0.health = .offline
                    $0.message = "未保存密码，需要时手动连接一次"
                    $0.requiredAction = .login
                }
            }
            return
        }
        for source in candidates {
            guard let secret = SecureStorage.read(account: source.credentialAccount,
                                                   identity: source.credentialIdentity),
                  !secret.isEmpty else {
                // ★ 读不出来有两种完全相反的原因，说法不能混：
                //   - 尚未授权：等用户主动点击登录，再读取钥匙串；
                //   - 确实没存过：只能重连一次。
                // 一律说「本机没有保存密码」会让前一种用户白重输一遍密码，
                // 而重输完下次启动照样弹——他永远找不到真正的问题。
                let problem = CredentialStore.currentProblem
                setSourceStatus(source.id) {
                    $0.health = .needsAttention
                    $0.message = problem == .notAuthorized
                        ? "点击「登录」以使用已保存的密码，需要时系统会请求钥匙串授权"
                        : "本机没有保存密码，请连接一次"
                    $0.requiredAction = .login
                }
                continue
            }
            setSourceStatus(source.id) {
                $0.health = .connecting
                $0.message = "正在自动连接…"
                $0.requiredAction = nil
            }
            let credential = PendingCredential(password: secret, otp: nil)
            // 自动连接不占「当前草稿」——否则会把设置页正在编辑的内容冲掉。
            startQuietConnect(config: source, credential: credential)
        }
    }

    /// 静默连接：与 `performConnect` 同样的流程，但不写草稿、
    /// 且只有 `interactiveOTP == false` 时才真正「不弹任何东西」。
    ///
    /// 单独一份而不是给 `performConnect` 加开关——自动连接没有用户在场，
    /// 把草稿状态改来改去只会造成「设置页莫名其妙变了」。
    ///
    /// - Parameter interactiveOTP: 用户**自己点的登录**（而不是开机自动连接）。
    ///   为 true 时，设备要动态码就当场弹框问，码错了在同一个弹框里再问一次。
    func performConnectQuietly(config: NASSourceConfig, credential: PendingCredential,
                               interactiveOTP: Bool = false) async {
        guard sharedBridge != nil else { return }
        // ★ 登记本轮连接意图。之后**每一个 `await` 之后**都要用它复核：
        // 用户可能刚刚点了这台 NAS 的「断开」。过期连接不许 install、不许回写状态、
        // 更不许 invalidate —— 那一下会把其它来源在飞的查询一起取消。
        //
        // ★★ 意图**只登记一次**，放在重试循环之外（修）：
        // 若每轮重试都重新登记，用户在重试间隙点「断开」作废的只是某一轮，
        // 下一轮又会拿到一个「当前有效」的新意图 —— 断开被自己绕过去了，
        // 表现为「点了断开，过几秒它又自己连上了」。
        let token = connectIntent.begin(config)
        let runner = NASAutoConnectRunner()
        runner.stillValid = { [weak self] in self?.quietConnectStillValid(token) ?? false }
        runner.attempt = { [weak self] in
            guard let self else { return false }
            return try await self.quietConnectSteps(config: config, credential: credential, token: token)
        }
        runner.log = { [weak self] detail in
            self?.diagnostics.append(["at": ISO8601DateFormatter().string(from: Date()),
                                      "event": "autoConnect",
                                      "sourceID": config.sourceID,
                                      "detail": detail])
        }
        // 三种终态：连上（成功路径自己写好了状态）/ 已收尾（证书要确认、
        // 或意图在重试间隙被作废）/ 试满次数仍失败（要补一句失败原因）。
        switch await runner.run() {
        case .connected, .settled: return
        case let .failed(_, error):
            let otp = ConnectionFailureText.otpFailure(error)
            // ★ 用户主动点的登录：设备要码就**现在**问，别把答案留到下一次点击。
            //
            // 用户报障（2026-10-26）：「第一次输入提示需要输入动态码，但是不会自动
            // 弹出动态码，需要点击两次登陆，很反人类」。根因就是这里——第一次只是
            // 写一行「自动连接失败：设备要求两步验证码」，非要用户再点一次
            // 「登录」才走到 `reconnectSource` 里那条弹框分支。
            if interactiveOTP, let otp {
                await retryWithOTPUntilAnswered(config: config, password: credential.password,
                                                token: token, failure: otp)
                return
            }
            setSourceStatus(config.id) {
                $0.health = .needsAttention
                // 同上：走统一的连接失败文案，不裸拼 localizedDescription。
                $0.message = "自动连接失败："
                    + ConnectionFailureText.describe(error, host: config.hostName, port: config.effectivePort)
                // OTP 失败时不给「重试」按钮：重试还是 otp: nil，只会再失败一次。
                // 必须走「登录」按钮，让重新登录时弹 OTP 输入框。
                $0.requiredAction = otp == nil ? .retry : .login
                $0.needsOTP = otp != nil
                $0.otpRejected = otp == .rejected
            }
        }
    }

    /// 设备要动态码 → 当场问；码不对就**在同一个框里**再问，直到连上或用户取消。
    ///
    /// ## 为什么是循环而不是「失败后提示用户再点一次登录」
    ///
    /// 用户报障原文：
    ///
    ///   「输入 OTP 验证码错误，不会提示验证码错误，而是没有什么反应，
    ///     还是在外边提示需要动态码，需再次点击登陆。」
    ///
    /// 码错是**这一轮对话里就能解决的问题**：用户就在弹框前、验证器就在手上。
    /// 把它推回「再点一次登录」等于让用户重新走一遍他刚刚走完的路，
    /// 而且中间那句「需要动态码」会让他以为码根本没发出去。
    ///
    /// 循环只在拿到**非 OTP 失败**或用户取消时结束：前者是真问题，后者是用户的选择。
    private func retryWithOTPUntilAnswered(config: NASSourceConfig, password: String,
                                           token: SourceConnectIntent.Token,
                                           failure: OTPFailure) async {
        var failure = failure
        while true {
            // 用户可能在弹框前后点了「断开」：那条意图已经作废，不许再问、不许再连。
            guard quietConnectStillValid(token) else { return }
            let rejected = failure == .rejected
            setSourceStatus(config.id) {
                $0.health = .needsAttention
                $0.message = rejected
                    ? "动态码输入错误，请重新输入"
                    : "这台设备需要两步验证码，正在等待你输入"
                $0.requiredAction = .login
                $0.needsOTP = true
                $0.otpRejected = rejected
            }
            guard let code = await askForOTP(sourceName: config.displayName, failure: failure) else {
                // 取消：不写「失败」——失败的是「这次没填」，不是连接。
                // 但必须说清下次怎么把它叫回来（同一条事实不写在两处）。
                setSourceStatus(config.id) {
                    $0.health = .needsAttention
                    $0.message = ConnectionFailureText.otpRetryHint(buttonTitle: "登录")
                    $0.requiredAction = .login
                    $0.needsOTP = true
                    $0.otpRejected = rejected
                }
                return
            }
            guard quietConnectStillValid(token) else { return }
            setSourceStatus(config.id) {
                $0.health = .connecting
                $0.message = "正在用已保存的密码和动态码连接…"
                $0.requiredAction = nil
            }
            do {
                // 复用同一条连接流程：discover / 证书 / 读共享 / 绑范围 一处都不许少。
                // 返回 false 时它已经自己写明了状态（证书待确认 / 没有共享 / 意图作废），
                // 那种情况下再问码只是折磨用户，所以一律收手。
                _ = try await quietConnectSteps(
                    config: config,
                    credential: PendingCredential(password: password, otp: code),
                    token: token)
                return
            } catch {
                guard quietConnectStillValid(token) else { return }
                guard let next = ConnectionFailureText.otpFailure(error) else {
                    setSourceStatus(config.id) {
                        $0.health = .needsAttention
                        $0.message = "连接失败："
                            + ConnectionFailureText.describe(error, host: config.hostName,
                                                             port: config.effectivePort)
                        $0.requiredAction = .login
                        $0.needsOTP = false
                        $0.otpRejected = false
                    }
                    return
                }
                failure = next
            }
        }
    }

    /// 把模态弹窗挪出本次连接的 async 流程。
    ///
    /// `NSAlert.runModal` 会占住主线程跑自己的模态循环。直接在 `quietConnectSteps`
    /// 之后的流程里就地弹，会把「这次尝试彻底收尾」卡在半路——向导那条路踩过
    /// 同一个坑（见 `promptForOTPThenReconnect` 的注释），这里不重复。
    private func askForOTP(sourceName: String, failure: OTPFailure?) async -> String? {
        await withCheckedContinuation { continuation in
            Task { @MainActor in
                continuation.resume(returning: promptForOTP(sourceName: sourceName, failure: failure))
            }
        }
    }

    /// 一次静默连接的完整步骤（discover → login → 重新绑定范围）。
    ///
    /// 从 `performConnectQuietly` 里切出来的理由：开机自动连接现在会退避重试，
    /// 「重试」与「怎么连一次」必须是两件事 —— 否则每轮重试都要重复
    /// 登记意图、写状态、清闸门那一大段，任何一处漏改都是新缺陷。
    ///
    /// - Returns: 是否连上（false = 这条路径已经自己写明了状态，或意图已作废）。
    /// - Throws: 连接层/登录失败，由宿主的退避策略决定要不要再试。
    func quietConnectSteps(config: NASSourceConfig, credential: PendingCredential,
                                   token: SourceConnectIntent.Token) async throws -> Bool {
        guard let sharedBridge else { return false }
        await resetCoreSource(config.sourceID)
        guard quietConnectStillValid(token) else { return false }
        let provider = NASSearchProvider(bridge: sharedBridge, config: config, port: config.port)
        provider.queryBudgetMs = max(1, min(120, nativeSearchTimeoutSeconds)) * 1000
        provider.mountService = mountService
        attachAutoReconnect(provider)
        do {
            let discovered = try await provider.discover()
            guard quietConnectStillValid(token) else { return false }
            if discovered["candidate"] != nil {
                // 证书需要重新确认：把用户带到向导里，不要在后台替他决定。
                setSourceStatus(config.id) {
                    $0.health = .needsAttention
                    $0.message = "证书需要重新确认，请在来源详情里点「继续设置」"
                    $0.requiredAction = .continueSetup
                }
                return false
            }
            try await provider.login(account: config.username, password: credential.password, otp: credential.otp)
            guard quietConnectStillValid(token) else { return false }
            // 同样不用 `try?`：「读取失败」与「确实没有共享」必须分开。
            // 混在一起的话，用户会看到「该账号看不到任何共享目录」，
            // 跑去 NAS 上翻权限，而真正的问题在连接层。
            let shares: [String]
            do {
                shares = try await provider.loadShares()
            } catch {
                // 断开之后的失败不许再写状态卡片：来源卡片已经写着「已断开」，
                // 再被一条早于断开的失败覆盖回去，用户会以为断开没生效。
                guard quietConnectStillValid(token) else { return false }
                setSourceStatus(config.id) {
                    $0.health = .needsAttention
                    // ★ 不用 localizedDescription：核心错误的 errorDescription 返回的是
                    // kind（`TLSRejected` 之类），直接拼出来等于把内部状态抖给用户。
                    $0.message = "读取共享目录失败："
                        + ConnectionFailureText.describe(error, host: config.hostName, port: config.effectivePort)
                    $0.requiredAction = .continueSetup
                }
                return false
            }
            guard quietConnectStillValid(token) else { return false }
            // 沿用仍然有效的已保存位置；一个都没留时才退回「唯一共享」。
            var scopes = config.scopes.filter { shares.contains($0) }
            if scopes.isEmpty, shares.count == 1 { scopes = [shares[0]] }
            if !scopes.isEmpty { _ = try await provider.selectScopes(scopes) }
            guard quietConnectStillValid(token) else { return false }
            guard provider.ready else {
                setSourceStatus(config.id) {
                    $0.health = .needsAttention
                    $0.message = shares.isEmpty ? "该账号确实没有任何共享目录" : "请选择搜索位置"
                    $0.availableShares = shares
                    $0.requiredAction = .continueSetup
                }
                return false
            }
            var effective = config
            effective.scopes = scopes
            if let index = nasSources.firstIndex(where: { $0.id == effective.id }) {
                nasSources[index] = effective; persistSources()
            }
            // ★ 最后一道闸门，就差这一步就是 install（= 发布 Provider 变化 +
            // 上层整体重建协调器）。这里必须再确认一次：上面 `selectScopes`
            // 与写 `nasSources` 之间还有一次 `await`。
            guard quietConnectStillValid(token) else { return false }
            // ★ 已登录的实例必须**交给连接管理器**，不能只写界面字典（R02）。
            // 只写字典的话，下一次 rebuild 会用管理器自己那个从未登录的实例
            // 覆盖回来：核心里登录成功了，界面却显示未连接。
            nasConnectionManager.install(provider)
            setSourceStatus(effective.id) {
                $0.health = .ready
                $0.message = scopes.count == 1
                    ? "搜索位置：\(scopes[0])"
                    : "已选择 \(scopes.count) 个搜索位置"
                $0.requiredAction = nil
                // 连上了就把 OTP 标记清掉：不清的话用户下次点「重新登录…」
                // 还会被问一次动态码，而这次会话根本不需要。
                $0.needsOTP = false
                $0.otpRejected = false
                $0.selectedScope = scopes.joined(separator: "、")
                $0.availableShares = shares
                $0.discoveredPort = effective.port
            }
            // install 已经把新的 Provider 集合发布出去（含协调器重建），
            // 这里不要再 rebuild —— 那正是把已登录实例顶掉的动作。
            // 但 `invalidate()` 是全局的：只在确认这次连接仍然有效时才做。
            invalidate()
            // ★ 连上之后按当前查询重搜一次。
            //
            // 由来（2026-10-26）：位置面板不再按「已连接」过滤候选，于是
            // 「选一台还没连上的 NAS 的位置」会先连再搜。那条路径里位置限定
            // 早就设好了，用户不会为了触发搜索再去敲一个字 —— 不补这一下，
            // 表现就是「连上了，但列表还空着」。
            // 开机自动连接时 `query` 通常为空，`changedQuery` 会在第一行早退，
            // 不存在多搜一次的问题。
            changedQuery()
            return true
        } catch {
            // 断开之后迟到的失败：来源已经离线，把意图作废的事实交回宿主，
            // 由宿主决定「不写状态」还是「写失败」。
            guard quietConnectStillValid(token) else { return false }
            throw error
        }
    }
}
