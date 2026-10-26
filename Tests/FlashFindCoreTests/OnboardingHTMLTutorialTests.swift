import XCTest
@testable import FlashFindCore

final class OnboardingHTMLTutorialTests: XCTestCase {
    private var client: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    func testTutorialIncludesSearchPreviewTypeAndLocationWithRealDocumentNumber() throws {
        let html = try String(contentsOf: client.appendingPathComponent("Resources/Onboarding/search-demo.html"), encoding: .utf8)
        for required in ["周杰伦", "Space", "preview", "location", "fileType", "continue", "prefers-reduced-motion"] {
            XCTAssertTrue(html.contains(required), "缺少教学环节：\(required)")
        }
        let types = SearchCommandCatalog.items(kind: .fileType, sources: [], includeLocal: true, includeSettings: false)
        let document = try XCTUnwrap(types.firstIndex { $0.title == "文档" })
        XCTAssertEqual(SearchCommandNumbering.key(for: document, in: types), 9)
        XCTAssertTrue(html.contains("data-document-key=\"9\""), "HTML 文档类型编号必须与实际目录一致")
        XCTAssertFalse(html.contains("https://"), "离线演示不应依赖外部素材")
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
