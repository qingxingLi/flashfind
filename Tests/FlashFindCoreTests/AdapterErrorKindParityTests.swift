import XCTest
@testable import FlashFindCore

/// 核心错误 `kind` 的**跨语言契约**校验。
///
/// ## 守的是什么
///
/// `kind` 是 Dart 核心与 Swift 界面之间的契约：核心用它说「出了什么事」，
/// Swift 用它决定给用户看哪句话。两边各写各的，就没有任何校验关系。
///
/// 缺口的代价：核心新增了 `HttpFailure`、`TLSRejected`、`ApiError`
/// 等十余个 kind 而 Swift 一个都不认得，界面就只能落到兜底分支显示
/// 「设备返回了未预期的错误（HttpFailure）」——把技术名词甩给用户，
/// 而核心那句「文件流请求失败（HTTP 500）」明明就存在。
///
/// 这类缺陷**不可能被单侧测试发现**：Dart 侧看 Swift 不存在，
/// Swift 侧看 kind 只是个字符串。只有把两张表放在一起比对才看得见。
///
/// ## 守两条
///
/// 1. Dart 会抛出的每个 kind，Swift 都得认得（不认得 ⇒ 用户看到技术名词）；
/// 2. Dart 承诺「界面一定有话可说」的那些，Swift 必须真的有一句中文。
///
/// 契约来源有两份，都查：JSON 是导出的契约（覆盖改成 `ErrorKind.xxx` 常量
/// 之后的引用），直接扫 Dart 源码是兜底（JSON 忘了重新导出也能抓到）。
final class AdapterErrorKindParityTests: XCTestCase {

    /// `client/` 根目录。测试文件在 `client/Tests/FlashFindCoreTests/` 下，上溯两级。
    private var clientRoot: URL {
        let here = URL(fileURLWithPath: #filePath)
        return here.deletingLastPathComponent()   // FlashFindCoreTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // client
    }

    private func loadContract() throws -> (userFacing: Set<String>, internal: Set<String>) {
        let url = clientRoot
            .appendingPathComponent("MyNASCore")
            .appendingPathComponent("error_kinds.json")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ContractError.missing(url.path)
        }
        let data = try Data(contentsOf: url)
        let obj = try JSONSerialization.jsonObject(with: data)
        guard let dict = obj as? [String: Any],
              let uf = dict["userFacing"] as? [String],
              let int = dict["internal"] as? [String] else {
            throw ContractError.malformed
        }
        return (Set(uf), Set(int))
    }

