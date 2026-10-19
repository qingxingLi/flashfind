import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「浮窗会话」分区（Stage 3A）。
//
// 两件小事，一个主题：**这一轮会话的痕迹留多久**。
//   - 键位提示：新人第一次打开才出现，之后永不再现（记在偏好里）；
//   - 查询与结果：关掉 30 秒内再打开要接着用，超过就清空，且无论保留与否
//     都要重新校验结果是否还对得上当前设置。
// 它们都只跟「这一次打开」有关，跟搜索本身、跟连接状态都无关，所以放一起。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    // MARK: - 首次搜索的键位提示
    //
    // 状态 `searchHintsVisible` 留在主文件：Swift 的 extension 不能含存储属性，
    // 这是分文件 extension 的硬约束，不是设计取舍。行为未变。

    /// 搜索窗出现时调用。只显示一次，之后不再出现。
    ///
    /// 输入框里已经有词时不摆这一行：那说明用户在继续上次的搜索，
    /// 一行新人提示只会挤占结果区。
    func showSearchHintsIfNeeded() {
        guard !AppEnvironment.isPreview, SearchHintGuide.shouldShow(preferences: preferences) else { return }
        guard query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        searchHintsVisible = true
    }

    /// 用户一开始输入或操作就收起，并记为「已显示过」。
    func dismissSearchHints() {
        guard searchHintsVisible else { return }
        searchHintsVisible = false
        SearchHintGuide.markShown(preferences: preferences)
    }

    /// 重新打开搜索浮窗。
    ///
    /// 短时间关闭再打开时，保留上一次的查询与结果——
    /// 常常是为了「关掉去点个复制，再回来接着看」，
    /// 如果这时清空，用户得把同一个词重新敲一遍。
    ///
    /// 保留期限由 `SearchSessionMemory` 决定：超过就清空，
    /// 因为此时用户大概率是开始一件新的事，
    /// 留着旧结果反而让人以为搜的是那个词。
    ///
    /// 无论保留与否都会重新校验结果有效性：搜索范围、启用的来源或
    /// 显示隐藏文件等设置一旦变了，旧结果就不再对应当前状态，
    /// 由 `canUseDisplayedResults` 拦下，不会拿过期结果冒充。
    func showSearch() {
        defer { hiddenAt = nil }
        // 恢复策略复用 FlashFindCore.SearchSessionMemory，与单元测试共用同一份判定。
        guard SearchSessionMemory.shouldRestore(hiddenAt: hiddenAt,
                                               hasQuery: !displayedQuery.isEmpty,
                                               resultsAreValid: canUseDisplayedResults) else {
            if hiddenAt != nil { clearSearchSession() }
            return
        }
        // 结果仍有效：只把查询词放回输入框，不重新发起搜索。
        query = displayedQuery
    }

    /// 清空搜索会话：查询词与结果一起清。
    ///
    /// 只清 `query` 而留着 `results` 会造成「输入框空了但下面还有一串结果」，
    /// 那是明显自相矛盾的界面。
    func clearSearchSession() {
        query = ""
        results = []
        selected = nil
        searchFailure = nil
        searchWarnings = []
        resultsAreCurrent = false
        displayedQuery = ""
        changedQuery()
    }

    /// 关闭浮窗。只记住关闭时间，不动查询与结果——
    /// 是否保留由 `showSearch` 按保留期决定。
    func hideSearch() {
        hiddenAt = Date()
        // 由面板自己收窗口，不能按 keyWindow 收：点其它应用时 keyWindow 为 nil，
        // 面板关不掉；而若设置窗口恰好是 key，又会把设置窗口一起关掉。
        hidePanel?()
        // 关闭路径不止一条（点外部、按 Esc、菜单栏退出、关设置…），
        // 统一在这里广播，让控制器卸载事件监视——靠各处自己记得卸载一定会漏。
        NotificationCenter.default.post(name: .flashFindPanelHidden, object: nil)
    }
}
