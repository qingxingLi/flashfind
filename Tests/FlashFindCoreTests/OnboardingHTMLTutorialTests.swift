import XCTest
@testable import FlashFindCore

final class OnboardingHTMLTutorialTests: XCTestCase {
    private var client: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTutorialCoversSearchPreviewFilterPinAndContinue() throws {
        let html = try String(contentsOf: client.appendingPathComponent("Resources/Onboarding/search-demo.html"), encoding: .utf8)
        for required in ["周杰伦", "Space", "preview", "data-type-id", "继续搜索", "钉住",
                         "continue", "prefers-reduced-motion"] {
            XCTAssertTrue(html.contains(required), "缺少教学环节：\(required)")
        }
        XCTAssertFalse(html.contains("https://"), "离线演示不应依赖外部素材")
    }

    /// 演示里的类型条必须与真实类型条**同序同标签**。
    ///
    /// 引导最容易过期的不是措辞，是**顺序**：Core 里加了/调整了一个类型，
    /// 演示还按老顺序排，用户记住的位置就与界面对不上。所以这里直接拿
    /// `SearchTypeBar.entries` 当唯一事实源，逐段比对 id 序列。
    func testTutorialTypeBarMirrorsRealTypeBarOrder() throws {
        let html = try String(contentsOf: client.appendingPathComponent("Resources/Onboarding/search-demo.html"), encoding: .utf8)
        let ids = Self.typeBarIDs(in: html)
        XCTAssertEqual(ids, SearchTypeBar.entries.map(\.id),
                       "演示里的类型条顺序/数量必须与 Core 的 SearchTypeBar 一致")
        // 阳性对照：确实抽到了内容，而不是正则失效导致空数组「恰好」……
        XCTAssertFalse(ids.isEmpty)
    }

    /// `/` 与 `\` 唤起的命令面板已于 2026-10-28 删除，引导不能再教它们。
    ///
    /// 这条是**回归守卫**：演示页曾经整章在教「输入 / 选类型、输入 \ 选位置、
    /// 按数字 9」—— 用户在界面上按下去什么都不发生。界面里有的只有
    /// 类型条与左侧位置栏，演示也必须只讲这两样。
    func testTutorialDoesNotTeachRemovedSlashCommands() throws {
        let html = try String(contentsOf: client.appendingPathComponent("Resources/Onboarding/search-demo.html"), encoding: .utf8)
        // 阳性对照：确认读到的确实是新版演示（新版一定讲类型条与位置栏）。
        XCTAssertTrue(html.contains("data-type-id"), "读到的不是新版演示，否定断言没有意义")
        XCTAssertTrue(html.contains("class=\"sidebar\""), "新版演示必须有位置侧边栏")
        for removed in ["输入 /", "输入 \\", "英文输入 /", "数字 9", "按列表旁的数字"] {
            XCTAssertFalse(html.contains(removed), "命令面板已删除，演示不能再教：\(removed)")
        }
    }

    /// 从 HTML 里按出现顺序抽出类型段的 id。
    private static func typeBarIDs(in html: String) -> [String] {
        let pattern = "data-type-id=\"([^\"]+)\""
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        return regex.matches(in: html, range: range).compactMap { match in
            Range(match.range(at: 1), in: html).map { String(html[$0]) }
        }
    }

    func testShortcutAndContinuePresentTutorialBeforePermissions() throws {
        let view = try String(contentsOf: client.appendingPathComponent("Sources/FlashFind2App/OnboardingView.swift"), encoding: .utf8)
        let window = try String(contentsOf: client.appendingPathComponent("Sources/FlashFind2App/OnboardingWindow.swift"), encoding: .utf8)
        XCTAssertTrue(view.contains("OnboardingWindow.shared.showSearchDemo()"), "快捷键页继续按钮需要打开演示")
        XCTAssertTrue(window.contains("self?.showSearchDemo()"), "试按快捷键需要打开演示")
        XCTAssertTrue(window.contains("OnboardingSearchDemoWindow.shared.isVisible"), "教学期间快捷键不能切换真实搜索窗")
        XCTAssertTrue(window.contains("if advance { controller.advance() }"), "只有演示继续按钮才能进入下一环节")
        XCTAssertFalse(view.contains("OnboardingSearchDemo()"), "欢迎页不再嵌入旧练习区")
    }

    func testHTMLIsPackagedAndWebKitHandlerIsRemovedOnClose() throws {
        let packaging = try String(contentsOf: client.appendingPathComponent("scripts/build_trial.py"), encoding: .utf8)
        let demo = try String(contentsOf: client.appendingPathComponent("Sources/FlashFind2App/OnboardingSearchDemo.swift"), encoding: .utf8)
        XCTAssertTrue(packaging.contains("Resources/Onboarding"), "正式包装必须携带离线 HTML")
        XCTAssertTrue(demo.contains("loadFileURL"))
        XCTAssertTrue(demo.contains("removeScriptMessageHandler"))
        XCTAssertTrue(demo.contains(".nonPersistent()"))
    }
}
