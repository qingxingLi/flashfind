import Foundation

private extension String {
    /// NSPredicate 的 `LIKE` 里 `*`、`?`、`\` 是通配符，字面量必须先转义。
    var escapedForLike: String {
        replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "*", with: "\\*")
            .replacingOccurrences(of: "?", with: "\\?")
    }
}

@MainActor
public final class SpotlightProvider {
    private let query = NSMetadataQuery()
    private var observer: NSObjectProtocol?
    private var continuation: CheckedContinuation<[SearchResult], Error>?
    private var deadline: Timer?
    public private(set) var searchWasIncomplete = false
    public private(set) var deadlineExceeded = false
    public init() {}
    /// - Parameters:
    ///   - text: 名字关键词（已由 `SearchQueryParser` 剥离格式词）。
    ///   - extensions: 格式限制。**直接写进 Spotlight 谓词**，而不是取回来再筛：
    ///     Spotlight 一次查询只回前 200 条，先取后筛会把真想要的结果挤掉。
    ///     两者都为空时才返回空（没有任何条件可查）。
    ///   - folders: 查询范围。**产品代码一律走默认空值，不要传** ——
    ///     这条路的含义是「整台 Mac」，而残留的旧文件夹会把它缩成那几个目录，
    ///     界面写着全盘却搜不到全盘（审核新发现）。要限定目录请走
    ///     `LocalFolderSearch`（真遍历、不碰索引）。
    public func search(_ text: String, extensions: [String] = [], folders: [URL] = []) async throws -> [SearchResult] {
        searchWasIncomplete = false;deadlineExceeded = false
        let terms = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty || !extensions.isEmpty else { return [] }
        let availability = await SpotlightAvailability.inspect()
        try Task.checkCancellation()
        guard availability.state == .available else { throw FlashFindError.message(availability.message) }
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                query.searchScopes = folders.isEmpty ? [NSMetadataQueryLocalComputerScope] : folders
                var predicates = terms.map { term -> NSPredicate in
                    NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*" + term.escapedForLike + "*")
                }
                if !extensions.isEmpty {
                    // 多个扩展名之间是「或」：`测试报告 ppt` 要同时出 .ppt 和 .pptx。
                    let choices = extensions.map { ext in
                        NSPredicate(format: "%K LIKE[cd] %@", NSMetadataItemFSNameKey, "*." + ext.escapedForLike)
                    }
                    predicates.append(choices.count == 1 ? choices[0] : NSCompoundPredicate(orPredicateWithSubpredicates: choices))
                }
                query.predicate = predicates.count == 1 ? predicates[0] : NSCompoundPredicate(andPredicateWithSubpredicates: predicates)
                observer = NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidFinishGathering,
                                                                  object: query, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated { self?.finish() }
                }
                deadline = Timer(timeInterval: 5, repeats: false) { [weak self] _ in
                    MainActor.assumeIsolated { self?.deadlineExceeded = true; self?.searchWasIncomplete = true; self?.finish() }
                }
                RunLoop.main.add(deadline!, forMode: .common)
                if !query.start() { complete(.failure(FlashFindError.message("Spotlight 查询未能启动，请检查系统索引"))) }
            }
        } onCancel: { Task { @MainActor [weak self] in self?.cancel() } }
    }
    public func cancel() { complete(.failure(CancellationError())) }
    private func finish() {
        guard continuation != nil else { return }
        query.disableUpdates()
        searchWasIncomplete = searchWasIncomplete || query.resultCount > 200
        var results: [SearchResult] = []
        for index in 0..<min(query.resultCount, 200) {
            guard let item = query.result(at: index) as? NSMetadataItem,
                  let path = item.value(forAttribute: NSMetadataItemPathKey) as? String else { continue }
            let url = URL(fileURLWithPath: path)
            guard (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else { continue }
            let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey])
            results.append(SearchResult(id: "local:" + path, name: url.lastPathComponent, relativePath: path,
                                        sourceID: "local_mac", sourceName: "本机", kind: values?.isDirectory == true ? "directory" : "file",
                                        size: values?.fileSize.map(Int64.init), localURL: url))
            results[results.count - 1].modifiedDate = values?.contentModificationDate
        }
        complete(.success(results))
    }
    private func complete(_ result: Result<[SearchResult], Error>) {
        guard let continuation else { return }
        self.continuation = nil; query.stop(); deadline?.invalidate(); deadline = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }; observer = nil
        continuation.resume(with: result)
    }
}