    /// 直接扫 Dart 产品代码里的 kind 字面量。
    ///
    /// 为什么还要这一条：JSON 是**导出的**产物，改了 Dart 表却忘了重跑导出脚本
    /// 时，JSON 就是旧的——那时候「JSON 与 Swift 对齐」并不能说明源码对齐。
    /// Dart 侧有测试盯着 JSON 与源码一致，这里再扫一遍源码是第二道防线。
    private func scanDartKindLiterals() -> Set<String> {
        let root = clientRoot.appendingPathComponent("MyNASCore")
        var found: Set<String> = []
        let pattern = "\\b(?:AdapterFailure|CoreError)\\s*\\(\\s*'([A-Za-z][A-Za-z0-9]*)'"
        guard let re = try? NSRegularExpression(pattern: pattern, options: []) else {
            XCTFail("正则编译失败")
            return []
        }
        for dir in ["lib", "bin"] {
            let dirURL = root.appendingPathComponent(dir)
            guard let e = FileManager.default.enumerator(
                at: dirURL, includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]) else { continue }
            for case let file as URL in e where file.pathExtension == "dart" {
                guard let text = try? String(contentsOf: file, encoding: .utf8) else { continue }
                let range = NSRange(text.startIndex..., in: text)
                for m in re.matches(in: text, options: [], range: range) {
                    if let r = Range(m.range(at: 1), in: text) {
                        found.insert(String(text[r]))
                    }
                }
            }
        }
        return found
    }

    func testContractFileIsReachable() {
        // 找不到文件时不静默跳过——那等于这条契约没人守。
        XCTAssertNoThrow(try loadContract(), "缺少 error_kinds.json；先跑 dart run bin/export_error_kinds.dart")
    }

    func testDartSourceScanFindsKinds() throws {
        let scanned = scanDartKindLiterals()
        XCTAssertGreaterThan(scanned.count, 20,
                             "只扫到 \(scanned.count) 个 kind——正则或路径已经失效，下面几条测试会假绿")
    }

    /// ★ 核心会抛出的 kind，Swift 必须全部认得。
    func testEveryDartKindIsRegisteredInSwift() throws {
        let contract = try loadContract()
        let scanned = scanDartKindLiterals()
        let dartKinds = contract.userFacing.union(contract.internal).union(scanned)
        let missing = dartKinds.subtracting(NASSearchFailureText.registeredKinds).sorted()
        XCTAssertTrue(missing.isEmpty,
                      """
                      这些 kind 核心会抛出，但 Swift 不认得，界面只能显示
                      「设备返回了未预期的错误（<kind>）」：
                      \(missing.joined(separator: "\n"))
                      在 NASSearchFailureText.sentences 补中文主句，
                      或确认它不该出现在提示里后加进 internalKinds。
                      """)
    }

    /// ★ 核心承诺「界面有话可说」的那些，必须真的有一句中文。
    func testEveryUserFacingKindHasChineseSentence() throws {
        let contract = try loadContract()
        let noSentence = contract.userFacing.filter { kind in
            guard let s = NASSearchFailureText.sentences[kind] else { return true }
            return s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }.sorted()
        XCTAssertTrue(noSentence.isEmpty,
                      "这些 kind 在 Dart 侧被标为 userFacing，但 Swift 没有文案：\(noSentence)")
    }

    /// 文案不能只是把 kind 复述一遍——那和兜底分支没区别。
    func testSentencesAreHumanReadableNotEchoes() {
        for (kind, sentence) in NASSearchFailureText.sentences {
            XCTAssertFalse(sentence == kind, "\(kind) 的文案就是 kind 本身，等于没翻译")
            XCTAssertGreaterThan(sentence.count, 4, "\(kind) 的文案过短：\(sentence)")
        }
    }

    /// 两类互斥：一个 kind 不能既「必须有文案」又「故意不给文案」。
    func testUserFacingAndInternalDoNotOverlap() throws {
        let contract = try loadContract()
        let both = contract.userFacing.intersection(contract.internal).sorted()
        XCTAssertTrue(both.isEmpty, "同时出现在两类里，Swift 侧该不该给文案无法判定：\(both)")

        let swiftBoth = Set(NASSearchFailureText.sentences.keys)
            .intersection(NASSearchFailureText.internalKinds).sorted()
        XCTAssertTrue(swiftBoth.isEmpty, "Swift 侧同一个 kind 既有文案又标为 internal：\(swiftBoth)")
    }

    /// 已登记的 kind 必须真的能翻出句子（防御字典里出现空值/重复键）。
    func testDescribeCoversAllRegisteredKinds() {
        for kind in NASSearchFailureText.sentences.keys.sorted() {
            let text = NASSearchFailureText.describe(kind: kind, apiCode: nil)
            XCTAssertFalse(text.isEmpty, "\(kind) 翻出来是空的")
            XCTAssertFalse(text.contains("未预期的错误"),
                           "\(kind) 已登记，却落进了兜底分支：\(text)")
        }
    }

    /// 反向差集只报告、不断言：Swift 里留着几个历史 kind 无害，
    /// 但要知道它们已经没有来源，别再当真。
    func testReportSwiftOnlyKinds() throws {
        let contract = try loadContract()
        let dartKinds = contract.userFacing.union(contract.internal).union(scanDartKindLiterals())
        let onlySwift = NASSearchFailureText.registeredKinds.subtracting(dartKinds).sorted()
        if !onlySwift.isEmpty {
            print("""
                  [AdapterErrorKindParityTests] Swift 有但 Dart 已无来源的 kind（历史遗留，不阻断）：
                  \(onlySwift.joined(separator: ", "))
                  """)
        }
    }

    private enum ContractError: Error {
        case missing(String)
        case malformed
    }
}
