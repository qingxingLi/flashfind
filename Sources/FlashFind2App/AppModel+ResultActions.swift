import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「结果定位与打开」分区（Stage 3A）。
//
// 一组彼此咬合的动作：绑定挂载目录 → 解析结果 URL（必要时触发挂载）→ 打开 /
// 预览 / 复制 / 在 Finder 中定位。它们共同回答一个问题：**搜到的这一条，
// 用户到底能不能打开**。所以放在一起，不按「转发 / 非转发」拆散。
//
// 行为一行未改，调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────
extension AppModel {
    func bind(_ source: Source) {
        if fixtureMode, let id = selectedConnectionID {
            _ = updateProfile(id, { $0.bindings[source.id] = MountBinding(root: AppEnvironment.previewRoot.appendingPathComponent("MockMount")) })
            updateCompatibility(); status = "UI 样例：绑定已保存到内存"; return
        }
        guard !AppEnvironment.isPreview, let id = selectedConnectionID,
              connectionStates[id]?.sources.contains(source) == true else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let binding = MountBinding(root: url, bookmark: try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        guard updateProfile(id, { $0.bindings[source.id] = binding }) else { return }
        updateCompatibility(); invalidate(); changedQuery(); status = "已绑定 " + source.name
    }
    func currentResult(_ result: SearchResult) -> SearchResult? {
        guard canUseDisplayedResults, let row = results.first(where: { $0.id == result.id }) else { return nil }
        if let id = row.connectionID {
            guard enabled, let profile = nasConnections.first(where: { $0.id == id }), profile.enabled,
                  profile.cacheProfile == row.accountProfile, let runtime = runtimes[id], !runtime.blocked,
                  runtime.permissionRevision == row.permissionRevision, profile.selectedSourceIDs.contains(row.sourceID ?? ""),
                  connectionStates[id]?.sources.contains(where: { $0.id == row.sourceID }) == true else { return nil }
        }
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
        guard let id = result.connectionID, let profile = nasConnections.first(where: { $0.id == id }),
              let sourceID = result.sourceID, let source = connectionStates[id]?.sources.first(where: { $0.id == sourceID }),
              let binding = profile.bindings[sourceID] else { throw FlashFindError.message("请先为此 NAS 来源绑定 SMB 挂载目录") }
        return try binding.resolve(source: source, relativePath: result.relativePath)
    }

    func preferredOpenTarget(_ result: SearchResult) async throws -> SearchOpenTarget {
        if let sourceID = result.sourceID,
           let provider = nativeProviders.values.first(where: { $0.source.id == sourceID }),
           provider.config.vendor == .synology || provider.config.vendor == .openlist {
            return try await provider.preferredOpenTarget(result)
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
        return try fileURLSync(result)
    }

    func fileURLSync(_ result: SearchResult) throws -> URL {
        guard let id = result.connectionID, let profile = nasConnections.first(where: { $0.id == id }),
              let sourceID = result.sourceID, let source = connectionStates[id]?.sources.first(where: { $0.id == sourceID }),
              let binding = profile.bindings[sourceID] else { throw FlashFindError.message("请先为此 NAS 来源绑定 SMB 挂载目录") }
        return try binding.resolve(source: source, relativePath: result.relativePath)
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
    func copyName(_ result: SearchResult) { resultActions.copyName(result) }
    func open(_ result: SearchResult, reveal: Bool = false) { resultActions.open(result, reveal: reveal) }
    /// 用户主动要求时才请访达发起 SMB 连接；实现在 controller 里，那里有完整说明。
    func connectInFinder(_ smbURL: String) { resultActions.connectInFinder(smbURL) }
    /// 用户在提示条上点「重试」。
    func retryOpenCurrentResult() { resultActions.retryOpen(selectedResult) }
    /// 复制路径（不需要挂载）。
    func copy(_ result: SearchResult) { resultActions.copyPath(result) }
    /// 复制网页链接。只有网页来源（OpenList 这类）有；与「复制路径」是两个不同结果。
    func copyWebLink(_ result: SearchResult) { resultActions.copyWebLink(result) }
    func openServerManagement() {
        guard !AppEnvironment.isPreview, let id = selectedConnectionID,
              let profile = nasConnections.first(where: { $0.id == id }), let url = URL(string: profile.address), url.scheme == "https" else { return }
        if !NSWorkspace.shared.open(url) { status = "系统无法打开服务器管理页面" }
    }
}
