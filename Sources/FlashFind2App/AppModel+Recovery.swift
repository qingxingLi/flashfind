import AppKit
import Network
import FlashFindCore

/// 自动登录恢复：启动解锁（A）、网络恢复补跑（B）、解锁后带起其余来源（C）。
///
/// 2026-11-13 报障：「闪寻的自动登陆老失败，比如切换/关闭网络的重新打开，
/// 设备开关机的重新登陆」。三个根因分别落在本文件的三段里：
/// - 冷启动只读进程内 `vaultCache`，新进程必空 ⇒ 所有来源落成「需要登录」；
/// - 开机那 120 秒重试完就不再看网络，断网回来无人补跑；
/// - 用户手动登录一台只解锁那一次，其余来源仍停在「需要登录」。
extension AppModel {

    // MARK: - A：启动期解锁

    /// 在 `applicationDidFinishLaunching` 里调，不放 `AppModel.init`：
    /// 授权框是系统窗口，App 还没起完、界面还没出现时弹出来会被压到别的 App 后面。
    func unlockCredentialsAndReplay() {
        guard !AppEnvironment.isPreview, credentialAccessAllowed else { return }
        // ★★ 纯新用户（没有「记住密码」的来源）根本不会走钥匙串：
        //   这就是「第一次打开不该弹密码框」的保证，别为了顺手去掉它。
        //   会弹框的其实是**升级后第一次启动**：ad-hoc 签名变了，钥匙串 ACL 失效，
        //   SecurityAgent 要求重新输入密码授权。
        let candidates = nasSources.filter {
            $0.enabled && $0.isConnectConfigured && $0.rememberPassword
        }
        guard !candidates.isEmpty else { return }
        if CredentialStore.vaultNeedsUnlock {
            unlockVaultWithFocusGuard()
        }
        lastRecoveryReplayAt = Date()
        replayPendingSources(reason: "startupUnlock")
    }

    /// 一次可能弹系统授权框的读，前后包住界面保护（1.1.71）。
    ///
    /// 两条独立路径都能让界面「消失」，都得靠这一段收口：
    /// ① 框弹出 ⇒ 失焦 ⇒ 全局点击监视补挂 ⇒ 用户点框里任何一处被判成点外部 ⇒ `hideSearch()`；
    /// ② 框关掉 ⇒ 系统把激活还给先前 App ⇒ `LSUIElement` 的闪寻不自己回前台 ⇒
    ///    整组窗口被压到后面（视觉上也是「界面没了」）。
    ///
    /// `primeVaultCache()` 刻意绕开 `read(allowInteraction:)`，所以 ② 里既有的
    /// `bringPreferencesForwardAfterSystemPrompt()` 不会被触发，必须在这里显式救。
    private func unlockVaultWithFocusGuard() {
        let before = searchPanelVisibilityBeforeSystemPrompt?() ?? .unknown
        // 先激活：系统授权框才会出现在闪寻界面上方，而不是别的 App 后面。
        NSApp.activate(ignoringOtherApps: true)
        _ = SystemPromptGuard.shared.around {
            CredentialStore.unlockVaultForStartup()
        }
        onSystemPromptFinished?(before)
    }

    // MARK: - C：解锁 / 交互读之后带起其余来源

    /// 用户手动登录一台之后，钥匙串已被解锁，其余来源不该还要逐台点一次。
    func replayAfterInteractiveRead() {
        guard !AppEnvironment.isPreview else { return }
        if let last = lastRecoveryReplayAt,
           Date().timeIntervalSince(last) < NetworkRecoveryPolicy.replayDebounce { return }
        lastRecoveryReplayAt = Date()
        replayPendingSources(reason: "interactiveUnlock")
    }

    /// ★ 刻意走**非交互**读：`reconnectUsingStoredCredential` 用的是
    /// `allowInteraction: true`，会再触发 `CredentialStore.onInteractiveRead`，
    /// 而那个回调又回来补跑 ⇒ 自己递归自己，且每台都会再弹一次授权框。
    /// 这里只读已解锁的缓存，配合 `startQuietConnect` 就能静默带起全部来源。
    func replayPendingSources(reason: String) {
        guard !AppEnvironment.isPreview else { return }
        for source in nasSources {
            let status = sourceStatus(source.id)
            let action = status.requiredAction
            let needsLogin = action == .login || action == .retry
                || status.health == .needsAttention || status.health == .offline
            let ready = nativeProviders[source.id]?.ready ?? false
            let running = connectTasks[source.id] != nil
            guard NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: source.enabled,
                isConnectConfigured: source.isConnectConfigured,
                rememberPassword: source.rememberPassword,
                providerReady: ready,
                connectTaskRunning: running,
                needsLogin: needsLogin) else { continue }
            guard let secret = SecureStorage.read(account: source.credentialAccount,
                                                  identity: source.credentialIdentity),
                  !secret.isEmpty else { continue }
            setSourceStatus(source.id) {
                $0.health = .connecting
                $0.message = "正在自动连接…"
                $0.requiredAction = nil
            }
            startQuietConnect(config: source,
                              credential: PendingCredential(password: secret, otp: nil))
        }
        diagnostics.append(["at": ISO8601DateFormatter().string(from: Date()),
                            "event": "replayPendingSources", "detail": reason])
    }

    // MARK: - B：网络恢复

    func startNetworkRecoveryMonitor() {
        guard networkPathMonitor == nil else { return }
        let monitor = NWPathMonitor()
        let queue = DispatchQueue(label: "com.flashfind.v2.network-recovery")
        monitor.pathUpdateHandler = { [weak self] path in
            let satisfied = path.status == .satisfied
            Task { @MainActor in self?.handleNetworkPath(satisfied: satisfied) }
        }
        monitor.start(queue: queue)
        networkPathMonitor = monitor
        networkRecoveryQueue = queue
    }

    func stopNetworkRecoveryMonitor() {
        (networkPathMonitor as? NWPathMonitor)?.cancel()
        networkPathMonitor = nil
        networkRecoveryQueue = nil
    }

    /// 只在「不可用 → 可用」的那一跳补跑；首次回调仅记录基线。
    func handleNetworkPath(satisfied: Bool) {
        guard let previous = networkWasSatisfied else {
            networkWasSatisfied = satisfied
            return
        }
        networkWasSatisfied = satisfied
        let gap = lastRecoveryReplayAt.map { Date().timeIntervalSince($0) }
        guard NetworkRecoveryPolicy.shouldReplay(wasSatisfied: previous,
                                                  isSatisfied: satisfied,
                                                  secondsSinceLastReplay: gap) else { return }
        lastRecoveryReplayAt = Date()
        // 用户在启动那次授权框点了「拒绝」时，vault 仍未解锁；网络恢复这一跳会再读一次，
        // 同样可能弹框 ⇒ 一样要包住界面保护，不能只护启动那一次。
        if CredentialStore.vaultNeedsUnlock { unlockVaultWithFocusGuard() }
        replayPendingSources(reason: "networkRestored")
    }
}
