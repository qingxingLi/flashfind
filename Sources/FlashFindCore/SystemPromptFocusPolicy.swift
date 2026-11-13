import Foundation

/// 系统授权框（钥匙串密码 / 「始终允许」）前后的界面保护判据。
///
/// 2026-11-13 报障原话：「第一次打开，弹出输入钥匙串密码后，输入后闪寻的
/// 搜索框直接关闭了，这个如果是新用户，就会觉得软件不能用啊」。
///
/// 1.1.70 的启动解锁 `primeVaultCache()` 会弹系统框，却**绕开**了
/// `CredentialStore.onInteractiveRead`（那条只由 `read(allowInteraction:)` 触发），
/// 于是既有的 `bringPreferencesForwardAfterSystemPrompt()` 根本没被调用；同时
/// 失焦期间补挂的全局点击监视把「在授权框里点一下」判成点在闪寻之外，真把浮窗
/// 收掉了。两条路径各自都能让界面消失，判据因此集中在这里：App 层只取现状、只执行。
public enum SystemPromptFocusPolicy {

    /// 授权框结束后，仍把「点外部」当成误触拦住的时长（秒）。
    ///
    /// 要盖住两件事：框关掉那一刻还留在事件队列里的 `leftMouseDown`，以及系统把
    /// 激活交回先前 App 的异步回跳。宁可 1.2 秒内多点一次外面不收窗，也不能让
    /// 用户输完密码看到一片空桌面。
    public static let dismissalGrace: TimeInterval = 1.2

    /// 启动解锁推迟到搜索框已经画出来、拿到焦点之后再跑（秒）。
    /// 不做这一步，系统框会在启动那一帧直接盖住还没出现的界面。
    public static let startupUnlockDelay: TimeInterval = 0.8

    /// 发起解锁之前，搜索浮窗的可见性。
    public enum VisibilityBeforePrompt: Sendable, Equatable {
        case visible
        case hidden
        /// 面板还没建好 / 拿不到状态。
        ///
        /// ★★ 不许当成 `hidden`：「不知道」不是「用户主动收起了」（缺证据 ≠ 反证据）。
        /// 按「可能可见」处理才不会让界面在授权之后凭空消失；兜底动作是最轻的
        /// `.activateOnly`，不会把用户自己收起的窗口强行弹出来。
        case unknown
    }

    public enum Recovery: String, Sendable, Equatable {
        case none
        /// 浮窗还在，只是被激活交接压到后面：激活 + 提回最前，不重建视图、不动查询。
        case activateOnly
        /// 浮窗被那一下点击收掉了：重新显示。
        case showAndActivate
    }

    /// 此刻该不该拦住「点外部收窗」。
    public static func blocksDismissal(promptInFlight: Bool,
                                       secondsSincePromptEnded: TimeInterval?,
                                       grace: TimeInterval = dismissalGrace) -> Bool {
        if promptInFlight { return true }
        guard let gap = secondsSincePromptEnded else { return false }
        // 负值是系统时钟回拨，不该被当成「刚结束」而永久拦住收窗。
        return gap >= 0 && gap < grace
    }

    /// 授权框关掉之后该怎么把界面找回来。
    ///
    /// 判据用「有没有」：本来就没显示的浮窗不擅自弹回来；设置/向导/引导正在呈现时
    /// 交给它们自己的救援，别把搜索框顶到用户正在填的表单前面。
    public static func recovery(visibilityBeforePrompt: VisibilityBeforePrompt,
                                isVisibleAfterPrompt: Bool,
                                hasPreferencesWindow: Bool,
                                onboardingVisible: Bool) -> Recovery {
        guard !hasPreferencesWindow, !onboardingVisible else { return .none }
        guard visibilityBeforePrompt != .hidden else { return .none }
        return isVisibleAfterPrompt ? .activateOnly : .showAndActivate
    }
}
