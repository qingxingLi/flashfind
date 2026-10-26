import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「原生 NAS 来源与桥接」分区（Stage 3A）。
//
// 产品主路径上与 NAS 直接打交道的一层：进程桥的装配与诊断落盘、Provider 的
// 重建、以及向导状态的同名转发。搬出来之后，主文件剩下的才是「搜索本身」。
//
// ★ 向导的二十来个状态为什么连状态一起留在这一块：它们彼此咬合，只搬动作会
//   换来一堆互相引用的回调。界面写的是 `model.xxx`，所以转发属性必须同名，
//   且**必须桥接 objectWillChange** —— 不桥接的表现是「向导里点了连接，界面
//   一点反应都没有」，编译能过、也不报错。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    /// 核心状态目录（信任库所在处）。诊断轨迹写在它的兄弟目录里。
    var bridgeStateDirectory: URL? { nasConnectionManager.stateDirectory }
    var draftOffersPlainHTTPRetry: Bool { wizard.draftOffersPlainHTTPRetry }
    var draftBusy: Bool { wizard.draftBusy }
    /// 草稿还在等上一轮收尾落定（此时「已连接 / 可保存」都还不成立）。
    var draftSettling: Bool { wizard.draftSettling }
    var draftAvailableShares: [String] { wizard.draftAvailableShares }
    var draftConnected: Bool { wizard.draftConnected }
    var draftUsesAdminAccount: Bool { wizard.draftUsesAdminAccount }
    var nasTrustCandidate: NASTrustCandidate? { wizard.nasTrustCandidate }
    var adminAccountWarning: String { wizard.adminAccountWarning }
    var draftIdentityChanged: Bool { wizard.draftIdentityChanged }
    var canConnectDraft: Bool { wizard.canConnectDraft }
    var connectDisabledReason: String? { wizard.connectDisabledReason }
    var draftCredentialResetHint: String? { wizard.draftCredentialResetHint }
    var draftAllowsBasePath: Bool { wizard.draftAllowsBasePath }
    var draftUsesPlainHTTP: Bool { wizard.draftUsesPlainHTTP }
    var draftAllowsPlainHTTPChoice: Bool { wizard.draftAllowsPlainHTTPChoice }
    /// 桥接层归 `NASConnectionManager` 持有，这里只做转发：
    /// 于是本文件里既有的 `sharedBridge` 用法一行都不用改。
    var sharedBridge: (any MyNASBridgeTransport)? { nasConnectionManager.bridge }
    /// 诊断该往哪写。是否落盘由打包标记决定（只有验收包才旁录），
    /// 这个策略属于 App 层，不该写进诊断控制器。
    func configureDiagnostics() {
        diagnostics.stateDirectory = { [weak self] in self?.bridgeStateDirectory }
        diagnostics.acceptanceDirectory = {
            guard Bundle.main.object(forInfoDictionaryKey: "FlashFindAcceptanceRecording") as? String == "1" else { return nil }
            return Bundle.main.bundleURL.deletingLastPathComponent()
        }
        // 凭据变更审计。
        //
        // 起因：实测发现凭据文件被写成空表 `{"records":{},"version":1}`，
        // 而能写出这个结果的只有「删掉最后一条已存在的记录」——三处删除入口
        // （来源移除 / 关掉记住密码 / 地址账号改动）留下的文件**一模一样**，
        // 事后无法判断是谁动的。于是每次真实变更都记一行，
        // 把「哪一步动过凭据」变成可核对的事实。
        // 只记操作/来源标识/剩余条数/原因：不记密码，也不记账号名。
        CredentialStore.onMutation = { [weak self] mutation in
            let row: [String: Any] = [
                "event": "credentialMutation",
                "at": ISO8601DateFormatter().string(from: Date()),
                "operation": mutation.operation.rawValue,
                "sourceKey": mutation.sourceKey,
                "storedCount": mutation.storedCount,
                "reason": mutation.reason
            ]
            Task { @MainActor in self?.appendDiagnosticRow(row) }
        }
    }
    func recordProviderEvent(_ event:ProviderEvent) {
        diagnostics.recordProviderEvent(event)
    }

    /// 核心协议修订号对不上时立刻说清楚。
    ///
    /// 之前这种不同步（只改了 Dart 源码、忘了重编译 mynas-core）的现场是
    /// 「什么都没发生」：请求发出去，回来的事件名对不上，界面既不报错也不超时。
    /// 与其让人去猜，不如第一条消息就把原因摆出来。
    func noteCoreRevisionMismatch(_ m: [String: Any]) {
        guard m["event"] as? String == "coreRevisionMismatch" else { return }
        let expected = m["expected"] as? Int ?? -1
        let actual = m["actual"] as? Int ?? -1
        let text = actual < 0
            ? "搜索核心是旧版本（客户端需要修订号 \(expected)）。客户端源码与打包进去的核心不同步，请重新构建后再试。"
            : "搜索核心与客户端版本不匹配（需要 \(expected)，实际 \(actual)）。请重新构建客户端后再试。"
        nativeNASStatus = text
        draftStatus = text
    }

    /// 记录「搜索为什么没跑成」的极小轨迹。
    ///
    /// 由来： 用户在真机上搜「报告」，两台 NAS 都只显示一个 `failed`。
    /// 那个字符串本身没有说清任何事——而根因其实早就从核心发过来了
    /// （`terminal` 事件里带着 `error.kind` 与 `apiCode`），只是**没有任何地方落过盘**，
    /// 于是只能靠反复猜。界面文案已经改成直接说人话；这里再补一份可核对的原始记录，
    /// 让下一次同类问题一眼可判，而不是又一轮推测。
    ///
    /// 刻意**只记失败与终态**，并且**不记查询词、不记文件名/路径、不记凭据**：
    /// 这些字段与「为什么失败」无关，却是最敏感的内容。
    func recordSearchFailureTrace(_ m: [String: Any]) {
        // 是否落盘由打包标记决定（只有验收包才旁录）——
        // 正式版不该在用户机器上写这个文件。
        guard Bundle.main.object(forInfoDictionaryKey: "FlashFindAcceptanceRecording") as? String == "1" else { return }
        diagnostics.recordSearchFailureTrace(m)
    }

    func recordProtocolEvent(_ m: [String: Any]) {
        diagnostics.recordProtocolEvent(m)
    }

    func ensureProviderCoordinator() {
        guard providerCoordinator == nil || nasConnectionManager.bridge == nil else { return }
        guard let resources = Bundle.main.resourceURL else { nativeNASStatus = "应用缺少搜索资源"; return }
        configureDiagnostics()
        nasConnectionManager.observeProtocol = { [weak self] message in
            self?.noteCoreRevisionMismatch(message)
            self?.recordSearchFailureTrace(message)
            self?.recordProtocolEvent(message)
        }
        nasConnectionManager.onDiagnostic = { [weak self] row in self?.diagnostics.append(row) }
        // Provider 集合一变就重建协调器：本机文件 + 已安装应用 + 全部 NAS 来源。
        nasConnectionManager.onProvidersChanged = { [weak self] providers in
            guard let self else { return }
            self.nativeProviders = providers
            var list: [any SearchProvider] = [self.localProvider, self.appProvider]
            list.append(contentsOf: providers.values.sorted { $0.source.id < $1.source.id })
            self.providerCoordinator = SearchCoordinator(providers: list)
        }
        guard nasConnectionManager.ensureBridge(resourceDirectory: resources) else {
            nativeNASStatus = "应用缺少搜索资源"
            return
        }
        rebuildNativeProviders()
    }

    /// 往常驻诊断文件追加一行（不记查询词 / 文件名 / 凭据）。
    func appendDiagnosticRow(_ row: [String: Any]) {
        diagnostics.append(row)
    }

    /// 给 Provider 装上自动重连。实际实现在 `NASConnectionManager`——
    /// 凭据读取与重放都属于连接管理，不归界面层。
    func attachAutoReconnect(_ provider: NASSearchProvider) {
        nasConnectionManager.attachAutoReconnect(provider)
    }


    /// 按当前配置重建全部 Provider。
    ///
    /// 重建动作本身（含自动重连装配、旧 Provider 的断开）在 `NASConnectionManager`；
    /// 结果通过 `onProvidersChanged` 回传，由这里刷新 `@Published` 与搜索协调器。
    func rebuildNativeProviders() {
        nasConnectionManager.rebuild(configs: nasSources,
                               queryBudgetMs: max(1, min(120, nativeSearchTimeoutSeconds)) * 1000,
                               mountService: mountService)
    }

    // MARK: - 原生 NAS 来源（产品主路径）


    var nasSources: [NASSourceConfig] {
        get { wizard.nasSources }
        set { wizard.nasSources = newValue }
    }
    var nasSourceStatus: [String: NASSourceStatus] {
        get { wizard.nasSourceStatus }
        set { wizard.nasSourceStatus = newValue }
    }
    var nativeProviders: [String: NASSearchProvider] {
        get { wizard.nativeProviders }
        set { wizard.nativeProviders = newValue }
    }
    var selectedSourceID: String? {
        get { wizard.selectedSourceID }
        set { wizard.selectedSourceID = newValue }
    }
    var nativeNASPassword: String {
        get { wizard.nativeNASPassword }
        set { wizard.nativeNASPassword = newValue }
    }
    /// 动态码只由弹窗写入（见 `promptForOTPThenReconnect`）：拿到的码先落到这里，
    /// 再由 `connectDraft()` 读走。界面上**没有**绑定到它的输入框 ——
    /// 一次性凭证不是一台 NAS 的属性，不该常驻在表单里。
    var nativeNASOTP: String {
        get { wizard.nativeNASOTP }
        set { wizard.nativeNASOTP = newValue }
    }
    var draftSource: NASSourceConfig {
        get { wizard.draftSource }
        set { wizard.draftSource = newValue }
    }
    var draftStatus: String {
        get { wizard.draftStatus }
        set { wizard.draftStatus = newValue }
    }
    /// 保持旧类型名：界面写的是 `model.nasTrustCandidate`，不改动调用点。
    typealias NASTrustCandidate = NASSourceWizardController.NASTrustCandidate



    /// 读取已保存的原生 NAS 来源。读取失败时保留配置，不静默丢弃用户的 NAS。
    func loadNativeSources() {
        guard !AppEnvironment.isPreview else { return }
        guard let data = preferences.data(forKey: NASSourceWizardController.sourcesStorageKey) else { return }
        do {
            var decoded = try JSONDecoder().decode([NASSourceConfig].self, from: data)
            // 同 ID 重复会让来源身份冲突，直接停下比默默挑一个更安全。
            guard Set(decoded.map(\.id)).count == decoded.count else {
                nativeNASStatus = "已保存的 NAS 来源配置有重复项，未加载；请到设置里重新添加"
                return
            }
            for index in decoded.indices { decoded[index].normalizeHost() }
            // 迁移：旧版本端口是「自动探测」的结果，读出来可能为 0。
            // 这类来源不能直接用（探测已被移除），必须让用户补填端口，
            // 因此保留配置但在状态里明确说明，不静默丢弃。
            let needsPort = decoded.filter { !$0.hasEffectivePort }
            nasSources = decoded
            selectedSourceID = decoded.first?.id
            for source in decoded {
                setSourceStatus(source.id) {
                    if !source.hasEffectivePort {
                        $0.health = .needsAttention
                        $0.message = "请补填端口后再连接"
                        $0.requiredAction = .continueSetup
                    } else if source.isSearchConfigured {
                        $0.health = .offline
                        $0.message = "已保存，尚未连接"
                        $0.requiredAction = .retry
                    } else {
                        $0.health = .unconfigured
                        $0.message = "请完成账号与搜索位置配置"
                        $0.requiredAction = .continueSetup
                    }
                    $0.selectedScope = source.scopes.joined(separator: "、")
                }
            }
            if !needsPort.isEmpty {
                nativeNASStatus = "有 \(needsPort.count) 台 NAS 需要补填端口（之前是自动探测的）"
            }
            rebuildNativeProviders()
        } catch {
            nativeNASStatus = "无法读取 NAS 来源配置：\(error.localizedDescription)。原配置已保留。"
        }
    }
}
