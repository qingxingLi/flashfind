import XCTest
@testable import FlashFindCore

/// Phase 6.3b-0 preflight ①：**Provider 的 `relativePath` 到底是什么形态**，
/// 以及它在进入 MCP 之前被收敛成什么（方案 §3.2.1 / §4.6.3）。
///
/// ## 为什么这是硬 Gate
///
/// `FileID.make` 只接受**已经规范**的相对路径——这是 6.3a 有意留下的严格性：
/// 身份层「修一下再用」会让两个不同的入参产出同一个 `file_id`，而 `file_id` 会进
/// History（只增不减）。所以规范化必须发生在**路径的生产者一侧**，
/// 一旦某个 provider 给出绝对路径或 `abc//file.txt`，那批结果会被整体跳过。
///
/// 于是本轮的第一件事不是写搜索，而是把四种 provider 的真实形态**测出来**：
///
/// | Provider | 真实形态 | 出处 |
/// | --- | --- | --- |
/// | 本机 · 系统索引 | 绝对路径 `/Users/…` | `SpotlightProvider.swift:76` |
/// | 本机 · 已选文件夹 | 绝对路径 `/Users/…` | `LocalFolderSearch.swift:91/123` |
/// | NAS · 通用（含 Synology / WebDAV / 飞牛 / OpenList） | 设备根路径 `/共享名/…` | `NASSearchProvider.swift:676` + Dart `lib/core.dart:144` |
///
/// 结论：**没有一个 provider 给的是「相对路径」**。它们给的是「相对来源根的路径」，
/// 只是把根写在了串首（本机是 `/`，NAS 是设备根）。因此收敛规则是
/// 「剥前导斜杠、消空段、消 `.`、`..` 拒绝」，而不是「让 `FileID` 宽容一点」。
///
/// 证据：`04-测试与验收/mcp-phase6-3b0-preflight-20261020/provider-path-probe.txt`。
final class ProviderPathShapeTests: XCTestCase {

    // MARK: - 1. 规范化本身（§3.2.1.1 的 8 合法 + 7 越界样本）

    /// 九种拼写必须收敛到**同一个**规范路径（原方案写「8 条」，实际列了 9 行，
    /// 这里按 9 条跑：多一条不比少一条差）。
    ///
    /// ★ NFC/NFD 样本必须带**组合字符**才测得出来：纯 ASCII 串两种形态逐字节相同，
    /// 用 `TAG/x` 当样本等于没测（APFS 给 NFC、SMB/AFP 给 NFD 的差异只在非 ASCII 上）。
    func testTheNineLegalSpellingsConvergeToOnePath() throws {
        let nfc = "TAG/café.txt"
        let nfd = nfc.decomposedStringWithCanonicalMapping
        // ★ 只能比字节：Swift 的 `String ==` 是**规范化等价**比较，
        // NFC 与 NFD 在它眼里相等。用它断言「收敛成功」，等于什么都没测。
        XCTAssertNotEqual(Array(nfc.utf8), Array(nfd.utf8),
                          "样本本身要先证明 NFC/NFD 不是同一串字节，否则这条用例什么都没测")
        let inputs = ["TAG/café.txt", "TAG/./café.txt", "TAG/sub/../café.txt", "./TAG/café.txt",
                      "/TAG/café.txt", "TAG//café.txt", nfc, nfd, "TAG\\café.txt"]
        let outputs = try Set(inputs.map { Data(try RelativePath.canonical($0).utf8) })
        XCTAssertEqual(outputs.count, 1, "九种拼写没有收敛到同一个路径：\(outputs.map { String(decoding: $0, as: UTF8.self) })")
        XCTAssertEqual(outputs.first, Data(nfc.utf8), "收敛结果必须是 NFC 字节")
    }

    /// 越界必须**拒绝**，不许钳到根。钳位的后果是撞 id（§3.2.1.1 有实测反例）。
    func testTheSevenEscapingFormsAreRejected() {
        let inputs = ["../TAG/x", "../../x", "../../../x", "TAG/../../x",
                      "TAG/../../TAG/x", "TAG/sub/../../../x", ".."]
        for input in inputs {
            XCTAssertThrowsError(try RelativePath.canonical(input), "越界路径被接受了：\(input)") { error in
                XCTAssertEqual(error as? RelativePath.CanonicalError,
                               .escapesSourceRoot(raw: input))
            }
        }
    }

    /// 撞 id 的**直接反证**：越界那条必须造不出路径，而根内那条正常。
    /// 若规范化被改成「钳到根」，这两行会得到同一个结果——那正是不能用钳位的原因。
    func testAnEscapingPathNeverCollidesWithARealFileAtTheRoot() throws {
        XCTAssertEqual(try RelativePath.canonical("secret/x"), "secret/x")
        XCTAssertThrowsError(try RelativePath.canonical("../../secret/x"))
    }

    /// 空串 / `/` / `.` / `//` 都不是文件：拒绝，而不是当成根。
    ///
    /// 若把空结果当「来源根本身」，一个目录结果就会拿到「根」的 `file_id`，
    /// 而 `get_metadata` 之后会把整个来源当成一个文件。
    func testPathsThatCanonicaliseToNothingAreRejected() {
        for input in ["", "/", ".", "./", "//", "///"] {
            XCTAssertThrowsError(try RelativePath.canonical(input), "空路径被接受了：\(input)") { error in
                XCTAssertEqual(error as? RelativePath.CanonicalError, .empty(raw: input))
            }
        }
    }

