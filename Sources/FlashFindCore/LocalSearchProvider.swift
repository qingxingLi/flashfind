import Foundation

@MainActor public final class LocalSearchProvider: SearchProvider {
    public let source = SearchSource.local
    private var active: UUID?
    private var spotlight: SpotlightProvider?
    /// 文件夹模式的后台遍历。**存句柄是为了能取消**：`Task.detached` 不继承
    /// 调用方的取消，不握住它的话，输入框一改就废弃的那次搜索仍会在后台跑满
    /// 3 秒预算，而界面早就切到新的一次查询了。
    private var folderTask: Task<LocalFolderSearchReport, Error>?
    public var folders: [URL] = []
    /// 本机搜索方式。
    ///
    /// ★ 这一项是 `folders` 判不出来、必须由设置显式给出的：
    /// 从「已选文件夹」切回「整台 Mac」时用户挑过的文件夹**仍留在 `localFolders` 里**
    /// （切换方式不清空它们，重新切回去时还要用）。只凭 `folders` 是否为空判断，
    /// 那几台刚切回全盘搜索的 Mac 会继续被旧文件夹限制住，搜不到全盘。
    public var mode: LocalSearchMode = .spotlight
    public init() {}

    public func cancel(queryID: UUID) {
        guard active == queryID else { return }
        active = nil
        spotlight?.cancel()
        folderTask?.cancel()
    }

    public func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent)->Void) async {
        active = queryID
        emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .searching))
        // 与 NAS 侧同一套解析：`测试报告 ppt` 的 ppt 是格式限制，不是名字的一部分。
        let parsed = SearchQueryParser.parse(text)
        switch mode {
        case .selectedFolders:
            await searchSelectedFolders(parsed, queryID: queryID, emit: emit)
        case .spotlight:
            await searchWithSpotlight(parsed, queryID: queryID, emit: emit)
        }
    }

    // MARK: - 已选文件夹：目录遍历，不碰系统索引

    /// 界面上这一项写的是「**无需系统索引**」，索引关着时设置页还会主动引导
    /// 用户切过来。所以它必须真的不看索引——否则用户被我们自己的提示领进死路：
    /// 设置页显示没问题，一搜就失败。
    private func searchSelectedFolders(_ parsed: ParsedSearchQuery, queryID: UUID,
                                       emit: @escaping @MainActor (ProviderEvent)->Void) async {
        let folders = self.folders, keywords = parsed.keywords, extensions = parsed.extensions
        do {
            // ★ 遍历是同步的、最长跑满 3 秒预算，而这个 provider 在 @MainActor 上：
            // 不放后台的话整条主线程被占住，界面会卡住。
            let task = Task.detached(priority: .userInitiated) {
                try LocalFolderSearch.search(keywords, folders: folders, extensions: extensions)
            }
            folderTask = task
            let report = try await task.value
            folderTask = nil
            guard active == queryID, !Task.isCancelled else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, results: report.results,
                               state: .completed, message: report.warnings.first,
                               isComplete: report.warnings.isEmpty))
        } catch is CancellationError {
            folderTask = nil
            guard active == queryID else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .cancelled))
        } catch let error as FlashFindError {
            folderTask = nil
            guard active == queryID else { return }
            // 原因要说具体的（「请选择要搜索的本机文件夹；不会自动扫描全盘」
            // 「不能将文件系统根目录用作降级搜索范围」）。统一成一句
            // 「本机搜索暂不可用」的话，用户只会以为闪寻坏了，而其实是他能改的。
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                               message: error.errorDescription))
        } catch {
            folderTask = nil
            guard active == queryID else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .failed,
                               message: "本机搜索暂不可用"))
        }
    }

    // MARK: - 整台 Mac：系统索引

    private func searchWithSpotlight(_ parsed: ParsedSearchQuery, queryID: UUID,
                                     emit: @escaping @MainActor (ProviderEvent)->Void) async {
        let provider = SpotlightProvider(); spotlight = provider
        do {
            // ★ 整台 Mac 就是整台 Mac：**不把 `folders` 转发给 Spotlight**。
            //
            // 从「已选文件夹」切回「整台 Mac」时，用户挑过的文件夹仍留在
            // `localFolders` 里（切换方式不清空它们，切回去还要用）。这里若顺手转发，
            // `NSMetadataQuery.searchScopes` 就会变成那几个旧目录 —— 界面写着「整台 Mac」，
            // 实际只在旧文件夹里找，用户搜全盘必然空手而归（审核新发现）。
            //
            // 该走哪条路由 `mode` 决定；走到这条分支就只剩「全盘」一种含义，
            // 所以 `folders` 在这一分支里根本不该被读到。要限定目录就走
            // `searchSelectedFolders`（真遍历、不碰索引）。
            let results = try await provider.search(parsed.keywords, extensions: parsed.extensions)
            guard active == queryID, !Task.isCancelled else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id, results: results,
                               state: provider.deadlineExceeded ? .timedOut : .completed,
                               message: provider.searchWasIncomplete ? "本机查询达到时间或数量上限" : nil,
                               isComplete: !provider.searchWasIncomplete))
        } catch {
            guard active == queryID else { return }
            emit(ProviderEvent(queryID: queryID, sourceID: source.id,
                               state: error is CancellationError ? .cancelled : .failed,
                               message: "本机搜索暂不可用"))
        }
    }
}
