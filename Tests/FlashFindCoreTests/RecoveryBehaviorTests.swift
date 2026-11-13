import XCTest
import CoreGraphics
import Foundation
@testable import FlashFindCore

/// 1.1.70 自动登录恢复 / 长按退出 / 点击外部快照的守卫级证据。
///
/// ★ 三条「这个 bug 存在时会红」的判据：
/// ① 点击外部：按下时刻的快照与松手后的实时值必须判出**不同**结果；
/// ② 授权挑战：后台自动连接撞到浏览器授权必须一次停手；
/// ③ 长按退出：进度不到 1 绝不终止。
final class RecoveryBehaviorTests: XCTestCase {

    // MARK: - 源码扫描 helper（与 AppLayerStructureTests 同口径：先去整行注释）

    private func source(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(relative), encoding: .utf8)
    }

    private func codeOnly(_ s: String) -> String {
        s.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 括号配平切出函数体；整文件 `contains` 回答不了「这行在不在函数里」。
    private func block(after marker: String, in src: String) -> String? {
        guard let start = src.range(of: marker),
              let brace = src.range(of: "{", range: start.upperBound..<src.endIndex) else { return nil }
        var depth = 0
        var index = brace.lowerBound
        while index < src.endIndex {
            switch src[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(src[brace.lowerBound...index]) }
            default: break
            }
            index = src.index(after: index)
        }
        return nil
    }

    // MARK: - A：启动期解锁

    func testStartupUnlockOnlyPrimesTheVaultAndNeverRunsMigration() throws {
        let core = try source("Sources/FlashFindCore/CredentialStore.swift")
        let body = try XCTUnwrap(block(after: "static func unlockVaultForStartup()", in: core))
        XCTAssertTrue(body.contains("primeVaultCache()"))
        XCTAssertFalse(body.contains("read("), "走 read 会在读不到值时连带触发迁移链")
        XCTAssertFalse(body.contains("migrate"))
        XCTAssertFalse(body.contains("onInteractiveRead"))
    }

    func testStartupWiresUnlockNetworkMonitorAndQuitHold() throws {
        let app = codeOnly(try source("Sources/FlashFind2App/FlashFind2App.swift"))
        XCTAssertTrue(app.contains("QuitHoldController.shared.install()"))
        XCTAssertTrue(app.contains("model.startNetworkRecoveryMonitor()"))
        XCTAssertTrue(app.contains("model.unlockCredentialsAndReplay()"))
        XCTAssertFalse(app.contains("CredentialStore.migrate"), "迁移仍不许出现在启动路径")
    }

    func testInteractiveReadReplaysTheOtherSourcesWithoutRecursing() throws {
        let app = codeOnly(try source("Sources/FlashFind2App/FlashFind2App.swift"))
        XCTAssertTrue(app.contains("replayAfterInteractiveRead()"))
        let recovery = codeOnly(try source("Sources/FlashFind2App/AppModel+Recovery.swift"))
        let body = try XCTUnwrap(block(after: "func replayPendingSources(reason: String)", in: recovery))
        XCTAssertTrue(body.contains("SecureStorage.read(account: source.credentialAccount"))
        XCTAssertFalse(body.contains("allowInteraction: true"),
                       "交互读会回调 onInteractiveRead，补跑自己递归自己")
        XCTAssertTrue(body.contains("NetworkRecoveryPolicy.shouldReplaySource"))
    }

    func testDragFrameTraceDefaultsToOff() throws {
        let trace = codeOnly(try source("Sources/FlashFind2App/DragFrameTrace.swift"))
        XCTAssertTrue(trace.contains("FF2_DRAG_TRACE\"] == \"1\""),
                      "1.1.69 默认开、写日志的边界必须在 120 收口")
    }

    // MARK: - B：网络恢复

    func testReplayOnlyOnTheUnsatisfiedToSatisfiedEdge() {
        XCTAssertTrue(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: false, isSatisfied: true,
                                                          secondsSinceLastReplay: nil))
        XCTAssertFalse(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: true, isSatisfied: true,
                                                           secondsSinceLastReplay: nil))
        XCTAssertFalse(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: true, isSatisfied: false,
                                                           secondsSinceLastReplay: nil))
        XCTAssertFalse(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: false, isSatisfied: false,
                                                           secondsSinceLastReplay: nil))
    }

    func testRapidFlappingIsDebounced() {
        XCTAssertFalse(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: false, isSatisfied: true,
                                                           secondsSinceLastReplay: 0.4))
        XCTAssertTrue(NetworkRecoveryPolicy.shouldReplay(wasSatisfied: false, isSatisfied: true,
                                                          secondsSinceLastReplay: 5))
    }

    func testSourceFilterSkipsAnythingThatDoesNotNeedReplay() {
        XCTAssertTrue(NetworkRecoveryPolicy.shouldReplaySource(
            isEnabled: true, isConnectConfigured: true, rememberPassword: true,
            providerReady: false, connectTaskRunning: false, needsLogin: true))
        let variants: [(String, Bool)] = [
            ("已连上", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: true, isConnectConfigured: true, rememberPassword: true,
                providerReady: true, connectTaskRunning: false, needsLogin: true)),
            ("正在连", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: true, isConnectConfigured: true, rememberPassword: true,
                providerReady: false, connectTaskRunning: true, needsLogin: true)),
            ("状态本来就正常", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: true, isConnectConfigured: true, rememberPassword: true,
                providerReady: false, connectTaskRunning: false, needsLogin: false)),
            ("已禁用", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: false, isConnectConfigured: true, rememberPassword: true,
                providerReady: false, connectTaskRunning: false, needsLogin: true)),
            ("没勾记住密码", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: true, isConnectConfigured: true, rememberPassword: false,
                providerReady: false, connectTaskRunning: false, needsLogin: true)),
            ("配置不全", NetworkRecoveryPolicy.shouldReplaySource(
                isEnabled: true, isConnectConfigured: false, rememberPassword: true,
                providerReady: false, connectTaskRunning: false, needsLogin: true)),
        ]
        for (label, value) in variants { XCTAssertFalse(value, label) }
    }

    // MARK: - C：授权挑战停手

    func testAuthorizationChallengeIsNotRetried() {
        let error = FlashFindError.authorizationRequired(
            url: URL(string: "https://nas.example.com/oauth")!, validFor: 300, rejected: false)
        XCTAssertFalse(NASAutoConnectPolicy.shouldRetry(error))
        XCTAssertTrue(NASAutoConnectPolicy.shouldRetry(URLError(.timedOut)),
                      "普通网络失败仍要按退避重试")
    }

    // MARK: - 点击外部：事件时刻快照

    func testSnapshotKeepsPressTimeInputEvenAfterTheWindowMoves() {
        let field = CGRect(x: 100, y: 100, width: 300, height: 60)
        let press = CGPoint(x: 120, y: 120)   // 拖搜索框的起点，明明在窗口内
        let snapshot = SearchClickOutside.Snapshot(click: press, field: field,
                                                   otherVisibleWindows: [],
                                                   overlayBlocksDismissal: false)
        // 旧实现在异步 Task 里读到的是「松手后」：指针走远、窗口被 settle 摆走。
        let stale = SearchClickOutside.Snapshot(
            click: CGPoint(x: 900, y: 500),
            field: CGRect(x: 500, y: 400, width: 300, height: 60),
            otherVisibleWindows: [], overlayBlocksDismissal: false)
        XCTAssertTrue(SearchClickOutside.shouldDismiss(stale),
                      "这正是拖动时把浮窗收掉的误判；两种输入必须判出不同结果")
        XCTAssertFalse(SearchClickOutside.shouldDismiss(snapshot))
    }

    func testSnapshotStillDismissesARealOutsideClick() {
        let snapshot = SearchClickOutside.Snapshot(
            click: CGPoint(x: 900, y: 500), field: CGRect(x: 100, y: 100, width: 300, height: 60),
            otherVisibleWindows: [], overlayBlocksDismissal: false)
        XCTAssertTrue(SearchClickOutside.shouldDismiss(snapshot))
    }

    func testSnapshotStillHonoursVisibleWindowsAndOverlay() {
        let field = CGRect(x: 100, y: 100, width: 300, height: 60)
        let point = CGPoint(x: 900, y: 500)
        let withWindow = SearchClickOutside.Snapshot(
            click: point, field: field,
            otherVisibleWindows: [CGRect(x: 880, y: 480, width: 100, height: 100)],
            overlayBlocksDismissal: false)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(withWindow))
        let withOverlay = SearchClickOutside.Snapshot(
            click: point, field: field, otherVisibleWindows: [], overlayBlocksDismissal: true)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(withOverlay))
    }

    func testClickOutsideUsesSnapshotTakenAtEventTime() throws {
        let controller = codeOnly(try source("Sources/FlashFind2App/SearchPanelController.swift"))
        XCTAssertTrue(controller.contains("func makeClickOutsideSnapshot()"))
        // 两个调用点都必须传快照；改回「Task 里重读实时坐标」会立刻红。
        XCTAssertEqual(controller.components(separatedBy: "dismissIfClickOutside(snapshot)").count - 1, 2)
        XCTAssertFalse(controller.contains("dismissIfClickOutside()"))
        let body = try XCTUnwrap(block(after: "private func dismissIfClickOutside(_ snapshot:",
                                       in: controller))
        XCTAssertFalse(body.contains("NSEvent.mouseLocation"))
        XCTAssertFalse(body.contains("panel.frame"))
        XCTAssertTrue(body.contains("shouldDismiss(snapshot)"))
    }

    // MARK: - 长按 ⌘Q

    func testPlainCommandQStartsTheHold() {
        XCTAssertTrue(QuitHoldPolicy.isQuitKeyDown(keyCode: 12, hasCommand: true,
                                                   hasOtherModifiers: false, isRepeat: false))
    }

    func testRepeatOtherModifiersAndOtherKeysNeverStartTheHold() {
        XCTAssertFalse(QuitHoldPolicy.isQuitKeyDown(keyCode: 12, hasCommand: true,
                                                    hasOtherModifiers: false, isRepeat: true))
        XCTAssertFalse(QuitHoldPolicy.isQuitKeyDown(keyCode: 12, hasCommand: true,
                                                    hasOtherModifiers: true, isRepeat: false))
        XCTAssertFalse(QuitHoldPolicy.isQuitKeyDown(keyCode: 12, hasCommand: false,
                                                    hasOtherModifiers: false, isRepeat: false))
        XCTAssertFalse(QuitHoldPolicy.isQuitKeyDown(keyCode: 53, hasCommand: true,
                                                    hasOtherModifiers: false, isRepeat: false))
    }

    func testProgressIsClampedAndReachesOneOnlyAtTheEnd() {
        XCTAssertEqual(QuitHoldPolicy.progress(elapsed: -3), 0, accuracy: 0.0001)
        XCTAssertEqual(QuitHoldPolicy.progress(elapsed: 0), 0, accuracy: 0.0001)
        XCTAssertEqual(QuitHoldPolicy.progress(elapsed: QuitHoldPolicy.holdDuration / 2),
                       0.5, accuracy: 0.0001)
        XCTAssertEqual(QuitHoldPolicy.progress(elapsed: QuitHoldPolicy.holdDuration),
                       1, accuracy: 0.0001)
        XCTAssertEqual(QuitHoldPolicy.progress(elapsed: 99), 1, accuracy: 0.0001)
    }

    func testShortPressNeverTerminates() {
        XCTAssertFalse(QuitHoldPolicy.shouldTerminate(progress: 0))
        XCTAssertFalse(QuitHoldPolicy.shouldTerminate(progress: 0.99))
        XCTAssertFalse(QuitHoldPolicy.shouldTerminate(
            progress: QuitHoldPolicy.progress(elapsed: QuitHoldPolicy.holdDuration * 0.4)))
        XCTAssertTrue(QuitHoldPolicy.shouldTerminate(progress: 1))
    }

    func testQuitKeyDownIsSwallowedAndTerminateIsGatedByProgress() throws {
        let controller = codeOnly(try source("Sources/FlashFind2App/QuitHoldController.swift"))
        let handle = try XCTUnwrap(block(after: "private func handle(event: NSEvent)", in: controller))
        XCTAssertTrue(handle.contains("QuitHoldPolicy.isQuitKeyDown"))
        XCTAssertTrue(handle.contains("return nil"), "⌘Q 必须被吞掉，否则系统直接 terminate")
        XCTAssertFalse(handle.contains("NSApplication.shared.terminate"), "按下时不许直接退出")
        let tick = try XCTUnwrap(block(after: "private func tick()", in: controller))
        XCTAssertTrue(tick.contains("QuitHoldPolicy.shouldTerminate(progress:"))
        let finish = try XCTUnwrap(block(after: "private func finishQuit()", in: controller))
        XCTAssertTrue(finish.contains("NSApplication.shared.terminate(nil)"))
        let menu = codeOnly(try source("Sources/FlashFind2App/FlashFind2App.swift"))
        XCTAssertTrue(menu.contains("Button(\"退出闪寻\")"), "菜单里明确的点击退出要保留")
    }

    func testQuitHoldRingWordingSaysLongPress() throws {
        let controller = codeOnly(try source("Sources/FlashFind2App/QuitHoldController.swift"))
        XCTAssertTrue(controller.contains("Text(\"长按关闭闪寻\")"),
                      "「关闭中」看不出要一直按住，用户 2026-11-13 指定改文案")
        XCTAssertFalse(controller.contains("Text(\"关闭中\")"))
    }

    // MARK: - 系统授权框：输完钥匙串密码界面不许消失（1.1.71）

    func testDismissalIsBlockedOnlyDuringThePromptAndItsGrace() {
        XCTAssertTrue(SystemPromptFocusPolicy.blocksDismissal(promptInFlight: true,
                                                              secondsSincePromptEnded: nil))
        XCTAssertTrue(SystemPromptFocusPolicy.blocksDismissal(promptInFlight: false,
                                                              secondsSincePromptEnded: 0.2))
        XCTAssertFalse(SystemPromptFocusPolicy.blocksDismissal(promptInFlight: false,
                                                               secondsSincePromptEnded: nil),
                       "平时点外部照旧收窗，不许把功能焊死")
        XCTAssertFalse(SystemPromptFocusPolicy.blocksDismissal(promptInFlight: false,
                                                               secondsSincePromptEnded: 1.3))
        XCTAssertFalse(SystemPromptFocusPolicy.blocksDismissal(promptInFlight: false,
                                                               secondsSincePromptEnded: -1),
                       "系统时钟回拨不算「刚结束」")
    }

    /// ★ 红证口径：同一份「点在窗口外」的快照，1.1.70 判收窗（界面真的没了），
    /// 1.1.71 在保护期内判不收。两个输入必须判出**不同**结果，否则这条用例是假绿。
    func testClickInsideSystemPromptDoesNotDismissSearchField() {
        let field = CGRect(x: 100, y: 100, width: 300, height: 60)
        let point = CGPoint(x: 900, y: 500)   // 授权框在屏幕中央，落在搜索框之外
        let old = SearchClickOutside.Snapshot(
            click: point, field: field, otherVisibleWindows: [], overlayBlocksDismissal: false)
        XCTAssertTrue(SearchClickOutside.shouldDismiss(old),
                      "这正是 1.1.70 把浮窗收掉的那一判")
        let protected = SearchClickOutside.Snapshot(
            click: point, field: field, otherVisibleWindows: [],
            overlayBlocksDismissal: false, systemPromptBlocksDismissal: true)
        XCTAssertFalse(SearchClickOutside.shouldDismiss(protected))
        XCTAssertTrue(SearchClickOutside.shouldDismiss(
            click: point, field: field, otherVisibleWindows: [],
            overlayBlocksDismissal: false, systemPromptBlocksDismissal: false),
            "宽限期过后必须恢复正常的点外部收窗")
    }

    func testRecoveryOnlyBringsBackWhatWasVisibleBeforeThePrompt() {
        typealias V = SystemPromptFocusPolicy.VisibilityBeforePrompt
        typealias R = SystemPromptFocusPolicy.Recovery
        // 别把方法直接赋给 `let`：Swift 6 会抹掉闭包的参数标签，调用点得写 `_`。
        func decide(visibilityBeforePrompt v: V, isVisibleAfterPrompt a: Bool,
                    hasPreferencesWindow p: Bool, onboardingVisible o: Bool) -> R {
            SystemPromptFocusPolicy.recovery(visibilityBeforePrompt: v,
                                             isVisibleAfterPrompt: a,
                                             hasPreferencesWindow: p,
                                             onboardingVisible: o)
        }
        XCTAssertEqual(decide(visibilityBeforePrompt: .visible, isVisibleAfterPrompt: false,
                              hasPreferencesWindow: false, onboardingVisible: false),
                       R.showAndActivate, "浮窗被那一下点击收掉了，要重新显示")
        XCTAssertEqual(decide(visibilityBeforePrompt: .visible, isVisibleAfterPrompt: true,
                              hasPreferencesWindow: false, onboardingVisible: false),
                       R.activateOnly, "窗口还在，只是被压到后面：别重建视图")
        XCTAssertEqual(decide(visibilityBeforePrompt: .unknown, isVisibleAfterPrompt: true,
                              hasPreferencesWindow: false, onboardingVisible: false),
                       R.activateOnly, "★ 拿不到状态不等于「用户收起了」")
        XCTAssertEqual(decide(visibilityBeforePrompt: .hidden, isVisibleAfterPrompt: false,
                              hasPreferencesWindow: false, onboardingVisible: false),
                       R.none, "用户自己收起的浮窗不擅自弹回来")
        XCTAssertEqual(decide(visibilityBeforePrompt: .visible, isVisibleAfterPrompt: false,
                              hasPreferencesWindow: true, onboardingVisible: false),
                       R.none, "设置/向导走它们自己的救援")
        XCTAssertEqual(decide(visibilityBeforePrompt: .visible, isVisibleAfterPrompt: false,
                              hasPreferencesWindow: false, onboardingVisible: true),
                       R.none, "引导页不许被搜索框盖住")
    }

    func testStartupUnlockIsGuardedDeferredAndExplicitlyRescuesThePanel() throws {
        let recovery = codeOnly(try source("Sources/FlashFind2App/AppModel+Recovery.swift"))
        let body = try XCTUnwrap(block(after: "private func unlockVaultWithFocusGuard()", in: recovery))
        XCTAssertTrue(body.contains("SystemPromptGuard.shared.around"))
        XCTAssertTrue(body.contains("CredentialStore.unlockVaultForStartup()"))
        XCTAssertTrue(body.contains("onSystemPromptFinished?(before)"),
                      "★ primeVaultCache 不触发 onInteractiveRead，救援必须显式调")
        XCTAssertTrue(body.contains("NSApp.activate(ignoringOtherApps: true)"))
        let app = codeOnly(try source("Sources/FlashFind2App/FlashFind2App.swift"))
        XCTAssertTrue(app.contains("SystemPromptFocusPolicy.startupUnlockDelay"),
                      "不许在启动那一帧就弹系统框")
        XCTAssertTrue(app.contains("recoverAfterSystemPrompt(before: before)"))
        XCTAssertTrue(app.contains("searchPanel?.bringForward(showIfHidden: true)"))
        let controller = codeOnly(try source("Sources/FlashFind2App/SearchPanelController.swift"))
        let snapshot = try XCTUnwrap(block(after: "private func makeClickOutsideSnapshot", in: controller))
        XCTAssertTrue(snapshot.contains("SystemPromptGuard.shared.blocksDismissal"),
                      "结论必须在事件时刻拍进快照；异步再读会把宽限期读没")
    }
}
