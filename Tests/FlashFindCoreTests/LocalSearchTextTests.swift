import XCTest
@testable import FlashFindCore

/// 本机搜索「这样设置会不会搜不到东西」的提示文案。
///
/// 这句话是用户判断「为什么搜不到本机文件」的唯一依据。
/// 说错方向的后果不是报错，而是让用户以为闪寻坏了——
/// 比如没选文件夹时只说「请选择」，而不说「不会自动扫描全盘」，
/// 用户就会一直等一个永远不会发生的全盘搜索。
///
/// 另一半同样要锁住：**没问题就不说话**。设置页上那行灰字只要一直挂着，
/// 用户就会开始找「它到底在说哪个问题」。
final class LocalSearchTextTests: XCTestCase {

    // MARK: - 真实运行

    func testNoFolderSelectedMustSayItWillNotScanEverything() {
        let text = LocalSearchText.availability(mode: .selectedFolders, folderCount: 0, context: .live)
        XCTAssertEqual(text, "请选择具体本机文件夹；不会自动扫描全盘")
    }

    /// ★ 选好文件夹就闭嘴。
    ///
    /// 这里若说「仅搜索已明确选择的 N 个本机文件夹；无需系统索引」，
    /// 而那几个文件夹就列在同一个 Section 里——这句话除了占地方没有别的作用。
    func testFoldersSelectedStaysQuiet() {
        XCTAssertNil(LocalSearchText.availability(mode: .selectedFolders, folderCount: 3, context: .live),
                     "已选文件夹是正常状态，不该在设置页留一行说明")
    }

    /// Spotlight 模式下文案由系统索引探测结果决定，这里返回 nil 交给调用方。
    ///
    /// 断言 nil 而不是断言某句话：探测可能报「索引正在重建」，
    /// 硬编一句会盖掉真实状态。
    func testSpotlightModeWaitsForSystemProbe() {
        XCTAssertNil(LocalSearchText.availability(mode: .spotlight, folderCount: 0, context: .live))
    }

    // MARK: - 预览

    /// 纯预览不改文案：那句话可能是上一次真实运行留下的，改了会让预览失真。
    func testPreviewDoesNotOverwriteMessage() {
        XCTAssertNil(LocalSearchText.availability(mode: .selectedFolders, folderCount: 2, context: .preview))
        XCTAssertNil(LocalSearchText.availability(mode: .spotlight, folderCount: 0, context: .preview))
    }

    func testPreviewFixtureTellsItIsASample() {
        XCTAssertEqual(LocalSearchText.availability(mode: .spotlight, folderCount: 0, context: .previewFixture),
                       "UI 样例：系统 Spotlight 已关闭")
        XCTAssertEqual(LocalSearchText.availability(mode: .selectedFolders, folderCount: 0, context: .previewFixture),
                       "UI 样例：请选择具体文件夹")
        XCTAssertNil(LocalSearchText.availability(mode: .selectedFolders, folderCount: 2, context: .previewFixture),
                     "样例态与真实运行态一样：选好文件夹就不说话")
    }

    /// 样例文案必须自报是样例，不能和真实运行态的文案混在一起。
    func testPreviewFixtureWordingIsAlwaysMarkedAsSample() {
        for mode in LocalSearchMode.allCases {
            for count in [0, 1, 5] {
                guard let text = LocalSearchText.availability(mode: mode, folderCount: count, context: .previewFixture) else {
                    continue
                }
                XCTAssertTrue(text.hasPrefix("UI 样例"),
                              "样例态文案必须标出是样例，实际得到：\(text)（\(mode)/\(count)）")
            }
        }
    }
}
