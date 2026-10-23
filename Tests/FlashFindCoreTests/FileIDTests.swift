import XCTest
@testable import FlashFindCore

/// Phase 6.3a 契约一：`FileID` 是 `file_id` 的**唯一**事实来源（方案 §4.6）。
///
/// ## 为什么必须先做这一步
///
/// 在 6.3a 之前，`ff1_ + 32 位小写 hex` 这条规则只存在于 `ToolRouter` 的校验里，
/// **没有生成侧**。接真 `locate` 时生成侧必然要自己拼一遍字符串——于是同一个格式
/// 有两份实现：校验那份改了、生成那份没改，Agent 就会拿到「自己刚收到的 id 被自己
/// 拒掉」这种玄学 bug。这个项目已经因为「同一事实写两遍」栽过两次
/// （`limit` 上限、`kind` 枚举），第三次不能在 `file_id` 上重演。
///
/// 所以本文件的用例分两类：
///
/// 1. **行为**：生成/解析/归一化的规则（含一条 golden，把哈希规则钉死）；
/// 2. **结构**：`ff1_` 这个字面量在 `Sources/` 里只许出现在 `FileID.swift`。
///    只测行为抓不住「另写一份一模一样的规则」——那种副本行为完全正确，
///    只有结构测试看得见。
final class FileIDTests: XCTestCase {

    private let sourceID = "src_nas_work"
    /// 夹具路径刻意用**不含业务含义**的通用目录名。
    ///
    /// 这里原来写的是一个真实业务文件名。脱敏脚本有一条「组织/业务名」替换规则，
    /// 会把那个词换成占位，于是**输入变了、期望的 hash 没变**——发布仓里跑测试
    /// 必然红，而 client 里全绿。两个仓跑出不同结论，比测试本身红更难查。
    /// 夹具用什么路径对「钉住哈希规则」这件事毫无影响，所以换成通用名，
    /// 让脱敏工具碰不到它。
    private let path = "示例目录/年度报告.xlsx"

    // MARK: - 1. 形态

    func testMakeProducesPrefixAndThirtyTwoLowercaseHex() throws {
        let id = try FileID.make(sourceID: sourceID, canonicalRelativePath: path)

        XCTAssertTrue(id.value.hasPrefix("ff1_"), "前缀只有一份定义：FileID.prefix")
        XCTAssertEqual(id.value.count, 36, "`ff1_` + 32 位 hex")
        let hex = id.value.dropFirst(4)
        XCTAssertEqual(hex.count, 32)
        XCTAssertTrue(hex.allSatisfy { $0.isHexDigit && !$0.isUppercase },
                      "必须是小写 hex：`ff1_AAAA…` 与 `ff1_aaaa…` 不能是两个 id")
        XCTAssertEqual(id.description, id.value, "线上形态就是 value 本身")
        XCTAssertEqual(id.value, FileID.prefix + String(id.value.dropFirst(FileID.prefix.count)),
                       "prefix 常量与真实前缀不一致")
    }

    // MARK: - 2. 同样的输入永远同一个 id

    func testTheSameSourceAndPathAlwaysProduceTheSameID() throws {
        let a = try FileID.make(sourceID: sourceID, canonicalRelativePath: path)
        let b = try FileID.make(sourceID: sourceID, canonicalRelativePath: path)
        XCTAssertEqual(a, b)
    }

    /// `source_id` 必须在哈希里。否则两个 NAS 上的同名文件会撞成同一个 id，
    /// `get_metadata` 就会去错来源找文件——这是**跨来源串号**，比找不到更糟。
    func testTheSourceIsPartOfTheIdentity() throws {
        let a = try FileID.make(sourceID: "src_nas_a", canonicalRelativePath: path)
        let b = try FileID.make(sourceID: "src_nas_b", canonicalRelativePath: path)
        XCTAssertNotEqual(a, b, "同名文件在不同来源上必须是两个 id")
    }

    func testThePathIsPartOfTheIdentity() throws {
        let a = try FileID.make(sourceID: sourceID, canonicalRelativePath: "a/report.pdf")
        let b = try FileID.make(sourceID: sourceID, canonicalRelativePath: "b/report.pdf")
        XCTAssertNotEqual(a, b)
    }

    /// 大小写**不折叠**：同一台 NAS 上 `Report.pdf` 与 `report.pdf` 可以是两个文件
    /// （Linux 后端大小写敏感）。折叠会让其中一个永久拿不到正确 id。
    func testCaseIsNotFolded() throws {
        let upper = try FileID.make(sourceID: sourceID, canonicalRelativePath: "Docs/Report.pdf")
        let lower = try FileID.make(sourceID: sourceID, canonicalRelativePath: "Docs/report.pdf")
        XCTAssertNotEqual(upper, lower, "大小写折叠会把大小写敏感来源上的两个文件合成一个")
    }

