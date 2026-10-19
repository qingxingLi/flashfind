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
        var results = [
            SearchResult(id: "preview-1", name: "项目设计说明.pdf", relativePath: "团队文档/闪寻/项目设计说明.pdf", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 1240000, localURL: nil),
            SearchResult(id: "preview-2", name: "项目资料", relativePath: "团队文档/项目资料", sourceID: "preview", sourceName: "团队共享", kind: "directory", size: 0, localURL: nil),
            SearchResult(id: "preview-3", name: "项目进度.xlsx", relativePath: "团队文档/计划/项目进度.xlsx", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 48200, localURL: nil),
            SearchResult(id: "preview-4", name: "项目讨论记录.txt", relativePath: "团队文档/记录/项目讨论记录.txt", sourceID: "preview", sourceName: "团队共享", kind: "file", size: 9200, localURL: nil)
        ]
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
        return results
    }
}
