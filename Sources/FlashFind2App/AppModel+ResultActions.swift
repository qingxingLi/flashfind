import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「结果定位与打开」分区（Stage 3A）。
//
// 一组彼此咬合的动作：解析结果 URL（必要时触发挂载）→ 打开 / 预览 / 复制 /
// 在 Finder 中定位。它们共同回答一个问题：**搜到的这一条，用户到底能不能打开**。
// 所以放在一起，不按「转发 / 非转发」拆散。
//
// 2026-10-28 清理：删掉了服务端线残留的「bind / 挂载绑定」分支与 openServerManagement
//（那条产品线已废弃，且没有任何界面调用方）。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    /// 当前列表里这一行还能不能操作（还在这批结果里）。
    func currentResult(_ result: SearchResult) -> SearchResult? {
        guard canUseDisplayedResults, results.contains(where: { $0.id == result.id }) else { return nil }
        return actionableRow(result)
    }

    /// 钉在桌面上的那一批里的行。
    ///
    /// ★ 与 `currentResult` 只差**一条**：不要求它此刻还在 `results` 里。
    ///   钉住的意义就是「搜索框去搜下一组，这一批留着」，所以「不在当前结果里」
    ///   是**常态**，不是失效。但来源开关这些照旧要核——
    ///   钉住的结果也可能因为断开 NAS 而打不开，那时该说「搜索或权限已变化」。
    func pinnedResult(_ result: SearchResult) -> SearchResult? { actionableRow(result) }

    private func actionableRow(_ row: SearchResult) -> SearchResult? {
        return row
    }
    /// 解析结果的本地 URL。
    ///
    /// NAS 来源在**没有挂载**时会自动发起后台挂载，再重新解析——
    /// 否则搜索能出结果、Finder 却打不开，用户会以为坏了。
    func fileURL(_ result: SearchResult) async throws -> URL {
        if let local = result.localURL { return local }
        if let sourceID = result.sourceID,
           let provider = nativeProviders.values.first(where: { $0.source.id == sourceID }) {
            return try await provider.verifiedFileURL(result)
        }
        throw FlashFindError.message("此结果来自已下线的搜索来源，无法打开")
    }

    func preferredOpenTarget(_ result: SearchResult) async throws -> SearchOpenTarget {
        if let sourceID = result.sourceID,
           let provider = nativeProviders.values.first(where: { $0.source.id == sourceID }) {
            // ★ 飞牛这一路**自己带网页兜底**（SMB 不可达 → 文件管理器）：
            //   目标类型必须原样传出去。包成 `.mountedFile` 的话，
            //   「在访达中显示」会把一个浏览器地址当本地路径去碰 Finder。
            if provider.config.vendor == .fnos {
                return try await provider.verifiedOpenTarget(result)
            }
            if provider.config.vendor == .synology || provider.config.vendor == .openlist {
                return try await provider.preferredOpenTarget(result)
            }
        }
        if case .webURL = result.openTarget { return result.openTarget }
        return .mountedFile(try await fileURL(result))
    }

    /// 只查已挂载的解析结果，不触发挂载。用于「能否打开」的判定。
    func fileURLWithoutMounting(_ result: SearchResult) throws -> URL {
        if let local = result.localURL { return local }
        if let sourceID = result.sourceID,
           let provider = nativeProviders.values.first(where: { $0.source.id == sourceID }) {
            return try provider.verifiedFileURLWithoutMounting(result)
        }
        throw FlashFindError.message("此结果来自已下线的搜索来源，无法打开")
    }

    func openSelectedResult() { if let row = results.first(where: { $0.id == selected }) { openCurrentResult(row) } }
    var selectedResult: SearchResult? { results.first { $0.id == selected } }
    /// ⌘↵：在 Finder 中定位当前结果。
    func revealSelectedResult() { if let row = selectedResult { openCurrentResult(row, reveal: true) } }
    /// Space：快速查看当前结果。
    func quickLookSelectedResult() { if let row = selectedResult { quickLook(row) } }
    func openCurrentResult(_ result: SearchResult, reveal: Bool = false) { open(result, reveal: reveal) }

    // 以下五个动作的实现在 ResultActionController；这里保留签名是为了调用点零改动
    // （SearchView、菜单、快捷键作用域都直接调 AppModel）。
    func quickLook(_ result: SearchResult) { resultActions.quickLook(result) }

    /// 这条结果的来源是否提供右键「下载」动作（fnOS）。
    func supportsDirectDownload(_ result: SearchResult) -> Bool {
        resultActions.supportsDownloadRow(result)
    }
    /// 右键「下载后打开」：下载到临时目录并交系统默认程序打开。
    func downloadAndOpen(_ result: SearchResult) { resultActions.downloadAndOpen(result) }
    /// 右键「下载到…」：弹保存框选位置，完成后在访达里显示。
    func downloadToFolder(_ result: SearchResult) { resultActions.downloadToFolder(result) }
    func copyName(_ result: SearchResult) { resultActions.copyName(result) }
    func open(_ result: SearchResult, reveal: Bool = false) { resultActions.open(result, reveal: reveal) }

    // 钉住的窗口用的是**快照**里的行：那一批已经不在 `results` 里了，
    // 所以解析要走 `pinnedResult`（只核来源与权限，不核「还在不在结果里」）。
    private var pinnedResolver: (SearchResult) -> SearchResult? {
        { [weak self] result in self?.pinnedResult(result) }
    }
    func openPinned(_ result: SearchResult, reveal: Bool = false) {
        resultActions.open(result, reveal: reveal, resolve: pinnedResolver)
    }
    func quickLookPinned(_ result: SearchResult) { resultActions.quickLook(result, resolve: pinnedResolver) }
    func copyPinned(_ result: SearchResult) { resultActions.copyPath(result, resolve: pinnedResolver) }
    func copyPinnedWebLink(_ result: SearchResult) { resultActions.copyWebLink(result, resolve: pinnedResolver) }
    /// 用户主动要求时才请访达发起 SMB 连接；实现在 controller 里，那里有完整说明。
    func connectInFinder(_ smbURL: String) { resultActions.connectInFinder(smbURL) }
    /// 用户在提示条上点「重试」。
    func retryOpenCurrentResult() { resultActions.retryOpen(selectedResult) }
    /// 复制路径（不需要挂载）。
    func copy(_ result: SearchResult) { resultActions.copyPath(result) }
    /// 复制网页链接。只有网页来源（OpenList 这类）有；与「复制路径」是两个不同结果。
    func copyWebLink(_ result: SearchResult) { resultActions.copyWebLink(result) }
}
