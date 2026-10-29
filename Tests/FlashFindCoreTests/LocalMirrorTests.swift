import XCTest
@testable import FlashFindCore

/// 「从本机路径拷一份」——群晖 / OpenList 的下载走这条。
final class LocalMirrorTests: XCTestCase {

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("mirror-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    func testCopiesAFileAndKeepsItsName() throws {
        let source = root.appendingPathComponent("示例发票.pdf")
        try Data("报价".utf8).write(to: source)
        let copy = try LocalMirror.copyToTemporaryDirectory(source)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertEqual(copy.lastPathComponent, "示例发票.pdf", "下载下来的文件名必须跟原文件一致")
        XCTAssertEqual(try Data(contentsOf: copy), Data("报价".utf8))
        XCTAssertNotEqual(copy.path, source.path, "必须是另一份，不能把原文件当下载结果")
        XCTAssertTrue(FileManager.default.fileExists(atPath: source.path), "原文件不许被动")
    }

    /// 目录也要能拷：访达里右键文件夹下载是合理要求。
    func testCopiesADirectoryRecursively() throws {
        let folder = root.appendingPathComponent("资料")
        try FileManager.default.createDirectory(at: folder.appendingPathComponent("子目录"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: folder.appendingPathComponent("子目录/a.txt"))
        let copy = try LocalMirror.copyToTemporaryDirectory(folder)
        addTeardownBlock { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        XCTAssertTrue(FileManager.default.fileExists(atPath: copy.appendingPathComponent("子目录/a.txt").path))
    }

    /// 两次下载同名文件互不覆盖 —— 每次一个新目录。
    func testTwoDownloadsDoNotOverwriteEachOther() throws {
        let source = root.appendingPathComponent("a.txt")
        try Data("1".utf8).write(to: source)
        let first = try LocalMirror.copyToTemporaryDirectory(source)
        try Data("2".utf8).write(to: source)
        let second = try LocalMirror.copyToTemporaryDirectory(source)
        addTeardownBlock {
            try? FileManager.default.removeItem(at: first.deletingLastPathComponent())
            try? FileManager.default.removeItem(at: second.deletingLastPathComponent())
        }
        XCTAssertEqual(try Data(contentsOf: first), Data("1".utf8), "第一份不该被后一次覆盖")
        XCTAssertEqual(try Data(contentsOf: second), Data("2".utf8))
    }

    /// 文件已经不在了：说清「可能已被移动或删除」，并**不留下空目录**。
    func testMissingSourceReportsAndLeavesNothingBehind() {
        let missing = root.appendingPathComponent("不存在.pdf")
        XCTAssertThrowsError(try LocalMirror.copyToTemporaryDirectory(missing)) { error in
            XCTAssertTrue("\(error)".contains("重新搜索"), "要告诉用户下一步，而不只是失败：\(error)")
        }
    }
}
