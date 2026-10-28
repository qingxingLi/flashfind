import AppKit
import Foundation
import FlashFindCore

/// The preview bundle opts in at packaging time; production never uses fixtures.
enum AppEnvironment {
    static let isPreview = Bundle.main.object(forInfoDictionaryKey: "FlashFindUIOnlyPreview") as? Bool == true
    static let defaults: UserDefaults = isPreview
        ? UserDefaults(suiteName: "com.flashfind.ui-fixtures.pm-ui-003")! : .standard
    static var previewRoot: URL {
        Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("PreviewData", isDirectory: true)
    }
    static var previewAppearance: NSAppearance? {
        guard isPreview, let name = ProcessInfo.processInfo.environment["FF_UI_APPEARANCE"] else { return nil }
        return NSAppearance(named: name == "dark" ? .darkAqua : .aqua)
    }
    static func fixtures(for query: String) -> [SearchResult] {
        guard !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return [] }
        if query == "empty" || query == "error" { return [] }
        let now = Date()
        var results = [
            SearchResult(id: "preview-1", name: "项目设计说明.pdf", relativePath: "团队文档/闪寻/项目设计说明.pdf", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 1240000, localURL: nil),
            SearchResult(id: "preview-2", name: "项目资料", relativePath: "团队文档/项目资料", sourceID: "preview", sourceName: "团队共享", kind: "directory", size: 0, localURL: nil),
            SearchResult(id: "preview-3", name: "项目进度.xlsx", relativePath: "团队文档/计划/项目进度.xlsx", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 48200, localURL: nil),
            SearchResult(id: "preview-4", name: "项目讨论记录.txt", relativePath: "团队文档/记录/项目讨论记录.txt", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 9200, localURL: nil)
        ]
        // ★ 夹具也要走**真实的评分与排序**：手工构造的结果如果 score 是 0，
        //   截图里的顺序就与真机不同（`SearchResultMerge` 会退回 rank 口径），
        //   那个截图就只能证明「界面能摆几行」，证明不了「按匹配度与时间排」。
        //   时间从 1 天前起，每条晚一天，这样同一分数下顺序是确定的。
        for index in results.indices {
            results[index].modifiedDate = now.addingTimeInterval(-86_400 * Double(index + 1))
            results[index].score = SearchRanking.score(
                name: results[index].name, path: results[index].relativePath, query: query,
                modified: results[index].modifiedDate, now: now).score
        }
        if query == "long" {
            results[0].name = "闪寻客户端原生搜索界面与权限隔离验证记录_2026年第四季度最终评审版本.pdf"
            results[0].relativePath = "团队文档/项目/闪寻客户端/界面设计/2026年第四季度评审与确认/闪寻客户端原生搜索界面与权限隔离验证记录_2026年第四季度最终评审版本.pdf"
        }
        if query == "many" {
            return (0..<12).map { index in
                var result = results[index % results.count]
                result.id = "preview-\(index + 1)"
                return result
            }
        }
        if query == "truncated" {
            // 240 条：超过 200 的上限 ⇒ 状态栏显示「200 / 240 项」。
            // 名字与时间都随下标变化，排序才看得出「按相关度与新近度」，
            // 而不是「谁先构造谁在前」。
            return (0..<240).map { index in
                var result = results[index % results.count]
                result.id = "preview-\(index + 1)"
                result.name = "项目资料-\(String(format: "%03d", index)).pdf"
                result.relativePath = "团队文档/项目/项目资料-\(String(format: "%03d", index)).pdf"
                result.modifiedDate = now.addingTimeInterval(-86_400 * Double(index))
                result.score = SearchRanking.score(name: result.name, path: result.relativePath,
                                                   query: "项目资料", modified: result.modifiedDate,
                                                   now: now).score
                return result
            }
        }
        return results
    }
}
