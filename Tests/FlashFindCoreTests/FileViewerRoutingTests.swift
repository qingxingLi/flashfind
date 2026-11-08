import XCTest
@testable import FlashFindCore

/// 「在文件管理器中显示」的判定。这条判据之所以能测，是因为它被放在 Core：
/// App 层只能扫源码，判定写在那儿就跟没测一样。
final class FileViewerRoutingTests: XCTestCase {
    private let file = URL(fileURLWithPath: "/Volumes/共享/目录/报告.pdf")
    // `deletingLastPathComponent()` 给的是带尾斜杠的目录 URL（isDirectory），
    // 用 `URL(fileURLWithPath:)` 造的不带斜杠，两者 Equatable 不相等但语义相同。
    private let parent = URL(fileURLWithPath: "/Volumes/共享/目录", isDirectory: true)
    private let finder = "com.apple.finder"
    private let pathFinder = "com.cocoatech.PathFinder"
    private let forkLift = "com.binarynights.ForkLift-3"

    func testNoThirdPartyEvidenceKeepsFinderRevealAndSelection() {
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: nil, folderHandler: nil),
                       .finderReveal(file))
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: nil, folderHandler: finder),
                       .finderReveal(file))
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: finder, folderHandler: nil),
                       .finderReveal(file))
    }

    /// 用户显式写回访达时，Launch Services 里残留的第三方设置不该翻案。
    func testExplicitFinderPreferenceWinsOverThirdPartyHandler() {
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: finder, folderHandler: pathFinder),
                       .finderReveal(file))
    }

    /// 本机现场：NSFileViewer = Path Finder，而 public.folder 的 handler 仍是访达。
    /// 只看 Launch Services 就会漏掉用户真正的偏好。
    func testPathFinderPreferenceOpensTheParentFolder() {
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: pathFinder, folderHandler: finder),
                       .openParentFolder(parent, appBundleIdentifier: pathFinder))
    }

    /// 只改了 Launch Services 的第三方（ForkLift 的另一种设置方式）也要认。
    func testLaunchServicesHandlerAloneIsEnough() {
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: nil, folderHandler: forkLift),
                       .openParentFolder(parent, appBundleIdentifier: forkLift))
    }

    /// 空串 / 空白不是「用户选了某个第三方」，不能拿它去拼一个假的 bundle id。
    func testBlankPreferencesAreNotEvidenceOfAThirdPartyViewer() {
        for blank in ["", "   ", "\n\t "] {
            XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: blank, folderHandler: nil),
                           .finderReveal(file))
        }
    }

    func testPreferenceIsTrimmedBeforeUse() {
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: "  \(pathFinder)  ", folderHandler: nil),
                       .openParentFolder(parent, appBundleIdentifier: pathFinder))
        XCTAssertEqual(FileViewerRouting.route(for: file, preferredViewer: nil, folderHandler: " \(forkLift)\n"),
                       .openParentFolder(parent, appBundleIdentifier: forkLift))
    }

    /// 第三方那条路必须交出**父目录**，把文件本身递过去会被当成「用文件管理器打开文件」。
    func testThirdPartyRouteUsesParentFolderNotTheFile() {
        guard case .openParentFolder(let url, _) = FileViewerRouting.route(
            for: file, preferredViewer: pathFinder, folderHandler: nil) else {
            return XCTFail("应走第三方分支")
        }
        XCTAssertEqual(url.path, parent.path)
        XCTAssertNotEqual(url.path, file.path)
    }

    func testFinderIdentifierIsTheRealBundleIdentifier() {
        XCTAssertEqual(FileViewerRouting.finderBundleIdentifier, "com.apple.finder")
    }

    // MARK: - 双击 / Return 打开（2026-11-06 第二轮报障）

    /// 目录 URL 构造时要带 isDirectory，否则 hasDirectoryPath 这条兜底证据拿不到。
    private let folder = URL(fileURLWithPath: "/Volumes/共享/目录/子目录", isDirectory: true)

    /// 本机现场：NSFileViewer = Path Finder，public.folder handler = 访达。
    /// 双击文件夹若仍走 `NSWorkspace.open`，Launch Services 一定把它交给访达。
    func testDoubleClickingAFolderUsesThePreferredViewer() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: "directory",
                                                      preferredViewer: pathFinder, folderHandler: finder),
                       .preferredViewer(folder, appBundleIdentifier: pathFinder))
    }

    /// 只改 Launch Services 的第三方（ForkLift 的另一种设置方式）也要认。
    func testDoubleClickingAFolderHonorsLaunchServicesHandlerAlone() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: "directory",
                                                      preferredViewer: nil, folderHandler: forkLift),
                       .preferredViewer(folder, appBundleIdentifier: forkLift))
    }

    /// ★ 只改派文件夹。普通文件必须继续交系统默认应用 —— 把 .pdf 也递给
    ///   Path Finder 等于替用户改掉所有文件的默认打开方式，比原 bug 更糟。
    func testDoubleClickingARegularFileKeepsItsDefaultApplication() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: file, itemKind: "file",
                                                      preferredViewer: pathFinder, folderHandler: finder),
                       .systemDefault(file))
        // .app 是磁盘上的目录，但语义是「启动应用」，不是「浏览文件夹」。
        let appURL = URL(fileURLWithPath: "/Applications/Safari.app", isDirectory: false)
        XCTAssertEqual(FileViewerRouting.openingRoute(for: appURL, itemKind: "app",
                                                      preferredViewer: pathFinder, folderHandler: finder),
                       .systemDefault(appURL))
    }

    /// 访达用户（或没有第三方证据）行为与旧版完全一致。
    func testFinderUsersDoubleClickIsUnchanged() {
        for (preferred, handler) in [(String?.none, String?.none),
                                    (finder, String?.none),
                                    (String?.none, finder),
                                    (finder, pathFinder),
                                    ("", nil)] {
            XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: "directory",
                                                          preferredViewer: preferred, folderHandler: handler),
                           .systemDefault(folder))
        }
    }

    /// 显式写回访达时，Launch Services 里残留的第三方不翻案（与 reveal 同口径）。
    func testExplicitFinderPreferenceWinsForDoubleClickToo() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: "directory",
                                                      preferredViewer: finder, folderHandler: forkLift),
                       .systemDefault(folder))
    }

    /// 结果行 kind 缺失时，URL 自身的目录形态仍是有效证据。
    func testDirectoryURLShapeIsEnoughWhenKindIsMissing() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: nil,
                                                      preferredViewer: pathFinder, folderHandler: finder),
                       .preferredViewer(folder, appBundleIdentifier: pathFinder))
        XCTAssertEqual(FileViewerRouting.openingRoute(for: file, itemKind: nil,
                                                      preferredViewer: pathFinder, folderHandler: finder),
                       .systemDefault(file))
    }

    func testOpeningRoutePreferenceIsTrimmed() {
        XCTAssertEqual(FileViewerRouting.openingRoute(for: folder, itemKind: " directory ",
                                                      preferredViewer: "  \(pathFinder)  ", folderHandler: nil),
                       .preferredViewer(folder, appBundleIdentifier: pathFinder))
    }

    /// ★ 两条链共用「谁是用户偏好」这一个出处：只要它给出同一个 bundle id，
    ///   reveal 与双击打开就不可能一个认 Path Finder、一个开访达。
    func testBothChainsShareTheSamePreferenceDecision() {
        let pairs: [(String?, String?)] = [(nil, nil), (finder, nil), (pathFinder, finder),
                                            (finder, forkLift), (nil, forkLift), ("  ", nil)]
        for (preferred, handler) in pairs {
            let viewer = FileViewerRouting.preferredViewerBundleIdentifier(
                preferredViewer: preferred, folderHandler: handler)
            let reveal = FileViewerRouting.route(for: file, preferredViewer: preferred,
                                                 folderHandler: handler)
            let opening = FileViewerRouting.openingRoute(for: folder, itemKind: "directory",
                                                         preferredViewer: preferred, folderHandler: handler)
            switch (viewer, reveal, opening) {
            case (nil, .finderReveal, .systemDefault):
                break
            case (let id?, .openParentFolder(_, let revealID), .preferredViewer(_, let openID)):
                XCTAssertEqual(id, revealID)
                XCTAssertEqual(id, openID)
            default:
                XCTFail("两条链的偏好判定不一致：preferred=\(String(describing: preferred)), handler=\(String(describing: handler))")
            }
        }
    }
}