    // MARK: - 3. Unicode 归一化

    /// macOS 本地卷给的是 NFD，NAS 给的通常是 NFC。不归一化的话**同一个文件**
    /// 在两条路径上会得到两个 id，`get_metadata` 就会有一半概率落空。
    func testComposedAndDecomposedFormsProduceTheSameID() throws {
        let composed = try FileID.make(sourceID: "local_mac",
                                       canonicalRelativePath: "Docs/caf\u{00E9}.txt")
        let decomposed = try FileID.make(sourceID: "local_mac",
                                         canonicalRelativePath: "Docs/cafe\u{0301}.txt")
        XCTAssertEqual(composed, decomposed, "NFC / NFD 必须归一到同一个 id")
        XCTAssertEqual(composed.value, "ff1_9e034b622f87e4b62d8668dfa04528ef",
                       "归一化后应当命中 NFC 那条 golden")
    }

    // MARK: - 4. 生成侧的拒绝

    /// 不安全的相对路径**不生成 id**，而不是「修一下再用」。
    ///
    /// 修一下意味着两个不同的入参产出同一个 id，而调用方以为自己拿到的是各自的身份。
    func testUnsafePathsAreRejected() {
        let bad = ["",
                   "/Users/someone/secret.pdf",          // 绝对路径
                   "/",                                  // 根
                   "a//b",                               // 空段
                   "a/./b",                              // 当前目录
                   "a/../b",                             // 越界
                   "../escape.pdf",
                   "a/b/",                               // 尾随斜杠
                   "a\u{0}b"]                            // NUL
        for path in bad {
            XCTAssertThrowsError(try FileID.make(sourceID: sourceID, canonicalRelativePath: path),
                                 "不安全的路径被生成了 id：\(path)") { error in
                XCTAssertEqual(error as? FileID.MakeError, .unsafePath, "错的拒绝理由：\(path)")
            }
        }
    }

    /// `source_id` 也会进哈希前像，所以它不能为空、不能含分隔符 `0x1F`、
    /// 不能含控制字符——否则两个不同来源能拼出同一个前像。
    func testUnusableSourceIDsAreRejected() {
        let bad = ["", "src\u{1F}nas", "src\nnas", "src\u{0}nas"]
        for id in bad {
            XCTAssertThrowsError(try FileID.make(sourceID: id, canonicalRelativePath: path),
                                 "不可用的来源 id 被接受：\(String(reflecting: id))") { error in
                XCTAssertEqual(error as? FileID.MakeError, .unusableSourceID)
            }
        }
    }

    // MARK: - 5. 解析

    func testParseAcceptsWhatMakeProduces() throws {
        let id = try FileID.make(sourceID: sourceID, canonicalRelativePath: path)
        let parsed = FileID.parse(id.value)
        XCTAssertEqual(parsed, id, "自己生成的 id 必须能被自己解析（否则 get_metadata 必然失败）")
    }

    func testParseRejectsEverythingElse() {
        let bad = ["",
                   "report.pdf",
                   "/Users/someone/secret.pdf",
                   "ff1_",
                   "ff1_" + String(repeating: "a", count: 31),   // 短
                   "ff1_" + String(repeating: "a", count: 33),   // 长
                   "ff1_" + String(repeating: "A", count: 32),   // 大写
                   "ff1_" + String(repeating: "z", count: 32),   // 非 hex
                   "ff2_" + String(repeating: "a", count: 32),   // 换版本前缀
                   " ff1_" + String(repeating: "a", count: 32),  // 前导空格
                   "ff1_" + String(repeating: "a", count: 32) + "\n"]
        for value in bad {
            XCTAssertNil(FileID.parse(value), "非法 id 被解析成功：\(String(reflecting: value))")
        }
    }

    /// 解析不接受空白：`get_metadata` 的入参已经由 Router trim 过一次，
    /// 到这里还带空白说明调用方绕过了 Router——这种情况应当失败，不是「顺手修好」。
    func testParseDoesNotTrim() {
        let id = "ff1_" + String(repeating: "a", count: 32)
        XCTAssertNotNil(FileID.parse(id))
        XCTAssertNil(FileID.parse(" " + id))
        XCTAssertNil(FileID.parse(id + " "))
    }

    // MARK: - 6. 哈希规则只钉一次（golden）