    /// 尾随斜杠**不是**错误：目录结果带不带尾随斜杠是 provider 的写法差异，
    /// 不是「越界」也不是「空段」。它必须被收敛掉（否则整批目录结果会被跳过）。
    func testATrailingSlashIsNormalisedRatherThanRejected() throws {
        XCTAssertEqual(try RelativePath.canonical("abc/file.txt/"), "abc/file.txt")
        XCTAssertEqual(try RelativePath.canonical("abc/资料/"), "abc/资料")
    }

    /// 规范化的输出**必须**能直接喂给 `FileID.make`：这是两张契约的接缝。
    /// 反过来的写法（`FileID.make` 宽容一点）会让身份层承担修补职责。
    func testEveryCanonicalPathIsSafeForFileID() throws {
        let inputs = ["/Users/someone/Downloads/report.pdf",
                      "/允许共享/中文-1.txt",
                      "abc//file.txt",
                      "abc/./file.txt",
                      "abc/file.txt/",
                      "TAG\\x"]
        for input in inputs {
            let path = try RelativePath.canonical(input)
            XCTAssertTrue(RelativePath.isSafe(path), "规范化输出不是安全相对路径：\(input) → \(path)")
            XCTAssertNoThrow(try FileID.make(sourceID: "local_mac", canonicalRelativePath: path))
        }
    }

    // MARK: - 2. 本机 Provider：真实跑一次，确认它给的是绝对路径

    /// **实测**：`LocalFolderSearch`（「只搜索指定文件夹」那条路）在真实文件系统上
    /// 返回的 `relativePath` 是**绝对路径**。
    ///
    /// 这条用例的价值不是「证明当前实现对」，而是把假设钉住：如果哪天某个 provider
    /// 改成返回相对路径，这条会红，提醒「规范化规则的上游变了」。
    /// 反过来，若没有这条用例，改完 provider 的人不会知道 MCP 侧依赖这个形态。
    func testTheLocalFolderProviderEmitsAbsolutePaths() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ff-path-\(UUID().uuidString)", isDirectory: true)
        let nested = root.appendingPathComponent("资料", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = nested.appendingPathComponent("年度汇总报告.xlsx")
        XCTAssertTrue(FileManager.default.createFile(atPath: file.path, contents: Data("x".utf8)))

        let report = try LocalFolderSearch.search("报告", folders: [root])
        let hit = try XCTUnwrap(report.results.first, "本机文件夹搜索没有返回结果")
        XCTAssertTrue(hit.relativePath.hasPrefix("/"),
                      "本机 provider 改了形态（不再给绝对路径）：\(hit.relativePath)")

        // 收敛之后才是 MCP 能用的东西：不再以 `/` 开头，且能生成 file_id。
        let canonical = try RelativePath.canonical(hit.relativePath)
        XCTAssertFalse(canonical.hasPrefix("/"))
        XCTAssertTrue(canonical.hasSuffix("资料/年度汇总报告.xlsx"), canonical)
        XCTAssertNoThrow(try FileID.make(sourceID: "local_mac", canonicalRelativePath: canonical))
    }

    // MARK: - 3. NAS Provider：设备根路径（静态取证 + 收敛）

    /// NAS 的路径来自 Dart 核心（`lib/core.dart` 原样透传 `f.path`），
    /// 形态是「设备根 + 共享名 + 目录 + 文件名」，**带前导斜杠**。
    ///
    /// 样本取自核心自己的 fixture：`MyNASCore/lib/mock_transport.dart`
    /// `{'path': '$root/中文-$i.txt'}`，`root = '/允许共享'`。
    func testTheNASEmittedPathIsADeviceRootPath() throws {
        let emitted = "/允许共享/中文-1.txt"
        XCTAssertTrue(emitted.hasPrefix("/"), "核心给的是「从设备根算起」的路径")
        XCTAssertEqual(try RelativePath.canonical(emitted), "允许共享/中文-1.txt")
    }

    /// Synology native 与 WebDAV 共用同一个 Swift provider
    /// （`NASSearchProvider.result(_:)`），它们的路径都来自 Dart 的 `File.path`。
    /// 两个适配器拼路径的写法不完全一样（有的带前导斜杠、有的不带），
    /// 收敛之后**必须**是同一个串——否则同一个文件经不同品牌接入会得到两个 `file_id`。
    func testBothLeadingSlashFormsConvergeToOnePath() throws {
        let withSlash = try RelativePath.canonical("/允许共享/示例资料/a.pdf")
        let withoutSlash = try RelativePath.canonical("允许共享/示例资料/a.pdf")
        XCTAssertEqual(withSlash, "允许共享/示例资料/a.pdf")
        XCTAssertEqual(withoutSlash, withSlash,
                       "带不带前导斜杠是适配器的写法差异，不能变成两个身份")
    }

    // MARK: - 4. 身份层不许偷偷规范化

    /// ★ 结构测试：`FileID.swift` 里**不许**出现 `RelativePath.canonical`。
    ///
    /// 「在身份层顺手修一下路径」是最自然、也最危险的一步：它会让
    /// `abc//file.txt` 与 `abc/file.txt` 得到同一个 id（这一步是对的），
    /// 也会让 `../x` 与 `x` 得到同一个 id（这一步是灾难）。
    /// 两条规则只差一个 case，所以用结构测试把整类写法挡在外面。
    func testFileIDNeverRepairsItsInput() throws {
        let source = try String(contentsOf: Self.clientRoot
            .appendingPathComponent("Sources/FlashFindCore/FileID.swift"), encoding: .utf8)
        XCTAssertTrue(source.contains("RelativePath.isSafe"), "没读到 FileID.swift，这条会假绿")
        XCTAssertFalse(source.contains("RelativePath.canonical"),
                       "身份层开始规范化路径了：应当由 provider 侧收敛，见 §4.6.3")
    }

    // MARK: - 小工具

    private static var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
