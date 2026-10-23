import Foundation

/// 关掉一个窗口之后，屏幕上还剩什么、要不要把搜索浮窗放回来。
///
/// ## 为什么这条规则必须被单独写下来、单独锁住
///
/// 闪寻是**常驻的搜索浮窗应用**：搜索浮窗、设置窗口、来源向导三者谁都不是
/// 「主窗口」，随手关掉任一个都可能让屏幕上什么都不剩。而 macOS 有一条
/// 不写在界面上的机制 —— **Automatic Termination**：应用没有可见窗口时，
/// 系统会把它标记成可回收并直接杀掉。
///
/// 现场表现是「点完登录就闪退」：向导窗口一关，进程没了，
/// **而且没有崩溃报告**（它不是崩溃，是被系统回收）。
/// 用户完全无法区分这两件事，只会认为程序有 bug、操作丢了。
///
/// 实测日志（2026-10-22 15:24:35）正是这一串：
///
/// ```
/// window <NSWindow: 0x13aa6a650> finishing close
/// [com.apple.AppKit:AutomaticTermination] Setting _kLSApplicationWouldBeTerminatedByTALKey=1
/// ```
///
/// 所以关窗之后必须二选一：要么把搜索浮窗放回来（用户有地方可点），
/// 要么进程靠 `disableAutomaticTermination` 保住（快捷键仍能唤起）。
/// 两件都做，因为这俩解决的是不同的失败：前者管「看得见」，
/// 后者管「进程还在」——只做前者，回收窗口关闭到浮窗出现之间的那几秒
/// 仍可能被系统判定为空闲；只做后者，用户会盯着一片桌面找不到入口。
public enum LastWindowClosePolicy {

    /// 关掉正在关闭的那个窗口之后，是否该把搜索浮窗放回来。
    ///
    /// - Parameter hasOtherVisibleWindow: 除正在关闭的这个之外，
    ///   是否还有别的**可见且能成为 key** 的窗口。
    ///
    /// 有别的窗口时**不抢焦点**：从设置里点「重新登录…」进向导是常见路径，
    /// 关掉向导应当回到设置窗口，而不是把搜索浮窗顶到设置前面 ——
    /// 那会把用户从「我还在改这台 NAS」的上下文里硬拽出来。
    public static func shouldRestoreSearchPanel(hasOtherVisibleWindow: Bool) -> Bool {
        !hasOtherVisibleWindow
    }

    /// 禁用自动终止的理由。
    ///
    /// 非 nil 表示应当禁用。理由串会进统一日志：出问题时能一眼看出
    /// 是谁、为什么把系统回收关掉了，而不是猜「这应用怎么不退出」。
    ///
    /// ★ 不能改成 nil 来「临时绕过」某个窗口问题：那会让应用在真正
    /// 无事可做时永远驻留，开发者本机的 `xctest` 与预览进程也会被拖住。
    public static let automaticTerminationDisabledReason =
        "闪寻常驻：窗口全部关闭后靠全局快捷键唤起，不应被系统回收"
}