    /// 这一条是**跨版本兼容**的唯一保险：`file_id` 会进 Agent 的上下文，
    /// 也会被用户粘贴进别的对话。规则一改，昨天给的 id 今天就全废。
    ///
    /// golden 值不是从实现里抄的，而是用另一份独立实现（Python `hashlib`）按
    /// §4.6 写明的字节序列算出来的——见证据目录 `golden.txt`。
    ///
    /// ★ 夹具路径**必须**是不含真实业务名的通用名：脱敏脚本按「组织/业务名」
    /// 改写源码时会把这个字面量换掉，而它是 sha256 的输入——换了输入、期望值
    /// 不会跟着变，发布仓里这条就必红。规则没动，变的只是夹具。
    func testGoldenIDsPinTheHashRule() throws {
        XCTAssertEqual(try FileID.make(sourceID: "src_nas_work",
                                       canonicalRelativePath: "示例目录/年度报告.xlsx").value,
                       "ff1_2b0f43c14f47954bf14a55de12e4bb21")
        XCTAssertEqual(try FileID.make(sourceID: "local_mac",
                                       canonicalRelativePath: "Downloads/report.pdf").value,
                       "ff1_964aa26b4cc9b742e08df4c3ad2f8780")
        XCTAssertEqual(try FileID.make(sourceID: "local_mac",
                                       canonicalRelativePath: "downloads/report.pdf").value,
                       "ff1_5ca1d69bbe14a6242676741f0634622d")
    }

    /// 前像必须**逐字节**等于「source_id + 0x1F + "path:" + 归一化路径」。
    ///
    /// 不写这条的话，`make` 与 `parse` 能在任何自定义前像下自洽地跑绿，
    /// 只有 golden 会红——而 golden 红了以后没人知道该改哪一边。
    func testPreimageIsTheDocumentedByteSequence() {
        let preimage = FileID.preimage(sourceID: "local_mac", canonicalPath: "Docs/caf\u{00E9}.txt")
        let expected = Data("local_mac".utf8)
            + Data([0x1F])
            + Data("path:".utf8)
            + Data("Docs/caf\u{00E9}.txt".utf8)
        XCTAssertEqual([UInt8](preimage), [UInt8](expected))
    }

    /// 分隔符必须真的是 `0x1F`：换成 `\0`、`|`、`:` 都能让上面的用例一起绿，
    /// 只有把字节值钉住才抓得住——而它决定了两个字段的边界在哪里。
    func testTheSeparatorIsUnitSeparator() {
        let preimage = FileID.preimage(sourceID: "a", canonicalPath: "b")
        XCTAssertEqual([UInt8](preimage), Array("a".utf8) + [0x1F] + Array("path:b".utf8))
        XCTAssertEqual(FileID.separator, 0x1F)
    }

    // MARK: - 7. 结构：格式只有一个出处

    /// `ff1_` 字面量在 `Sources/` 里只许出现在 `FileID.swift`。
    ///
    /// 这条守的是「生成侧另写一份一模一样的拼接」——那种副本行为完全正确，
    /// 所有行为用例都会绿，只有这条会红。
    func testTheFormatLiteralLivesInExactlyOneSourceFile() throws {
        let hits = try sourceFiles(under: "Sources").filter { $0.code.contains("ff1_") }
        XCTAssertEqual(hits.map(\.path), ["Sources/FlashFindCore/FileID.swift"],
                       "`ff1_` 出现在多个源文件里：格式被抄了第二份")
    }

    /// Router 不许再自带 36 / 32 / `isHexDigit` 这套判据。
    func testTheRouterDoesNotCarryASecondShapeRule() throws {
        let router = try code(of: "Sources/FlashFindCore/ToolRouter.swift")
        for marker in ["isHexDigit", "hasPrefix(\"ff1", "count == 36", "count == 32"] {
            XCTAssertFalse(router.contains(marker),
                           "ToolRouter 里又出现了 `\(marker)`——形状只能由 FileID.parse 判")
        }
        XCTAssertTrue(router.contains("FileID.parse"),
                      "Router 必须用 FileID.parse 校验 file_id")
    }

    // MARK: - 小工具

    private var clientRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    private func code(of relativePath: String) throws -> String {
        let url = clientRoot.appendingPathComponent(relativePath)
        return try String(contentsOf: url, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func sourceFiles(under directory: String) throws -> [(path: String, code: String)] {
        let root = clientRoot.appendingPathComponent(directory)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        var files: [URL] = []
        for case let url as URL in walker where url.pathExtension == "swift" { files.append(url) }
        return try files.sorted { $0.path < $1.path }.map { url in
            let relative = url.path.replacingOccurrences(of: clientRoot.path + "/", with: "")
            return (relative, try code(of: relative))
        }
    }
}
