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
                let names = source.scopes.map(NASScopeLabel.text(for:)).joined(separator: "、")
                message = connected ? "已连接，搜索位置：\(names)" : "已保存，尚未连接"
                required = connected ? nil : .retry
            } else {
                health = connected ? .ready : .unconfigured
                message = connected ? "已连接，请选择搜索位置" : "已保存，请选择搜索位置"
                required = .continueSetup
            }
            // 位置名统一走 `NASScopeLabel`：`"/"` 直接 `dropFirst()` 会变成空白，
            // 摘要里就成了「搜索位置：、」。
            let scope = (provider?.config.scopes ?? source.scopes)
                .map(NASScopeLabel.text(for:)).joined(separator: "、")
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
    /// ★ OTP 特殊处理：动态口令不会也不该保存在本机。
    ///
    /// 2026-10-26 用户报障两条，都出在这个函数「把已知的事留到下一轮」：
    ///
    ///  1. 「第一次输入提示需要输入动态码，但是不会自动弹出动态码，
    ///     需要点击两次登陆，很反人类」——第一次走的是静默连接，失败只写一行状态；
    ///  2. 「输入 OTP 验证码错误，不会提示验证码错误，而是没有什么反应」
    ///     —— 码错又回到同一条静默路径，只把状态改回「需要动态码」。
    ///
    /// 现在：**已知要码就地问**（不再先撞一次注定失败的登录）；不知道要码也走
    /// `interactiveOTP: true`，由连接层在失败当场把框弹出来，并在码错时于同一个
    /// 框里再问一次。用户点一次「登录」就够了。
    func reconnectSource(_ id: String) {
        guard let source = nasSources.first(where: { $0.id == id }) else { return }

        let stored = SecureStorage.read(account: source.credentialAccount,
                                        identity: source.credentialIdentity, allowInteraction: true) ?? ""

        if sourceStatus(id).needsOTP {
            guard !stored.isEmpty else {
                let reason = "此账号需要动态口令。请先输入密码，再填写 OTP。"
                setSourceStatus(id) { $0.health = .needsAttention; $0.message = reason; $0.requiredAction = .login; $0.needsOTP = true }
                openReconnectWizard(id, reason: reason)
                return
            }
            // 状态里记着「上一次那个码被拒了」就照实说，否则只说设备要码。
            let failure: OTPFailure = sourceStatus(id).otpRejected ? .rejected : .required
            guard let otp = promptForOTP(sourceName: source.displayName, failure: failure) else {
                // 取消不是失败：说清下次怎么把它叫回来，别把状态留在「需要动态码」上干等。
                setSourceStatus(id) {
                    $0.health = .needsAttention
                    $0.message = ConnectionFailureText.otpRetryHint(buttonTitle: "登录")
                    $0.requiredAction = .login
                    $0.needsOTP = true
                }
                return
            }
            reconnectUsingStoredCredential(id, otp: otp, interactiveOTP: true)
            return
        }

        switch ReconnectEntryState.route(rememberPassword: source.rememberPassword,
                                         hasStoredCredential: !stored.isEmpty) {
        case .storedCredential:
            // ★ 用户主动点的登录（不是开机自动连接）⇒ 允许当场弹 OTP 框。
            reconnectUsingStoredCredential(id, otp: nil, interactiveOTP: true)
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
    ///
    /// - Parameter interactiveOTP: 用户自己点的登录（而不是批量诊断 / 开机自动连）。
    ///   为 true 时设备要动态码会当场弹框，且码错就在同一个框里重问。
    /// - Returns: 是否**真的发起了**连接。`false` = 没存密码或钥匙串里读不到，
    ///   这种情况下只写了来源状态卡片，调用方若在搜索面板上（那里看不到卡片）
    ///   必须自己补一句，否则用户看到的是「点了没反应」。
    @discardableResult
    func reconnectUsingStoredCredential(_ id: String, otp: String? = nil,
                                        interactiveOTP: Bool = false) -> Bool {
        guard let source = nasSources.first(where: { $0.id == id }) else { return false }
        guard source.rememberPassword else {
            setSourceStatus(id) { $0.health = .needsAttention; $0.message = ReconnectEntryState.notRememberedReason; $0.requiredAction = .login }
            return false
        }
        guard let secret = SecureStorage.read(account: source.credentialAccount,
                                             identity: source.credentialIdentity, allowInteraction: true), !secret.isEmpty else {
            setSourceStatus(id) { $0.health = .needsAttention; $0.message = CredentialStore.currentProblem?.summary ?? ReconnectEntryState.missingStoredReason; $0.requiredAction = .login }
            return false
        }
        let message = otp == nil ? "正在用已保存的密码连接…" : "正在用已保存的密码和动态码连接…"
        setSourceStatus(id) { $0.health = .connecting; $0.message = message; $0.requiredAction = nil }
        let credential = PendingCredential(password: secret, otp: otp)
        startQuietConnect(config: source, credential: credential, interactiveOTP: interactiveOTP)
        return true
    }

    /// 弹出一个 OTP 输入框，返回用户填的 6 位动态码；用户点取消返回 `nil`。
    ///
    /// 放在 AppModel 而不是 Core：它需要 AppKit `NSAlert`，Core 不能依赖 AppKit。
    /// 但「什么情况下该弹 / 该说什么」的判定在 Core 的 `ConnectionFailureText`
    /// （`otpFailure` / `otpPromptText` / `otpDialogTitle(for:)`），
    /// 这样 OTP 逻辑的可测部分与不可测部分边界清晰。
    ///
    /// - Parameter failure: `nil` / `.required` = 还没填过码；`.rejected` = 刚填的被拒，
    ///   标题与正文都要直说「输入错误」，这是用户 2026-10-26 明确要求的。
    func promptForOTP(sourceName: String, failure: OTPFailure? = nil) -> String? {
        let alert = NSAlert()
        alert.messageText = ConnectionFailureText.otpDialogTitle(for: failure)
        alert.informativeText = ConnectionFailureText.otpPromptText(sourceName: sourceName, failure: failure)
        alert.alertStyle = failure == .rejected ? .warning : .informational
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

    /// 弹一个「去浏览器授权 → 把页面上的授权码粘回来」的窗，返回用户填的授权码；取消返回 `nil`。
    ///
    /// ★ 2026-10-29：**向导不再走这里**。用户要求「不要弹窗 直接在图示位置生成
    ///   获取授权码，点击后打开浏览器 然后再粘贴授权码」——授权码在向导里已经是
    ///   「连接信息」表单的一格（`NASSourceWizardController.draftAuthorizeCode`），
    ///   浏览器由向导自己打开。这条路只剩**没有表单可填**的那一个调用方：
    ///   设置页点「登录」触发的后台重连（`AppModel+QuietConnect`），
    ///   它撞上授权态时没有别的地方能接收那串码。
    ///
    /// 放在 AppModel 而不是 Core：需要 AppKit 的 `NSAlert` 与 `NSWorkspace`，
    /// Core 不能依赖 AppKit。但「说什么」全在 Core 的
    /// `ConnectionFailureText.authorizationPromptText`（可单测）。
    ///
    /// ★ **为什么只用一扇窗、而不是「先弹去授权、再弹粘授权码」**：
    /// 两个弹窗意味着用户要在两个模态之间来回切，中间那次取消会让连接停在半路；
    /// 而且地址与输入框分开之后，用户切回来时页面上那串码已经不在视野里了。
    /// 所以浏览器在本窗出现前**自动打开**，窗里只做一件事：粘码。
    /// 剩下的「打开授权页面」按钮是给「页面被关了 / 勾了额外权限要换地址」用的。
    ///
    /// - Parameter rejected: 上一次交的码被拒 ⇒ 标题与首句都直说「没有被接受」，
    ///   而不是让用户对着同一句话猜自己刚才那串到底怎么了。
    /// - Parameters:
    ///   - scopes: 授权页权限清单（fnOS）。必需项锁定勾选，可选项默认不勾 ——
    ///     **不勾就不申请**：授权地址按「必需 + 勾选」重新产出，授权页上
    ///     根本不会出现没勾的那几项（2026-10-29 审查：原先全量申请 11 项）。
    ///   - reauthorize: 用户勾选了额外权限后重新产出授权地址。传勾选的
    ///     可选 scope id，返回包含这些权限的新地址。
    func promptForAuthorizeCode(sourceName: String, url: URL,
                                validFor: TimeInterval, rejected: Bool,
                                scopes: [NASAuthorizationScope],
                                reauthorize: @escaping ([String]) async throws -> URL) async -> String? {
        let required = scopes.filter { $0.required }
        let optional = scopes.filter { !$0.required }
        let alert = NSAlert()
        alert.messageText = rejected
            ? ConnectionFailureText.authorizeRejectedTitle
            : ConnectionFailureText.authorizeDialogTitle
        alert.informativeText = ConnectionFailureText.authorizationPromptText(
            sourceName: sourceName, url: url, validFor: validFor, rejected: rejected)
        alert.alertStyle = rejected ? .warning : .informational
        alert.addButton(withTitle: "连接")
        alert.addButton(withTitle: "取消")

        // 附件视图：[必需权限说明] [可选权限勾选] [授权码输入框] [重新打开授权页面]
        // 宽 440：输入框 300 + 间距 8 + 按钮 128 = 436，420 会切掉按钮右边一截。
        let checkboxHeight: CGFloat = optional.isEmpty ? 0 : CGFloat(optional.count) * 22 + 8
        let container = NSView(frame: NSRect(x: 0, y: 0, width: 440,
                                             height: 26 + 20 + checkboxHeight))
        var y = container.frame.height
        if !required.isEmpty {
            y -= 20
            let note = NSTextField(labelWithString:
                "闪寻只需要：\n" + required.map { "· \($0.label)" }.joined(separator: "\n"))
            note.font = NSFont.systemFont(ofSize: 11)
            note.frame = NSRect(x: 0, y: y, width: 440, height: 20 + CGFloat(required.count) * 15)
            container.addSubview(note)
            y -= 6
        }
        // 可选权限：默认全部不勾。勾选后点「重新打开授权页面」会按勾选结果
        // 重新生成授权地址 —— 未勾选的权限不会出现在授权页上。
        var optionalBoxes: [(button: NSButton, id: String)] = []
        for item in optional {
            y -= 22
            let box = NSButton(checkboxWithTitle: item.label, target: nil, action: nil)
            box.font = NSFont.systemFont(ofSize: 11)
            box.state = .off
            box.frame = NSRect(x: 0, y: y, width: 440, height: 20)
            container.addSubview(box)
            optionalBoxes.append((box, item.id))
        }
        y -= 30
        let field = NSTextField(frame: NSRect(x: 0, y: y + 1, width: 300, height: 24))
        field.placeholderString = "粘贴页面上的授权码"
        field.alignment = .left
        field.lineBreakMode = .byTruncatingMiddle
        container.addSubview(field)
        // 按钮的 target 是 unretained，所以这个 opener 必须活到弹窗结束——
        // 放在局部常量上即可：`runModal` 是同步阻塞的，作用域覆盖整个弹窗生命周期。
        let opener = AuthorizePageOpener(url: url, boxes: optionalBoxes, reauthorize: reauthorize)
        // 标题写「重新」：浏览器在这个窗出现前已经自动开过一次（见下面 `NSWorkspace.open`），
        // 按钮只负责「页面被我关了 / 要换成勾选后的新地址」这一种情况。
        let openButton = NSButton(title: "重新打开授权页面", target: opener,
                                  action: #selector(AuthorizePageOpener.openInBrowser))
        openButton.bezelStyle = .rounded
        // 起点 308 + 宽 128 = 436，正好落在 440 的 container 里。
        openButton.frame = NSRect(x: 308, y: y + 4, width: 128, height: 26)
        container.addSubview(openButton)
        alert.accessoryView = container

        let alertWindow = alert.window
        DispatchQueue.main.async { alertWindow.makeFirstResponder(field) }
        // 与动态码弹窗同一条规则：闪寻不进程序坞（`accessory`），runModal 建的窗口
        // 不会自动抢前台，不激活就压在设置窗口底下——用户看到的是「点了一下毫无反应」。
        NSApp.activate(ignoringOtherApps: true)

        // ★ 授权期间先把闪寻自己的窗口收起来（2026-10-29 用户截图：弹窗 + 设置窗 +
        //   向导窗正好把浏览器里的授权页整个挡死，得手动挪开窗口才看得见）。
        //
        //   只「把浏览器叫到前台」是不够的：`runModal` 建立的 modal session 会把 App
        //   重新激活，闪寻的窗口随即又压回浏览器上方。所以这里先 `orderOut`。
        //
        //   恢复放在 `defer` 里**无条件**执行：取消、授权码被拒、直接抛错都要把窗口
        //   放回去，否则用户会遇到「闪寻像死了一样，一个窗口都没有」。
        let hiddenBehindAlert = hideWindowsBehindAuthorizationAlert(except: alertWindow)
        defer {
            // 倒序放回：`orderedWindows` 是 front-to-back，倒着 orderFront
            // 才能保住原来谁在上面。
            for window in hiddenBehindAlert.reversed() { window.orderFront(nil) }
            // 用户点完「连接 / 取消」是要继续在闪寻里操作，把前台还回来——
            // 不激活的话焦点还在浏览器上，向导状态行的变化看不到。
            NSApp.activate(ignoringOtherApps: true)
        }

        // ★ 用户点了「连接」就是要连上，不该再让他在弹窗里点第二次才看到授权页
        //   （2026-10-29 用户要求：「点击连接直接弹出浏览器打开这个网页登陆授权就行」）。
        //   打开放在 runModal **之前**：即使这扇窗被别的窗口挡住，浏览器也已经在前台，
        //   用户照着弹窗文案做就是「去浏览器登录 → 回来粘码」两步。
        //   返回值不看：开不出来（没有默认浏览器）时弹窗里就有「重新打开授权页面」，
        //   不值得为它加一条分支。
        NSWorkspace.shared.open(url)

        let response = alert.runModal()
        guard response == .alertFirstButtonReturn else { return nil }
        // ★ 授权码的去空白**只在弹窗出口做这一次**（入口即边界）：
        // 调用方（向导 / 静默重连）拿到手的已经是干净的非空串。
        let code = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return code.isEmpty ? nil : code
    }

    /// 授权弹窗期间把闪寻自己的窗口收起来，返回收起来的那些（供调用方原样放回）。
    ///
    /// 判据是**层级**而不是标题栏：闪寻有两类窗口——设置窗 / 向导窗（普通层级），
    /// 以及搜索、结果、钉住这三块浮层（`floating`，且 `hidesOnDeactivate = false`，
    /// 所以 App 退到后台它们也不让开）。两类都会把浏览器挡死，都得收。
    /// `floating` 以上的层级是系统窗口（菜单、状态栏面板），一律不碰。
    private func hideWindowsBehindAuthorizationAlert(except alertWindow: NSWindow) -> [NSWindow] {
        var hidden: [NSWindow] = []
        // 按 front-to-back 取，调用方倒序放回才能保住原来谁在上面。
        for window in NSApp.orderedWindows where window !== alertWindow {
            guard window.isVisible,
                  window.level.rawValue <= NSWindow.Level.floating.rawValue else { continue }
            window.orderOut(nil)
            hidden.append(window)
        }
        return hidden
    }

    /// 断开一台已保存的 NAS，保留配置与缓存。
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
            $0.otpRejected = false
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
    func startQuietConnect(config: NASSourceConfig, credential: PendingCredential,
                           interactiveOTP: Bool = false) {
        connectTasks[config.sourceID]?.cancel()
        let task = Task { [weak self] in
            guard let self else { return }
            await self.performConnectQuietly(config: config, credential: credential,
                                             interactiveOTP: interactiveOTP)
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

/// 「打开授权页面」按钮的 target。
///
/// 单独一个 `NSObject` 小类，而不是让 `AppModel` 自己当 target：
/// `AppModel` 不是 `NSObject` 子类（它是 `ObservableObject`），而 `@objc`
/// 选择子只能挂在 NSObject 系上。加一个基类会把整个观察链卷进 ObjC 运行时，
/// 为了一个按钮不值得。
///
/// ★ 按钮的 target 是 **unretained**：调用方必须把实例活到弹窗结束
///   （`promptForAuthorizeCode` 里放在局部常量上，`runModal` 是同步阻塞的，
///   作用域正好覆盖弹窗整个生命周期）。改成惰性全局单例会引入「URL 被后一次覆盖」
///   的新 bug —— 用户在弹窗开着时再点一次连接就会开错地址。
final class AuthorizePageOpener: NSObject {
    private var url: URL
    /// 当前授权地址里已经包含的可选 scope（避免每次点击都重新产地址）。
    private var requestedOptional: Set<String> = []
    private let boxes: [(button: NSButton, id: String)]
    private let reauthorize: ([String]) async throws -> URL
    private var busy = false

    init(url: URL, boxes: [(button: NSButton, id: String)],
         reauthorize: @escaping ([String]) async throws -> URL) {
        self.url = url
        self.boxes = boxes
        self.reauthorize = reauthorize
    }

    @objc func openInBrowser() {
        guard !busy else { return }
        busy = true
        Task { @MainActor in
            defer { busy = false }
            let selected = boxes.filter { $0.button.state == .on }.map { $0.id }
            if Set(selected) != requestedOptional {
                do {
                    url = try await reauthorize(selected)
                    requestedOptional = Set(selected)
                } catch {
                    // 重新产地址失败必须说清，不能拿旧地址冒充「已包含勾选权限」。
                    let failure = NSAlert()
                    failure.messageText = "权限选择没有生效"
                    failure.informativeText = ConnectionFailureText.describe(error, host: "", port: 0)
                    failure.runModal()
                    return
                }
            }
            NSWorkspace.shared.open(url)
        }
    }
}
