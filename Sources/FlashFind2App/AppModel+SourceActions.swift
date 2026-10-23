import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「来源操作」分区（Stage 3A）。
//
// 「搜索来源」列表里一行的呈现与操作、连接诊断与导出、重连（含 OTP 二次确认）、
// 断开。单独成区，MARK 各归各位。
//
// ★ 断开为什么不只是「关掉当前 Provider」：见 `AppModel+QuietConnect.swift`
// 里的作废判定说明。两处是同一个 bug 的两半，改动时一起看。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    /// 清掉核心里某个 sourceID 的旧会话（自动连接路径也用）。
    func resetCoreSource(_ sourceID: String) async {
        await nasConnectionManager.resetCoreSource(sourceID)
    }
    func setSourceStatus(_ id: String, _ mutate: (inout NASSourceStatus) -> Void) {
        wizard.setSourceStatus(id, mutate)
    }

    func sourceStatus(_ id: String) -> NASSourceStatus { nasSourceStatus[id] ?? NASSourceStatus() }

    /// 「搜索来源」列表里一行的呈现与操作，全部由 Core 判定。
    ///
    /// 视图不再自己拼「已连接 / 无法连接 / 要不要给按钮」——那套判定一旦散在
    /// 视图里，就会出现「状态说有问题、却不给入口」这种不一致。
    func sourceRow(_ id: String) -> NASSourceRowModel? {
        guard let source = nasSources.first(where: { $0.id == id }) else { return nil }
        return NASSourceRowModel.make(config: source, status: sourceStatus(id),
                                      ready: nativeProviders[id]?.ready == true)
    }

    /// 行上那个按钮的唯一入口：按 Core 判定出的动作分派。
    func runSourceAction(_ id: String, _ action: NASSourceRequiredAction) {
        switch action {
        case .retry:
            reconnectSource(id)
        case .login:
            // 「登录」= 走重连向导；有没有已保存的密码由 ReconnectEntryState 决定，
            // 有就直接连上、不问用户——否则用户每次都得重输一遍密码。
            reconnectSource(id)
        case .continueSetup:
            editSource(id)
            NASWizardWindow.shared.show(model: self)
        }
    }

    /// 诊断文件路径（`nas-search-events.jsonl`）。存在才返回。
    var diagnosticsFileURL: URL? {
        guard let base = bridgeStateDirectory else { return nil }
        let url = base.deletingLastPathComponent()
            .appendingPathComponent("diagnostics/nas-search-events.jsonl")
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// 「运行连接诊断…」。
    ///
    /// 一个动作代替一排维修按钮：先按当前事实刷新所有来源状态，再用**已保存的密码**
    /// 把能连的来源连起来（没存密码的会在状态里说清原因，不会弹窗打扰）。
    /// 是否真的连上，看随后显示的诊断摘要。
    func runConnectionDiagnostics() {
        refreshStatuses()
        guard !AppEnvironment.isPreview || fixtureMode else { return }
        for source in nasSources where source.enabled && source.isConnectConfigured && source.rememberPassword {
            reconnectUsingStoredCredential(source.id)
        }
    }

    /// 系统定位：把诊断文件复制到用户选定的位置。
    ///
    /// 诊断文件里**没有**查询词、文件名与凭据（见 `NASDiagnosticsController` 的
    /// 记录规则），所以可以放心让用户自己拿去分享。
    func exportDiagnostics() {
        guard let source = diagnosticsFileURL else {
            status = "还没有可导出的诊断记录（本机未产生过 NAS 搜索事件）"
            return
        }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "闪寻诊断-" + ISO8601DateFormatter().string(from: Date()).prefix(10) + ".jsonl"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            try FileManager.default.copyItem(at: source, to: destination)
            status = "诊断已导出到 " + destination.path
        } catch {
            status = "导出诊断失败：" + error.localizedDescription
        }
    }
    var readyNativeSourceCount: Int {
        nasSources.filter { $0.enabled && (nativeProviders[$0.id]?.ready ?? false) }.count
    }
    /// 至少一个来源可以真正参与搜索。
    var hasUsableNativeSource: Bool { readyNativeSourceCount > 0 }


    /// 刷新所有来源的状态显示。
    ///
    /// 只重新评估「现在是什么状态」，不发起网络连接——用户点「刷新状态」的预期
    /// 是看状态更新，不是让所有 NAS 同时重连。
    func refreshStatuses() {
        for source in nasSources {
            let provider = nativeProviders[source.id]
            let connected = provider?.ready ?? false
            let message: String
            let health: NASSourceHealth
            // 列表行上画哪个按钮，由这一项决定（见 NASSourceRequiredAction）。
            // 判定与文案在同一处算出，避免「说了有事、却不给入口」。
            let required: NASSourceRequiredAction?
            if !source.enabled {
                health = .unconfigured; message = "已关闭"; required = nil
            } else if !source.hasEffectivePort {
                health = .unconfigured; message = "请补填端口"; required = .continueSetup
            } else if !source.isConnectConfigured {
                health = .unconfigured; message = "请填写地址与账号"; required = .continueSetup
            } else if !source.scopes.isEmpty {
                health = connected ? .ready : .offline
                let names = source.scopes.map { String($0.dropFirst()) }.joined(separator: "、")
                message = connected ? "已连接，搜索位置：\(names)" : "已保存，尚未连接"
                required = connected ? nil : .retry
            } else {
                health = connected ? .ready : .unconfigured
                message = connected ? "已连接，请选择搜索位置" : "已保存，请选择搜索位置"
                required = .continueSetup
            }
            let scope = provider?.config.scopes.joined(separator: "、") ?? source.scopes.joined(separator: "、")
            setSourceStatus(source.id) {
                $0.health = health
                $0.message = message
                $0.requiredAction = required
                $0.selectedScope = scope
            }
        }
    }

    /// 来源卡片上「重新连接」按钮的唯一入口（断开之后也走它）。
    ///
    /// 路由由 `ReconnectEntryState` 判定，三条出路：
    ///   * 本机有这把密码 → 静默重连，**不问用户**（这正是用户报障时缺的那条路）；
    ///   * 勾了记住但本机没有 → 打开向导，并如实说明为什么还要输一次；
    ///   * 没勾记住 → 打开向导，说清这是他自己的选择、勾上以后会怎样。
    ///
    /// 判定必须看**本机凭据文件里到底有没有**，不能只看 `rememberPassword`：
    /// 勾了却没存上（保存失败、被清除）时，宣称「有已保存的密码」就是在骗人。
    ///
    /// ★ OTP 特殊处理：动态口令不会也不该保存在本机。当状态标记 `needsOTP`
    /// 为 true 时，本机即使有保存的密码也要先弹 OTP 输入框，把码带进去再连。
    /// 否则用户会看到「设备要求两步验证码；重新连接并填写动态码」，
    /// 点重新登录却什么都不弹，再次失败。
    func reconnectSource(_ id: String) {
        guard let source = nasSources.first(where: { $0.id == id }) else { return }

        if sourceStatus(id).needsOTP {
            let stored = SecureStorage.read(account: source.credentialAccount,
                                            identity: source.credentialIdentity) ?? ""
            guard !stored.isEmpty else {
                let reason = "此账号需要动态口令。请先输入密码，再填写 OTP。"
                setSourceStatus(id) { $0.health = .needsAttention; $0.message = reason; $0.requiredAction = .login; $0.needsOTP = true }
                openReconnectWizard(id, reason: reason)
                return
            }
            guard let otp = promptForOTP(sourceName: source.displayName) else { return }
            reconnectUsingStoredCredential(id, otp: otp)
            return
        }

        let stored = SecureStorage.read(account: source.credentialAccount,
                                        identity: source.credentialIdentity) ?? ""
        switch ReconnectEntryState.route(rememberPassword: source.rememberPassword,
                                         hasStoredCredential: !stored.isEmpty) {
        case .storedCredential:
            reconnectUsingStoredCredential(id, otp: nil)
        case .askForPassword(let reason):
            // 状态卡片上先写一句，用户即使不看向导窗口也知道发生了什么。
            setSourceStatus(id) { $0.health = .needsAttention; $0.message = reason; $0.requiredAction = .login }
            openReconnectWizard(id, reason: reason)
        }
    }

    /// 用本机保存的密码连接一台**已保存**的来源。
    ///
    /// 走静默连接（`performConnectQuietly`），**不碰**编辑草稿的全局状态。
    /// 原因：设置页有一个「用已保存的密码重连所有 NAS」的循环按钮，
    /// 如果每个来源都去改 `draftSource / pendingCredential / pendingProvider`，
    /// 多台 NAS 会互相覆盖——后面那台把前面那台的草稿冲掉，
    /// 表现出来就是「点了重连，只有最后一台有反应」。
    func reconnectUsingStoredCredential(_ id: String, otp: String? = nil) {
        guard let source = nasSources.first(where: { $0.id == id }) else { return }
        guard source.rememberPassword else {
            setSourceStatus(id) { $0.health = .needsAttention; $0.message = ReconnectEntryState.notRememberedReason; $0.requiredAction = .login }
            return
        }
        guard let secret = SecureStorage.read(account: source.credentialAccount,
                                             identity: source.credentialIdentity), !secret.isEmpty else {
            setSourceStatus(id) { $0.health = .needsAttention; $0.message = ReconnectEntryState.missingStoredReason; $0.requiredAction = .login }
            return
        }
        let message = otp == nil ? "正在用已保存的密码连接…" : "正在用已保存的密码和动态码连接…"
        setSourceStatus(id) { $0.health = .connecting; $0.message = message; $0.requiredAction = nil }
        let credential = PendingCredential(password: secret, otp: otp)
        startQuietConnect(config: source, credential: credential)
    }

    /// 弹出一个 OTP 输入框，返回用户填的 6 位动态码；用户点取消返回 `nil`。
    ///
    /// 放在 AppModel 而不是 Core：它需要 AppKit `NSAlert`，Core 不能依赖 AppKit。
    /// 但「什么情况下该弹」的判定在 Core 的 `ConnectionFailureText.isOTPRequired`，
    /// 这样 OTP 逻辑的可测部分与不可测部分边界清晰。
    func promptForOTP(sourceName: String) -> String? {
        let alert = NSAlert()
        alert.messageText = ConnectionFailureText.otpDialogTitle
        alert.informativeText = ConnectionFailureText.otpPromptText(sourceName: sourceName)
        alert.alertStyle = .informational
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")

        let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 240, height: 24))
        textField.placeholderString = "6 位数字"
        textField.alignment = .center
        alert.accessoryView = textField

        // 把焦点放进输入框，否则用户还得多点一下。
        DispatchQueue.main.async { alert.window.makeFirstResponder(textField) }

        // ★ 弹框前必须先把应用激活到前台（点了「重新登录…」没弹窗）。
        // 闪寻不进程序坞（`accessory`），这类应用里 runModal 建的窗口不会自动抢前台：
        // 窗口建出来了，却压在设置窗口底下或不激活，用户看到的就是「点了一下毫无反应」。
        // 设置页开向导走的是同一条规则（activate + show 成对），这里不能例外。
        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        let otp = textField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return otp.isEmpty ? nil : otp
    }

    /// 断开一台已保存的 NAS，保留配置与缓存。
    ///
    /// ★ 断开只作用于这一台（BUG-NAS-DISCONNECT-01，用户报障：
    /// 「点某个 NAS 的断开按钮会导致全部 NAS 断开」）。这里**不做**三件事：
    ///   * 不 `rebuildNativeProviders()` —— 断开一台却把全部 Provider 重建核对一遍，
    ///     配置一旦判等失败就把已登录实例换成空白实例，其它 NAS 跟着掉线；
    ///   * 不 `changedQuery()` —— 全局查询重置会把**其它来源正在跑的搜索**一起取消；
    ///   * 不 `nativeProviders.removeValue` —— 断开不是移除，B 仍留在表内
    ///     （`ready == false`），界面立刻显示离线，配置与已保存密码原样保留。
    /// B 的会话与活跃查询由 `disconnectOne` → `NASSearchProvider.disconnect` 结束
    /// （并补发恰一次取消终态，界面不会永久转圈），迟到结果与迟到的自动重连都被
    /// Provider 的断开闸门挡住，不会把 B 复活。
    ///
    /// ★ 还必须**同步作废这一来源在飞的连接意图**并取消它的静默连接任务。
    /// 只关管理器里那个实例不够 —— 静默连接 / 向导手里是**另一个** B 的实例，
    /// 它晚到的成功仍会 `install(provider)`，而 install 会发布 Provider 变化，
    /// 上层随即整体重建搜索协调器 → A 在飞的查询被一起取消、B 复活成在线。
    /// 作废后：旧意图的每次 `await` 之后都会失败 → 不 install、不回写状态、不 invalidate。
    /// 代次单调递增，所以用户随后重新连接时拿到的是新代次，不受影响。
    func disconnectSource(_ id: String) {
        guard nasSources.contains(where: { $0.id == id }) else { return }
        connectIntent.invalidate(id)
        connectTasks[id]?.cancel()
        connectTasks.removeValue(forKey: id)
        setSourceStatus(id) {
            $0.health = .offline
            $0.message = "已断开，配置已保留"
            $0.requiredAction = .retry
            // 断开后 OTP 标记失效：用户再连时如果仍需要 OTP，失败路径会重新标记。
            $0.needsOTP = false
        }
        Task { [weak self] in
            await self?.nasConnectionManager.disconnectOne(id)
            // `ready` 在 Provider 实例内部翻转，字典的 @Published 感知不到；
            // 不在这里重发一次，卡片上的状态点与按钮会停留在旧渲染，
            // 直到下一次别的 @Published 变化才被顺带刷新
            // （断开后按钮仍显示「断开」，要点两次）。
            guard let self, self.nasSources.contains(where: { $0.id == id }) else { return }
            self.nativeProviders = self.nativeProviders
        }
    }

    /// 启动一次静默连接（同一来源只保留一个在飞的）。
    ///
    /// 旧的 `Task { await performConnectQuietly(...) }` 无处取消，断开之后
    /// 它还会一路走到底把来源 install 回来，所以这里把 Task 存下来供
    /// `disconnectSource` 取消；意图作废才是真正的闸门，取消只是让它可以早退。
    func startQuietConnect(config: NASSourceConfig, credential: PendingCredential) {
        connectTasks[config.sourceID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnectQuietly(config: config, credential: credential)
        }
        connectTasks[config.sourceID] = task
    }

    /// 这次静默连接现在还有效吗。
    ///
    /// 三件事一起判：任务没被取消、来源**仍然存在**、配置没变且连接意图没被断开作废。
    /// 判据全在 Core 的 `SourceConnectIntent` 里（可单测），这里只提供「现在的配置」。
    func quietConnectStillValid(_ token: SourceConnectIntent.Token) -> Bool {
        guard !Task.isCancelled else { return false }
        guard let current = nasSources.first(where: { $0.id == token.sourceID }) else { return false }
        return connectIntent.isCurrent(token, config: current)
    }
}
