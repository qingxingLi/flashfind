import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「登录时启动」分区（Stage 3A）。
//
// 真值来自系统（`SMAppService`），不是本地偏好——用户可能在
// 「系统设置 ▸ 通用 ▸ 登录项」里直接改掉，这里必须以系统的为准。
// 注册失败时把系统给的原因如实显示，不假装成功。
//
// 行为一行未改。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    // MARK: 登录时启动


    func setLaunchAtLogin(_ value: Bool) {
        guard !AppEnvironment.isPreview || fixtureMode else { status = "UI 预览不修改真实设置"; return }
        if let failure = LaunchAtLogin.set(value) {
            launchAtLoginMessage = "没能\(value ? "开启" : "关闭")「登录时启动」：\(failure)"
        } else {
            launchAtLoginMessage = nil
        }
        launchAtLogin = LaunchAtLogin.isEnabled
    }

    /// 每次打开设置时重新读一次系统真值。
    func refreshLaunchAtLogin() {
        launchAtLogin = LaunchAtLogin.isEnabled
    }
}
