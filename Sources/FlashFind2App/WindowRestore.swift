import AppKit
import FlashFindCore

/// 关掉一个窗口之后，把搜索浮窗放回屏幕上 —— 仅当没有别的可见窗口。
///
/// ## 为什么关窗也得管「屏幕上还剩什么」
///
/// 三个窗口（搜索浮窗 / 设置 / 来源向导 / 引导）谁都不是「主窗口」。
/// 打开设置或向导时会 `hideSearch()` 把浮窗收掉（它浮在更上层，会盖住设置窗口），
/// 于是**关掉当前这个窗口就可能是零窗口**。
///
/// 而 macOS 的 Automatic Termination 会把「没有可见窗口」的应用判成空闲并直接回收。
/// 它不是崩溃，所以**不产生崩溃报告**；用户看到的只有「点完登录就闪退」。
/// 实测日志（2026-10-22 15:24:35，build 25）：
///
/// ```
/// window <NSWindow: 0x13aa6a650> windowNumber=fc33 finishing close
/// [com.apple.AppKit:AutomaticTermination] Setting _kLSApplicationWouldBeTerminatedByTALKey=1
/// ```
///
/// 判定规则住 `LastWindowClosePolicy`（可测），这里只负责拿 AppKit 的现状去问它。
///
/// - Parameter closing: 正在关闭的窗口。**必须显式排除**：`windowWillClose`
///   触发时它还没真正消失，`isVisible` 仍为 true，不排除就会误判成「还有别的窗口」，
///   于是浮窗永远不放回来 —— 而这种缺陷在界面上表现为「偶尔不出现」，最难查。
@MainActor
func restoreSearchPanelIfNeeded(closing: NSWindow?, model: AppModel?) {
    let hasOtherVisibleWindow = NSApp.windows.contains { window in
        window !== closing && window.isVisible && window.canBecomeKey
    }
    guard LastWindowClosePolicy.shouldRestoreSearchPanel(hasOtherVisibleWindow: hasOtherVisibleWindow) else {
        return
    }
    model?.showPanel?()
}


/// 系统授权切走焦点后恢复原表单，不重新 show，避免重建视图或清空登录草稿。
///
/// ★ 它只负责**在本应用内部把窗口排到最前**，不负责激活应用。
/// 非激活态下调它等于白调（实测见 `raisePresentedPreferencesWindow`）。
@MainActor
@discardableResult
func restorePresentedPreferencesWindow(preferred: NSWindow? = nil) -> Bool {
    let candidates = presentedPreferencesWindows()
    guard let window = candidates.first(where: { $0 === preferred }) ?? candidates.first else { return false }
    window.makeKeyAndOrderFront(nil)
    return true
}

/// 当前呈现中、且没被用户主动最小化的设置/向导窗口。
///
/// 两处共用同一份「哪个窗口算数」的定义：`restorePresentedPreferencesWindow`
/// 用它挑窗口，`bringPreferencesForwardAfterSystemPrompt` 用它问「还该不该救」。
/// 分开写两份，迟早出现「一处认为有、另一处认为没有」。
@MainActor
func presentedPreferencesWindows() -> [NSWindow] {
    [NASWizardWindow.shared.presentedWindow, SettingsWindow.shared.presentedWindow]
        .compactMap { $0 }.filter { !$0.isMiniaturized }
}

/// 把设置/向导窗口提回最前：**先激活应用，再排窗口**。
///
/// ## 为什么必须先激活
///
/// 实测（build 56 测量包，2026-10-26 18:31:49.933）：应用不在前台时，
/// 只调 `makeKeyAndOrderFront` 之后 `NSApp.keyWindow` 仍是 `nil`、`isActive` 仍是 `0`
/// —— 它只在**本应用内部**把窗口排到最前，整组窗口依然落在前台 App 的窗口下面，
/// 屏幕上看不出任何变化。那一刻的窗口顺序实测是 `WorkBuddy | 闪寻设置`，
/// 700 ms 内一次都没翻上来。
///
/// 反过来，只要应用被激活，窗口就自然回到前面 —— 所以在前面先 `activate`。
@MainActor
func raisePresentedPreferencesWindow() {
    NSApp.activate(ignoringOtherApps: true)
    restorePresentedPreferencesWindow()
}

/// 钥匙串授权框关掉之后，把设置/向导窗口提回最前。
///
/// ## 它修的是什么
///
/// 报障原话：「每次更新重新登陆后，输入钥匙串密码后，闪寻设置界面就闪退了」。
/// 这不是闪退，甚至不是进程退出 —— 逐项查过：
///
/// - 统一日志（2026-10-26 17:24:38）：进程状态由 `running-active` 变成
///   `running-active-NotVisible`，**pid 一直活到 17:25:14 之后**；
/// - 没有 AppKit 的 `finishing close`，说明**窗口也没关**；
/// - 崩溃报告机制本身是好的（同时段用段错误程序验证过，立刻产出 `.ips`），
///   而闪寻没有报告 —— 本来就不是崩溃。
///
/// 真因是**层叠**：那个授权框属于系统（SecurityAgent），框一关，系统把激活还给
/// **先前活跃的另一个 App**。闪寻是 `LSUIElement` 常驻应用，不会自己回到前台，
/// 它的窗口就整组落到对方窗口后面 —— 屏幕上只剩对方，用户看到的就是
/// 「界面凭空消失」。日志里对应的就是那条 `FUSBProcessWindowState: occluded`。
///
/// 注意：本应用的其它入口（打开设置、打开向导）都是「激活 + show」成对出现，
/// 所以它们不受影响；只有钥匙串框这条**不动窗口、只交接激活**的路径会掉进去。
@MainActor
func bringPreferencesForwardAfterSystemPrompt() {
    guard !presentedPreferencesWindows().isEmpty else { return }
    raisePresentedPreferencesWindow()
    // 激活交接是异步的：框关掉之后系统才把激活还给那个 App，那一刻它的窗口会
    // 重新压上来。隔一拍再提一次 —— 两次都幂等，谁先到都不白做；
    // 用户若已经自己关了窗口，这次直接跳过，不去无谓地抢前台。
    Task { @MainActor in
        try? await Task.sleep(nanoseconds: 400_000_000)
        guard !presentedPreferencesWindows().isEmpty else { return }
        raisePresentedPreferencesWindow()
    }
}
