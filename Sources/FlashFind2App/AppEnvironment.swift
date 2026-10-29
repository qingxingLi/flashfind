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

    /// `FF_UI_DEMO=1` 且在预览包里：demo 来源按「已就绪」画。
    ///
    /// ★ 为什么必须有这一档：demo 结果挂在三台假来源名下，而位置栏的副标题
    ///   由 `ready` 决定（`SourceEntry.locationSubtitle`）。没有真实会话，
    ///   `ready` 恒为 false，截出来的图就是「列表里全是它的结果、位置栏却说
    ///   未连接」的自相矛盾。夹具摆什么状态是截图的事，不许反向影响生产判定。
    static var demoSourcesActive: Bool {
        #if DEBUG
        return isPreview && ProcessInfo.processInfo.environment["FF_UI_DEMO"] == "1"
        #else
        return false
        #endif
    }

    /// 预览演示：三台**不同厂商**的样例来源（群晖 / 飞牛 / OpenList）。
    ///
    /// 为什么单独定义一处：来源由 `NASSourceWizardController` 造，结果行的
    /// `sourceName` / `sourceID` 由 `AppModel` 写，两边必须一一对应——分开写名字，
    /// 改一个忘一个，截出来的图就会「来源列写着 A、位置栏里没有 A」。
    ///
    /// `host` 全落在 `192.0.2.0/24`（RFC 5737 的 TEST-NET-1，文档专用网段），
    // MARK: - 预览演示数据（`FF_UI_DEMO=1`）

    /// 演示结果行的公共形状。文件名、大小、修改时间都是编的；
    /// 分数仍由 `SearchRanking` 真算、排序仍走 `SearchResultMerge`。
    typealias DemoRow = (name: String, path: String, bytes: Int64, source: Int, daysAgo: Int)

    /// 第一组：查询词「2026」。三条来源各有命中，扩展名覆盖
    /// pdf / 图片 / 表格 / 视频 / 压缩包 / 音频 / 文档，类型条与图标才有东西可看；
    /// `daysAgo` 拉开，排序才看得出「新的在前」。
    static let demoRows: [DemoRow] = [
        ("2026年度产品路线图.pdf", "/Project/规划/2026年度产品路线图.pdf", 2_400_000, 1, 1),
        ("2026-京都-秋-001.jpg", "/Photo/旅行/2026-京都-秋-001.jpg", 5_600_000, 0, 3),
        ("2026-Q4-预算.xlsx", "/Document/财务/2026-Q4-预算.xlsx", 168_000, 1, 6),
        ("2026春节-家庭录像.mp4", "/Video/家庭/2026春节-家庭录像.mp4", 1_200_000_000, 0, 20),
        ("2026-09-自动备份.zip", "/Backup/2026-09-自动备份.zip", 340_000_000, 2, 32),
        ("2026-音乐节-现场.flac", "/Music/现场/2026-音乐节-现场.flac", 48_000_000, 2, 55),
        ("2026年度总结.docx", "/Document/汇报/2026年度总结.docx", 36_000, 1, 8),
        ("2026-10-会议纪要.md", "/Project/会议/2026-10-会议纪要.md", 12_000, 1, 2),
    ]

    /// 第二组：查询词「旅行」（`FF_UI_DEMO_SECOND`）。钉住第一组之后接着搜的
    /// 那一批——路径全含「旅行」，来源仍然三台各有份，跟第一组明显不是一批。
    static let demoSecondRows: [DemoRow] = [
        ("2026-京都-秋-001.jpg", "/Photo/旅行/2026-京都-秋-001.jpg", 5_600_000, 0, 3),
        ("京都五日行程单.pdf", "/Document/旅行/京都五日行程单.pdf", 88_000, 1, 5),
        ("2026春节-家庭录像.mp4", "/Video/旅行/2026春节-家庭录像.mp4", 1_200_000_000, 0, 20),
        ("行李打包清单.xlsx", "/Document/旅行/行李打包清单.xlsx", 24_000, 2, 12),
    ]

    /// 三台**不同厂商**的样例来源。与 `demoRows` 的 `source` 下标一一对应——
    /// 分开写名字，改一个忘一个，截出来的图就会「来源列写着 A、位置栏里没有 A」。
    /// 不会指向任何真实设备；搜根用通用的共享名，不用真机上的目录。
    static let demoSourceSpecs: [(id: String, name: String, vendor: NASSourceConfig.Vendor,
                                  host: String, scopes: [String])] = [
        ("preview-source-0", "家庭 NAS", .synology, "192.0.2.11", ["/Photo", "/Video"]),
        ("preview-source-1", "书房 NAS", .fnos, "192.0.2.12", ["/Project", "/Document"]),
        ("preview-source-2", "云盘", .openlist, "192.0.2.13", ["/Music", "/Backup"]),
    ]
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
