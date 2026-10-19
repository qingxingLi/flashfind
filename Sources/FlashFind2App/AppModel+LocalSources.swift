import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「本机来源转发」分区（Stage 3A）。
//
// 实现在 `LocalSourceController`，这里只留同名的转发签名。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    // MARK: - 本机来源转发（实现在 LocalSourceController）
    //
    // 界面直接调 AppModel，保留这些签名是为了调用点一行不改。
    func refreshLocalSearchAvailability() { localSources.refreshLocalSearchAvailability() }
    func setLocalSearchMode(_ mode: LocalSearchMode) { localSources.setLocalSearchMode(mode) }
    func refreshMountedSMBShares() { localSources.refreshMountedSMBShares() }
    @discardableResult
    func importMountedSMB(_ id: String) -> Bool { localSources.importMountedSMB(id) }
    func canApplyImportedSMBBinding(_ sourceID: String) -> Bool { localSources.canApplyImportedSMBBinding(sourceID) }
    func applyImportedSMBBinding(_ sourceID: String) { localSources.applyImportedSMBBinding(sourceID) }
    func removeLocalFolder(_ folder: URL) { localSources.removeLocalFolder(folder) }
    func addLocalFolder() { localSources.addLocalFolder() }
    func localSettingsChanged() { localSources.localSettingsChanged() }
}
