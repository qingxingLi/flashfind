import AppKit
import SwiftUI
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「向导转发」分区（Stage 3A）。
//
// 为什么搬出来：AppModel 一度 2038 行，这一块 49 行是其中**依赖最干净**的一块——
// 它只碰 `wizard`，不碰搜索状态、不碰连接状态。先搬它，是为了让「分文件 extension」
// 这条路的代价可以被量化和验证，再决定是否继续搬更大的块。
//
// 搬动规则：只搬实现，不搬声明；**行为一行不改**，界面写的仍是 `model.xxx`，
// 所以调用点一行都不用动。跨文件 extension 需要访问的状态已在主文件标为 internal。
// ─────────────────────────────────────────────────────────────────────────────

extension AppModel {
    /// 连接握手中暂存的凭据。定义随向导一起搬到 `NASSourceWizardController`；
    /// 本文件里的自动连接路径沿用同一个类型。
    typealias PendingCredential = NASSourceWizardController.PendingCredential

    // MARK: - 向导转发（实现在 NASSourceWizardController）
    //
    // 界面（NASSourceWizardView、SettingsView、菜单栏）写的是 `model.xxx`，
    // 保留这些签名是为了调用点一行不改。
    func addSource() { wizard.addSource() }
    func editSource(_ id: String) { wizard.editSource(id) }
    @discardableResult
    func saveDraft(rebuildProviders: Bool = true) -> Bool { wizard.saveDraft(rebuildProviders: rebuildProviders) }
    func removeSource(_ id: String) { wizard.removeSource(id) }
    func setDraftRememberPassword(_ value: Bool) { wizard.setDraftRememberPassword(value) }
    func setDraftPort(_ text: String) { wizard.setDraftPort(text) }
    func setDraftBasePath(_ text: String) { wizard.setDraftBasePath(text) }
    func setDraftVendor(_ vendor: NASSourceConfig.Vendor) { wizard.setDraftVendor(vendor) }
    /// 「附近的设备」里选中一台 → 预填地址与端口（不自动连接）。
    func applyDiscoveredDevice(_ device: DiscoveredDevice) { wizard.applyDiscoveredDevice(device) }
    func setDraftPlainHTTP(_ value: Bool) { wizard.setDraftPlainHTTP(value) }
    func setSourceEnabled(_ id: String, _ value: Bool) { wizard.setSourceEnabled(id, value) }
    func setDraftStatus(_ message: String) { wizard.setDraftStatus(message) }
    func connectDraft() { wizard.connectDraft() }
    func retryDraftUsingPlainHTTP() { wizard.retryDraftUsingPlainHTTP() }
    func confirmDraftTrust() { wizard.confirmDraftTrust() }
    func rejectDraftTrust() { wizard.rejectDraftTrust() }
    func toggleDraftScope(_ scope: String) { wizard.toggleDraftScope(scope) }
    func commitDraft() { wizard.commitDraft() }
    func disconnectDraft() { wizard.disconnectDraft() }
    func cancelDraft() { wizard.cancelDraft() }
    /// 打开「重新连接」向导，并把**为什么还要输密码**这句话带进去。
    ///
    /// 提示语只由 `ReconnectEntryState` 出：那里才知道「有没有已保存的密码」
    /// 这两种情况的区别该怎么向用户解释（见 `ReconnectEntryState` 的文档）。
    /// 打开重连向导：既要备好草稿，也要**真的把窗口显示出来**。
    ///
    /// 只转发给 `wizard.openReconnectWizard` 是不够的：那边做的是
    /// `editSource(id)` + 写一句状态文案，**不负责显示窗口**。
    /// 于是用户点「重新登录…」（本机没存密码那条路）之后界面毫无反应——
    /// 草稿准备好了，窗口却从没被叫出来。同一文件里 `.continueSetup` 分支与
    /// 设置页的 `openWizard()` 都是「激活 + show」成对出现，重连这条不能少。
    func openReconnectWizard(_ id: String, reason: String) {
        wizard.openReconnectWizard(id, reason: reason)
        NSApp.activate(ignoringOtherApps: true)
        NASWizardWindow.shared.show(model: self)
    }
    /// 本文件里既有的调用点（自动连接、刷新状态）一行不改。
    func persistSources() { wizard.persistSources() }
}
