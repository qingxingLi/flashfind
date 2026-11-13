import Foundation
import FlashFindCore

/// 一次「可能弹系统钥匙串授权框」的读，从发起到返回的时间窗。
///
/// 判据在 Core（`SystemPromptFocusPolicy`），这里只记两件事：框是不是还没回来、
/// 以及回来多久了。`SearchPanelController` 在 mouseDown 那一刻把结论拍进快照，
/// 异步判定不许再读一次「现在」——否则宽限期会被读没，界面照样消失。
@MainActor
final class SystemPromptGuard {
    @MainActor static let shared = SystemPromptGuard()

    private var inFlight = false
    private var endedAt: Date?

    var blocksDismissal: Bool {
        SystemPromptFocusPolicy.blocksDismissal(
            promptInFlight: inFlight,
            secondsSincePromptEnded: endedAt.map { Date().timeIntervalSince($0) })
    }

    /// 包住一次同步读。`defer` 保证用户点「拒绝」、授权超时等所有出口都收口，
    /// 不会把 `inFlight` 永远留在 true、让浮窗此后再也点不收。
    func around<T>(_ body: () -> T) -> T {
        inFlight = true
        endedAt = nil
        defer {
            inFlight = false
            endedAt = Date()
        }
        return body()
    }
}
