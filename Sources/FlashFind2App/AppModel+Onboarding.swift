import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「首次启动引导」分区（Stage 3A）。
//
// 引导读的是**真实**配置状态（判定在 Core 的 `OnboardingState.make`），不是
// 另一套「引导专用进度」。这里只负责把它喂给引导窗口，以及在用户要求
// 「再看一遍」时**只清已完成标记**——不动 NAS、快捷键、搜索文件夹与权限。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    // MARK: - 首次启动引导转发

    /// 引导读写自己的痕迹（走没走完、停在哪一步）用的偏好存储。
    /// 与设置共用同一份 —— 引导不该另开一个「用户看不见的配置层」。
    var onboardingPreferences: any ClientPreferences { preferences }

    /// 「重新运行欢迎引导…」。
    ///
    /// 注意它做什么、不做什么：**只清「已完成」标记**，已有 NAS、快捷键、
    /// 搜索文件夹、权限一律不动。把「再看一遍」做成「恢复出厂设置」是这类入口
    /// 最常见的错，而用户点它的时候往往只是想确认一下设置在哪。
    func restartOnboarding() {
        onboardingStore.rerun()
        NSApp.activate(ignoringOtherApps: true)
        OnboardingWindow.shared.show(model: self, startAt: .welcome)
    }

    /// 引导各步要显示的**真实**配置状态。判定在 Core（`OnboardingState.make`）。
    var onboardingState: OnboardingState {
        OnboardingState.make(shortcutAvailable: shortcutAvailable,
                             shortcutName: globalShortcut.displayName,
                             fullDiskAccessGranted: FullDiskAccess.isGranted,
                             localEnabled: localEnabled,
                             localMode: localSearchMode,
                             localFolderCount: localFolders.count,
                             sources: nasSources)
    }

    /// 引导里按了一次全局快捷键。只做标记，**不打开搜索窗**——
    /// 「试一下」不该把用户从引导页上顶走（见 `AppDelegate` 里注册器的按下回调）。
    func noteOnboardingShortcutPressed() { pushOnboardingShortcutPressed?() }
    // `pushOnboardingShortcutPressed` 由引导窗口在展示时装配，是存储属性，
    // 留在主文件（extension 不能含存储属性）。
}
