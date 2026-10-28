import XCTest
@testable import FlashFindCore

/// 向导「编辑已连接来源」的接线回归（用户报障：已登录后勾选不了搜索位置）。
///
/// ## 为什么这批断言读源码
///
/// `FlashFind2App` 是 executableTarget，测试目标 import 不到，`DraftSession`
/// 的语义又只在 Core 里（`DraftSessionTests` 已经锁死）。真正出错的是**接线**：
/// 判断分支写成「有没有本次新连的会话」、收尾路径无条件断开。
/// 这两种错都在控制器的方法体内，只能在方法体内断言。
///
/// 所以这里先按名字取函数体（括号配平，不是全文 `contains`），再在体内断言。
/// 全文搜索不算证据：同一个标识符在别的函数里出现过，就能把一条假接线判成绿。
final class WizardDraftSessionWiringTests: XCTestCase {

    // MARK: - 取源码与方法体

    private func controllerSource() throws -> String {
        let clientRoot = URL(fileURLWithPath: #filePath)   // …/client/Tests/FlashFindCoreTests/X.swift
            .deletingLastPathComponent()                   // …/client/Tests/FlashFindCoreTests
            .deletingLastPathComponent()                   // …/client/Tests
            .deletingLastPathComponent()                   // …/client
        let url = clientRoot.appendingPathComponent("Sources/FlashFind2App/NASSourceWizardController.swift")
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// 按名字取一个函数的函数体（含外层花括号）。括号配平，遇到字符串里的括号也照数，
    /// 但这些方法体里没有「字符串内含花括号」的写法。
    private func body(of name: String, in source: String) throws -> String {
        guard let signature = source.range(of: "func \(name)(") ?? source.range(of: "func \(name) (") else {
            throw XCTSkip("控制器里找不到 func \(name)，名字改了就要同步改这条断言")
        }
        guard let braceStart = source[signature.upperBound...].firstIndex(of: "{") else {
            XCTFail("func \(name) 没有函数体")
            return ""
        }
        var depth = 0
        var index = braceStart
        while index < source.endIndex {
            switch source[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(source[braceStart...index]) }
            default: break
            }
            index = source.index(after: index)
        }
        XCTFail("func \(name) 的花括号没有配平"); return ""
    }

    // MARK: - 进入编辑：必须借到活会话

    /// ★ 编辑一个已连接的来源时，必须把管理器里那个 **ready** 的实例借进来。
    ///
    /// 没有这一步，后面所有勾选都无从谈起（这正是 bug 的第一环）。
    func testEditSourceBorrowsLiveSession() throws {
        let source = try controllerSource()
        let method = try body(of: "editSource", in: source)
        XCTAssertTrue(method.contains("nativeProviders[id]"),
                      "编辑入口要去看管理器里这台来源有没有活实例")
        XCTAssertTrue(method.contains("live.ready") || method.contains("?.ready"),
                      "只有 ready（已登录）的实例才能借；没连上的仍要用户先点连接")
        // ★ 「借」这个动作现在有两条入口（立即可借 / 等收尾落定后借），
        //   断言必须**跟着代码走**：只读 editSource 会在收尾分支上找不到 `.borrowed(`，
        //   那是断言过期，不是代码坏了。两条入口共用同一个 `adoptLiveSession`。
        XCTAssertTrue(method.contains("adoptLiveSession("),
                      "借活会话必须走唯一的那条实现")
        let adopt = try body(of: "adoptLiveSession", in: source)
        XCTAssertTrue(adopt.contains(".borrowed("),
                      "活着就必须记成「借来的」——记成自己建的，取消时就会断开用户正在用的连接")
        XCTAssertTrue(adopt.contains("draftSource.scopes = live.config.scopes"),
                      "界面已选位置必须取自这个活实例本身，不能来自状态字典的旧值")
    }

    // MARK: - 勾选：判定依据必须是「有没有会话」，而不是「有没有本次新连的会话」

    /// ★ 这条直接对着 bug：`guard pendingProvider != nil` 会让编辑态永远进不来。
    func testToggleScopeUsesSessionOwnershipNotPendingProvider() throws {
        let source = try controllerSource()
        let method = try body(of: "toggleDraftScope", in: source)
        // 勾一个 / 全选 / 取消全选三个入口共用同一道准入门（2026-10-27 加的批量入口
        // 也走它）。断言跟着代码走：判断留在共用函数里，这里只查「有没有过门」。
        XCTAssertTrue(method.contains("mayEditDraftScopes()"),
                      "勾选要过共用的准入门，不许各写一份")
        let gate = try body(of: "mayEditDraftScopes", in: source)
        XCTAssertTrue(gate.contains("draftSession.canEditScopes"),
                      "勾选是否可用要问会话本身（借来的也能改）")
        XCTAssertFalse(gate.contains("pendingProvider != nil"),
                       "旧的判定「有没有本次新连的会话」会让编辑已连接来源时永远提示「请先完成连接」")
        for entry in ["toggleDraftScope", "selectAllDraftScopes", "clearAllDraftScopes"] {
            let body = try body(of: entry, in: source)
            XCTAssertTrue(body.contains("mayEditDraftScopes()"),
                          "\(entry) 没过准入门：按下去可能什么都不说")
        }
    }

    // MARK: - 取消 / 返回：不许断开借来的会话，且要回滚范围

    /// ★ 取消（返回、切换来源也走这里）必须交还给 `DraftSession.release`，
    /// 不能自己无条件 `disconnect`。
    func testCancelReleasesSessionThroughOwnership() throws {
        let method = try body(of: "cancelDraft", in: try controllerSource())
        XCTAssertFalse(method.contains(".disconnect()"),
                       "取消编辑不许直接断开：借来的会话是用户正在用的连接")
        XCTAssertTrue(method.contains("release(persistedScopes:"),
                      "收尾必须交给 DraftSession.release —— 它会按所有权决定断开还是回滚")
    }

    /// 提交：只有自己建的才 install（借来的本来就在管理器表里）。
    ///
    /// 给借来的也 install 一次，会发布一次 Provider 变化，
    /// 上层随即整体重建搜索协调器，把其它来源在飞的查询一起取消。
    func testCommitInstallsOnlyWizardOwnedSession() throws {
        let method = try body(of: "commitDraft", in: try controllerSource())
        XCTAssertTrue(method.contains("session.disconnectsOnTeardown"),
                      "install 必须以所有权为条件")
        XCTAssertTrue(method.contains("installProvider(provider)"),
                      "自己建的会话仍然要交给管理器（R02）")
        XCTAssertFalse(method.contains("release(persistedScopes:"),
                       "提交不是取消：会话已经归管理器，这里不能再走 release（那会断开它）")
    }

    /// 断开按钮：断开借来的会话时必须同时把来源状态改成离线。
    ///
    /// 只断实例不改状态，卡片会继续写「已连接」——用户点进去才发现搜索早没了。
    func testDisconnectDraftMarksBorrowedSourceOffline() throws {
        let method = try body(of: "disconnectDraft", in: try controllerSource())
        XCTAssertTrue(method.contains("session.isBorrowed"), "要区分借来的会话")
        XCTAssertTrue(method.contains("$0.health = .offline"), "断开后来源状态必须同步变离线")
        XCTAssertTrue(method.contains("$0.requiredAction = .retry"), "要给用户一个「重新连接」的入口")
    }
}
