import XCTest
@testable import FlashFindCore

/// App 层（FlashFind2App）拆分后必须成立的结构性规则。
///
/// ## 为什么只能扫源码
///
/// `FlashFind2App` 是 executableTarget，SwiftPM 的 testTarget **依赖不了它**，
/// 所以 AppModel、ShortcutController 这些没法直接实例化来测。能让编译器帮上忙的
/// 只有「改了就编译不过」的那部分；剩下的只能靠扫源码——这比不测好，
/// 而且本文件锁的恰好是「编译能过、运行也不报错、只有人工点一遍才发现」的那类问题。
///
/// 扫源码时**必须跳过整行注释**，否则谁在注释里提一句旧实现就会误报——
/// 项目里 `NoKeychainAccessTests` 踩过同一个坑。
final class AppLayerStructureTests: XCTestCase {

    private func appSource(_ name: String) throws -> String {
        // 测试文件在 client/Tests/FlashFindCoreTests/ 下，上溯两级是 client/。
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFind2App/\(name)"),
                          encoding: .utf8)
    }

    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    private func appModelCode() throws -> String {
        // AppModel 随 Stage 3A 拆成主文件 + 若干 `AppModel+<分区>.swift`。
        // 源码包含断言必须**跟着代码走**：只读主文件的话，搬到分区里的实现就
        // 「找不到符号」——轻则断言假绿（`range(of:)` 返回 nil 被 `?? ""` 吃掉），
        // 重则下面几条 `region!` 直接强制解包崩溃（拆分当天就真崩过一次）。
        // 所以按文件名把分区一并并进来，顺序固定，保证结果可复现。
        return try AppModelSource.read(callerFilePath: #filePath)
    }

    /// ★ 分区文件必须被扫进来 —— 否则上面的 helper 一失效，几十条断言集体假绿。
    ///
    /// `openReconnectWizard` 已搬到 `AppModel+Wizard.swift`：它还在不在不重要，
    /// 重要的是**helper 的取范围**能覆盖到分区。这条守的是 helper 本身。
    func testAppModelScanCoversTheSplitOutPartitions() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlashFind2App")
        let partitions = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("AppModel+") && $0.pathExtension == "swift" }
        XCTAssertFalse(partitions.isEmpty, "没有任何 AppModel+ 分区，本条断言失去意义")

        let code = try appModelCode()
        // 主文件与分区都必须在扫描结果里：只命中一边就说明取范围错了。
        XCTAssertTrue(code.contains("final class AppModel"), "主文件没被扫进来")
        for url in partitions {
            let head = try String(contentsOf: url, encoding: .utf8)
            // 取分区里第一个 func 名，确认它出现在合并结果中
            guard let m = head.range(of: "func ") else { continue }
            let after = head[m.upperBound...]
            let name = after.prefix { !$0.isWhitespace && $0 != "(" }
            XCTAssertTrue(code.contains("func " + name),
                          "分区 \(url.lastPathComponent) 的实现没进扫描范围")
        }
    }

    /// 扫描确实读到了文件——读不到的话下面的「不含 XX」断言会全部假绿。
    func testSourceScanActuallyReadsFiles() throws {
        let code = try appModelCode()
        XCTAssertTrue(code.contains("final class AppModel"), "没读到 AppModel.swift，下面几条会假绿")
        XCTAssertGreaterThan(code.count, 50_000, "读到的是空壳")
    }

    /// ★ 事件监视器的生命周期只允许在一处管理。
    ///
    /// 录制快捷键要装 `NSEvent.addLocalMonitorForEvents`，装了就必须卸，而卸有两条路径：
    /// 正常结束（录到组合键 / Esc / 窗口失焦或关闭）与对象释放（deinit）。
    /// 这两条一旦散在不同文件里，改一处忘一处，留下的就是一个永不摘除的全局监视器
    /// ——不崩、不报错，只是此后每次按键都要多跑一段闭包。
    func testEventMonitorLivesOnlyInShortcutController() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("addLocalMonitorForEvents"),
                       "AppModel 不该再装事件监视器；录制归 ShortcutController")
        XCTAssertFalse(appModel.contains("NSEvent.removeMonitor"),
                       "AppModel 不该再卸事件监视器；卸载路径只有 ShortcutController 里那两条")

        let controller = codeOnly(try appSource("ShortcutController.swift"))
        XCTAssertTrue(controller.contains("addLocalMonitorForEvents"))
        XCTAssertTrue(controller.contains("func cancelRecording()"), "缺少正常结束时的卸载路径")
        XCTAssertTrue(controller.contains("deinit"), "缺少释放时的卸载路径")
    }

    /// ★ 状态搬走后必须桥接变更通知，否则界面不刷新。
    ///
    /// 这些状态原本是 AppModel 自己的 `@Published`，界面观察的是 AppModel。
    /// 改成转发属性之后，如果忘了把 `shortcuts.objectWillChange` 接过来，
    /// 编译能过、运行也不报错——只是「录完快捷键界面没反应」，只能靠手动点出来。
    func testShortcutChangesAreBridgedToAppModel() throws {
        let appModel = try appModelCode()

        for name in ["globalShortcut", "shortcutStatus", "shortcutAvailable", "isRecordingShortcut"] {
            let publishedLine = appModel.split(separator: "\n").first { line in
                line.contains("@Published") && line.contains(name)
            }
            XCTAssertNil(publishedLine,
                         "\(name) 不该再是 AppModel 的 @Published，应转发到 ShortcutController")
        }

        XCTAssertTrue(appModel.contains("objectWillChange.sink"),
                      "状态搬到 ShortcutController 后必须桥接 objectWillChange，否则界面不刷新")
        XCTAssertTrue(appModel.contains("shortcutBridge"),
                      "桥接必须被持有（AnyCancellable），否则订阅立刻被释放")
    }

    // MARK: - 结果动作（打开 / 定位 / 快速查看 / 复制）

    /// ★ 动作的系统调用只允许在 controller 里。
    ///
    /// 打开链路最脆的一处是「reveal 之后不许再 `NSApp.activate`」——
    /// 它会把焦点从访达抢回闪寻，表现为「访达打开了但闪寻又弹回来」，
    /// 等于定位没生效。这种缺陷只有真机点一次才看得见，所以把整条链路
    /// 收在一处，让这类配套的坑随代码一起搬、不再有机会被复制走样。
    func testFileOpeningCallsLiveOnlyInResultActionController() throws {
        let appModel = try appModelCode()
        // 只锁「结果动作专属」的调用。`NSWorkspace.shared.open` 不在此列——
        // AppModel 里还有打开服务器管理页、发起 SMB 连接两处用途与结果动作无关，
        // 把它们写进断言只会逼出一个谎言。
        for call in ["activateFileViewerSelecting", "QuickLookPreview.present",
                     "NSPasteboard.general"] {
            XCTAssertFalse(appModel.contains(call),
                           "AppModel 不该再直接 \(call)；结果动作归 ResultActionController")
        }

        let controller = codeOnly(try appSource("ResultActionController.swift"))
        XCTAssertTrue(controller.contains("activateFileViewerSelecting"))
        XCTAssertTrue(controller.contains("QuickLookPreview.present"))
    }

    /// ★ 直接打开文件成功后浮窗必须自动收起，且不许把焦点抢回闪寻。
    ///
    /// 用户报障：从搜索结果打开文件，目标 App 在前台打开了，
    /// 闪寻浮窗却还压在上面——因为 open 的普通分支只做了
    /// `NSApp.activate`（把闪寻拉回前台），从不调用 `onHidePanel()`。
    /// 这与 reveal 分支的教训同源：打开动作之后**闪寻必须让位**。
    ///
    /// ★ 断言必须切到「打开成功」那个花括号块里做：整份 `func open` 用
    /// `contains("onHidePanel()")` 会被 reveal 分支满足——变异测试已实锤过。
    /// 另外**只在成功路径收起**：打开失败（NAS 没连上等）要留着浮窗
    /// 显示错误提示，收了提示就没人看得见了。
    func testOpenFileHidesPanelAndDoesNotStealFocus() throws {
        let controller = codeOnly(try appSource("ResultActionController.swift"))
        let openBody = try XCTUnwrap(braceBlock(after: "func open(", in: controller),
                                     "ResultActionController 里找不到 func open(")
        // 锁住「打开成功」分支本身：这里面必须有收起浮窗的调用。
        let successBlock = try XCTUnwrap(
            braceBlock(after: "NSWorkspace.shared.open(url)", in: openBody),
            "func open 里找不到 NSWorkspace.shared.open 的花括号块")
        XCTAssertTrue(successBlock.contains("onHidePanel()"),
                      "打开文件成功后必须收起浮窗（onHidePanel）")
        // reveal 分支早有结论：动作之后再 activate 会把焦点抢回闪寻。
        // 普通打开同理——NSWorkspace.open 自己会激活目标 App。
        XCTAssertFalse(openBody.contains("NSApp.activate"),
                       "打开文件后不许 NSApp.activate 抢焦点，浮窗收起后目标 App 应保持前台")
    }

    /// ★ 开机自动连接必须带重试（Mac 重启后不自动登录）。
    ///
    /// 开机那一刻网络常常还没就绪（Wi-Fi 未连上 / DHCP 未拿到地址），
    /// 只发一次连接就等于把「还没拿到 IP」误判成「设备拒绝登录」。
    /// 驱动器是 Core 里的可测类型，这里只锁「App 层确实走了它」——
    /// 少了这一层，重试逻辑写得再好也不会被调用。
    func testAutoConnectRetriesThroughRunner() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("NASAutoConnectRunner()"),
                      "开机自动连接应交给驱动器，而不是自己发一次就了事")
        XCTAssertTrue(appModel.contains("await runner.run()"))
        // ★ 意图只登记一次且在重试循环之外：每轮重试都重新登记的话，
        // 用户在重试间隙点「断开」只作废某一轮，下一轮又会自己连回来。
        XCTAssertEqual(appModel.components(separatedBy: "connectIntent.begin").count - 1, 1,
                       "一次自动连接只能登记一次连接意图")
        XCTAssertTrue(appModel.contains("async throws -> Bool"),
                      "单次连接要回报「是否连上」，宿主据此决定要不要重试")
    }

    /// ★ 打开失败的提示状态只能有一处定义。
    ///
    /// 界面写的是 `model.openFailure`（读）与 `model.openFailure = nil`（写），
    /// 所以 AppModel 必须同时留 getter 与 setter，并且把变更通知桥接过来——
    /// 少任何一样，提示条要么不出现、要么关不掉。
    func testOpenFailureIsForwardedButStillBridged() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("struct OpenFailure"),
                       "OpenFailure 的定义应随动作一起搬到 ResultActionController")
        XCTAssertTrue(appModel.contains("var openFailure"),
                      "界面写的是 model.openFailure，转发属性必须保留")
        // 只给 getter 的话，提示条上点「关闭」就再也关不掉。
        XCTAssertTrue(appModel.contains("set { resultActions.failure = newValue }"),
                      "openFailure 必须可写，否则界面上的「关闭」失效")
        // ★ 要断言「桥接动作」而不是变量名：光查 `resultActionBridge` 会被它的
        // 声明行满足，桥接代码删掉照样绿——这正是反向验证要抓的东西。
        XCTAssertTrue(appModel.contains("resultActions.objectWillChange.sink"),
                      "必须把 resultActions 的 objectWillChange 接到 AppModel，否则提示条不刷新")
    }

    /// 打开失败的文案必须与搜索失败共用同一套中文。
    ///
    /// 两边各写一张表就会说出两种话；这里的强制点是：AppModel 里不该再有任何
    /// 私有翻译函数（旧的 `openErrorMessage` 就是这么来的）。
    func testNoPrivateErrorTranslationInAppModel() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("openErrorMessage"),
                       "打开失败的翻译已统一到 OpenFailureText（Core，可测），AppModel 不该再留私有版本")
    }

    /// ★ 打开失败提示条要自己占高，而且不许跨查询残留。
    ///
    /// 真机 bug：浮窗高度是算出来的（`panelHeight`），原来没算提示条，
    /// 于是它被压成一条只露出「无法打开文件」和两个按钮的窄边，正文整段被切掉；
    /// 更糟的是查询清空后提示条还挂在面板上，对着空列表喊「无法打开文件」。
    func testOpenFailureBannerOwnsItsHeightAndLeavesWithTheQuery() throws {
        let view = codeOnly(try appSource("SearchView.swift"))
        let panel = try XCTUnwrap(braceBlock(after: "private var panelHeight", in: view),
                                  "找不到 panelHeight")
        XCTAssertTrue(panel.contains("openFailureBannerHeight"),
                      "浮窗高度必须算上提示条，否则提示条撑不开、被切成窄边")

        let banner = try XCTUnwrap(
            braceBlock(after: "struct OpenFailureBanner", in: codeOnly(try appSource("SearchStateView.swift"))),
            "找不到 OpenFailureBanner")
        XCTAssertTrue(banner.contains("SearchLayout.openFailureBannerHeight"),
                      "提示条高度要取自 SearchLayout（与 panelHeight 同源），不能各写一个数")
        XCTAssertTrue(banner.contains("lineLimit(2)"),
                      "固定高度下正文必须限行，否则长句被拦腰截断又没有别的读法")

        let appModel = try appModelCode()
        let changed = try XCTUnwrap(braceBlock(after: "func changedQuery", in: appModel),
                                    "找不到 changedQuery")
        XCTAssertTrue(changed.contains("openFailure = nil"),
                      "查询一变就要清掉上一条结果的打开失败提示，否则它会对着空列表报错")
    }

    /// ★ Provider 只能从工厂造，依赖必须一次装齐。
    ///
    /// 真机 bug：证书确认那条路自己 new 了一个 Provider，漏装 `mountService`。
    /// 表现极不对称——同一份代码，证书正常的 NAS 能开文件，需要确认证书的那台
    /// 点开就报「尚未连接共享」；搜索却是好的，所以很难往挂载上想。
    func testWizardBuildsEveryProviderThroughOneFactory() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardController.swift"))
        let factory = try XCTUnwrap(braceBlock(after: "private func makeProvider", in: wizard),
                                    "找不到 makeProvider")
        XCTAssertTrue(factory.contains("provider.mountService = mountService"),
                      "挂载服务要在工厂里装：漏了就是「能搜、不能开」")
        XCTAssertTrue(factory.contains("provider.queryBudgetMs"),
                      "搜索超时预算同样要在工厂里装，否则这台 NAS 用默认预算")
        XCTAssertEqual(wizard.components(separatedBy: "NASSearchProvider(bridge:").count - 1, 1,
                       "Provider 的构造只许出现在 makeProvider 里，别处手写必然漏装依赖")
        XCTAssertEqual(wizard.components(separatedBy: "makeProvider(sharedBridge").count - 1, 2,
                       "连接与「确认证书后继续」两条路都必须走工厂")
    }

    // MARK: - 本机来源（搜索方式 / 已挂载共享 / 文件夹）

    /// ★ 状态搬走后必须桥接变更通知。
    ///
    /// 「本机搜索方式」的说明文字、已挂载共享列表都是界面直接观察的：
    /// 忘了桥接的表现是「设置里改了方式，下面那句说明还是旧的」，
    /// 编译能过、也不报错。所以这条和快捷键、结果动作一样要锁住。
    func testLocalSourceChangesAreBridgedToAppModel() throws {
        let appModel = try appModelCode()

        for name in ["localEnabled", "localFolders", "localSearchMode", "localSearchAvailabilityMessage",
                     "mountedSMBShares", "importedSMBShare", "mountedSMBDiscoveryCompleted",
                     "mountedSMBDiscoveryError"] {
            let publishedLine = appModel.split(separator: "\n").first { line in
                line.contains("@Published") && line.contains(name)
            }
            XCTAssertNil(publishedLine,
                         "\(name) 不该再是 AppModel 的 @Published，应转发到 LocalSourceController")
        }

        // ★ 锁「动作」不锁变量名：`localSourcesBridge` 的声明行就能满足 contains，
        // 桥接删掉照样绿。
        XCTAssertTrue(appModel.contains("localSources.objectWillChange.sink"),
                      "必须把 localSources 的 objectWillChange 接到 AppModel，否则设置界面不刷新")
    }

    /// ★ 本机来源的三件事只能住在 controller 里：
    /// 偏好读写、本机文件夹选择、挂载表发现。
    ///
    /// `NSOpenPanel` 本身不能拿来做断言——AppModel 里还有 `bind(_:)`
    /// 给旧版来源绑目录，也是同一个面板。所以挑只属于「本机文件夹」的
    /// `volumeIsLocalKey`（网络卷不许进本机搜索）作标记。
    func testLocalSourceMechanicsLiveOnlyInController() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("volumeIsLocalKey"),
                       "选择本机文件夹（含排除网络卷）应归 LocalSourceController")
        XCTAssertFalse(appModel.contains("ff2.localSearchMode"),
                       "本机搜索方式的偏好读写应归 LocalSourceController")
        XCTAssertFalse(appModel.contains("self.mountDiscovery ="),
                       "挂载表读取的入口应随状态一起搬到 LocalSourceController")

        let controller = codeOnly(try appSource("LocalSourceController.swift"))
        XCTAssertTrue(controller.contains("volumeIsLocalKey"))
        XCTAssertTrue(controller.contains("ff2.localSearchMode"))
        XCTAssertTrue(controller.contains("mountDiscovery"))
    }

    // MARK: - 向导（添加 / 编辑 NAS 来源）

    /// ★ 状态搬走后必须桥接变更通知。
    ///
    /// 这一轮和前几轮不同：**连状态一起搬了**（`nasSources` / `nativeProviders` /
    /// `draftSource` …），因为向导这二十来个状态彼此咬合，只搬动作会换来一堆
    /// 互相引用的回调。代价是界面依赖的转发属性更多了——不桥接的表现是
    /// 「向导里点连接，界面一点反应都没有」，编译能过，也不报错。
    func testWizardChangesAreBridgedToAppModel() throws {
        let appModel = try appModelCode()

        for name in ["draftSource", "draftStatus", "draftBusy", "draftConnected", "draftAvailableShares",
                     "nasSources", "nasSourceStatus", "nativeProviders", "selectedSourceID",
                     "nativeNASPassword", "nativeNASOTP", "nasTrustCandidate"] {
            // ★ 要整词匹配：`selectedSourceID` 会被 `selectedSourceIDs`
            // （复数、属于 NASConnectionProfile）误伤——那是另一个字段，不在此列。
            let publishedLine = appModel.split(separator: "\n").first { line in
                guard line.contains("@Published") else { return false }
                return line.contains(name + " ") || line.contains(name + ":")
            }
            XCTAssertNil(publishedLine,
                         "\(name) 不该再是 AppModel 的 @Published，应转发到 NASSourceWizardController")
        }

        // ★ 锁「动作」不锁变量名：`wizardBridge` 的声明行就能满足 contains。
        XCTAssertTrue(appModel.contains("wizard.objectWillChange.sink"),
                      "必须把 wizard 的 objectWillChange 接到 AppModel，否则向导界面不刷新")
    }

    /// ★ 向导的三件机制只能住在 controller 里：
    /// 连接尝试闸门、明文重试的判定、凭据条目的删除、搜索位置的串行提交。
    ///
    /// 这四样每一条背后都是一次真实故障（双击连接并行、失败后无法一键重试、
    /// 旧密码被发给新机器、连点共享后核心与界面不一致），
    /// 各自只有一处才好守住。
    func testWizardMechanicsLiveOnlyInController() throws {
        let appModel = try appModelCode()
        for marker in ["ConnectionAttemptGate", "PlainHTTPRetryOffer",
                       "SecureStorage.delete", "scopeSelectionSequence"] {
            XCTAssertFalse(appModel.contains(marker),
                           "\(marker) 应只出现在 NASSourceWizardController 里")
        }

        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        for marker in ["ConnectionAttemptGate", "PlainHTTPRetryOffer",
                       "SecureStorage.delete", "scopeSelectionSequence"] {
            XCTAssertTrue(controller.contains(marker))
        }
    }

    /// ★ 已登录的 Provider 只能交给连接管理器，不能写界面字典（R02）。
    ///
    /// 界面读的是 `nativeProviders[id]?.ready`。谁要是把「登录好的实例」
    /// 直接写进这个字典，下一次 rebuild 就会被管理器那个从未登录的实例盖掉，
    /// 表现为「核心里登录成功、设置页显示未连接」——报上来的正是这个。
    ///
    /// 注意这里断言的是**赋值动作**而不是变量名：`nativeProviders[id]?`
    /// 这种读法在本文件里是合法的（界面要读 ready），不能一刀切禁掉。
    func testLoggedInProviderIsInstalledNotAssigned() throws {
        let appModel = try appModelCode()
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        // ★ 必须排除 `===`（同一性比较）：「等待收尾期间这台实例有没有被换掉」
        //   正是靠 `nativeProviders[sourceID] === live` 判的，它是读不是写。
        //   只写 `=` 的话 `===` 会被当成赋值，把一次合法读取误报成违规。
        let assignment = try NSRegularExpression(pattern: #"nativeProviders\[[^\]]*\]\s*=(?!=)"#)
        for (name, code) in [("AppModel", appModel), ("NASSourceWizardController", controller)] {
            let hits = assignment.numberOfMatches(in: code, range: NSRange(code.startIndex..., in: code))
            XCTAssertEqual(hits, 0,
                           "\(name) 不该直接给 nativeProviders 赋值；已登录实例要走 NASConnectionManager.install")
        }
        XCTAssertTrue(appModel.contains("nasConnectionManager.install("),
                      "静默自动连接必须把已登录实例交给管理器")
        XCTAssertTrue(controller.contains("installProvider("),
                      "向导保存后必须把已登录实例交给管理器")
    }

    /// ★ 来源配置的落盘位置必须**构造注入**，不能是可选闭包。
    ///
    /// 第一版写成 `var preferences: (any ClientPreferences)?`，漏装配也能编译通过，
    /// 后果是来源配置永远写不进磁盘——界面上看不出任何异常，
    /// 只有重启应用才发现刚添加的 NAS 不见了。
    func testWizardPreferencesIsInjectedAtConstruction() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("NASSourceWizardController(preferences:"),
                      "构造 wizard 时必须把 preferences 传进去")
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertTrue(controller.contains("init(preferences:"))
        XCTAssertFalse(controller.contains("var preferences"),
                       "可选闭包漏装配也能编译过；必须用构造注入让编译器强制")
    }

    /// 来源配置的落盘 key 只有一处定义。
    ///
    /// 两处各写一份字面量的话，改了一边就会「存进去却读不出来」。
    func testSourcesStorageKeyHasSingleDefinition() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("ff2.nasSources.v1"),
                       "落盘 key 应只在 NASSourceWizardController.sourcesStorageKey 里写一次")
    }

    /// 本机搜索的说明文案只有一个来源（Core 的 `LocalSearchText`）。
    ///
    /// 在 AppModel 里再写一遍字面量，就会出现「改了 Core、界面还是旧话」，
    /// 而这种不一致从代码上看不出谁对谁错。
    func testNoLocalSearchWordingInAppModel() throws {
        let appModel = try appModelCode()
        for phrase in ["不会自动扫描全盘", "仅搜索已明确选择的", "UI 样例：系统 Spotlight 已关闭"] {
            XCTAssertFalse(appModel.contains(phrase),
                           "本机搜索文案应只在 Core 的 LocalSearchText 里写一次：\(phrase)")
        }
    }

    // MARK: - R01：NAS 总开关

    /// ★ 总开关的初始值判定归 Core，AppModel 不许再用「`?? bool(forKey:)`」那套回落。
    ///
    /// `bool(forKey:)` 对**不存在**的 key 返回 false，于是全新安装时总开关被初始化成关闭：
    /// 用户连好了 NAS，搜索却一次都不请求 —— 而设置页里那个开关点了也没用。
    func testMasterSwitchInitialValueComesFromCore() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("NASMasterSwitch.resolve("),
                      "总开关初始值应由 Core 的 NASMasterSwitch 判定（空偏好必须默认开启）")
        XCTAssertFalse(appModel.contains("?? defaults.bool(forKey:"),
                      "对不存在的 key 用 bool(forKey:) 会得到 false，把新装用户的总开关关掉")
    }

    /// ★ NAS 总开关从「搜索」页去掉了，但**不能让用户卡在关闭状态**。
    ///
    /// 「搜索」页与「搜索来源」页各放一个总开关是重复入口，必须去重。
    /// 去重之后要保证两件事：写回模型的绑定是真的（`.constant` 那套点了不改模型，
    /// 正是 R01 的成因）；以及总开关关着（= 异常状态）时，来源页给出一个能打开它的入口。
    func testMasterSwitchIsOnlySurfacedWhenOffAndIsTwoWayBound() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("isOn: .constant(model.enabled)"),
                       "总开关不许用 constant 绑定，点了不改模型")
        XCTAssertTrue(settings.contains("model.enabled = true; model.toggleNetwork()"),
                      "异常状态下的「打开 NAS 搜索」必须真写回模型并落盘")
        XCTAssertTrue(settings.contains("if !model.enabled && !model.nasSources.isEmpty"),
                      "总开关入口必须只在关着且有来源时才出现——正常状态不出现操作")
    }

    /// 保存来源成功后要顺手把总开关打开（否则「已连接却搜不到」）。
    func testSavingSourceEnablesMasterSwitch() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertTrue(wizard.contains("ensureNASSearchEnabled()"),
                      "向导保存成功后应确保 NAS 总开关是开的")
        let appModel = try appModelCode()
        // ★ 自动打开只能发生在「用户从未设置过」时，不许反过来替用户打开。
        XCTAssertTrue(appModel.contains("!masterSwitchIsExplicit"),
                      "用户显式关掉总开关的场景必须原样保留，不能被自动打开")
    }

    /// ★ 断开之后「重新连接」必须仍然**点得到**（两次报障换来的结论）。
    ///
    /// 这一轮把「断开 / 重新连接 / 管理… / 刷新状态 / 详细信息」从来源行上撤掉了
    /// （那些是 NAS 管理器的操作）。但「断开之后连得回来」这条**能力**不许跟着丢：
    ///   · 列表行只在出问题时给出 Core 判定出的那**一个**按钮（离线 → 「重试」）；
    ///   · 详情页保留「重新登录…」，走 `reconnectSource` 统一路由。
    /// 判定本身在 Core 的 `NASSourceRowModel`，视图只负责把结果画出来。
    func testReconnectStaysReachableWithoutLifecycleButtonsOnTheListRow() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.runSourceAction(source.id, action)"),
                      "行上的按钮必须走 Core 判定出的动作分派")
        XCTAssertTrue(settings.contains("if let action = row.action"),
                      "正常行不许出现按钮：只有 action 非空时才画")
        XCTAssertTrue(settings.contains("Button(\"重新登录…\") { model.reconnectSource(source.id) }"),
                      "详情页必须保留重连入口，且走 reconnectSource 统一判定")
        // 行上的那些生命周期按钮不该回来。
        for removed in ["Button(\"断开\")", "Button(\"重新连接\")", "FFSecondaryButton(\"管理…\")", "Button(\"刷新状态\")"] {
            XCTAssertFalse(settings.contains(removed),
                           "来源行上的生命周期按钮 \(removed) 已按 UI 简化撤下")
        }
    }

    /// ★ 断开的异步收尾完成后必须**主动重发一次** Provider 表。
    ///
    /// `ready` 在 Provider 实例内部翻转，字典的 `@Published` 感知不到；
    /// 不重发的话卡片要等下一次别的状态变化才刷新——表现就是按钮滞后。
    func testDisconnectRepublishesProvidersAfterAsyncTeardown() throws {
        let appModel = try appModelCode()
        let region = appModel.range(of: "func disconnectSource(_ id: String)")
        XCTAssertNotNil(region, "disconnectSource 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])
        XCTAssertTrue(body.contains("await self?.nasConnectionManager.disconnectOne(id)"),
                      "断开要经 NASConnectionManager.disconnectOne（单来源入口）")
        XCTAssertTrue(body.contains("self.nativeProviders = self.nativeProviders"),
                      "异步收尾后必须重发 Provider 表，否则界面停留在旧渲染")
    }

    /// ★ OTP 失败时，「重新登录…」必须弹出输入框，再把码传进登录流程。
    ///
    /// 自动重连用的密码是本机凭据文件里那把，而 OTP 是一次性的、不该保存。
    /// 如果重新登录不弹 OTP 框，用户会陷入「点一百次重新登录都失败」的死路。
    func testReconnectPromptsForOTPWhenStatusNeedsOTP() throws {
        let appModel = try appModelCode()
        let region = appModel.range(of: "func reconnectSource(_ id: String)")
        XCTAssertNotNil(region, "reconnectSource 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("sourceStatus(id).needsOTP"),
                      "reconnectSource 必须先查 needsOTP 标记")
        XCTAssertTrue(body.contains("promptForOTP(sourceName:"),
                      "需要 OTP 时必须弹输入框")
        XCTAssertTrue(body.contains("reconnectUsingStoredCredential(id, otp: otp, interactiveOTP: true)"),
                      "弹框拿到的 OTP 必须传给 reconnectUsingStoredCredential")
        // ★ 2026-10-26：**不知道**要不要码时也必须允许当场弹。
        //
        // 报障原文：「第一次输入提示需要输入动态码，但是不会自动弹出动态码，
        // 需要点击两次登陆」。根因就是这条分支走的是纯静默连接，失败只写一行状态，
        // 用户非得再点一次「登录」才进到上面那段弹框逻辑。
        XCTAssertTrue(body.contains("reconnectUsingStoredCredential(id, otp: nil, interactiveOTP: true)"),
                      "用户自己点的登录必须允许当场弹 OTP 框，否则第一次点等于白点")
    }

    /// ★ OTP 弹框前必须先把应用激活到前台（点了「重新登录…」没弹窗）。
    ///
    /// 闪寻是**不进程序坞**的辅助型应用（`accessory`）。这类应用里，
    /// `NSAlert.runModal()` 创建的窗口不会自动抢到前台：窗口建出来了，
    /// 但压在设置窗口底下或不激活，用户看到的就是「点了一下什么都没发生」。
    /// 设置页自己开向导时是 `NSApp.activate(ignoringOtherApps: true)` + show，
    /// 弹 OTP 框走的是同一条规则，不能例外。
    func testOTPPromptActivatesAppBeforeRunModal() throws {
        let appModel = try appModelCode()
        let region = appModel.range(of: "func promptForOTP(sourceName: String,")
        XCTAssertNotNil(region, "promptForOTP 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])
        XCTAssertTrue(body.contains("NSApp.activate(ignoringOtherApps: true)"),
                      "弹 OTP 框前必须激活应用，否则辅助型应用下窗口不前置")
        // 激活必须发生在 runModal 之前：之后才激活的话 modal loop 已经跑起来了。
        guard let activate = body.range(of: "NSApp.activate(ignoringOtherApps: true)"),
              let modal = body.range(of: "alert.runModal()") else {
            XCTFail("promptForOTP 必须同时有 activate 与 runModal")
            return
        }
        XCTAssertTrue(activate.lowerBound < modal.lowerBound,
                      "激活要写在 runModal 之前")
    }

    /// ★ 向导里「设备要动态码」必须走同一扇弹窗，且拿到码之后自己接着连。
    ///
    /// 2026-10-22 用户要求「全部改成登录时弹 OTP 弹窗的形式」。
    /// 向导以前是把折叠区展开让用户回表单再点一次「连接」——多一步不说，
    /// 用户还会以为刚才那次连接已经作废。现在与详情页「重新登录…」
    /// 共用 `otpPrompter`（同一扇窗、同一套文案），拿到码直接 `connectDraft()`。
    ///
    /// ★ 弹窗必须放在**独立 Task** 里：失败收尾是 `performConnect` 的最后一步，
    /// 模态弹窗就地弹会把本次尝试的收尾（按钮解锁、`draftBusy` 复位）卡在半路。
    func testWizardPromptsForOTPAndContinuesOnItsOwn() throws {
        let controller = try appSource("NASSourceWizardController.swift")
        let region = controller.range(of: "private func promptForOTPThenReconnect(sourceName: String,")
        XCTAssertNotNil(region, "向导必须有「弹窗问码 → 自动续连」这条路径")
        let tail = String(controller[region!.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("Task {"), "弹窗必须在独立 Task 里，别卡住本次尝试的收尾")
        XCTAssertTrue(body.contains("otpPrompter?("),
                      "必须走注入的那扇弹窗，向导自己再造一个就会走出两套文案")
        XCTAssertTrue(body.contains("self.nativeNASOTP = code"),
                      "拿到的码要落进模型，否则 connectDraft 读不到")
        XCTAssertTrue(body.contains("connectDraft()"),
                      "拿到码必须自动接着连，不能让用户回表单再点一次「连接」")
        XCTAssertTrue(body.contains("otpRetryHint"),
                      "用户点取消时，状态行要补上「下一次怎么把它叫回来」")
    }

    /// ★ 失败收尾必须真的去叫那扇弹窗 —— 判定走 Core，不能自己拼字符串。
    ///
    /// ★ 断言必须锁到**调用点**（`sourceName: config.displayName`）：
    /// 截断点 `\n    func ` 吞不下下一行 `    private func promptForOTPThenReconnect…`
    /// 的定义，body 会一直延伸到那扇弹窗的**定义体**里去。只断言
    /// `promptForOTPThenReconnect(sourceName:` 的话，**定义行本身就把它满足了**——
    /// 调用点删没删测试都绿（2026-10-22 批跑 MISS 实测，靠单条变异复现定位）。
    func testWizardFailurePromptsWhenTheDeviceNeedsOTP() throws {
        let controller = try appSource("NASSourceWizardController.swift")
        let region = controller.range(of: "private func finishFailedAttempt(")
        XCTAssertNotNil(region, "finishFailedAttempt 必须存在")
        let tail = String(controller[region!.lowerBound...])
        let end = tail.range(of: "\n    private func promptForOTPThenReconnect")?.lowerBound
            ?? tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])
        XCTAssertTrue(body.contains("ConnectionFailureText.otpFailure(error)"),
                      "「要不要动态码、是码错还是要码」只能由 Core 判定")
        XCTAssertTrue(body.contains("promptForOTPThenReconnect(sourceName: config.displayName, failure: otp)"),
                      "判定成立就必须弹窗，并把失败类型带下去；只写一句状态就完事等于没修")
    }

    /// ★ 表单里不能再有常驻的动态码输入框。
    ///
    /// 动态码是**一次性**的，不属于「这台 NAS 的配置」。摆在表单里，
    /// 用户会先去填它，而多数账号根本用不到——那正是改弹窗式的原因。
    func testTheWizardFormHasNoInlineOTPField() throws {
        let view = try appSource("NASSourceWizardView.swift")
        let code = codeOnly(view)
        XCTAssertFalse(code.contains("nas-otp"), "表单里不该再有动态码输入框")
        XCTAssertFalse(code.contains("nativeNASOTP"), "表单不该再绑定动态码字段")
        XCTAssertFalse(code.contains("DisclosureGroup"), "动态码不再用折叠区承载")
    }

    /// ★ 「重新登录…」在本机没有保存密码时必须真的打开向导窗口。
    ///
    /// `openReconnectWizard` 早先只做 `editSource(id)` + 写一句状态文案，
    /// **没有** `NASWizardWindow.shared.show` —— 于是用户点「重新登录…」
    /// 之后界面毫无反应：向导草稿准备好了，窗口却从没被要求显示。
    /// 对照同一文件里 `.continueSetup` 分支与设置页的 `openWizard()`，
    /// 两处都是「激活 + show」成对出现，重连这条不能少。
    func testOpenReconnectWizardShowsWizardWindow() throws {
        let appModel = try appModelCode()
        let region = appModel.range(of: "func openReconnectWizard(_ id: String, reason: String)")
        XCTAssertNotNil(region, "openReconnectWizard 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])
        XCTAssertTrue(body.contains("NASWizardWindow.shared.show(model: self)"),
                      "重连向导必须真的显示窗口，只改草稿状态用户看不到任何反馈")
        XCTAssertTrue(body.contains("NSApp.activate(ignoringOtherApps: true)"),
                      "显示向导前同样要先激活应用")
    }

    /// ★ 静默连接失败时，只有「设备要求 OTP」这类失败才标记 needsOTP。
    ///
    /// 判定必须走 Core 的 `ConnectionFailureText.isOTPRequired`，
    /// 不能自己在 AppModel 里写字符串 contains("NeedsOTP")——那会让「同 kind 两种说法」
    /// 的契约慢慢烂掉。
    func testQuietConnectMarksNeedsOTPThroughCore() throws {
        let appModel = try appModelCode()
        let region = appModel.range(of: "func performConnectQuietly(config: NASSourceConfig, credential: PendingCredential,")
        XCTAssertNotNil(region, "performConnectQuietly 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    private func retryWithOTPUntilAnswered")?.lowerBound
            ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("ConnectionFailureText.otpFailure(error)"),
                      "OTP 判定必须走 Core 的 ConnectionFailureText.otpFailure")
        XCTAssertTrue(body.contains("$0.needsOTP = otp != nil"),
                      "catch 块里必须回写 needsOTP 标记")
        XCTAssertTrue(body.contains("$0.requiredAction = otp == nil ? .retry : .login"),
                      "OTP 失败时列表行必须给「登录」按钮而不是「重试」——重试还是不带 OTP")
    }

    /// ★ 连接成功后必须把 needsOTP 标记清掉。
    ///
    /// 不清的话，用户下次点「重新登录…」还会被问 OTP，即使这次会话已经成功。
    func testSuccessfulConnectClearsNeedsOTP() throws {
        let appModel = try appModelCode()
        // ★★ 必须切到「成功分支」的花括号块里断言，不能扫 install 之后的整段文本。
        //
        // 的教训（红证实锤）：全量变异是**一起**应用的。
        // 失败路径的变异会把 `$0.needsOTP = needsOTP` 改写成一个
        // `$0.needsOTP = false` 字面量，正好落在「install 之后」这个宽区间里，
        // 于是成功分支的 `= false → = true` 被它顶替 —— 断言照样通过 = **假绿**。
        // 判「这句在不在正确的分支里」，只能按括号配平切块，不能用 contains。
        XCTAssertTrue(appModel.contains("nasConnectionManager.install(provider)"),
                      "install(provider) 成功路径必须存在")
        let successBlock = try XCTUnwrap(
            braceBlock(after: "setSourceStatus(effective.id)", in: appModel),
            "成功分支的 setSourceStatus 花括号块必须存在")
        XCTAssertTrue(successBlock.contains("$0.needsOTP = false"),
                      "连接成功的 setSourceStatus 里必须清掉 needsOTP 标记")
        // 反向验证：失败分支**不能**写死 false，它必须按 kind 判定。
        //
        // ★ 这里不能再用 `braceBlock(after: "case let .failed(_, error)")`：
        // 2026-10-26 之后该分支里第一个 `{` 是 `if interactiveOTP, let otp {`，
        // 取到的是那个子块，`$0.needsOTP = otp != nil` 在它外面 ⇒ 断言恒红/恒绿都不可信。
        // 改为切到「失败分支起点 → 下一个函数定义」这段。
        let driverStart = try XCTUnwrap(appModel.range(of: "case let .failed(_, error)"))
        let driverTail = String(appModel[driverStart.lowerBound...])
        let driverEnd = driverTail.range(of: "\n    private func retryWithOTPUntilAnswered")?.lowerBound
            ?? driverTail.endIndex
        let driver = String(driverTail[driverTail.startIndex..<driverEnd])
        XCTAssertTrue(driver.contains("$0.needsOTP = otp != nil"),
                      "失败分支的 needsOTP 必须来自 Core 的 otpFailure 判定结果")
    }

    /// ★ 用户自己点「登录」时，设备要码必须**当场**弹框，不能等他再点一次。
    ///
    /// 2026-10-26 报障原文：「第一次输入提示需要输入动态码，但是不会自动弹出动态码，
    /// 需要点击两次登陆，很反人类」。
    /// 根因：第一次走纯静默路径，失败只写一行「自动连接失败：设备要求两步验证码」，
    /// 弹框分支只在**下一次**点击时才被走到。
    ///
    /// 修法是加一个 `interactiveOTP` 入口标志，**只**给用户手动点的那条路；
    /// 开机自动连接与批量诊断仍保持静默——那时没有人在键盘前看弹窗。
    func testUserInitiatedReconnectAsksForOTPWithinTheSameAttempt() throws {
        let appModel = try appModelCode()
        let region = try XCTUnwrap(appModel.range(
            of: "func performConnectQuietly(config: NASSourceConfig, credential: PendingCredential,"),
            "performConnectQuietly 必须存在")
        let tail = String(appModel[region.lowerBound...])
        let end = tail.range(of: "\n    private func retryWithOTPUntilAnswered")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("interactiveOTP: Bool = false"),
                      "必须能区分「用户点的登录」与「开机自动连」")
        XCTAssertTrue(body.contains("if interactiveOTP, let otp {"),
                      "用户点的登录遇到 OTP 必须当场提问，而不是留到下一次点击")
        XCTAssertTrue(body.contains("retryWithOTPUntilAnswered("),
                      "给码这条路必须进「问码 → 再连」的循环")

        // 反证：开机自动连接那条路不许弹窗（用户在睡觉，模态框会把应用冻在那）。
        let auto = try XCTUnwrap(appModel.range(of: "func autoConnectSavedSources()"))
        let autoBody = String(appModel[auto.lowerBound...])
        let autoEnd = autoBody.range(of: "\n    func performConnectQuietly")?.lowerBound ?? autoBody.endIndex
        XCTAssertFalse(String(autoBody[autoBody.startIndex..<autoEnd]).contains("interactiveOTP: true"),
                       "开机自动连接不能弹 OTP 框")
    }

    /// ★ 码填错之后必须在**同一个框里**再问，而不是退回「需要动态码」等用户再点登录。
    ///
    /// 报障原文：「输入 OTP 验证码错误，不会提示验证码错误，而是没有什么反应，
    /// 还是在外边提示需要动态码，需再次点击登陆。」
    ///
    /// 这条锁三件事：循环真的存在、码错类型真的被带回下一轮、用户取消时真的有话说。
    /// 少任一环，「码错」就会退回「再点一次登录」。
    func testOTPAttemptKeepsAskingUntilItSucceedsOrTheUserCancels() throws {
        let appModel = try appModelCode()
        let region = try XCTUnwrap(appModel.range(of: "private func retryWithOTPUntilAnswered("),
                                   "必须有「问码 → 再连」的循环")
        let tail = String(appModel[region.lowerBound...])
        let end = tail.range(of: "\n    private func askForOTP")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("while true"), "必须循环，问一次就收手等于没修")
        XCTAssertTrue(body.contains("askForOTP("), "循环里必须真的弹框")
        XCTAssertTrue(body.contains("failure = next"),
                      "码错必须把新的失败类型带回循环，否则第二轮又问成「需要动态码」")
        XCTAssertTrue(body.contains("ConnectionFailureText.otpFailure(error)"),
                      "往不往下问由 Core 判，App 层不许自己 contains 字符串")
        XCTAssertTrue(body.contains("otpRetryHint(buttonTitle: \"登录\")"),
                      "用户取消时要说清下次怎么叫回来，且按钮名必须是来源卡片上那个「登录」")
        XCTAssertTrue(body.contains("$0.needsOTP = false"),
                      "非 OTP 失败必须收手并摘掉 OTP 标记——那时再问码只是折磨用户")
    }

    /// ★ 弹框文案按「要码 / 码错」分流，且文案本身住 Core（两条登录路径共用一套）。
    ///
    /// 在调用点写三元，第二次改文案必然只改一处。
    func testOTPDialogPicksCoreWordingForRejectedCodes() throws {
        let appModel = try appModelCode()
        let region = try XCTUnwrap(appModel.range(of: "func promptForOTP(sourceName: String,"))
        let tail = String(appModel[region.lowerBound...])
        let end = tail.range(of: "\n    func ")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("ConnectionFailureText.otpDialogTitle(for: failure)"),
                      "标题必须按失败类型从 Core 取")
        XCTAssertTrue(body.contains("ConnectionFailureText.otpPromptText(sourceName: sourceName, failure: failure)"),
                      "正文必须带上失败类型，否则码错与要码说成同一句")
        XCTAssertTrue(body.contains(".warning"),
                      "码错用警告样式，视觉上与「只是要你填个码」区分开")
    }

    /// ★ 状态栏图标必须是品牌模板图，且应用不进程序坞（决策）。
    ///
    /// 两件事一起锁：
    /// 1. MenuBarExtra 标签用 `StatusIcon.menuBar`（品牌圆环+闪电单色字形），
    ///    且 NSImage 标了 `isTemplate`——这是 macOS 状态栏明暗配色的正道，
    ///    用系统符号 `magnifyingglass` 或写死颜色都不对；
    /// 2. Info.plist 带 `LSUIElement`：不占程序坞、不进 Cmd+Tab，只后台挂状态栏。
    func testMenuBarIconIsBrandTemplateAndAppIsAccessoryOnly() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(app.contains("Image(nsImage: StatusIcon.menuBar)"),
                      "状态栏标签必须用品牌模板图标，不许退回系统放大镜做主路径")
        XCTAssertTrue(app.contains("isTemplate = true"),
                      "必须标记模板图，跟随系统明暗配色（浅色黑、深色白）")
        // 兜底路径只许在素材缺失时出现（swift run 裸跑），不许反过来。
        XCTAssertTrue(app.contains("magnifyingglass"),
                      "素材缺失时要退回系统符号，状态栏不能空着")

        let pkgRoot = URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
            .deletingLastPathComponent().deletingLastPathComponent()
        let plist = try String(contentsOf: pkgRoot.appendingPathComponent("Resources/Packaging/Info.plist"),
                               encoding: .utf8)
        XCTAssertTrue(plist.contains("<key>LSUIElement</key>"),
                      "必须 LSUIElement：应用不进程序坞，只后台挂状态栏")
    }

    /// ★ 搜索框前导图标必须是同一枚品牌字形，不许退回系统放大镜。
    ///
    /// 「把闪寻前边的搜索图标换成自己的」，并指定「用状态栏那个图标，
    /// 大小符合搜索框要求」。两件事一起锁：
    /// 1. 素材要与状态栏**同源**（都走 `StatusIcon.brandGlyph`），不许各自重新画一枚；
    /// 2. 缩放必须过 Core 的 `BrandGlyphMetrics`——等比换算只有一处，
    ///    免得「状态栏改了、搜索框没跟着改」再来一次。
    ///
    /// ★ 断言切在 `HStack(spacing: 14)` 的花括号块里：整份文件 `contains` 会被
    /// 别处的同名调用满足（本项目在 build 12 / build 13 已经栽过两次）。
    func testSearchFieldShowsBrandGlyphNotSystemMagnifier() throws {
        let field = codeOnly(try appSource("SearchFieldView.swift"))
        XCTAssertFalse(field.contains("Image(systemName: \"magnifyingglass\")"),
                       "搜索框前导图标不许再用系统放大镜，要用自家图标")

        guard let row = braceBlock(after: "HStack(spacing: 14)", in: field) else {
            return XCTFail("搜索框的行容器 HStack(spacing: 14) 必须存在")
        }
        XCTAssertTrue(row.contains("StatusIcon.searchFieldGlyph()"),
                      "前导图标必须取品牌字形：\(row)")
        XCTAssertTrue(row.contains("foregroundStyle(.secondary)"),
                      "品牌字形要压到系统搜索框同档灰度，不许用原色黑")
        XCTAssertTrue(row.contains("accessibilityHidden(true)"),
                      "装饰性图标对读屏隐藏， TextField 自己有 label")

        // 换算只允许存在一处（Core），App 层不许自己算 NSSize。
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(app.contains("BrandGlyphMetrics.fittedSize"),
                      "缩放必须走 Core 的 BrandGlyphMetrics，不许在 App 层手写尺寸")
        // 注意这两个调用点都是**跨行**的，别用一整串.contains 去锁。
        XCTAssertTrue(app.contains("glyph(named: \"ShanXunGlyph\""),
                      "搜索框必须取 22pt 专用那一套素材")
        XCTAssertTrue(app.contains("BrandGlyphMetrics.searchFieldHeight"),
                      "搜索框高度必须由 Core 的常量给出")
        XCTAssertTrue(app.contains("glyph(named: \"ShanXunMenuIcon\""),
                      "状态栏必须仍取状态栏那一套素材")
        XCTAssertTrue(app.contains("BrandGlyphMetrics.menuBarHeight"),
                      "状态栏高度必须由 Core 的常量给出")
        XCTAssertTrue(app.contains("private static func glyph(named name: String, height: CGFloat) -> NSImage"),
                      "两处必须共用同一条换算路径，不许各自写一份")
        // 仍要留一条「素材缺失」的兜底：swift run 裸跑时 Bundle 里没有资源。
        XCTAssertTrue(app.contains("systemSymbolName: \"magnifyingglass\""),
                      "素材缺失时要有系统符号兜底，图标位不能空着")
    }

    /// ★ 搜索框那套素材必须**真的进包**。
    ///
    /// `StatusIcon.searchFieldGlyph()` 从 Bundle 里读 `ShanXunGlyph*.png`；
    /// 打包脚本漏拷 → 运行时静默退回系统放大镜，也就是「换图标」没生效，
    /// 而编译能过、测试也绿（它在 swift run 下本来就走兜底）。
    /// 素材文件与打包清单在这里一起锁。
    func testSearchGlyphAssetsExistAndArePackaged() throws {
        let pkgRoot = URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
            .deletingLastPathComponent().deletingLastPathComponent()
        let brand = pkgRoot.appendingPathComponent("Resources/Brand")
        for name in ["ShanXunGlyph.png", "ShanXunGlyph@2x.png"] {
            XCTAssertTrue(FileManager.default.fileExists(atPath: brand.appendingPathComponent(name).path),
                          "缺少 22pt 专用素材 \(name)：跑了 tools/make-menubar-icon.swift 才有")
        }

        let script = try String(contentsOf: pkgRoot.appendingPathComponent("scripts/build_trial.py"),
                                encoding: .utf8)
        let declaration = script.split(separator: "\n").first { $0.contains("SEARCH_GLYPH_NAMES") }
        XCTAssertNotNil(declaration, "打包脚本必须有 22pt 素材的单一名单")
        for name in ["ShanXunGlyph.png", "ShanXunGlyph@2x.png"] {
            XCTAssertTrue(declaration?.contains("'\(name)'") == true,
                          "名单里漏了 \(name)")
        }
        // 名单必须真的被用起来：哈希追踪一处 + 进包拷贝一处，两处都要有。
        // 只在一处出现（比如只有 inputs 里那个字面量）说明拷贝步骤被漏了。
        let uses = script.split(separator: "\n").filter { $0.contains("SEARCH_GLYPH_NAMES") }
        XCTAssertGreaterThanOrEqual(uses.count, 3,
                                    "名单必须同时用于声明、inputs 追踪与进包拷贝，现在只有 \(uses.count) 处")
    }

    /// ★ 「重新搜索」按钮必须是一个**真接上了线**的按钮。
    ///
    /// 某台 NAS 偶发「设备返回的分页数据不完整
    /// （错误类型 IncompleteResponse）」，而他自己发现「第二次搜索可能会解决」。
    /// 所以要有一个一键重来的入口——但要防的正是本项目最典型的假状态：
    /// **只有定义、没有调用点**（按钮画在那儿，点了什么都不发生）。
    ///
    /// 断言全部切到 `HStack(spacing: 14)` 花括号块内：那个块里同时住着
    /// 品牌字形、清除按钮和更多菜单，整函数 `contains` 会被别的控件满足。
    func testSearchFieldResearchButtonIsWiredForReal() throws {
        let field = codeOnly(try appSource("SearchFieldView.swift"))
        guard let row = braceBlock(after: "HStack(spacing: 14)", in: field) else {
            return XCTFail("搜索框的行容器 HStack(spacing: 14) 必须存在")
        }
        XCTAssertTrue(row.contains("Button(action: research)"),
                      "重新搜索必须是个真按钮，且动作接到注入的 research：\(row)")
        XCTAssertTrue(row.contains("Image(systemName: \"arrow.clockwise\")"),
                      "重新搜索要用可识别的重试图标（arrow.clockwise）")
        XCTAssertTrue(row.contains(".disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)"),
                      "关键词只有空白时重搜没有意义，必须置灰——不能给点了没反应的按钮")
        XCTAssertTrue(row.contains(".help(\"重新搜索\")"),
                      "按钮名字要能悬停看到（图标按钮没有文字）")
        XCTAssertTrue(row.contains(".accessibilityLabel(\"重新搜索\")"),
                      "按钮名字要能被读屏拿到")

        // 依赖由外部注入：视图不许自己去抓 AppModel（App 层不可测的根因之一）。
        XCTAssertTrue(field.contains("let research: () -> Void"),
                      "research 必须是注入的闭包属性")

        // ★ 调用点：SearchView 必须真的把它接到「重跑当前关键词」。
        // 接到别的（比如只清结果、只刷新状态）都会让按钮名不副实。
        let view = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(view.contains("research: model.changedQuery"),
                      "SearchView 必须把 research 接到 model.changedQuery，否则按钮不会重跑当前关键词")
    }

    /// ★ 第 1 步是三个入口：群晖 / OpenList / 附近的设备。
    ///
    /// 前两块决定**走哪套接口**（品牌一换，表单、默认协议、端口全跟着换），
    /// 后一块是一次动作：打开小窗挑一台设备。可选集合仍由 Core 的
    /// `ExperimentalSources` 决定，视图里不许写死品牌。
    ///
    /// 连接成功之后就撤掉这三块：那时再让用户点品牌，只会误触
    /// （换品牌会清空已填的地址与账号）。
    func testTypeStepShowsBrandAndNearbyEntriesFromTheModel() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("model.selectableVendors"),
                      "可选类型必须来自模型（Core 的 ExperimentalSources），不能写死在视图里")
        XCTAssertTrue(wizard.contains("private var typeEntrySection"),
                      "第 1 步要有一块专门放这三个入口")
        // 当前品牌不在可选列表里时要补一块：从「附近的设备」选中一台实验性品牌
        // （局域网里有台威联通、而实验开关关着）之后，界面必须能显示现在选的是谁。
        XCTAssertTrue(wizard.contains("private var entryVendors"),
                      "入口列表要能补上当前品牌")
        XCTAssertTrue(wizard.contains("list + [model.draftSource.vendor]"),
                      "补的必须是**当前**这一个品牌，不是别的")
        XCTAssertTrue(wizard.contains("private var nearbyEntry"),
                      "「附近的设备」要和品牌块并排成一个入口")
        XCTAssertTrue(wizard.contains("\"nearby-open\""),
                      "附近的设备入口要有标识，界面自动化要点它")
        XCTAssertTrue(wizard.contains("if !model.draftConnected, !isEditing"),
                      "入口只在还没连上、也不是编辑已有来源时出现")
        XCTAssertFalse(wizard.contains("Vendor.allCases"),
                       "选类型不该再直接铺全部品牌")
        XCTAssertFalse(wizard.contains("supportBadge"),
                       "选项上不该再挂「已验证 / 已接入 · 未验证」这类状态标签")
    }

    /// ★ 连接信息下面不再挂「去浏览器看地址栏」这类说明。
    ///
    /// 原来这里按品牌取一句页脚，群晖那份写的是「常见端口 5001」——
    /// OpenList 的用户填完站点地址，下方还在提示他去看群晖的 5001。
    /// 现在整句删掉：端口就填在上面那个框里，不需要一段文字指路。
    /// Core 里的品牌文案仍保留（`VendorConnectionFooterTests` 守着它别写错），
    /// 但界面不再渲染。
    func testConnectionSectionShowsNoExplanatoryFooter() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertFalse(wizard.contains("connectionFooter"),
                       "连接信息不再有页脚说明")
        XCTAssertFalse(wizard.contains("群晖常见端口是 5001"),
                       "视图里不该写死群晖端口")
        // 同理：品牌说明也不再作为单独一段摆在页面上。
        XCTAssertFalse(wizard.contains("serviceHint"),
                       "品牌说明不再占页面位置")
    }

    /// ★ 界面里不再写「解释性备注」。
    ///
    /// 用户 2026-10-24 的要求：只留控件与结果，不要每个开关下面再挂一段话
    /// 解释它是干什么的。这些句子一条条删掉之后，靠这条守住——
    /// 否则下一次「顺手补个说明」就全回来了。
    ///
    /// ★ 注意这里守的是**说明**，不是**反馈**：连接失败的原因、字段格式错误、
    /// 管理员账号的越权警告这一类别删（它们回答的是「刚才发生了什么」，
    /// 不解释就有用户点不到东西）。
    func testSettingsPanesCarryNoExplanatoryFooters() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        for phrase in [
            "再次按下快捷键可隐藏搜索窗口",
            "搜索桌面、文档这类受保护的位置需要「完全磁盘访问」",
            "关掉后 AI 立刻失去连接",
            "AI 只能看到你在这里勾选的来源",
            "这一行说的是闪寻这一侧在不在等待连接",
            "历史只记在本机",
            "诊断会刷新所有来源的状态",
            "打开后，「添加搜索来源」里会一并出现",
            "从 GitHub 的发布页读取最新版本号后比对",
        ] {
            XCTAssertFalse(settings.contains(phrase),
                           "设置页又出现了说明性备注：\(phrase)")
        }

        for pane in ["private var generalForm: some View",
                     "private var advancedForm: some View"] {
            let body = braceBlock(after: pane, in: settings) ?? ""
            XCTAssertFalse(body.contains("sectionFooter"),
                           "\(pane) 里不该再有页脚说明")
        }
    }

    /// ★ 向导里也不再有说明性备注，但**连接失败的原因必须保留**。
    func testWizardCarriesNoExplanatoryHintsButKeepsFailureText() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        for phrase in [
            "填 DSM 的地址与端口",
            "群晖常见端口是 5001",
            "在浏览器打开 NAS 管理页面",
            "密码存到本机凭据文件",
            "还没连上或还没选搜索位置",
            "搜索结果里会标成",
        ] {
            XCTAssertFalse(wizard.contains(phrase),
                           "向导里又出现了说明性备注：\(phrase)")
        }

        // 失败/状态那一块不能删：它是连不上时界面上唯一的反馈。
        XCTAssertTrue(wizard.contains("statusSection"),
                      "连接结果那一块被删了就没任何反馈")
        XCTAssertTrue(wizard.contains("model.draftStatus"),
                      "状态文案仍要显示出来")

        // 两个字段标签按界面要求改了名。
        XCTAssertTrue(wizard.contains("\"IP/域名\""), "地址栏的标签应为「IP/域名」")
        XCTAssertTrue(wizard.contains("\"记住密码\""), "勾选框应为「记住密码」")
    }

    /// 方向键选择后能预览，状态栏应重新展示 Space 提示。
    func testStatusBarIncludesSpacePreview() throws {
        let stateView = codeOnly(try appSource("SearchStateView.swift"))
        for kept in ["↑↓ 选择", "Space 预览", "↵ 打开", "⌘↵ Finder", "esc 隐藏"] {
            XCTAssertTrue(stateView.contains(kept), "状态栏缺少键位提示：\(kept)")
        }
    }

    func testEmptyStateDoesNotSayNASOnly() throws {
        let view = codeOnly(try appSource("SearchView.swift"))
        XCTAssertFalse(view.contains("确认 NAS 的搜索位置"),
                       "空状态提示不该把搜索位置说成只有 NAS 才需要确认")
        XCTAssertTrue(view.contains("试试更短的关键词"),
                      "空状态提示要保留「换短关键词」这条可操作建议")
    }

    /// ★ 协议选择**不许再做成开关**。
    ///
    /// 原来那是个反向开关：绑「是否用明文 HTTP」，而标签在关着时写
    /// 「使用加密连接 HTTPS」。用户把「勾上」读成「启用加密」，
    /// 实际勾上却切到了明文——而界面看上去一切正常。
    ///
    /// 开关天生是「功能开着/关着」，协议是二选一、两边都是有效状态。
    /// 现在必须是两段并列的选择器：两个选项都写在脸上，当前生效的被选中。
    func testProtocolChoiceIsASegmentedPickerNotAReversedToggle() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))

        XCTAssertTrue(wizard.contains("protocolChoiceBinding"),
                      "协议选择要用绑定，不能直接把布尔值塞进开关")
        XCTAssertTrue(wizard.contains("Picker(\"协议\""),
                      "协议要用两段并列的选择器")
        XCTAssertTrue(wizard.contains(".pickerStyle(.segmented)"),
                      "两个协议要并排显示，不是竖排单选")
        XCTAssertTrue(wizard.contains("NASProtocolChoice.allCases"),
                      "选项必须来自 Core 的枚举，不能在视图里写死两个标题")

        // ★ 反向开关的三个特征，一个都不许再出现。
        XCTAssertFalse(wizard.contains("Toggle(isOn: Binding(get: { model.draftUsesPlainHTTP"),
                       "协议选择不许再做成 Toggle：那个开关的方向与文案相反")
        XCTAssertFalse(wizard.contains("使用加密连接 HTTPS"),
                       "旧的反向标签不许回来")
        XCTAssertFalse(wizard.contains("使用明文 HTTP（不加密）"),
                       "旧的反向标签不许回来")
        XCTAssertFalse(wizard.contains("nas-plain-http"),
                       "旧控件的 accessibilityIdentifier 要一起换掉，别留下指向旧语义的入口")
    }

    /// ★ 绑定的**方向**必须对：界面选的是协议，模型存的是「是否明文」。
    ///
    /// 这两者的方向是相反的，写反了就是「选加密反而变明文」。
    /// 那种错在界面上完全看不出来（两段都点得动），只能靠这条断言守。
    func testProtocolBindingMapsProtocolToPlainHTTPWithoutFlipping() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("NASProtocolChoice(usesPlainHTTP: model.draftUsesPlainHTTP)"),
                      "读取方向：是否明文 → 协议")
        XCTAssertTrue(wizard.contains("model.setDraftPlainHTTP($0.usesPlainHTTP)"),
                      "写入方向：协议 → 是否明文")
        XCTAssertFalse(wizard.contains("model.setDraftPlainHTTP(!$0.usesPlainHTTP)"),
                       "写入方向不许再取反：取反就是「选加密变明文」")
    }

    /// ★ 「重新连接」到底要不要输密码，只由 Core 的判定说了算。
    ///
    /// 之前向导里写死了一句「请输入密码以重新连接」：本机凭据文件里存着密码也这么说，
    /// 用户只能再输一遍，而事后无法从界面上看出**为什么**要输。
    func testReconnectAsksForPasswordOnlyWhenThereIsNoStoredOne() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("ReconnectEntryState.route(rememberPassword:"),
                      "路由必须看「配置里勾了记住」与「本机真有密码」两件事")
        // ★ 这条锁的是「**不问密码**」，不是「不弹任何东西」。
        // 2026-10-26 起这条调用多了 `interactiveOTP: true`：设备要动态码时
        // 得当场弹框（动态码是另一件事，且本机永远不可能存它）。
        XCTAssertTrue(appModel.contains("reconnectUsingStoredCredential(id, otp: nil, interactiveOTP: true)"),
                      "有已保存密码时不该再问密码，直接用它连")

        let wizard = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertFalse(wizard.contains("请输入密码以重新连接"),
                       "不许再写死「请输入密码」：那句话在「本机有密码」时是错的")
        XCTAssertTrue(wizard.contains("func openReconnectWizard(_ id: String, reason: String)"),
                      "向导应当接收由判定得出的原因，而不是自己编一句")
    }

    /// ★ 保存密码失败**不许**再用 `try?` 吞掉。
    ///
    /// 吞掉的后果只有一个：文件里没有这把密码，而界面一路显示「已记住」，
    /// 于是用户看到的永远是「它又忘了」，也无从判断是没存上还是被清了。
    func testCredentialSaveFailureIsNotSwallowedInWizard() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertFalse(wizard.contains("try? await Task.detached"),
                       "保存凭据失败必须说出来，不能 try? 吞掉")
        XCTAssertTrue(wizard.contains("credentialSaveFailed"),
                      "保存失败要走一条能给用户看的路径")
    }

    /// ★ 每一次真实凭据变更都要带原因，且挂上审计出口。
    ///
    /// 真机上出现过凭据文件被清成空表而**无法判断是谁清的**：
    /// 三处删除入口留下的文件一模一样。审计记的是「哪一步动的」，不是密码。
    func testCredentialMutationsAreAudited() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("CredentialStore.onMutation"),
                      "App 层必须接上凭据变更审计，否则下次再被清空仍然查不出是谁")
        XCTAssertTrue(appModel.contains("\"credentialMutation\""),
                      "审计行要有自己的事件名，便于在诊断文件里筛")
        // 诊断文件不许出现密码：审计行只带四项（操作/来源/剩余条数/原因）。
        XCTAssertFalse(appModel.contains("\"password\": mutation"),
                       "审计行里不许放密码字段")

        // 三处删除策略：记住开关关闭、来源被移除、地址或账号改动后旧密码失效。
        // 前两处现已落到 Core（见 CredentialStore.applyRememberPassword / removeSource），
        // 计数按**策略点**算而不是按命名空间——搬走不代表这条要求放宽。
        let wizard = codeOnly(try appSource("NASSourceWizardController.swift"))
        let entryPoints = ["SecureStorage.delete(account:",
                           "CredentialStore.applyRememberPassword(",
                           "CredentialStore.removeSource("]
        let deletions = wizard.split(separator: "\n").filter { line in
            entryPoints.contains { line.contains($0) }
        }
        XCTAssertEqual(deletions.count, 3, "删除入口就是三处，实际：\(deletions.count)")
        // App 层这一处仍然要自己写原因；另两处的原因由 Core 统一带（有单独的测试守着）。
        for line in deletions where line.contains("SecureStorage.delete(account:") {
            XCTAssertTrue(line.contains("reason:"),
                          "每一处删除都必须带上原因，否则审计分不清是谁动的：\(line)")
        }
    }

    // MARK: - UI 简化

    /// ★ 设置界面走系统原生的分组表单，一级导航只由 Core 的三页驱动。
    ///
    /// 每段自绘的大圆角白卡（`FFSettingsSection`）行高接近 100pt，
    /// 整体像 NAS 管理器。改用 `Form` + `.formStyle(.grouped)`：行高、分隔线、
    /// 背景材质都由系统给，天然贴近 macOS。
    func testSettingsUsesNativeGroupedFormAndThreePanes() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains(".formStyle(.grouped)"),
                      "设置页必须用系统分组表单，别再自绘卡片")
        XCTAssertTrue(settings.contains("SettingsPane.allCases"),
                      "一级导航的页面集合必须来自 Core 的 SettingsPane")
        XCTAssertFalse(settings.contains("FFSettingsSection"),
                       "设置页不该再用自绘卡片段落")
        XCTAssertFalse(settings.contains("NASSourceCard"),
                       "每台 NAS 一张大卡片的写法已撤下")
    }

    /// ★ 「搜索来源」并入「搜索」后，视图里不许再有它的一级页面分支。
    ///
    /// 这条防的是「合并了一半」：Core 里删了 `.sources`，视图里却留着
    /// `case .sources` 或旧的 `sourcesPane` / `sourcesList`——那种状态下一改
    /// 枚举就会编译不过，或者留下一个永远走不到的死分支。
    func testSourcesPaneIsGoneFromTheView() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("case .sources"),
                       "视图里不该再有「搜索来源」这条分支")
        XCTAssertFalse(settings.contains("var sourcesPane"),
                       "旧的 sourcesPane 已并入搜索页")
        XCTAssertFalse(settings.contains("var sourcesList"),
                       "旧的 sourcesList 已并入搜索页")
        XCTAssertTrue(settings.contains("var searchPane"),
                      "搜索页需要承载「列表 / 来源详情」两种形态")
    }

    /// ★ 三页的导航是顶部原生分段控件，不再是一条常驻侧栏。
    ///
    /// 三页配一条 `NavigationSplitView` 侧栏：窗口拉高时左栏留下大片空白，
    /// 还白占 170–230pt 的宽度。这里锁的是**新形态**：
    /// 页面集合仍唯一来自 Core（不写死在视图里）、每一段仍挂无障碍标识
    ///（键盘与 VoiceOver 靠它定位）、侧栏那一套（selection / 侧栏样式 /
    /// 列宽 / `tag`）全部撤干净。
    func testTopLevelNavigationUsesANativeSegmentedControl() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("Picker(\"设置页面\", selection: $pane)"),
                      "一级导航要是一个带标签的 Picker（标签供 VoiceOver 读出用途）")
        XCTAssertTrue(settings.contains("ForEach(SettingsPane.allCases) { item in"),
                      "三页必须由 Core 的 SettingsPane 遍历出来，不许在视图里另写一份")
        XCTAssertTrue(settings.contains("settings-nav-"),
                      "每一段都要挂 settings-nav- 标识，键盘导航与 VoiceOver 靠它定位")
        for gone in ["NavigationSplitView", ".listStyle(.sidebar)",
                     "navigationSplitViewColumnWidth", "List(selection: $pane)"] {
            XCTAssertFalse(settings.contains(gone),
                           "侧栏的 \(gone) 已随导航收敛撤掉")
        }

        guard let picker = braceBlock(after: "private var panePicker: some View", in: settings) else {
            return XCTFail("缺少一级导航的 panePicker")
        }
        XCTAssertTrue(picker.contains(".pickerStyle(.segmented)"),
                      "一级导航要用系统分段控件，不要自绘一排按钮")
        XCTAssertFalse(picker.contains("Image(systemName:"),
                       "三页的页名自带解释，分段上不必再摆图标")
    }

    /// ★ 宽度跟着导航一起收窄：内容区限宽居中，窗口不再为侧栏留位置。
    ///
    /// 侧栏撤掉后，880 宽里有一整条 170–230pt 是空的。这里不锁死具体像素
    ///（调排版时不该被迫改测试），只钉「内容区有上限」与「窗口确实窄了」。
    func testWidthsShrankWithTheSidebar() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let content = braceBlock(after: "private var content: some View", in: settings) else {
            return XCTFail("缺少内容区容器")
        }
        XCTAssertTrue(content.contains("maxWidth: SettingsLayout.contentMaxWidth"),
                      "内容区要有最大宽度，否则标签与控件之间会空出一大片")
        XCTAssertTrue(content.contains("maxWidth: .infinity"),
                      "限宽之后要在可用宽度里居中，不是贴着左边")

        let window = codeOnly(try appSource("SettingsWindow.swift"))
        guard let contentWidth = widthNumber(in: window, after: "setContentSize"),
              let minWidth = widthNumber(in: window, after: "minSize") else {
            return XCTFail("取不到设置窗口的宽度：\(window)")
        }
        XCTAssertLessThanOrEqual(contentWidth, 680,
                                 "默认宽度要收窄到 680 以内（880 是为侧栏留的），实际 \(contentWidth)")
        XCTAssertLessThanOrEqual(minWidth, 560,
                                 "最小宽度也要跟着收窄，实际 \(minWidth)")
    }

    /// 取出 `setContentSize(` / `minSize = NSSize(` 之后的 width 数字。
    private func widthNumber(in text: String, after marker: String) -> Int? {
        guard let markerRange = text.range(of: marker),
              let keyRange = text.range(of: "width: ", range: markerRange.upperBound..<text.endIndex) else {
            return nil
        }
        var digits = ""
        var index = keyRange.upperBound
        while index < text.endIndex, text[index].isNumber {
            digits.append(text[index])
            index = text.index(after: index)
        }
        return Int(digits)
    }

    /// ★ 来源列表与「添加搜索来源」入口必须住在**搜索页**里（合并的结果）。
    func testSourceListLivesInsideTheSearchPage() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.nasSources"),
                      "搜索页要列出已有来源")
        XCTAssertTrue(settings.contains("add-search-source"),
                      "「添加搜索来源」入口要跟着一起进来")
        // 标题文字改走 `sectionHeader(...)`（字号阶梯），分段本身没变。
        XCTAssertTrue(settings.contains("sectionHeader(\"网络存储\")"),
                      "来源列表在搜索页里用一个「网络存储」分段")
        // 原「搜索来源」页开头那行「此 Mac」与上面的「本地搜索范围」是同一件事，
        // 合并后必须去掉，否则摆两遍只会让人怀疑它们不一致。
        XCTAssertFalse(settings.contains("Text(\"此 Mac\")"),
                       "「此 Mac」那一行与「本地搜索范围」重复，合并后不该还在")
    }

    // MARK: - 局域网设备发现

    private func clientFile(_ path: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    /// ★ 浏览 Bonjour 必须声明服务类型，否则系统会拒绝。
    ///
    /// macOS 从 Sonoma 起对本地网络访问有明确门槛：`NSBonjourServices` 里没列
    /// 的服务类型，`NetServiceBrowser` 会静默查不到任何东西——界面表现为
    /// 「永远在查找中」，而控制台里连一句错误都没有。
    func testInfoPlistDeclaresTheBonjourServicesWeBrowse() throws {
        let plist = try clientFile("Resources/Packaging/Info.plist")
        XCTAssertTrue(plist.contains("NSBonjourServices"),
                      "浏览 Bonjour 必须在 Info.plist 里声明服务类型")
        for type in ["_smb._tcp", "_webdav._tcp", "_synology-dsm._tcp"] {
            XCTAssertTrue(plist.contains(type), "缺少服务类型声明：\(type)")
        }
        XCTAssertTrue(plist.contains("NSLocalNetworkUsageDescription"),
                      "访问局域网要有用途说明，系统弹窗里会显示给用户")
    }

    /// ★ Preview 证据采集设施不得进 Release 包。
    ///
    /// `PreviewInteractionValidation` 会往包外写 Evidence JSON、会合成按键投递
    /// 到面板里——它是**开发期取证工具**，不是产品功能。正式包里必须连编译
    /// 都不编进去，所以整个文件包在 `#if DEBUG` 下；每一处调用点也得在同一个
    /// 条件里，否则 Release 会因为找不到符号而编译失败（那还算好的，最怕的是
    /// 有人为了让 Release 编过去，又把文件从条件里放出来）。
    ///
    /// 两条都锁：① 文件两端确实是 `#if DEBUG` / `#endif`；② 所有调用点都落在
    /// `#if DEBUG` 块内。判定条件编译块归属要**自己数 `#if`/`#endif` 配平**，
    /// 不能用全局 `contains`——那是项目里踩过的坑。
    func testPreviewEvidenceFacilitiesAreExcludedFromReleaseBuilds() throws {
        let file = try clientFile("Sources/FlashFind2App/DebugSupport/PreviewInteractionValidation.swift")
        let lines = file.split(separator: "\n", omittingEmptySubsequences: false)
            .map { String($0).trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.first, "#if DEBUG",
                       "证据采集设施整个文件必须包在 #if DEBUG 里，否则会一起进 Release 包")
        XCTAssertEqual(lines.last { !$0.isEmpty }, "#endif",
                       "文件末尾必须收 #endif")

        // 旧位置必须已经清空：留着旧副本等于隔离白做。
        let stale = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlashFind2App/PreviewInteractionValidation.swift")
        XCTAssertFalse(FileManager.default.fileExists(atPath: stale.path),
                       "旧位置的 PreviewInteractionValidation.swift 还在，隔离未生效")

        // 调用点必须在同一个条件里，否则 Release 编译会找不到符号。
        var offenders: [String] = []
        for url in try appSwiftFiles() {
            let text = try String(contentsOf: url, encoding: .utf8)
            let raw = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
            let code = raw.map { $0.trimmingCharacters(in: .whitespaces) }
            for (offset, line) in code.enumerated() where line.contains("PreviewInteractionValidation.run(") {
                if !isGuardedByDebug(at: offset, in: code, raw: raw) {
                    offenders.append("\(url.lastPathComponent):\(offset + 1)")
                }
            }
        }
        XCTAssertEqual(offenders, [],
                       "这些调用点不在 #if DEBUG 块内，Release 构建会失败或把取证代码带进正式包：\(offenders)")
    }

    /// App 层所有 .swift（含子目录，如 DebugSupport/）。
    private func appSwiftFiles() throws -> [URL] {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let dir = root.appendingPathComponent("Sources/FlashFind2App")
        guard let enumerator = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    /// 第 `index` 行是否处在 `#if DEBUG` 块内。
    ///
    /// 从上面往回走：`#endif` 加深一层，`#if` 在最外层时就是决定性的守卫。
    /// 只认**行首**的编译指令——注释里提一句 `#if DEBUG` 不算真的守卫。
    private func isGuardedByDebug(at index: Int, in code: [String], raw: [String]) -> Bool {
        var depth = 0
        var cursor = index - 1
        while cursor >= 0 {
            let text = raw[cursor]
            let trimmed = code[cursor]
            if trimmed.hasPrefix("//") { cursor -= 1; continue }
            if trimmed.hasPrefix("#endif") { depth += 1 }
            else if trimmed.hasPrefix("#if") {
                if depth == 0 { return trimmed == "#if DEBUG" }
                depth -= 1
            }
            _ = text
            cursor -= 1
        }
        return false
    }

    /// ★ 向导要真的把「附近的设备」接上，且选中只**预填**、不自动连接。
    ///
    /// 自动连接等于替用户决定「就是这台、就用这个账号」，而账号密码还没填。
    /// 预填之后由用户核对地址再点「连接」。
    ///
    /// 列表放在独立的小窗里（`NearbyDevicesSheet`）：局域网设备可能几十台，
    /// 铺在向导第一屏会把「填地址 + 填账号」挤出去。
    func testWizardWiresUpNearbyDevicesWithoutAutoConnecting() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("LocalNetworkDiscovery()"),
                      "向导要起一个设备发现器")
        XCTAssertTrue(wizard.contains("NearbyDevicesSheet"),
                      "要有「附近的设备」这个挑选小窗")
        XCTAssertTrue(wizard.contains("model.applyDiscoveredDevice(device)"),
                      "选中设备要交给模型预填")
        // 小窗一关就回填完并自动关闭，主界面不被打断。
        XCTAssertTrue(wizard.contains("showingNearbyDevices = false"),
                      "选中之后要自动关窗")
        XCTAssertTrue(wizard.contains("discovery.start(existing: model.nasSources)"),
                      "开窗时要开始发现，并把已有来源传进去标记「已添加」")
        XCTAssertTrue(wizard.contains("discovery.stop()"),
                      "关窗要停掉浏览，不能窗口没了还在收广播")
        // 只预填，不许顺手连上。
        XCTAssertFalse(wizard.contains("applyDiscoveredDevice(device)\n                    model.connectDraft"),
                       "选中设备不该自动发起连接")

        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertTrue(controller.contains("func applyDiscoveredDevice"),
                      "预填逻辑住在控制器里")
    }

    /// ★ 选中设备时**先切品牌、再写地址**，顺序反了地址会被清空。
    ///
    /// `adoptVendor` 会清掉 host / port / username（换类型等于换一种服务）。
    /// 先写地址再切品牌，用户看到的就是「点了一台设备，地址栏还是空的」。
    func testDiscoveredDeviceAppliesVendorBeforeAddress() throws {
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        let body = controller.split(separator: "\n")
        guard let start = body.firstIndex(where: { $0.contains("func applyDiscoveredDevice") }) else {
            return XCTFail("找不到 applyDiscoveredDevice")
        }
        let window = body[start..<min(start + 20, body.count)]
        guard let vendorLine = window.firstIndex(where: { $0.contains("setDraftVendor(vendor)") }) else {
            return XCTFail("applyDiscoveredDevice 里没看到切品牌")
        }
        guard let hostLine = window.firstIndex(where: { $0.contains("draftSource.host = device.host") }) else {
            return XCTFail("applyDiscoveredDevice 里没看到写地址")
        }
        XCTAssertLessThan(vendorLine, hostLine,
                          "必须先切品牌再写地址，否则 adoptVendor 会把地址清掉")
    }

    /// ★ 搜索页不再重复管「搜哪些设备」，也不再把内部策略摆给用户。
    ///
    /// 「搜索本机文件 / 此 Mac / NAS」这三项与「搜索来源」页重复；
    /// 「至少输入 2 个字符」是内部策略，用户不该被要求做这个决定。
    func testSearchPageDropsDuplicatedSourceControlsAndInternalPolicy() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        for removed in ["搜索本机文件", "NAS 输入规则", "至少输入", "2 个字符"] {
            XCTAssertFalse(settings.contains(removed),
                           "搜索页不该再出现「\(removed)」：来源在来源页管，最少字符数是内部策略")
        }
    }

    /// ★ 来源行的呈现全部来自 Core，视图不再自己拼状态或自己决定给不给按钮。
    func testSourceRowPresentationComesFromCoreModel() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.sourceRow(source.id)"),
                      "行内容必须由 AppModel.sourceRow（Core 判定）产出")
        XCTAssertTrue(settings.contains("row.action"),
                      "按钮有无必须看 Core 判定出的 action")
        XCTAssertTrue(settings.contains("row.locations"),
                      "搜索位置必须来自 Core 行模型")
    }

    /// ★ 「关于」按 macOS 惯例改成独立面板，不再占设置里的一页。
    func testAboutUsesTheStandardPanelAndIsReachableFromTheStatusMenu() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(app.contains("AboutPanel.show()"),
                      "状态栏菜单必须有「关于闪寻」入口（本应用没有可点的菜单栏）")
        XCTAssertTrue(app.contains("orderFrontStandardAboutPanel"),
                      "关于面板用系统的标准面板，不自己画一套")

        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("来源统计"),
                       "「关于」页的内容已随页面撤下")
    }

    /// ★ 「登录时启动」必须真接系统，而不是一个 `.disabled(true)` 的假开关。
    ///
    /// 摆一个点了没反应的假开关往往还配一句「这两项还没有接系统设置」——
    /// 正式界面不该出现开发状态说明（UI 简化原则）。
    func testLaunchAtLoginIsReallyWiredAndNoDeveloperNotesRemain() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("这两项还没有接系统设置"),
                       "界面里不许留着开发状态说明")
        XCTAssertFalse(settings.contains(".disabled(true)"),
                       "不许再摆点了没反应的假开关")
        XCTAssertTrue(settings.contains("model.setLaunchAtLogin"),
                      "「登录时启动」必须写回模型")

        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("LaunchAtLogin.set("),
                      "登录项注册必须真的调系统接口")
        let launcher = codeOnly(try appSource("LaunchAtLogin.swift"))
        XCTAssertTrue(launcher.contains("SMAppService.mainApp.register()"),
                      "用 SMAppService 注册登录项")
        XCTAssertTrue(launcher.contains("error.localizedDescription"),
                      "注册失败要把系统给的原因如实返回，不许假装成功")
    }

    /// ★ 高级页只留诊断与实验性开关；维修按钮与内部参数不再出现在产品界面。
    func testAdvancedPageKeepsOnlyDiagnosticsAndExperimentalToggle() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        for removed in ["用已保存的密码重连所有 NAS", "刷新已挂载的 SMB 共享",
                        "NAS 搜索等待上限", "nativeSearchTimeoutSeconds"] {
            XCTAssertFalse(settings.contains(removed),
                           "「\(removed)」是维修工具/内部参数，不该出现在产品界面")
        }
        XCTAssertTrue(settings.contains("model.runConnectionDiagnostics()"),
                      "高级页保留一个「运行连接诊断」入口")
        XCTAssertTrue(settings.contains("model.showExperimentalSources"),
                      "实验性来源开关是高级页唯一的新增项")
    }

    /// ★ 来源出问题时该给哪个按钮，是**写进模型**的结构化字段，不是从文案猜的。
    ///
    /// 「读取共享目录失败」与「本机没有保存密码」都落在 `needsAttention`，
    /// 但前者要去继续设置、后者是要登录。靠文案匹配一定会错。
    func testRequiredActionIsWrittenForEveryProblemPath() throws {
        let appModel = try appModelCode()
        for assignment in ["$0.requiredAction = .login", "$0.requiredAction = .continueSetup",
                           "$0.requiredAction = .retry", "$0.requiredAction = nil"] {
            XCTAssertTrue(appModel.contains(assignment),
                          "缺少这条状态写入：\(assignment)")
        }
    }

    // MARK: - 设置页去噪（本机搜索提示 / 网络存储页脚）

    // MARK: - `/` 命令面板与位置限定

    /// ★ 命令模式下**不得**发起真实搜索。
    ///
    /// 那时的文本是「指令」不是关键词。把它当关键词发给设备，
    /// 设备会去搜一个叫「照片」的东西 —— 白白占一次设备侧检索，
    /// 而且用户看到的结果完全莫名其妙。
    ///
    /// 这条判在 App 层（`changedQuery` 里短路），所以只能靠源码结构断言。
    func testCommandModeShortCircuitsRealSearch() throws {
        let code = try appModelCode()
        guard let body = braceBlock(after: "func changedQuery()", in: code) else {
            return XCTFail("找不到 changedQuery")
        }
        XCTAssertTrue(body.contains("isCommandModeActive"),
                      "命令模式必须在 changedQuery 里被识别并短路")
        // ★ 短路必须**真的会发生**：`if isCommandModeActive && false` 这种
        // 「写了但永远不成立」的写法，contains 查不出来 —— 上一轮的反向变异
        // 正是这么溜过去的。所以这里要求 if 的条件里没有 `&& false` 之类的
        // 短路掉整个判定的写法。
        guard let shortCircuit = body.range(of: "isCommandModeActive") else {
            return XCTFail("changedQuery 里没有命令模式判定")
        }
        let condition = String(body[shortCircuit.lowerBound...])
        XCTAssertFalse(condition.contains("&& false"),
                       "命令模式的判定被短路掉了（写法如 `&& false`）")
        XCTAssertFalse(condition.contains("|| true"),
                       "命令模式的判定被短路掉了（写法如 `|| true`）")
        // 短路必须发生在**调用搜索之前**：短路点之后不该再出现
        // searchDebounced 之前的搜索调用。
        let after = String(body[shortCircuit.upperBound...])
        guard let search = after.range(of: "searchDebounced") else {
            return XCTFail("changedQuery 里没有搜索调用")
        }
        let between = String(after[..<search.lowerBound])
        XCTAssertTrue(between.contains("return"),
                      "命令模式的 return 必须发生在 searchDebounced 之前")
    }

    /// ★ 位置限定必须真的进到请求计划里，并一路带到协调器。
    ///
    /// 只在界面上显示一个位置标签，设备侧却仍在扫全部共享 ——
    /// 那就完全没实现「减少检索时间」这个承诺。
    func testSearchTargetFlowsIntoRequestPlanAndCoordinator() throws {
        let code = try appModelCode()
        guard let body = braceBlock(after: "func changedQuery()", in: code) else {
            return XCTFail("找不到 changedQuery")
        }
        XCTAssertTrue(body.contains("target: tokenBar.location"),
                      "位置限定必须作为 target 传进 SearchRequestPlan")
        XCTAssertTrue(body.contains("authorizedRoots:"),
                      "必须把已授权根传进请求计划，否则越权的根也会被请求")
        XCTAssertTrue(body.contains("rootLimit:rootLimit"),
                      "rootLimit 必须一路带到协调器，否则设备侧不会收窄")
        // ★ 类型限定走的是「拼进搜索文本」这条路，必须真的下发，
        // 否则界面上选了类型、设备却照旧全搜。
        XCTAssertTrue(body.contains("tokenBar.searchText(keyword: query)"),
                      "类型限定必须拼进下发的搜索文本")
        XCTAssertTrue(body.contains("searchDebounced(searchText"),
                      "下发的一定是拼好的文本，不能是输入框原文")
    }

    /// 命令面板的候选必须来自 Core 的目录，不许在 App 层自己拼。
    func testCommandCandidatesComeFromCoreCatalog() throws {
        let code = try appSource("AppModel+SearchCommand.swift")
        XCTAssertTrue(code.contains("SearchCommandCatalog.items"),
                      "候选列表必须由 Core 的命令目录构建")
        XCTAssertTrue(code.contains("SearchCommandCatalog.filter"),
                      "筛选必须由 Core 的命令目录做")
        XCTAssertTrue(code.contains("SearchCommandParser.parse"),
                      "命令模式判定必须用 Core 的解析器")
        // App 层不许自己写「哪些位置可选」的判定。
        XCTAssertFalse(code.contains("provider?.ready == true") && code.contains("roots: config.scopes.filter"),
                       "App 层不许自己筛位置")
    }

    /// ★ 新 UI 不写提示备注：命令面板里不许出现解释性文字。
    func testCommandPaletteCarriesNoExplanatoryText() throws {
        // ★ 判的是**界面上的文字**，所以注释必须先剥掉 ——
        // 否则「多写一句……就是噪音」这种注释里的字会被当成界面文案，
        // 断言就成了一直红的假红。
        let code = codeOnly(try appSource("SearchCommandPaletteView.swift"))
        // 「没有匹配的位置」是**状态**（筛不出候选），不是说明文字，允许。
        for forbidden in ["更快", "减少", "检索时间", "点击", "选择位置后", "快捷键", "↑", "↓"] {
            XCTAssertFalse(code.contains(forbidden),
                           "命令面板不许出现解释性文字：\(forbidden)")
        }
    }

    /// ★ 已选定的限定必须显示在搜索框里，而且是**关键词前面**的蓝色小字。
    ///
    /// 用户的要求原话：「用蓝色字体更小一号把选择的内容放置在最前边」。
    /// 摆在关键词后面会被看成关键词的一部分。
    func testSearchFieldShowsTokensBeforeKeyword() throws {
        let field = codeOnly(try appSource("SearchFieldView.swift"))
        XCTAssertTrue(field.contains("tokens"), "搜索框必须显示已选定的限定")
        XCTAssertTrue(field.contains("deleteToken"), "限定必须能删掉")
        XCTAssertTrue(field.contains("Color.accentColor"), "限定要用强调色（蓝）与关键词区分")
        // ★ 顺序：token 必须在 TextField 之前，**且要在 body 内部比**。
        //
        // ⚠️ 别在整份源码里找第一个 `tokenStrip`：属性定义也在源码里，
        // 它写在 body 之前，于是「token 在前」永远成立 —— 断言成了恒真的聋子
        // （变异试过：真把 token 挪到输入框后面，这条照样全绿）。
        guard let body = braceBlock(after: "var body", in: field),
              let tokenRange = body.range(of: "tokenStrip"),
              let fieldRange = body.range(of: "TextField(") else {
            return XCTFail("搜索框 body 里找不到限定条或输入框")
        }
        XCTAssertTrue(tokenRange.lowerBound < fieldRange.lowerBound,
                      "限定必须放在输入框（关键词）前面")
        // 字号要比正文（22）小一号。
        XCTAssertTrue(field.contains("size: 15"), "限定的字号要比关键词小")
    }

    /// ★ 两个面板都必须画满十条（数字 1–9 + 0），而且**不许把多出来的候选截断**。
    ///
    /// 数字能按到哪，就得显示到哪：按 7 / 8 / 9 / 0 选中的必须是屏幕上那一条。
    /// 2026-10-26 真实报障：OpenList 勾了 A0001–A0004 四个文件夹，`\` 面板
    /// 只画出第一行 —— 行数上限写死 6，`prefix(maximumVisible)` 把剩下的裁掉了。
    func testCommandPaletteDrawsEveryNumberedRow() throws {
        let model = codeOnly(try appSource("AppModel+SearchCommand.swift"))
        let limit = try XCTUnwrap(braceBlock(after: "var commandMaximumVisible:", in: model))
        XCTAssertTrue(limit.contains("SearchCommandCatalog.maximumVisibleRows"),
                      "行数上限必须来自 Core（1–9 加 0 推出来的十条），不许在 App 层另写一个数")
        XCTAssertFalse(limit.contains("? 10 : 6"),
                       "位置面板不许再压到六条：那会让数字 7/8/9 指向屏幕外的位置")

        let palette = codeOnly(try appSource("SearchCommandPaletteView.swift"))
        XCTAssertFalse(palette.contains("prefix(maximumVisible)"),
                       "候选不许按行数上限截断：被裁掉的搜索根既看不见也点不到")
        XCTAssertTrue(palette.contains("ScrollView(.vertical"),
                      "超过一屏要能滚动，而不是只画前十行")
        XCTAssertTrue(palette.contains("proxy.scrollTo("),
                      "上下键翻到屏幕外的候选时，必须把它滚进可视区")
        XCTAssertTrue(palette.contains(".frame(height: CGFloat(maximumVisible) * rowHeight)"),
                      "滚动区的固定高度必须与浮窗高度用同一个上限，否则面板被切掉一截")
    }

    /// ★ 面板的行必须能用**鼠标点**（2026-10-27 用户要求：不只有按键一条路）。
    ///
    /// 面板不是 `List`／`NSTableView`，没有原生点击行为 —— 不显式挂
    /// `onTapGesture`，习惯用鼠标的用户在这个面板里一条都选不了。
    /// 悬停也要选中：点之前得先看清会点中哪一条。
    func testCommandPaletteRowsCanBePickedWithTheMouse() throws {
        let palette = codeOnly(try appSource("SearchCommandPaletteView.swift"))
        XCTAssertTrue(palette.contains(".onTapGesture { onPick(index) }"),
                      "★ 没有点击手势，这个面板对鼠标用户就是死的")
        XCTAssertTrue(palette.contains(".onHover { inside in"),
                      "鼠标移上来要选中（高亮），否则点之前不知道会点中谁")
        XCTAssertTrue(palette.contains("let onPick: (Int) -> Void"))
        XCTAssertTrue(palette.contains("let onHover: (Int) -> Void"))

        let view = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(view.contains("onPick: { index in"), "面板的点击必须接到模型")
        XCTAssertTrue(view.contains("model.pickCommand(at: index)"),
                      "★ 点击与数字键要走同一条执行路径：各写一份迟早只改一边")
        XCTAssertTrue(view.contains("model.hoverCommand(at: $0)"),
                      "悬停也要接到模型：选中状态只有一份")
        // ★ 判在 `commandPalette` 的块里：整份文件还有两处 `focused = true`
        //   （显示面板、收到通知），拿全文查的话「点完不还焦点」这条断言是聋的。
        let paletteCall = try body(of: "commandPalette", in: view)
        XCTAssertTrue(paletteCall.contains("focused = true"),
                      "点完要把焦点还给输入框，否则选完位置还得再点一次才能接着打字")
    }

    /// ★ 浮窗高度必须按面板**实际显示的行数**算，不能写死 6。
    ///
    /// 两者一旦不同步，面板就会被浮窗底边切掉一截。
    func testPaletteHeightUsesSameRowLimit() throws {
        let code = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(code.contains("model.commandMaximumVisible"),
                      "浮窗高度与面板显示行数必须共用同一个上限")
        XCTAssertFalse(code.contains("filteredCommandItems.count, 6"),
                       "行数上限不许写死，否则与面板实际行数脱节")
    }

    func testCommandPaletteDoesNotReserveHiddenResultSpaceOrShowSearchProgress() throws {
        let source = codeOnly(try appSource("SearchView.swift"))
        let results = try XCTUnwrap(braceBlock(after: "private var expandedHeight:", in: source))
        XCTAssertTrue(results.contains("guard hasQuery, !model.isCommandModeActive else { return 0 }"),
                      "命令菜单显示时没有结果区，不能再加空结果或上一轮结果的高度")
        let pending = try XCTUnwrap(braceBlock(after: "private var pending:", in: source))
        XCTAssertTrue(pending.contains("!model.isCommandModeActive"), "命令模式并没有发起真实搜索")
        let palette = try XCTUnwrap(braceBlock(after: "private var commandPaletteHeight:", in: source))
        XCTAssertTrue(palette.contains("max(1,"), "无匹配选项也会渲染一行，必须为该行留出高度")
    }

    func testPermissionReturnRestoresPresentedPreferencesWithoutRebuildingDraft() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        let reopen = try XCTUnwrap(braceBlock(after: "func applicationShouldHandleReopen(", in: app))
        let restore = try XCTUnwrap(reopen.range(of: "restorePresentedPreferencesWindow("))
        let search = try XCTUnwrap(reopen.range(of: "searchPanel?.show()"))
        XCTAssertLessThan(restore.lowerBound, search.lowerBound,
                          "重开应用必须先恢复设置/登录窗口，不能直接让浮窗抢走焦点")
        let active = try XCTUnwrap(braceBlock(after: "func applicationDidBecomeActive(", in: app))
        XCTAssertTrue(active.contains("restorePresentedPreferencesWindow("))
        XCTAssertTrue(active.contains("searchPanel?.isKeyWindow"), "主动唤起搜索的快捷键不能被设置窗口抢走")
        let windows = codeOnly(try appSource("SettingsWindow.swift"))
        XCTAssertEqual(windows.components(separatedBy: "isPresented = true").count - 1, 2)
        XCTAssertEqual(windows.components(separatedBy: "isPresented = false").count - 1, 4,
                       "设置/向导关闭后必须清除呈现标记，不能在下一次激活时复活")
        let restoreSource = codeOnly(try appSource("WindowRestore.swift"))
        let helper = try XCTUnwrap(braceBlock(after: "func restorePresentedPreferencesWindow(",
                                             in: restoreSource))
        XCTAssertTrue(helper.contains("makeKeyAndOrderFront"))
        XCTAssertFalse(helper.contains("rootView"), "授权返回不能重建表单并清空草稿")
        XCTAssertFalse(helper.contains("cancelDraft"))
        // 「哪个窗口算数」只有一处定义，最小化的排除规则跟着它一起搬了家：
        // 断言盯住现居地，规则本身不变 —— 擅自还原用户主动最小化的窗口同样是缺陷。
        let picker = try XCTUnwrap(braceBlock(after: "func presentedPreferencesWindows(",
                                              in: restoreSource))
        XCTAssertTrue(picker.contains("isMiniaturized"), "不能擅自还原用户主动最小化的窗口")
    }

    /// 删除键删限定的判定必须在 Core，不许 App 层自己写顺序。
    func testTokenRemovalOrderIsDecidedInCore() throws {
        let code = try appSource("AppModel+SearchCommand.swift")
        XCTAssertTrue(code.contains("slotToRemoveOnBackspace"),
                      "删哪个限定必须由 Core 的 SearchTokenBar 判定")
        XCTAssertTrue(code.contains("tokenBar.clear("), "删除必须走 Core 的 clear")
    }

    /// ★ **点标签**与**删除键**必须是两条规则，不能共用一条。
    ///
    /// 共用（1.1.16 的实际写法：每枚标签都接同一个 `deleteToken`）有两个后果：
    /// ① 输入框里还有关键词时，点击被「关键词非空」这条删除键的前提挡住 ⇒ 点了没反应；
    /// ② 位置与类型都在时，点位置删掉的却是最近设的那个（类型）。
    func testTappingATokenClearsThatTokenNotTheBackspaceRule() throws {
        let field = codeOnly(try appSource("SearchFieldView.swift"))
        XCTAssertTrue(field.contains("deleteToken(token.slot)"),
                      "点一枚限定必须删**被点的那一枚**（把槽位传下去），"
                      + "不能调用无参的删除键动作")
        // 无参的 `deleteToken()` 一旦还在，说明点击仍是「删最近设的那个」。
        XCTAssertFalse(field.contains("Button(action: deleteToken)"),
                       "点击不许直接接删除键动作")

        let model = codeOnly(try appSource("AppModel+SearchCommand.swift"))
        XCTAssertTrue(model.contains("func deleteSearchToken(_ slot: SearchTokenBar.Slot)"),
                      "App 层要有「按槽位删」的入口")
        XCTAssertTrue(model.contains("slotToRemoveOnBackspace"),
                      "删除键仍要走 Core 的 LIFO 判定（关键词非空时不抢键）")

        let view = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(view.contains("tokens: model.searchTokens"),
                      "搜索框必须拿到带槽位的限定，而不是一串字符串")
        XCTAssertTrue(view.contains("deleteToken: { model.deleteSearchToken($0) }"),
                      "点击必须把槽位交给 App 层")
        XCTAssertTrue(view.contains("deleteSearchToken: { model.deleteSearchToken() }"),
                      "键盘删除键仍走无参那条（保留「有关键词时只删文字」的行为）")
    }

    // MARK: - 收尾边界（取消 / 重新编辑 / 提交 的真实调用顺序）

    /// ★ 「取消」必须**同步**认领归属，不能把票号留到收尾 Task 里再取。
    ///
    /// 行为由 `DraftSessionTests` 用真实 provider 覆盖（见
    /// `testTeardownClaimedBeforeItsTaskStartsIsNotOverriddenByLaterEdit`）；
    /// 这里锁的是 controller 那条**真实调用链**上的顺序——
    /// 只查「源码里有没有 beginTeardown」是不够的，写在 `Task {` 之后等于没写。
    func testCancelDraftClaimsTeardownOwnershipBeforeItsTaskStarts() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let body = try XCTUnwrap(braceBlock(after: "func cancelDraft()", in: source),
                                 "找不到 cancelDraft 的实现")
        let claim = try XCTUnwrap(body.range(of: "beginTeardown()"), "取消必须认领本轮归属")
        let task = try XCTUnwrap(body.range(of: "Task {"), "取消之后仍要把收尾丢到后台跑")
        XCTAssertTrue(claim.lowerBound < task.lowerBound,
                      "认领必须发生在 Task 之前：晚一步取票号，旧收尾就会把新的编辑认领成自己的")
        XCTAssertTrue(body.contains("ticket: ticket"), "收尾必须带上同步拿到的票号")
        XCTAssertTrue(body.contains("endTeardown()"), "收尾落定后必须摘掉「收尾中」这面旗")
    }

    /// ★ 重新编辑同一台来源时，不许在收尾还没落定时就把范围快照复制进草稿。
    func testEditSourceWaitsForPendingTeardownBeforeAdoptingLiveSession() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let body = try XCTUnwrap(braceBlock(after: "func editSource(", in: source),
                                 "找不到 editSource 的实现")
        let gate = try XCTUnwrap(body.range(of: "hasPendingTeardown"),
                                 "借活会话之前必须看这台来源上有没有未落定的收尾")
        let drain = try XCTUnwrap(body.range(of: "drainTeardown()"), "有收尾在飞时必须等它落定")
        XCTAssertTrue(gate.lowerBound < drain.lowerBound, "先看再等，顺序不能反")
        XCTAssertTrue(body.contains("adoptLiveSession("),
                      "「借会话 + 复制范围」必须是同一个动作，两条路共用，不许各写一遍")
        XCTAssertTrue(source.contains("private func adoptLiveSession("),
                      "收养逻辑必须有唯一实现")
    }

    /// ★ 提交必须是「先有绑定结果，再落盘」，不是「先落盘再补一次绑定」。
    ///
    /// 第三轮那个 `Task { _ = try? await provider.selectScopes(target) }` 属于后者：
    /// 它在 `saveDraft` 已持久化、`setSourceStatus` 已显示旧范围、`changedQuery`
    /// 已按旧范围发起搜索之后才出发，且 `false` 与 `throw` 全丢 ⇒ 绑定失败时
    /// 界面照样说「已保存」，只有搜索在悄悄用旧范围。
    /// **那不是修好，是把「配置与实际不一致」推迟成静默不一致。**
    func testCommitDraftBindsScopesBeforePersisting() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let body = try XCTUnwrap(braceBlock(after: "func commitDraft()", in: source),
                                 "找不到 commitDraft 的实现")
        let bind = try XCTUnwrap(body.range(of: "bindScopesForCommit("),
                                 "提交前必须先把范围绑定等出结果")
        let save = try XCTUnwrap(body.range(of: "guard saveDraft(rebuildProviders: false)"), "提交要落盘")
        let search = try XCTUnwrap(body.range(of: "changedQuery()"), "提交后要重新搜索")
        XCTAssertTrue(bind.lowerBound < save.lowerBound,
                      "绑定必须排在落盘之前：反过来就是「配置已存、实际没生效」")
        XCTAssertTrue(save.lowerBound < search.lowerBound,
                      "只有配置真的落盘之后才发起搜索")
        XCTAssertFalse(body.contains("try? await provider.selectScopes"),
                       "不许再有「落盘之后才绑定、且丢掉结果」的兜底")
        XCTAssertTrue(body.contains("draftGeneration"),
                      "提交必须认领代次：await 之后要核对这一轮草稿还作数")
        XCTAssertTrue(body.contains("return false"),
                      "绑定失败必须回 false —— 调用方据此不关窗口、不说已保存")
    }

    /// ★ 绑定要等一次网络往返，往返期间草稿仍然可编辑（勾选不推进代次）。
    ///
    /// 只记目标范围是**不够**的：落盘走 `saveDraft()`，读的是此刻的 `draftSource`。
    /// 于是「绑 B、存 C、搜 B」——存下来的是一份用户从没确认过的值，
    /// 且代次守卫、会话身份守卫都抓不到（两者都没变）。
    func testCommitDraftRejectsADraftEditedWhileBinding() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let body = try XCTUnwrap(braceBlock(after: "func commitDraft()", in: source),
                                 "找不到 commitDraft 的实现")
        let bind = try XCTUnwrap(body.range(of: "bindScopesForCommit("), "提交要先绑定范围")
        let save = try XCTUnwrap(body.range(of: "guard saveDraft(rebuildProviders: false)"), "提交要落盘")
        let snapshot = try XCTUnwrap(body.range(of: "let committedDraft = draftSource"),
                                     "出发前必须把整份草稿拍下来，不能只记目标范围")
        XCTAssertTrue(snapshot.lowerBound < bind.lowerBound,
                      "快照必须在 await（绑定）之前拍：绑完再拍，拍到的就是被改过的那份")
        // ★ 只查 `contains` 会恒真（定义了但没核对照样命中），必须查它落在
        //   「绑定之后、落盘之前」这一段里。
        guard bind.upperBound <= save.lowerBound else {
            XCTFail("范围绑定必须在落盘之前")
            return
        }
        let between = String(body[bind.upperBound..<save.lowerBound])
        XCTAssertTrue(between.contains("draftSource == committedDraft"),
                      "落盘前必须核对草稿仍是出发时那一份：变了就拒绝保存，不能存用户没确认过的值")
        XCTAssertTrue(between.contains("return false"),
                      "草稿被改过必须回 false —— 调用方据此不关窗口、不说已保存")
        let entryGuard = try XCTUnwrap(body.range(of: "guard !draftBusy"),
                                       "提交入口要挡住上一次提交还在飞的情况：直接调用/双击绕得过按钮")
        XCTAssertTrue(entryGuard.lowerBound < bind.lowerBound,
                      "入口的忙碌判断必须在绑定之前")
    }

    /// ★ 收养活会话必须认代次，并在 await 之后复核实例仍然可用。
    func testAdoptLiveSessionIsGuardedByDraftGeneration() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let adopt = try XCTUnwrap(braceBlock(after: "private func adoptLiveSession(", in: source),
                                 "找不到 adoptLiveSession 的实现")
        // ★ 必须在 `guard` 那一段里查，不能全文 `contains`：
        //   函数开头的 `defer` 里也判了一次代次（解除忙碌只归自己这一轮），
        //   全文匹配的话「guard 里漏判」照样是绿的——那就是假证据。
        let guardStart = try XCTUnwrap(adopt.range(of: "guard "), "收养必须有过期的判断")
        let guardEnd = try XCTUnwrap(adopt.range(of: "else { return }"), "判断不通过必须放弃收养")
        XCTAssertTrue(guardStart.lowerBound < guardEnd.lowerBound)
        let guardClause = String(adopt[guardStart.lowerBound..<guardEnd.lowerBound])
        XCTAssertTrue(guardClause.contains("draftGeneration == generation"),
                      "等收尾回来之后必须核对草稿代次：取消/重开/切来源都让旧回调作废")
        XCTAssertTrue(guardClause.contains("live.ready"),
                      "ready 必须在 await **之后**复核：等待期间实例可能已经掉线")
        XCTAssertTrue(adopt.contains("draftSettling = false"),
                      "收养结束（或作废）要解除本轮忙碌")
        let edit = try XCTUnwrap(braceBlock(after: "func editSource(", in: source),
                                 "找不到 editSource 的实现")
        XCTAssertTrue(edit.contains("generation: generation"),
                      "发起等待之前就要把本轮代次交给收养，不能等回来再认领")
        XCTAssertTrue(edit.contains("draftSettling = true"),
                      "等待期间必须显示忙碌：此刻「已连接 / 可保存」都还不成立")
    }

    /// ★ 取消必须让本轮代次作废，否则旧提交/旧收养还能落到新草稿上。
    func testCancelDraftInvalidatesTheDraftGeneration() throws {
        let source = try appSource("NASSourceWizardController.swift")
        let body = try XCTUnwrap(braceBlock(after: "func cancelDraft()", in: source),
                                 "找不到 cancelDraft 的实现")
        XCTAssertTrue(body.contains("draftGeneration += 1"),
                      "取消要让本轮作废：在飞的绑定与收养都不许再写这台来源")
        XCTAssertTrue(body.contains("draftSettling = false"), "取消要解除本轮忙碌")
    }

    /// ★ 保存按钮不许再无条件关窗口。
    func testSaveButtonClosesOnlyAfterASavedCommit() throws {
        let view = try appSource("NASSourceWizardView.swift")
        XCTAssertTrue(view.contains("if await model.commitDraft()"),
                      "窗口只能在 commitDraft 回 true（真的保存了）之后关闭")
        XCTAssertFalse(view.contains("model.commitDraft(); NASWizardWindow.shared.close()"),
                       "不许再「点了就关」——绑定失败时那会留下一台配置与实际不一致的来源")
    }

    /// 取出 `marker` 之后第一个花括号块的**完整内容**（含花括号）。
    ///
    /// 「这句调用在不在 `onAppear` 里」没法用 `contains` 回答——整份源码里
    /// 出现一次就够了。所以要按括号配平把块切出来再查。
    private func braceBlock(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text.range(of: "{", range: markerRange.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open.lowerBound...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// ★ 本机搜索的提示必须**真的被触发**，否则那行提醒永远等不到结果。
    ///
    /// 缺口就在这里：`refreshLocalSearchAvailability()` 若一个调用点都没有，
    /// 设置页里显示的永远只是初值「正在检查本机搜索状态」——
    /// 一句永远不结束的进度提示。所以两件事一起锁：
    /// 初值不许再写成「正在检查…」，且设置页出现时要真的去查。
    func testSettingsChecksLocalSearchStateWhenItAppears() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let appear = braceBlock(after: ".onAppear", in: settings) else {
            return XCTFail("设置界面必须有 onAppear，检查才有触发点")
        }
        XCTAssertTrue(appear.contains("model.refreshLocalSearchAvailability()"),
                      "本机搜索状态的检查要在设置页出现时发起，实际 onAppear 里没有：\(appear)")

        let controller = codeOnly(try appSource("LocalSourceController.swift"))
        XCTAssertFalse(controller.contains("正在检查本机搜索状态"),
                       "不许再摆一句永远等不到结果的「正在检查…」")
        let initial = controller.split(separator: "\n").first {
            $0.contains("localSearchAvailabilityMessage") && $0.contains("=")
        }
        XCTAssertTrue(initial?.contains("\"\"") == true,
                      "提示的初值必须是空（正常态不说话），实际：\(initial ?? "找不到声明")")
    }

    /// ★ 「网络存储」下面那句解释「附近设备」会自动查找的话是多余的。
    ///
    /// 点「添加搜索来源…」的第一屏就摆着「附近的设备」，用户在那里会亲眼看到；
    /// 常驻在设置页页脚的这段说明只会让人以为自己漏看了什么功能开关。
    func testNetworkStorageSectionCarriesNoExplainerFooter() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("会在添加时自动查找同一局域网内的 NAS"),
                       "「网络存储」不该再挂这段解释性页脚")
    }

    // MARK: - 首次启动引导

    /// ★ 引导是独立窗口，不塞进设置页。
    ///
    /// 塞进设置会让第一次见面的人先看到三条来源、诊断按钮、实验性开关——
    /// 那正是这轮要避免的「像 NAS 管理器」。
    func testOnboardingIsItsOwnWindowNotASettingsPane() throws {
        let window = codeOnly(try appSource("OnboardingWindow.swift"))
        XCTAssertTrue(window.contains("final class OnboardingWindow"), "引导要有自己的窗口类型")
        XCTAssertTrue(window.contains("720") && window.contains("520"),
                      "引导窗口按 720×520 设计（一屏放得下，不用滚动）")
        XCTAssertTrue(window.contains("OnboardingView(model:"), "窗口内容应是引导视图")

        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertFalse(settings.contains("OnboardingView"),
                       "设置页不许把引导拼进来：两者是「第一次见面」和「已经会用」")
    }

    /// ★ 首次启动走引导，不再先把空搜索浮窗弹出来。
    ///
    /// 无条件 `searchPanel?.show()` 的话，新用户看到的是一台没有来源、
    /// 也搜不出东西的空搜索框，然后不知道下一步该做什么。
    func testFirstLaunchPresentsOnboardingInsteadOfTheSearchPanel() throws {
        let code = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(code.contains("model.onboardingStore.shouldAutoPresent"),
                      "首启动判定必须来自 OnboardingStore")

        guard let launch = braceBlock(after: "func applicationDidFinishLaunching", in: code) else {
            return XCTFail("找不到 applicationDidFinishLaunching")
        }
        XCTAssertTrue(launch.contains("presentOnboardingOrSearch()"),
                      "启动路径必须经过「先引导还是先搜索窗」这个分岔")

        guard let branch = braceBlock(after: "private func presentOnboardingOrSearch", in: code) else {
            return XCTFail("缺少 presentOnboardingOrSearch")
        }
        XCTAssertTrue(branch.contains("OnboardingWindow.shared.show(model: model)"),
                      "没走完引导时要显示引导")
        XCTAssertTrue(branch.contains("searchPanel?.show()"),
                      "已经走完引导的用户仍应直接看到搜索浮窗")
        XCTAssertTrue(branch.contains("resumePrompt"),
                      "中途退出过的要问一句，而不是既不问也不管")
    }

    /// ★ 引导期间快捷键交给教学窗口，不触发真实搜索。
    ///
    /// 不拦的话：用户照着引导按一下，搜索浮窗盖到引导上面、还把焦点抢走，
    /// 而他只是想确认快捷键有没有生效。
    func testShortcutPressDuringOnboardingDoesNotOpenTheSearchPanel() throws {
        let code = codeOnly(try appSource("FlashFind2App.swift"))
        guard let press = braceBlock(after: "hotkeyRegistrar.onPress", in: code) else {
            return XCTFail("缺少全局快捷键按下回调")
        }
        XCTAssertTrue(press.contains("OnboardingWindow.shared.isVisible"),
                      "要先判断引导是不是开着")
        XCTAssertTrue(press.contains("noteOnboardingShortcutPressed"),
                      "开着时走引导的快捷键回调")
        // 反过来验证：不许把「打开搜索窗」整条删掉 —— 那是快捷键的正事。
        XCTAssertTrue(press.contains("toggleFlashFind2"))
    }

    /// ★ 权限要被「自己发现」，不能让用户回来点一个确认按钮。
    ///
    /// 用户是被我们送去系统设置里开开关的。回来时程序重查一次是它的本分；
    /// 摆一个「我已经开启」等于让用户替程序做检测，而那个按钮还可能是错的。
    func testPermissionStepRechecksOnItsOwnInsteadOfAskingTheUser() throws {
        let view = codeOnly(try appSource("OnboardingView.swift"))
        XCTAssertTrue(view.contains("didBecomeActiveNotification"),
                      "回到闪寻时（用户刚从系统设置回来）必须自己重查一次")
        XCTAssertTrue(view.contains("noteAppBecameActive"))
        XCTAssertTrue(view.contains("FullDiskAccess.isGranted"), "状态要现查，不能缓存")
        XCTAssertTrue(view.contains("FullDiskAccess.openSettings()"))
        // 人工确认是反模式：按钮可能被按在一个其实没开的状态上，之后所有搜索都莫名其妙。
        for forbidden in ["我已经开启", "我已授权", "我已开启", "确认已开启"] {
            XCTAssertFalse(view.contains(forbidden), "不许让用户替程序做检测：\(forbidden)")
        }

        let controller = codeOnly(try appSource("OnboardingController.swift"))
        XCTAssertTrue(controller.contains("activationRevision"),
                      "重查要有一个会变的输入，否则 SwiftUI 不会重算这一页")
    }

    /// ★ 「重新运行欢迎引导…」只清「已完成」标记，不动已有配置。
    func testRerunOnboardingKeepsConfiguration() throws {
        let appModel = try appModelCode()
        guard let rerun = braceBlock(after: "func restartOnboarding", in: appModel) else {
            return XCTFail("缺少 restartOnboarding")
        }
        XCTAssertTrue(rerun.contains("onboardingStore.rerun()"))
        for forbidden in ["removeSource", "resetGlobalShortcut", "removeLocalFolder", "clearSearchSession"] {
            XCTAssertFalse(rerun.contains(forbidden),
                           "重新运行引导不许顺手重置配置：\(forbidden)")
        }
    }

    /// 引导只自动出现一次，之后要有入口能再打开。
    func testMenuOffersRerunningTheWelcomeFlow() throws {
        let code = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(code.contains("Button(\"重新运行欢迎引导…\")"),
                      "菜单里要给回得去的入口")
        XCTAssertTrue(code.contains("model.restartOnboarding()"))
    }

    /// ★ 引导里不许出现实现细节的词汇。
    ///
    /// 新用户不需要知道 DSM / SMB / WebDAV / 端口 / API 是什么；
    /// 这些词出现在引导页上，只会让人觉得「这软件是给我用的吗」。
    func testOnboardingAvoidsImplementationVocabulary() throws {
        let view = codeOnly(try appSource("OnboardingView.swift"))
        for word in ["DSM", "SMB", "WebDAV", "API", "端口", "QNAP", "威联通", "绿联"] {
            XCTAssertFalse(view.contains(word), "引导页不该出现「\(word)」")
        }
    }

    /// ★ 引导用系统原生控件，不摆自绘卡片。
    ///
    /// `FFSettingsSection` 是设置页/向导那套带底色的段落。引导页铺一排这样的卡片，
    /// 立刻就变成「网页安装向导」，而不是 macOS 的设置助手。
    func testOnboardingUsesSystemControlsNotCustomCards() throws {
        let view = codeOnly(try appSource("OnboardingView.swift"))
        XCTAssertFalse(view.contains("FFSettingsSection"), "引导页不摆自绘卡片段落")
        XCTAssertTrue(view.contains("OnboardingPage"), "各步共用一个页头骨架")
    }

    // MARK: - 首次搜索的键位提示

    /// ★ 键位提示只显示一次，而且一动手就收。
    ///
    /// 只显示一次这条最容易漏：少了 `markShown`，它就会每次开搜索窗都冒出来，
    /// 从「提示」变成「每次挡在结果前面的一块东西」。
    func testSearchHintsAreWiredOnceAndOnlyOnce() throws {
        let searchView = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(searchView.contains("model.searchHintsVisible"))
        XCTAssertTrue(searchView.contains("model.dismissSearchHints()"),
                      "输入或操作后要能收起")

        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("SearchHintGuide.shouldShow(preferences: preferences)"),
                      "要不要显示必须问 Core，不能在 App 层另记一个布尔")
        XCTAssertTrue(appModel.contains("SearchHintGuide.markShown(preferences: preferences)"),
                      "显示过之后要落盘，否则每次都会再冒出来")

        let panel = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertTrue(panel.contains("model.showSearchHintsIfNeeded()"),
                      "搜索窗出现时才触发这一次提示")
    }

    // MARK: - 本机搜索开关的落盘

    /// ★ 改搜索方式时必须把「开/关」一起落盘。
    ///
    /// 真 bug：用户先选过「不搜索这台 Mac」（开关落盘为 false），
    /// 之后选「整台 Mac」，开关在内存里变回 true、磁盘上还是 false ——
    /// 重启之后设置页又变回「不搜索这台 Mac」。改一次设置、重启就丢，
    /// 而界面上看不出任何异常。
    func testLocalSearchEnabledIsPersistedWheneverTheModeChanges() throws {
        let controller = codeOnly(try appSource("LocalSourceController.swift"))
        guard let setMode = braceBlock(after: "func setLocalSearchMode", in: controller) else {
            return XCTFail("缺少 setLocalSearchMode")
        }
        XCTAssertTrue(setMode.contains("forKey: \"ff2.localEnabled\""),
                      "setLocalSearchMode 也要写 ff2.localEnabled")
        XCTAssertTrue(setMode.contains("forKey: \"ff2.localSearchMode\""))
    }

    // MARK: - V1.0 正式版：版本号展示与命名

    /// ★ 设置页「通用」必须显示版本号。
    ///
    /// 用户报问题前会先去「通用」找版本，找不到就得去状态栏菜单翻「关于」。
    /// 断言钉在 `generalForm` 这个块里——`contains` 扫全文件会假绿：
    /// `AppVersion` 在别的面板里出现一次就够了，但用户看不到。
    func testGeneralPaneShowsTheAppVersion() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let general = braceBlock(after: "private var generalForm: some View", in: settings) else {
            return XCTFail("缺少 generalForm")
        }
        XCTAssertTrue(general.contains("AppVersion.current"),
                      "「通用」页要显示版本号")
        XCTAssertTrue(general.contains("LabeledContent(\"版本\")"),
                      "版本号按系统表单行呈现，不自绘")
    }

    /// ★ 版本号只能有一个出处，且界面只写版本号、不写构建号。
    ///
    /// 设置页读一次 `Bundle.main`、关于面板再读一次，两处格式迟早分叉，
    /// 同一次安装里出现两个版本号说法。两边都必须走 `AppVersion`。
    ///
    /// `.version: ""` 这一行是**故意的空串**，删掉它系统就会把 Info.plist 里的
    /// 内部序号填进括号，面板变成「版本 1.0.1 (19)」。三种写法都截图实测过。
    func testAboutPanelAndSettingsShareOneVersionSource() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        guard let about = braceBlock(after: "static func show()", in: app) else {
            return XCTFail("缺少 AboutPanel.show")
        }
        XCTAssertTrue(about.contains("AppVersion.shortVersion"),
                      "关于面板的短版本也要走 AppVersion")
        XCTAssertFalse(about.contains("AppVersion.buildNumber"),
                       "构建号不进界面")
        XCTAssertTrue(about.contains(".version: \"\""),
                      "必须显式把括号里那一段清空，否则系统会填上 CFBundleVersion")
        XCTAssertFalse(about.contains("CFBundleShortVersionString"),
                       "关于面板不该自己再读一次 Bundle 键名")
    }

    /// ★ 「检查更新」必须走 Core 的判定，视图里不许另起一套。
    ///
    /// 视图里出现仓库地址、或者自己比一遍版本号，就意味着这份规则有两处：
    /// 改一处漏一处，最后表现成「明明发了新版却说已是最新」。所以这里既要求
    /// **调起来**（按钮接的是 `checkForUpdates`），也要求**不重复实现**
    /// （没有地址、没有 URLSession、没有版本比较）。
    func testAdvancedPaneChecksForUpdatesThroughCore() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let advanced = braceBlock(after: "private var advancedForm: some View", in: settings) else {
            return XCTFail("缺少高级页")
        }
        XCTAssertTrue(advanced.contains("sectionHeader(\"更新\")"),
                      "高级页要有「更新」这一节")
        XCTAssertTrue(advanced.contains("AppVersion.current"),
                      "这一节要显示当前版本，用户才知道在跟哪儿比")
        XCTAssertTrue(advanced.contains("model.checkForUpdates()"),
                      "检查更新按钮要真的接上动作")
        XCTAssertTrue(advanced.contains("updateResultRow("),
                      "结论要摆在按钮下面，不另开窗口")
        XCTAssertTrue(settings.contains("UpdateCheckText.message(for:"),
                      "结论文案走 Core，不在视图里拼字符串")
        XCTAssertTrue(advanced.contains("check-for-updates"),
                      "按钮要挂无障碍标识，键盘与 VoiceOver 靠它定位")
        XCTAssertFalse(advanced.contains("api.github.com"),
                       "仓库地址只能有一处（Core 的 UpdateCheck）")
        XCTAssertFalse(advanced.contains("URLSession"),
                       "请求不该由视图发起")

        let actions = codeOnly(try appSource("AppModel+UpdateCheck.swift"))
        XCTAssertTrue(actions.contains("UpdateCheck.evaluate(current:"),
                      "动作层只转调 Core 的判定")
        XCTAssertTrue(actions.contains("AppVersion.shortVersion"),
                      "当前版本在动作层取，视图不传")
        XCTAssertFalse(actions.contains("isNewer"),
                       "版本比较不许在动作层再现一遍")
        XCTAssertFalse(actions.contains("api.github.com"),
                       "动作层也不该出现仓库地址")
    }

    /// ★ 发出去的正式版不得再带 `trial` 字样。
    ///
    /// 打包脚本的试用版分支要求版本号以 `2.0.0-trial.` 开头。改版本号时忘摘
    /// `-trial.N`，包会被当成正式版发出去，用户看到的还是「试用候选」。
    func testReleaseIdentityCarriesNoTrialSuffix() throws {
        let plist = try clientFile("Resources/Packaging/Info.plist")
        XCTAssertFalse(plist.contains("trial"), "Info.plist 里还留着 trial 字样")
        XCTAssertFalse(plist.contains("试用"), "Info.plist 里还留着「试用」字样")

        // 短版本形如 `1.0` 或 `1.0.0`；构建号是纯数字。打包脚本的正式版分支
        // 用同一个正则卡身份，这里再钉一次——两边任何一侧放宽都会漏出去。
        guard let shortRange = plist.range(of: "<key>CFBundleShortVersionString</key>") else {
            return XCTFail("缺少 CFBundleShortVersionString")
        }
        let after = plist[shortRange.upperBound...]
        guard let valueStart = after.range(of: "<string>"),
              let valueEnd = after.range(of: "</string>") else {
            return XCTFail("CFBundleShortVersionString 没有值")
        }
        let version = String(after[valueStart.upperBound..<valueEnd.lowerBound])
        XCTAssertNotNil(version.range(of: "^\\d+(\\.\\d+){1,2}$", options: .regularExpression),
                        "短版本「\(version)」不是 1.0 / 1.0.0 这种形态")
    }

    // MARK: - 外观选择 / 标题字号 / 应用搜索

    /// ★ 外观状态搬走后必须桥接变更通知。
    ///
    /// 「设置里改了外观，那一行还是旧的」编译能过、运行也不报错——和前几轮
    /// 快捷键、本机来源、向导一模一样的坑，所以锁法也一样：不许是 AppModel 的
    /// `@Published`，且必须真的把 controller 的 objectWillChange 接过来。
    func testAppearanceChangesAreBridgedToAppModel() throws {
        let appModel = try appModelCode()
        let publishedLine = appModel.split(separator: "\n").first { line in
            line.contains("@Published") && line.contains("appearanceChoice")
        }
        XCTAssertNil(publishedLine,
                     "appearanceChoice 不该是 AppModel 的 @Published，应转发到 AppearanceController")
        // ★ 锁动作不锁变量名：只查 `appearanceBridge` 会被它的声明行满足。
        XCTAssertTrue(appModel.contains("appearance.objectWillChange.sink"),
                      "必须把 appearance 的 objectWillChange 接到 AppModel，否则设置里改外观界面不刷新")
    }

    /// ★ 外观选择器必须双向绑定，且真的把外观应用到窗口。
    ///
    /// 三件事一起锁：绑定是真的（`.constant` 是 R01 的成因，不能在新控件上重犯）、
    /// 选项来自 Core（不写死在视图里）、`跟随系统` 是 `nil` 而不是硬套浅色——
    /// 把「跟随系统」实现成浅色，用户改系统外观时闪寻不会跟着变。
    func testAppearancePickerIsTwoWayBoundAndAppliedForReal() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.appearanceChoice"),
                      "外观选择器要绑定到模型")
        XCTAssertFalse(settings.contains("appearanceChoice: .constant"),
                       "外观选择不许用 constant 绑定，点了不改模型")
        XCTAssertTrue(settings.contains("ForEach(AppearanceChoice.allCases)"),
                      "三个选项要由 Core 的 AppearanceChoice 驱动，不能写死在视图里")

        // 排版参考 macOS 系统设置「外观与语言」页——
        // 左标签「外观」+ 右侧分段选择器一行排布。segmented 是这条排版的硬件，
        // 不许退回竖排单选组（radioGroup），那既占地方又和系统里的样子对不上。
        XCTAssertTrue(settings.contains("Picker(\"外观\", selection: appearanceBinding)"),
                      "外观选择器要带「外观」标签，供 LabeledContent 与 VoiceOver 使用")
        XCTAssertTrue(settings.contains(".pickerStyle(.segmented)"),
                      "外观选择器必须是分段样式（参考系统设置），不许用竖排单选组")
        XCTAssertTrue(settings.contains("LabeledContent(\"外观\")"),
                      "外观行要左标签右选择器一行排布（LabeledContent），和系统设置一致")

        let controller = codeOnly(try appSource("AppearanceController.swift"))
        XCTAssertTrue(controller.contains("NSApp.appearance"),
                      "必须真的把外观应用到窗口，只存偏好不算")
        XCTAssertTrue(controller.contains("case .system: return nil"),
                      "「跟随系统」必须是 nil（把决定权交回系统），不是硬套一个浅色")
        XCTAssertTrue(controller.contains("forKey: AppearanceChoice.storageKey"),
                      "偏好 key 只能从 Core 取，不能另写一个字面量")
    }

    /// ★ 启动路径必须先应用外观，再呈现任何窗口。
    ///
    /// 漏了这一句，用户上次选了深色，重启后先闪一下浅色再变——而这种缺陷
    /// 编译能过、运行也不报错。顺序也锁：应用必须发生在 `presentOnboardingOrSearch()`
    /// 之前，否则第一帧就是错的外观。
    func testAppearanceIsAppliedBeforeAnyWindowAppears() throws {
        let code = codeOnly(try appSource("FlashFind2App.swift"))
        guard let launch = braceBlock(after: "func applicationDidFinishLaunching", in: code) else {
            return XCTFail("找不到 applicationDidFinishLaunching")
        }
        guard let applyRange = launch.range(of: "model.applyAppearance()") else {
            return XCTFail("启动路径必须应用上次选的外观")
        }
        guard let presentRange = launch.range(of: "presentOnboardingOrSearch()") else {
            return XCTFail("找不到 presentOnboardingOrSearch")
        }
        XCTAssertLessThan(applyRange.lowerBound, presentRange.lowerBound,
                          "外观要先于任何窗口应用，否则会先闪一下错误外观")
    }

    /// ★ 分段标题必须走字号阶梯，不再用系统默认那套「只差字重」的排版。
    ///
    /// 用户 「不同等级的标题以不同的文字大小区分，当前也有区分
    /// 但是不明显」。这里锁两件事：标题真的用了 Core 的 `SettingsTypography`，
    /// 且字号比正文大一档（否则等于没改）。
    func testSectionHeadersUseTheSharedTypographyScale() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("func sectionHeader("),
                      "分段标题要收在一个 helper 里，字号才有单一出处")
        guard let helper = braceBlock(after: "private func sectionHeader", in: settings) else {
            return XCTFail("找不到 sectionHeader")
        }
        XCTAssertTrue(helper.contains("SettingsTypography.sectionHeader"),
                      "分段标题字号必须来自 Core 的 SettingsTypography")
        XCTAssertTrue(helper.contains(".semibold"),
                      "分段标题保留半粗字重，与正文拉开层次")

        let core = try clientFile("Sources/FlashFindCore/SettingsTypography.swift")
        XCTAssertTrue(core.contains("sectionHeader"), "Core 侧必须登记 sectionHeader 这一级")
        XCTAssertTrue(core.contains("pageTitle") && core.contains("body") && core.contains("caption"),
                      "字号阶梯要覆盖页面标题 / 正文 / 辅助说明各级")
    }

    /// ★ 应用搜索必须真的接进搜索链路，否则功能只是躺在 Core 里。
    ///
    /// 三处接线各锁一处：provider 实例存在、它进了协调器的列表、请求计划带上
    /// 应用来源。少任何一处，用户输入 app 名字都不会有结果——而那种缺陷
    /// 编译能过、运行也不报错。
    func testAppSearchIsWiredIntoTheSearchPipeline() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("AppSearchProvider()"),
                      "要有一个应用搜索 provider 实例")
        guard let changed = braceBlock(after: "onProvidersChanged = ", in: appModel) else {
            return XCTFail("找不到 onProvidersChanged")
        }
        XCTAssertTrue(changed.contains("self.appProvider"),
                      "应用搜索必须进协调器的 provider 列表，否则永远不被请求")

        guard let query = braceBlock(after: "func changedQuery", in: appModel) else {
            return XCTFail("找不到 changedQuery")
        }
        XCTAssertTrue(query.contains("appSourceID: SearchSource.apps.id"),
                      "请求计划必须带上应用来源 ID")
        XCTAssertTrue(query.contains("includeApps: includeLocalSide"),
                      "应用搜索跟随「本机」作用域：NAS 作用域下不搜应用")
    }

    /// ★ 打包脚本要支持正式版命名，且**不能把试用版流程改掉**。
    ///
    /// 正式版包名不带版本号（`闪寻.app`，与 CFBundleDisplayName 一致），
    /// 版本只落在归档文件名与 Info.plist 里；试用版继续用
    /// `FlashFind-<版本>-build<n>`，历史记录与 PM-CLI-004 文档都靠它对齐。
    func testBuildScriptSupportsReleaseNamingWithoutBreakingTrials() throws {
        let script = try clientFile("scripts/build_trial.py")
        XCTAssertTrue(script.contains("--release"), "打包脚本没有正式版开关")
        XCTAssertTrue(script.contains("CFBundleDisplayName"),
                      "正式版应用名要取自 CFBundleDisplayName，而不是另写死一个")
        XCTAssertTrue(script.contains("Unexpected release identity"),
                      "正式版身份要校验（防 -trial 后缀漏摘）")
        XCTAssertTrue(script.contains("Unexpected trial identity"),
                       "试用版身份校验不能被改掉")
        XCTAssertTrue(script.contains("'2.0.0-trial.'"),
                      "试用版身份的前缀约定还在")
    }

    // MARK: - clean clone 下「编译成功但缺 NAS 运行时」必须被挡住

    /// ★ `build.sh app` 不得产出一个缺 NAS 运行时的 App。
    ///
    /// `Resources/MyNAS/` 整份是 `install-mynas-core.sh` 的产物、被 .gitignore 排除，
    /// 所以 clean clone 后一定不在位。而 `Package.swift` 并不把 `mynas-core` 当资源
    /// 依赖 —— 裸 `swift build` 会**编译成功**，产出的 App 直到用户点 NAS 搜索才炸，
    /// 报错落在运行时、指不回构建步骤。这种「成功」比报错贵得多。
    ///
    /// 这里锁的是两条路：**默认明确失败并指路**，或 `--with-core` 先补建再编译。
    /// 不许退回「编译照过、运行时再说」。
    func testBuildScriptRefusesToProduceAppWithoutNASRuntime() throws {
        let script = try clientFile("scripts/build.sh")

        // 1) 编译时确实检查了运行时，而不是只看 Swift 能不能过。
        XCTAssertTrue(script.contains("Resources/MyNAS/bin/mynas-core"),
                      "app 子命令必须检查 MyNAS 核心可执行文件是否在位")
        XCTAssertTrue(script.contains("Resources/MyNAS/native/TrustHTTP"),
                      "原生 HTTPS 助手同样要检查——核心起不来它也得在")

        // 2) 不在位就失败退出，不许继续编译。
        XCTAssertTrue(script.contains("exit 1"),
                      "运行时缺失时必须以非零退出，不能编译照过")

        // 3) 失败信息要指路，否则新人只知道「不行」不知道「下一步跑什么」。
        XCTAssertTrue(script.contains("build.sh core"),
                      "缺失时必须提示先执行 ./scripts/build.sh core")
        XCTAssertTrue(script.contains("--with-core"),
                      "必须提供一条自动补建的显式路径")

        // 4) 正常路径没被改坏：在位时仍然真的去编译 App。
        XCTAssertTrue(script.contains("--product FlashFind2App"),
                      "运行时在位时必须照常编译 App，检查不能喧宾夺主")
    }

    // MARK: - 仓库根必须按内容认定，不靠 `.git` 也不靠目录层级

    /// ★ 打包脚本定位仓库根时，**既不能写死层级，也不能要求 `.git` 存在**。
    ///
    /// 两条都踩过：
    /// - 写死 `client.parents[2]` 是内部布局（<项目根>/03-开发/FlashFind2/client）
    ///   的层级。公开仓里 client 自己就是仓根，那句会指向 /Users 之类的无关目录，
    ///   于是 `--output` 无论写什么都被判成「不在项目内」；clone 到更浅的目录
    ///   则直接 IndexError。
    /// - 靠 `.git` 定位更隐蔽：GitHub 的「Download ZIP」解压出来**没有** `.git`。
    ///   用 `.git` 当必要条件，就会造出「clone 能编、ZIP 不能编」——开发者永远
    ///   走 clone 所以碰不到，CI 也走 checkout 所以也不会红，只有用户会撞上。
    ///
    /// 正确判据是仓库内容：`Package.swift` + `Sources/` + `MyNASCore/`，
    /// 两种拿法里都在，且与 clone 到哪一层无关。
    func testBuildScriptsFindRepoRootByContentNotByGitOrDepth() throws {
        for name in ["scripts/build_trial.py", "scripts/build_mynas_resources.py"] {
            // 只看代码、不看注释：两个脚本的注释里都留着 `parents[2]` 与 `.git`
            // 的**反面理由**（为什么不能用）。按整串全文断言会把理由本身判成违规，
            // 逼着后人删掉理由——那正是这条测试存在的意义被抹掉的方式。
            let script = pythonCode(try clientFile(name))

            XCTAssertFalse(script.contains("parents[2]"),
                           "\(name) 不得按固定目录层级取仓库根：那是内部布局的层级，公开仓里不成立")

            XCTAssertFalse(script.contains("'.git'"),
                           "\(name) 不得把 .git 当作定位仓库根的必要条件：GitHub 的 Download ZIP 解压出来没有 .git")

            for marker in ["Package.swift", "Sources", "MyNASCore"] {
                XCTAssertTrue(script.contains("'\(marker)'") || script.contains("\"\(marker)\""),
                              "\(name) 必须按内容认定仓库根，标记缺 \(marker)")
            }
        }
    }

    /// 去掉 Python 行注释（`#` 到行尾），只留代码。
    ///
    /// 两个脚本里没有含 `#` 的字符串字面量，所以按行截断是安全的；
    /// 真出现了，这里要么失效（断言假绿）要么误伤（断言假红）——
    /// 那时要改成按引号配对切，不能继续假设。
    private func pythonCode(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in
                guard let hash = line.firstIndex(of: "#") else { return String(line) }
                return String(line[line.startIndex..<hash])
            }
            .joined(separator: "\n")
    }

    // MARK: - 局域网设备按类型筛选（用户 ）

    /// ★ `Info.plist` 必须声明**每一个**被浏览的 Bonjour 服务类型。
    ///
    /// 这是本项目踩过的坑：不声明 `NSBonjourServices`，`NetServiceBrowser`
    /// 会**静默查不到任何东西**——不报错、不崩溃，就是列表永远是空的。
    /// 加服务类型却忘了同步 plist，是这类哑火最容易复发的地方。
    func testEveryBrowsedServiceTypeIsDeclaredInInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let plistURL = root.appendingPathComponent("Resources/Packaging/Info.plist")
        let data = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: data, options: [], format: nil)
        guard let dict = plist as? [String: Any],
              let declared = dict["NSBonjourServices"] as? [String] else {
            return XCTFail("Info.plist 里读不到 NSBonjourServices，局域网发现会集体哑火")
        }

        for type in NetworkDiscovery.browsedServiceTypes {
            XCTAssertTrue(declared.contains(type),
                          "\(type) 在浏览清单里但没写进 NSBonjourServices，浏览器会查不到它且不报错")
        }
    }

    /// ★ 必须浏览 `_device-info._tcp`：它是区分 Mac 与 NAS 的唯一依据。
    ///
    /// macOS 访达靠它 TXT 里的 `model=` 区分设备图标；实测用户局域网的群晖报
    /// `model=Xserve`。不浏览它，所有设备都只能判成「未知」，筛选就失效了。
    func testDiscoveryBrowsesDeviceInfoService() {
        XCTAssertTrue(NetworkDiscovery.browsedServiceTypes.contains("_device-info._tcp"),
                      "不拿 _device-info 就没有型号，判别不了电脑和 NAS")
    }

    /// ★ App 层必须取 TXT 里的 `model=`，并把判定交给 Core。
    ///
    /// 类型怎么判是 Core 里能被测试锁住的逻辑；App 层只负责把「这台设备报了什么」
    /// 的事实汇过去。App 层自己写 if 判断，等于把同一次判定劈成两半。
    func testAppLayerReadsModelAndDelegatesClassificationToCore() throws {
        let discovery = codeOnly(try appSource("LocalNetworkDiscovery.swift"))
        XCTAssertTrue(discovery.contains(#"key: "model""#),
                      "要读 _device-info 的 TXT model= 字段，否则拿不到设备型号")
        // ★ 判定走 Core 的 `makeDevices`（内部再走 DeviceClassifier.classify(_:)）。
        //   App 层只产 DeviceEvidence（事实），不许自己判「这是什么」。
        XCTAssertTrue(discovery.contains("NetworkDiscovery.makeDevices"),
                      "装配与判定必须交给 Core 的 makeDevices，不许在 App 层自己判")
        XCTAssertFalse(discovery.contains("func kind(") || discovery.contains("classify(model")
                       || discovery.contains("DeviceClassifier.classify("),
                       "App 层不该自己实现类型判定")
    }

    /// ★ 向导里默认只列**明确识别**的设备；未知设备只进「显示全部」。
    ///
    /// 认不出的设备若全留在默认列表，实测一个网段 111 台在线主机里
    /// 108 台只有 ARP/端口证据，全列出来用户照样找不到 NAS。
    func testWizardDefaultsToIdentifiedDevicesAndKeepsShowAll() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("NetworkDiscovery.shownByDefault"),
                      "默认列表要走 shownByDefault：只有 NAS 与文件服务器出现")
        XCTAssertTrue(wizard.contains("showAllNearbyDevices"),
                      "要有「显示全部」的开关，误判的代价不该由用户承担")
        // 直接用全部设备平铺 = 回到用户反馈的那个问题。
        XCTAssertFalse(wizard.contains("ForEach(discovery.devices)"),
                       "不要把全部局域网设备平铺出来")
    }

    /// ★ 端口不许再被硬掰成 5001 —— Mac 也广播 `_smb._tcp`。
    ///
    /// 为了让群晖的 SMB（报 445）能接着走登录，若把凡是 `_smb` 的端口一律
    /// 改成 5001，Mac 也会被连坐 —— 它同样广播 `_smb`，于是被标成 `:5001`，
    /// 同一个 IP 上就出现了两个端口。现在一律用服务自己报的
    /// 端口，这条锁住不许退回去。
    func testDiscoveryDoesNotRewritePortsByServiceType() throws {
        let discovery = codeOnly(try appSource("LocalNetworkDiscovery.swift"))
        let body = try XCTUnwrap(braceBlock(after: "static func preferredPort(", in: discovery),
                                 "preferredPort 必须存在，端口映射只允许写在那里")
        XCTAssertFalse(body.contains("_smb"),
                       "不许再按 _smb 改写端口：Mac 同样广播 _smb，会被连坐")
        XCTAssertFalse(body.contains("5001"),
                       "不许把端口硬写成 5001（那是群晖 DSM 的端口，不是通用的）")
    }

    /// ★ 发布前必须把所有来源的证据**归并**成设备，否则同一台设备会占多行。
    ///
    /// 实测群晖同时出现在 5001（DSM）与 548（AFP），用户看到的是「两台 demo-synology」；
    /// 而 DS1621+ 有三块网卡（.88 / .152 / 192.0.2.4），不按序列号归并就是「三台 NAS」。
    ///
    /// 归并键是 IP + 序列号 + MAC，不在 App 层做——`DeviceMerger` 是能被测试锁住的纯函数。
    func testDiscoveryDeduplicatesByHostBeforePublishing() throws {
        let discovery = codeOnly(try appSource("LocalNetworkDiscovery.swift"))
        let body = try XCTUnwrap(braceBlock(after: "private func publish(", in: discovery),
                                 "publish 必须存在")
        XCTAssertTrue(body.contains("DeviceMerger.merge"),
                      "publish 前必须把所有来源的证据交给 DeviceMerger 归并，否则同一台设备占多行")
        XCTAssertTrue(body.contains("devices = NetworkDiscovery.makeDevices"),
                      "归并结果必须真的装配并赋给 devices，只调用不赋值等于没做")
        // 五路来源的证据都得汇进去，漏一路就会退化成单一协议决定界面。
        for source in ["bonjourEvidence", "arpEvidence", "synologyEvidence",
                       "ssdpEvidence", "probeEvidence"] {
            XCTAssertTrue(body.contains(source), "\(source) 必须汇进归并，否则单一协议就能决定界面")
        }
    }

    /// ★ 网段探测必须**边扫边发**，不能等整轮扫完才出结果。
    ///
    /// 实测：一个不存在的地址会把三个端口各耗到 1.2s 超时
    /// （同网段 ARP 无响应）→ 3.6s/台；253 台 ÷ 20 并发 ≈ **45 秒**才扫完一轮。
    /// 用户那台 `192.0.2.88`（不广播 mDNS 的群晖）大约第 16 秒就被探到了，
    /// 但因为 `publish()` 只在 `finishScan()` 里调一次，它要等满 45 秒才出现——
    /// 而 Bonjour 那两台的回调是增量发的，于是界面看起来「扫完了」，
    /// 用户自然认为「.0.88 没被识别出来」。
    ///
    /// 所以锁的是**循环体内**有 publish，不是函数里有。
    func testSubnetScanPublishesAsItGoes() throws {
        let discovery = codeOnly(try appSource("LocalNetworkDiscovery.swift"))
        let scan = try XCTUnwrap(braceBlock(after: "func probeOnlineHosts(", in: discovery),
                                 "TCP fallback 探测（probeOnlineHosts）必须存在")
        let loop = try XCTUnwrap(braceBlock(after: "for await hit in group", in: scan),
                                 "收结果的循环必须存在")
        XCTAssertTrue(loop.contains("publish()"),
                      "循环里命中一台就要 publish 一次；只在 finishScan 里发一次，用户要干等 45 秒")
        XCTAssertTrue(loop.contains("probeEvidence"),
                      "发布前要把新命中的那台并进 probeEvidence，否则发了也还是旧列表")
    }

    /// ★ TCP 扫描必须降级成 fallback：只对 ARP 说「在线」的主机扫。
    ///
    /// 实测：整网 253 个地址 × 4 端口 ≈ **33.5 秒**，
    /// 而先读 ARP 表（0.01 秒）拿到 128 台在线主机再扫只要 **12.2 秒**。
    /// 且端口命中本身不产生默认显示资格——开着 445 的机器可能是任何东西。
    func testTCPProbeIsAFallbackBehindARP() throws {
        let discovery = codeOnly(try appSource("LocalNetworkDiscovery.swift"))
        let scan = try XCTUnwrap(braceBlock(after: "func probeOnlineHosts(", in: discovery),
                                 "probeOnlineHosts 必须存在")
        XCTAssertTrue(scan.contains("onlineHosts"),
                      "TCP 探测的候选必须来自 ARP 的在线主机，不是整网枚举")
        XCTAssertTrue(scan.contains("subnetHosts"),
                      "拿不到 ARP 表时才退回整网扫描——那时仍要扫，否则发现功能整个没了")
        // 顺序：ARP 先，TCP 后。
        let pipeline = try XCTUnwrap(braceBlock(after: "func runPipeline(", in: discovery),
                                     "runPipeline 必须存在")
        let arpIndex = try XCTUnwrap(pipeline.range(of: "ARPTableReader.read")?.lowerBound,
                                     "流水线里必须有 ARP 这一步")
        let tcpIndex = try XCTUnwrap(pipeline.range(of: "probeOnlineHosts")?.lowerBound,
                                     "流水线里必须有 TCP fallback")
        XCTAssertTrue(arpIndex < tcpIndex, "ARP 必须排在 TCP 探测前面，否则 fallback 就退化成整网扫")
    }

    // MARK: - 已选文件夹模式（OSS-08）

    /// ★ 发起搜索时必须把「本机搜索方式」一起交给 provider。
    ///
    /// 缺口不在定义而在调用点：`LocalFolderSearch` 那套遍历实现写好了、测试也全绿，
    /// 可产品代码里没人调它。结果是界面写着「已选文件夹（无需系统索引）」、索引
    /// 关着时还主动引导用户切过来，而切过来之后一搜就失败——用户被我们自己的
    /// 提示领进死路。
    ///
    /// 只给 `folders` 不够：从「已选文件夹」切回「整台 Mac」时挑过的文件夹
    /// **仍留在 `localFolders` 里**（切回去还要用，切换方式不清空它们），
    /// 于是 provider 光看 folders 会以为还在文件夹模式。
    func testSearchHandsTheLocalSearchModeToTheProvider() throws {
        let code = try appModelCode()
        guard let changedQuery = braceBlock(after: "func changedQuery(", in: code) else {
            return XCTFail("找不到 changedQuery，下面的断言会假绿")
        }
        // ★ 2026-10-21（6.3b-4）：赋值搬进了 `applyLocalScopeToProvider`。
        //   MCP 执行侧也要套同一份范围，两处各写一遍就会出现「GUI 套了、Agent 没套」。
        XCTAssertTrue(changedQuery.contains("applyLocalScopeToProvider()"),
                      "搜索前必须把当前的本机范围交给 provider")

        guard let apply = braceBlock(after: "func applyLocalScopeToProvider(", in: code) else {
            return XCTFail("找不到 applyLocalScopeToProvider，下面的断言会假绿")
        }
        XCTAssertTrue(apply.contains("localProvider.folders = localFolders"),
                      "搜索前必须把当前选的文件夹交给 provider")
        XCTAssertTrue(apply.contains("localProvider.mode = localSearchMode"),
                      "搜索方式必须和文件夹一起给，否则 provider 判不出该走哪条路")
        // 两条必须同处一次装配：分开写在别处的话，改了一个另一个还是旧的。
        XCTAssertTrue(
            apply.contains("localProvider.folders = localFolders\n        localProvider.mode = localSearchMode"),
            "方式要与文件夹在同一处装配，避免只有定义、没有调用点")
        // MCP 那条调用点由产品级跨进程 E2E 守（`ProductAssemblyE2ETests`）：
        // 这里再断言一遍会让「删掉 MCP 那边的调用」有两条用例同时红，
        // 红证就归因不到唯一一条了。
    }

    /// ★ 测试启动钩子必须 **DEBUG-only**。
    ///
    /// 它能让进程绑到任意 socket 路径、并读一组内存偏好。这些在开发构建里是
    /// 测试设施，在**发布二进制里就是「谁设了环境变量谁说了算」**——所以整个文件
    /// 包在 `#if DEBUG` 里，发布构建根本不含这个符号，任何漏在外面的引用都会
    /// 在 release 编译时直接失败。
    func testTheE2ELaunchHookCannotReachReleaseBuilds() throws {
        let hook = try appSource("DebugSupport/E2ELaunchMode.swift")
        XCTAssertTrue(hook.hasPrefix("#if DEBUG"),
                      "整个文件必须包在 `#if DEBUG` 里，否则发布构建里也有这个符号")
        XCTAssertTrue(hook.contains("FF_E2E_LAUNCH"), "启动开关的名字只在这里读")

        // 注释里的那句说明不算：只看代码行。
        let authority = codeOnly(try appSource("MCPAuthority.swift"))
        let marker = try XCTUnwrap(authority.range(of: "FF_AUTHORITY_SOCKET"),
                                   "socket 覆盖不见了；它若被删，6.3b-4 的 E2E 会静默失败")
        XCTAssertTrue(authority[..<marker.lowerBound].contains("#if DEBUG"),
                      "socket 覆盖必须夹在 `#if DEBUG` 里")
    }

    func testStartupDoesNotReadOrMigrateStoredSecrets() throws {
        let model = codeOnly(try appSource("AppModel.swift"))
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertFalse(model.contains("consolidateCredentialsIfNeeded()"))
        XCTAssertFalse(app.contains("CredentialStore.migrate"), "迁移也可能弹授权框，不能放在启动路径")
        XCTAssertTrue(model.contains("autoConnectSavedSources()"), "保留已解锁缓存的后台连接能力")
    }

    func testExplicitLoginMayRequestKeychainAuthorization() throws {
        let wizard = try appSource("NASSourceWizardController.swift")
        let connect = try XCTUnwrap(braceBlock(after: "func connectDraft()", in: wizard))
        XCTAssertTrue(connect.contains("nativeNASPassword.isEmpty &&"), "已输入密码时不能额外索取钥匙串授权")
        XCTAssertTrue(connect.contains("allowInteraction: true"))
        let button = try XCTUnwrap(braceBlock(after: "var canConnectDraft:", in: wizard))
        XCTAssertTrue(button.contains("hasStoredPassword: canRequestStoredPasswordForDraft"),
                      "尚未解锁钥匙串也必须能点击连接，否则用户只能重新输入密码")
        let actions = try appSource("AppModel+SourceActions.swift")
        for name in ["func reconnectSource(", "func reconnectUsingStoredCredential("] {
            let body = try XCTUnwrap(braceBlock(after: name, in: actions))
            XCTAssertTrue(body.contains("allowInteraction: true"), "主动登录必须允许系统请求授权")
        }
    }

    // MARK: - 密码框下方的提示（2026-10-24 用户要求删除）

    /// ★ 密码框下方那行「将使用本机保存的密码」必须删掉。
    ///
    /// 用户在截图上把这句话圈出来写了「删除」。它是**提示备注**：
    /// 标题已经说清的事（密码框就是密码框），再补一句解释反而添乱。
    /// 项目规矩：做新 UI 一律不许写这类备注。
    ///
    /// 顺带把「依赖 `nativeNASPassword` 的条件视图」整类风险消掉了：
    /// 条件视图随每次按键增删子视图 → SwiftUI 重建密码框区块 →
    /// 重建瞬间按钮可用性判断读到空值 → 「填了密码却点不了连接」。
    /// 现在这个位置没有任何条件子视图。
    func testPasswordFieldHasNoStoredPasswordHintUnderneath() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertFalse(wizard.contains("将使用本机保存的密码"),
                       "用户点名删掉这句提示，不许再回来")
        XCTAssertFalse(wizard.contains("keychainHint"),
                       "提示没了，keychainHint 也不该再被视图引用")
        XCTAssertTrue(wizard.contains("PlainSecureField(text: $model.nativeNASPassword"),
                      "密码框本身必须还在")
    }

    /// 全 App 层扫一遍：那句提示不许换个文件再出现一次。
    func testNoAppSourceMentionsTheStoredPasswordHint() throws {
        let dir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/FlashFind2App")
        let files = try FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "App 源码目录读不到，本条断言失去意义")
        for url in files {
            let text = try String(contentsOf: url, encoding: .utf8)
            let code = codeOnly(text)
            XCTAssertFalse(code.contains("将使用本机保存的密码"),
                           "\(url.lastPathComponent) 里又出现了这句提示备注")
        }
    }

    // MARK: - 动态码死循环（2026-10-24 用户报障）

    /// ★ App 层必须走 Core 的 `NASCredentialPick` 取凭据。
    ///
    /// 死循环的根因是「密码从钥匙串取」的那一路把动态码丢了：
    /// 重连仍不带码 ⇒ 服务端仍回 402 ⇒ 又弹一次 OTP 框 ⇒ 停不下来。
    /// 「手输密码」那条路带码，于是现象像「只有空密码才死循环」。
    ///
    /// 规则搬进 Core 后有单元测试（`NASCredentialPickTests`）守着；
    /// 这里守的是**App 层不许再自己写一套取值**——自己写就等于把那条丢码的路又写回来。
    func testWizardTakesCredentialsFromTheCorePicker() throws {
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertTrue(controller.contains("NASCredentialPick.pick("),
                      "取值必须走 Core 的 NASCredentialPick，两条路共用一个出口")
        XCTAssertFalse(controller.contains("PendingCredential(password: saved, otp: nil)"),
                       "钥匙串那条路不许把动态码写死成 nil —— 那就是死循环的根因")
        XCTAssertFalse(controller.contains("otp: nil)"),
                       "凭据构造里不许出现写死 nil 的动态码")
    }

    // MARK: - 空格预览（2026-10-26 用户要求恢复）

    /// ★ 上一条报障的成因是「导航状态用错了快照」，这条锁住它。
    ///
    /// `Coordinator` 在按键**那一刻**读 `hasSelectableResult` 决定这次按键是不是
    /// 「已经在用方向键选结果」。真实搜索路径**不会**自动选中第一条
    /// （只有 fixture 会写 `selected = results.first?.id`），所以按下第一次 ↓ 时
    /// `selectedResult` 必定还是 nil。若这里传的是 `selectedResult != nil`，
    /// 第一次 ↓ 记下的就是「没在导航」⇒ 紧接着按空格仍然只打出一个空格，
    /// 用户得按两次方向键才看得到预览 —— 与「空格预览加回来了」的承诺相反。
    ///
    /// 判据：这一路要问的是「**有没有可选的条目**」，而不是「已经选中了没有」。
    func testSpacePreviewDoesNotWaitForAPreselectedRow() throws {
        let view = codeOnly(try appSource("SearchView.swift"))
        let start = try XCTUnwrap(view.range(of: "SearchKeyboardScope(enabled: true"),
                                  "搜索浮窗必须挂键盘作用域")
        let tail = String(view[start.lowerBound...])
        let end = try XCTUnwrap(tail.range(of: ".frame(width: 0, height: 0)"),
                                "作用域后面应紧跟零尺寸修饰符，取不到就说明切片点失配")
        let scope = String(tail[tail.startIndex..<end.lowerBound])

        let argument = try XCTUnwrap(
            scope.split(separator: "\n").first(where: { $0.contains("hasSelectableResult:") }),
            "必须显式传 hasSelectableResult")
        XCTAssertFalse(argument.contains("selectedResult"),
                       "不能用「已经选中」当判据：第一次按 ↓ 时它必为 nil，导航不会激活。实际：\(argument)")
        XCTAssertTrue(argument.contains("results.isEmpty"),
                      "要按「有没有可选条目」判定。实际：\(argument)")
    }

    /// 点击、键入、命令模式都必须能把「导航」状态推回文本输入。
    ///
    /// 承诺是「输入文字时空格照常输入」：只要还有一条路径不给 `navigation` 复位，
    /// 用户就会撞上「选中结果后想打个空格，结果跳出预览窗口」。
    func testTypingAndClickingReleaseTheSpaceKeyBackToTextInput() throws {
        let scope = codeOnly(try appSource("SearchKeyboardScope.swift"))
        XCTAssertTrue(scope.contains("if event.type == .leftMouseDown"),
                      "左键点击必须单独处理")
        XCTAssertTrue(scope.contains("self.navigation.reset()"),
                      "点击结果行后要交还空格：否则焦点回到输入框时空格仍被吞")
        XCTAssertTrue(scope.contains("navigation.record(route, hasResult: self.hasSelectableResult)"),
                      "导航记录必须用同一份 hasSelectableResult")
        XCTAssertTrue(scope.contains("c.navigation.reset()"),
                      "query 变化（用户继续打字）时必须复位导航")
    }

    /// 预览面板自己也要能收空格 —— 那时按键的 window 已经不是搜索浮窗了。
    ///
    /// `SearchKeyboardScope` 的监视器只处理搜索浮窗自己的事件；预览面板一开就变成
    /// key window，空格没人接 ⇒ 只能按 esc（还得先点回面板）。承诺的是「再按一次关闭」。
    func testPreviewPanelClosesOnSpaceItself() throws {
        let code = codeOnly(try appSource("QuickLookPreview.swift"))
        XCTAssertTrue(code.contains("func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool"),
                      "预览面板必须实现 handle 事件代理方法")
        XCTAssertTrue(code.contains("event.keyCode == 49"),
                      "要认的是空格（keyCode 49）")
        XCTAssertTrue(code.contains("panel.orderOut(nil)"),
                      "空格要关闭面板")
        XCTAssertTrue(code.contains("if panel.isVisible, sameItem"),
                      "同一个文件再按一次应当关闭（要先判 isVisible + sameItem），而不是重新弹一次")
    }

    /// ★ 钥匙串授权框关掉之后，设置窗口必须被主动提回最前。
    ///
    /// 用户原话（2026-10-26）：「每次更新重新登陆后，输入钥匙串密码后，
    /// 闪寻设置界面就闪退了」。查下来既不是崩溃也不是退出：
    ///
    /// - 统一日志 17:24:38 把进程状态记成 `running-active-NotVisible`，
    ///   **pid 一直活到 17:25:14 之后**；
    /// - 没有 AppKit 的 `finishing close`，**窗口也没关**；
    /// - 崩溃报告机制同时段用段错误程序验证过（立刻产出 `.ips`），而闪寻没有报告。
    ///
    /// 真因是层叠：授权框属于系统（SecurityAgent），框一关系统把激活还给
    /// **先前活跃的另一个 App**；闪寻是 `LSUIElement` 常驻应用，实测 `frontmost`
    /// 恒为 `false`、`activate` 不生效，于是设置窗口被压到对方窗口后面，
    /// 屏幕上只剩对方 —— 看着就是「界面凭空消失」。日志里对应
    /// `FUSBProcessWindowState: occluded`。
    ///
    /// 这条守两件事：① 有人订阅「交互式读凭据」（没人订阅 = 没修）；
    /// ② 提回前台走已有的 `restorePresentedPreferencesWindow`，且**提两次**
    ///    （立即一次 + 隔一拍一次：激活交接是异步的）。
    func testInteractiveCredentialReadBringsPreferencesWindowForward() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        XCTAssertTrue(app.contains("CredentialStore.onInteractiveRead = {"),
                      "没人订阅交互式读凭据 —— 钥匙串框关掉后设置窗口会沉到别的 App 后面")
        XCTAssertTrue(app.contains("bringPreferencesForwardAfterSystemPrompt()"),
                      "订阅了却没把窗口提回前台")

        let restore = codeOnly(try appSource("WindowRestore.swift"))
        let forward = try body(of: "bringPreferencesForwardAfterSystemPrompt", in: restore)
        let calls = forward.components(separatedBy: "raisePresentedPreferencesWindow()").count - 1
        XCTAssertEqual(calls, 2,
                       "要提两次：框关掉系统才把激活还给对方，只提一次会被重新压上来（实际 \(calls) 次）")

        // ★ 承重的是「激活」这一句。实测（build 56 测量包 18:31:49.933）：
        //   非激活态下只调 makeKeyAndOrderFront，`keyWindow` 仍为 nil、`isActive` 仍为 0，
        //   窗口整组留在前台 App 下面 700 ms 都没翻上来。把它删掉＝这个缺陷复发。
        let raise = try body(of: "raisePresentedPreferencesWindow", in: restore)
        XCTAssertTrue(raise.contains("NSApp.activate"),
                      "提窗口前必须先激活应用：非激活态下 makeKeyAndOrderFront 不生效")
        XCTAssertTrue(raise.contains("restorePresentedPreferencesWindow("),
                      "激活之后还得把窗口排到最前")
    }

    /// 按名字取一个函数的函数体（含外层花括号）。括号配平。
    ///
    /// ★ 用配平切块而不是全局 `contains`：`isSourceReady` 这种词在别处也有，
    /// 全局搜到就等于没证明「是这一条路径做的判断」。
    private func body(of name: String, in source: String) throws -> String {
        // 方法与被计算的属性都要取得到：`commandSources` 是 `var x: T { … }`，
        // 只认 `func` 的话它会直接判「找不到」—— 而那条断言守的正是它。
        var signature: Range<String.Index>?
        for anchor in ["func \(name)(", "var \(name):", "var \(name) "] {
            if let found = source.range(of: anchor) { signature = found; break }
        }
        guard let signature else {
            XCTFail("App 层找不到 func/var \(name)，名字改了要同步改这条断言")
            return ""
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
        XCTFail("func \(name) 的花括号没有配平")
        return ""
    }

    /// ★ 选了「未连接的来源」的位置必须当场发起连接。
    ///
    /// 2026-10-26 报障「位置没有生效，只能检测到本机的」共两处：
    /// ① Core 侧按 `ready` 过滤候选取（已改，`SearchLocationTests` 守着）；
    /// ② App 侧选了候选却不连 —— 候选能看见、点了没反应，比藏起来更糟。
    /// 这一条守的是 ②：它写在 executableTarget 里，只能扫源码。
    func testApplyingAnOfflineLocationStartsAConnection() throws {
        let code = try appModelCode()
        let apply = try body(of: "applySearchTarget", in: code)
        XCTAssertTrue(apply.contains("isSourceReady"),
                      "要不要连接必须由来源就绪状态判定，不能无条件连")
        XCTAssertTrue(apply.contains("connectSourceForSearch"),
                      "未就绪就必须当场连，不能只设限定就走人")

        let connect = try body(of: "connectSourceForSearch", in: code)
        XCTAssertTrue(connect.contains("interactiveOTP: true"),
                      "这是用户主动点的路径：设备要动态码必须当场弹框，"
                      + "不能等用户再点一次登录（与 OTP 报障同源）")
        XCTAssertTrue(connect.contains("searchWarnings"),
                      "连不上（没存密码）时要在搜索面板上说一句，否则界面像没反应")

        // 位置候选里的来源必须带**真实**就绪状态：写死 true 会让副标题永远不标
        // 「未连接」，用户就不知道点了还得等一次连接。
        let sources = try body(of: "commandSources", in: code)
        XCTAssertTrue(sources.contains("ready: nativeProviders[config.id]?.ready == true"),
                      "ready 要照实取；键是 config.id（nativeProviders 就是这么建的），"
                      + "用 sourceID 查在 id 含非法字符时会永远查不到")
        XCTAssertTrue(sources.contains("filter(\\.enabled)"),
                      "只列已启用的来源：停用的来源不该出现在位置面板里")
    }

    // MARK: - 命令面板：顺序与数字快捷键

    /// ★ 设置 ▸ 搜索页必须给出**一段两栏**：左位置、右类型，各带拖动排序 + 数字键。
    ///
    /// 这一段守的是「入口在不在、入口在不在同一处」。规则（怎么排、第几行是几号）
    /// 在 Core，界面只把动作接给模型 —— 所以这里同时要求界面**不自己算编号**。
    func testSearchSettingsExposeQuickPickOrderAndKeys() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        let searchForm = try body(of: "searchForm", in: settings)
        // 用户 2026-10-26 手绘定稿：一个「命令快捷键」标题下左右并排，
        // 不再拆成上下两段（拆开时要来回看才知道两个 2 撞不撞）。
        XCTAssertEqual(searchForm.components(separatedBy: "QuickPickSettingsSection(").count - 1, 1,
                       "两栏必须在同一段里：拆成两段就又回到「来回看」的老样子")
        XCTAssertEqual(searchForm.components(separatedBy: "QuickPickColumn(").count - 1, 2,
                       "左「搜索位置」右「文件类型」，缺一栏等于只做了一半功能")
        for title in ["搜索位置", "文件类型"] {
            XCTAssertTrue(searchForm.contains("title: \"\(title)\""),
                          "栏标题必须是「\(title)」：用户要的就是这两个词")
        }
        for kind in [".location", ".fileType"] {
            XCTAssertTrue(searchForm.contains("kind: \(kind),"),
                          "\(kind) 那一页要写明自己是哪个面板：页签初始选中与恢复默认都靠它")
            XCTAssertTrue(searchForm.contains("rows: model.quickPickRows(\(kind))"),
                          "\(kind) 那一栏的数据必须来自模型的同一个入口（面板与设置页共用顺序）")
            // ★ 2026-10-27 定稿：行尾的号只读，排序只留「拖」；删掉与换掉走右键。
            //   三条动作都必须接到 Core，不许界面自己改一份内存里的顺序。
            XCTAssertTrue(searchForm.contains("onDelete: { model.deleteQuickPick(\(kind), id: $0) }"),
                          "\(kind) 的右键删除必须落到 Core 的隐藏表（只跳过界面那一行，下次刷新它又回来了）")
            XCTAssertTrue(searchForm.contains("onReplace: { model.replaceQuickPick(\(kind), id: $0, with: $1) }"),
                          "\(kind) 的替换必须落到「同一位次换人」")
            XCTAssertTrue(searchForm.contains("replacements: { model.quickPickReplacements(\(kind), id: $0) }"),
                          "\(kind) 的替换候选取自 Core：界面各算一份迟早多出一条重复项")
            XCTAssertTrue(searchForm.contains("moveQuickPick(\(kind), from: $0, to: $1)"),
                          "\(kind) 要支持拖动排序")
        }

        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        XCTAssertEqual(section.components(separatedBy: "Section {").count - 1, 1,
                       "只有一段：多段就会多出一个标题，页签也就散了")
        // 用户 2026-10-26 二次定稿：点页签切换，切换时内容向左滑。
        XCTAssertTrue(section.contains("pickerStyle(.segmented)"),
                      "两页要能点着切（分段控件），不能又回到并排两栏")
        XCTAssertFalse(section.contains("HStack(alignment: .top"),
                       "并排两栏已经废弃：半宽放不下长名字")
        // ★ 判在 `select(_:)` 的函数体里：整份文件另有一处 `withAnimation(.spring(`
        //   （落手升/降温），拿全文查 `withAnimation(` 的话这条断言是聋的
        //   —— build 66 第一轮变异（把切页动画摘掉）就绿着跑过去了。
        let selectBody = try body(of: "select", in: section)
        XCTAssertTrue(selectBody.contains("withAnimation(.easeOut("),
                      "切换必须有动画，否则内容凭空换掉、看不出是换页")
        XCTAssertTrue(section.contains(".transition(slideTransition)"),
                      "切页要挂位移过渡：只有状态变、没有过渡等于瞬切")
        // ★ 审查 F02：`transition` 只在视图**插入/移除**时求值。只换参数、
        //   不换身份，过渡一次都不会跑（内容会变、高度会变，看起来「像是动了」）。
        XCTAssertTrue(section.contains(".id(columns[chosenIndex].kind)"),
                      "★ 页面身份必须绑到页签上：少了它，`transition` 永远不触发（审查 F02）")
        XCTAssertTrue(section.contains("removal: .offset(x: forward ? -slide : slide)"),
                      "旧页要往反方向滑走：只淡出、不位移就没有「换页」的方向感")
        XCTAssertTrue(section.contains("forward = next > chosenIndex"),
                      "方向要在换页之前定下来（换完之后再比就比不出前后了）")
        XCTAssertTrue(section.contains(".clipped()"),
                      "滑出去的那一页必须裁掉，否则压到段落外面")
        XCTAssertTrue(section.contains(".onDrag"), "没有起拖，用户就没法排序")
        XCTAssertTrue(section.contains(".onDrop"), "只有起拖没有落点判定，拖了也不生效")
        // ★ 2026-10-27 定稿：行尾的号码**只读**，不再是下拉选择器。
        //   上一版那里是「选个号把行搬过去」—— 与拖动是同一件事的两种写法，
        //   两套入口摆在一起，用户得先分辨哪个才是排序。
        XCTAssertFalse(section.contains("private func keyPicker"),
                       "行尾不许再是选择器：排序只留拖动一个入口")
        XCTAssertEqual(section.components(separatedBy: "Picker(").count - 1, 1,
                       "整段只该有一个 Picker —— 页签那个分段控件")
        XCTAssertTrue(section.contains("row.key.map(String.init)"),
                      "行尾号码必须来自 Core 算好的行号，界面不许自己数")
        XCTAssertFalse(section.contains("onChooseKey"), "旧的「选数字」入口必须彻底消失")
        XCTAssertFalse(section.contains("SearchCommandNumbering.numberedLimit"),
                       "设置页不再算「能选几档」：那档数已经随选择器一起删掉了")
        // ★ 拖起来是**整行虚影**，不是一个小把手图标（用户 2026-10-27）。
        XCTAssertTrue(section.contains("} preview: {"), "起拖必须带预览：没有 preview 就退回系统对把手拍的快照")
        XCTAssertTrue(section.contains("QuickPickDragPreview(row: row)"),
                      "虚影必须是整行（标题/副标题/号码），行名才是身份")
        // ★ 放下之后从原位置升/降到新位置，而不是瞬移。
        XCTAssertTrue(section.contains("withAnimation(.spring("),
                      "落手要包在动画事务里：`ForEach` 的 id 稳定，包了才会做位置插值")
        // ★ 右键：删掉 / 替换成别的位置或格式（用户 2026-10-27）。
        XCTAssertTrue(section.contains(".contextMenu"), "整行要有右键菜单")
        XCTAssertTrue(section.contains("\"删除该快捷方式\""), "右键第一项是删除")
        XCTAssertTrue(section.contains("Menu(\"替换为\")"), "右键还要能把这一行换成别的位置/格式")
        XCTAssertFalse(section.contains("onAssign"), "旧版的「指定键」入口必须彻底消失，不许留两套语义")
        XCTAssertFalse(section.contains("maxVisible"), "行数上限是面板的事，设置页不该再算一遍")
        // ★ 预览钩子只能落在预览构建里：少了 `isPreview` 这道门，
        //   正式版用户设一个环境变量就能把设置页开在第二页。
        XCTAssertTrue(section.contains("AppEnvironment.isPreview"),
                      "初始页签的预览钩子必须有 isPreview 守卫")
        // ★ 拖动状态必须是一栏一份：做成子视图，`@State` 自然每栏一个实例；
        //   放在容器层就会让左栏的落点高亮闪到右栏去。
        XCTAssertTrue(section.contains("private struct QuickPickColumnView"),
                      "栏要单独成视图：两栏的拖动状态各归各的，不许共用一个落点")
    }

    /// ★ 审查 F01：排序拖拽的载荷里不许装行 id。
    ///
    /// 位置行的 id 是 `target:<来源标识>:<根路径>`，根路径就是用户 NAS 上的
    /// 部门／客户／项目文件夹名。拖拽是**跨应用**通道：用 `NSString` 造 provider，
    /// 系统会顺带注册 `public.utf8-plain-text` 与 `public.url` 两种公开表示，
    /// 拖到任何一个接受文本的地方，接收方都能读出这份路径。
    ///
    /// 本地排序只需要「是本窗口在拖」，标识本来就存在内存里的 `draggingID`，
    /// 载荷退化成常量标记即可。
    func testQuickPickDragPayloadCarriesNoLocationIdentity() throws {
        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        XCTAssertFalse(section.contains("NSItemProvider(object:"),
                       "★ 载荷不许用 NSString 造：会被注册成公开文本与 URL，接收方读得到完整路径（审查 F01）")
        XCTAssertTrue(section.contains("NSItemProvider(item: Self.reorderMarker as NSSecureCoding"),
                      "载荷只能是常量标记，且类型由我们显式指定")
        XCTAssertTrue(section.contains("typeIdentifier: Self.reorderType.identifier"),
                      "必须显式指定私有类型，否则系统又会按内容推断回公开类型")
        XCTAssertTrue(section.contains("UTType(exportedAs: \"com.flashfind.quickpick-row\")"),
                      "排序拖拽要有自己的私有类型")
        XCTAssertTrue(section.contains(".onDrop(of: [Self.reorderType]"),
                      "落点只接受这个私有类型")
        XCTAssertFalse(section.contains(".plainText"),
                       "★ 旧版按纯文本收落点：等于把「本窗口排序」和「任意文本」并成一条通道")
        // 载荷不许由行内容决定 —— 路径就是这样被带出去的。
        let providerLine = section.split(separator: "\n")
            .first { $0.contains("NSItemProvider(item:") } ?? ""
        XCTAssertFalse(providerLine.contains("row."),
                       "★ provider 的实参里出现 row.* 就说明载荷又和行内容绑上了（路径会跟着走）")
        XCTAssertTrue(providerLine.contains("reorderMarker"),
                      "provider 实参必须正是那个常量标记")
    }

    /// ★ 拖动虚影是**整行**：`onDrag` 必须挂在行尾（HStack 收尾之后），
    /// 不是挂在内侧那个把手上 —— 挂在把手上拖出去的只是一个小图标，
    /// 用户看不出自己拿的是哪一条（2026-10-27 用户要求）。
    func testQuickPickDragIsAttachedToTheWholeRow() throws {
        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        let row = try body(of: "row", in: section)
        XCTAssertEqual(row.components(separatedBy: ".onDrag").count - 1, 1,
                       "整行只该有一处起拖：多了就说明有一处还挂在子视图上")
        let drag = try XCTUnwrap(row.range(of: ".onDrag {"), "找不到起拖")
        let wholeRow = try XCTUnwrap(row.range(of: ".frame(maxWidth: .infinity, alignment: .leading)"),
                                     "找不到整行的 frame：判据靠它区分「整行」与「把手」")
        XCTAssertTrue(wholeRow.lowerBound < drag.lowerBound,
                      "★ 起拖要挂在整行（HStack 收尾之后），不是挂在内侧那个把手上")
        XCTAssertTrue(row.contains("QuickPickDragPreview(row: row)"), "虚影必须是整行")
        let handle = try XCTUnwrap(row.range(of: "line.3.horizontal"))
        XCTAssertFalse(row[handle.upperBound..<drag.lowerBound].contains(".onDrag"),
                       "把手只剩视觉提示，不许自己挂起拖")
    }

    /// ★ 右键菜单的两项动作必须落到模型（再落到 Core 的隐藏表），
    /// 不是界面上假装一下（假装的话，关掉设置页再打开那条又回来了）。
    func testQuickPickRowContextMenuDeletesAndReplaces() throws {
        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        let row = try body(of: "row", in: section)
        XCTAssertTrue(row.contains("column.onDelete(row.id)"), "删除要落到 Core")
        XCTAssertTrue(row.contains("column.onReplace(row.id, candidate.id)"), "替换要落到 Core")
        XCTAssertTrue(row.contains("column.replacements(row.id)"),
                      "替换候选取自调用方（Core 判定），界面不许自己列一份")
        XCTAssertTrue(row.contains("ForEach(alternatives)"), "每个候选都要能点")
        XCTAssertTrue(row.contains(".contextMenu"), "菜单挂在整行上，不是藏在某个按钮里")
    }

    /// 私有类型标识在 Swift 与 `Info.plist` 各写一遍：写错一边编译照样过，
    /// 运行时表现为「拖了没反应」——所以这条把两边对起来比。
    func testQuickPickReorderTypeIsDeclaredInInfoPlist() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("Resources/Packaging/Info.plist")
        let data = try Data(contentsOf: url)
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        let declarations = plist?["UTExportedTypeDeclarations"] as? [[String: Any]]
        let identifier = "com.flashfind.quickpick-row"

        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        XCTAssertTrue(section.contains(identifier), "Swift 侧的标识必须就是这一个")
        XCTAssertTrue((declarations ?? []).compactMap { $0["UTTypeIdentifier"] as? String }
                        .contains(identifier),
                      "★ Info.plist 必须声明同一个标识：只写一边，拖拽在别的进程里认不出来")
        let conforms = (declarations ?? [])
            .first { $0["UTTypeIdentifier"] as? String == identifier }?["UTTypeConformsTo"] as? [String]
        XCTAssertTrue(conforms?.contains("public.data") == true,
                      "导出类型要 conform 到 public.data，否则不是一个可搬运的数据类型")
    }

    /// 预览钩子：`FF_UI_QUICKPICK_SWITCH` 能让设置页定时切一次。
    ///
    /// 要它是因为过渡只存在于插入/移除的那几帧里：人手点完再截图只能拿到结束态，
    /// 首尾两张图都正常既证明不了有动画，也证明不了没有（审查 F02 就这么漏的）。
    func testQuickPickPreviewSwitchHookIsGuardedAndSharesTheTabsPath() throws {
        let section = codeOnly(try appSource("QuickPickSettingsSection.swift"))
        XCTAssertTrue(section.contains("FF_UI_QUICKPICK_SWITCH"),
                      "没有这个钩子就没法在程序控制下截到过渡的中间帧")
        // ★ 只取这个函数的**函数体**：整份文件里还有别的 `isPreview`（初始页签那条），
        //   拿全文查的话，钩子自己丢了守卫也照样绿。
        let start = try XCTUnwrap(section.range(of: "private func switchPageInPreviewIfRequested"),
                                  "钩子函数不见了")
        let rest = section[start.lowerBound...]
        let end = rest.range(of: "\n    }\n")?.lowerBound ?? rest.endIndex
        let hook = String(rest[rest.startIndex..<end])
        XCTAssertTrue(hook.contains("AppEnvironment.isPreview"),
                      "★ 钩子必须有 isPreview 守卫：正式版设个环境变量就能让设置页自己换页")
        XCTAssertTrue(hook.contains("select("),
                      "钩子必须走页签同一条换页路径，不许另写一份")
        // 页签本身也只能走 select：两份切换逻辑迟早只改一边。
        XCTAssertTrue(section.contains("set: { select($0) }"),
                      "页签的 selection 要落到同一个 select(_:)")
    }

    /// ★ 面板的顺序与编号都必须来自「同一份用户设置」，而且**编号只由顺序决定**。
    ///
    /// 最容易犯的错：拖动排序了，编号却还带着一份「用户指定过的键」——
    /// 于是同一行排第 1 却写着 5，用户拖动之后号也不变（2026-10-26 报障）。
    func testPaletteOrderAndKeysComeFromTheSavedSettings() throws {
        let code = try appModelCode()
        let items = try body(of: "commandItems", in: code)
        XCTAssertTrue(items.contains("SearchCommandArrangement.arrange("),
                      "候选顺序必须走 Core 的重排，不能只按目录自然顺序")
        XCTAssertTrue(items.contains("quickPick.order(for: kind)"),
                      "顺序要取用户设置；取错了拖动排序就是白做")
        XCTAssertTrue(items.contains("hidden: quickPick.hiddenIDs(for: kind)"),
                      "★ 删掉的候选必须在这一层滤掉：只在界面里跳一行，下次刷新它又回来了")

        let numbers = try body(of: "commandNumbers", in: code)
        XCTAssertTrue(numbers.contains("SearchCommandNumbering.keys(in: filteredCommandItems)"),
                      "编号只能由当前显示的候选顺序算出来")
        XCTAssertFalse(numbers.contains("assigned"),
                       "★ 不许再传一份「指定键」：那会让拖动后的数字不跟着变")

        let pick = try body(of: "pickCommand", in: code)
        XCTAssertFalse(pick.contains("assigned"),
                       "数字键反查也要同一条规则，否则「写几按几」不成立")

        // 三个写入口：拖动（from/to）、删除（hide）、替换（replace）。
        // 后两个都是 2026-10-27 加的右键动作，都必须落到 Core。
        XCTAssertTrue(code.contains("func deleteQuickPick(_ kind: SearchCommandKind, id: String)"),
                      "删除入口必须存在")
        XCTAssertTrue(code.contains("next.hide(id, kind: kind, among: commandItems(for: kind))"),
                      "★ 删除必须记进 Core 的隐藏表：只从界面列表里跳过，关掉设置页它又回来了")
        XCTAssertTrue(code.contains("func replaceQuickPick(_ kind: SearchCommandKind, id: String, with newID: String)"),
                      "替换入口必须存在")
        XCTAssertTrue(code.contains("next.replace(id, with: newID, kind: kind"),
                      "替换必须落到「同一位次换人」")
        // 旧的行尾选号入口必须彻底删掉：留着就是第二套排序语义。
        XCTAssertFalse(code.contains("moveToKey"),
                       "★ 「选个数字把行搬过去」已经随行尾选择器一起删了，不许留死代码")

        let rows = try body(of: "quickPickRows", in: code)
        XCTAssertTrue(rows.contains("quickPick.rows("),
                      "设置页的行由 Core 统一算（含「不列打开设置」），界面不许各写一份")
    }
}
