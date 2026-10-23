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
