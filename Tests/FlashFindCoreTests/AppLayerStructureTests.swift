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
        let assignment = try NSRegularExpression(pattern: #"nativeProviders\[[^\]]*\]\s*="#)
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
        XCTAssertTrue(body.contains("reconnectUsingStoredCredential(id, otp: otp)"),
                      "弹框拿到的 OTP 必须传给 reconnectUsingStoredCredential")
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
        let region = appModel.range(of: "func promptForOTP(sourceName: String)")
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
        let region = appModel.range(of: "func performConnectQuietly(config: NASSourceConfig, credential: PendingCredential)")
        XCTAssertNotNil(region, "performConnectQuietly 必须存在")
        let tail = String(appModel[region!.lowerBound...])
        let end = tail.range(of: "\n    /// 打开独立设置窗口")?.lowerBound ?? tail.endIndex
        let body = String(tail[tail.startIndex..<end])

        XCTAssertTrue(body.contains("ConnectionFailureText.isOTPRequired(error)"),
                      "OTP 判定必须走 Core 的 ConnectionFailureText.isOTPRequired")
        XCTAssertTrue(body.contains("$0.needsOTP = needsOTP"),
                      "catch 块里必须回写 needsOTP 标记")
        XCTAssertTrue(body.contains("$0.requiredAction = needsOTP ? .login : .retry"),
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
        let driver = try XCTUnwrap(braceBlock(after: "case let .failed(_, error)", in: appModel),
                                   "失败分支必须存在")
        XCTAssertTrue(driver.contains("$0.needsOTP = needsOTP"),
                      "失败分支的 needsOTP 必须来自 isOTPRequired 的判定结果")
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

    /// ★ 选类型不再先让用户挑协议；只有一种可选时这一步整个不出现。
    ///
    /// 把研发精力收回群晖，其余品牌撤下选型。若仍保留一个
    /// 只装一项的网格，等于让用户白点一次，还暗示「这里本来有得选」。
    /// 现在可选集合由 Core 的 `ExperimentalSources` 决定（默认只给群晖），
    /// 并且**只有多项时才画这一步**。
    func testVendorStepAppearsOnlyWhenThereIsMoreThanOneChoice() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("model.selectableVendors"),
                      "可选类型必须来自模型（Core 的 ExperimentalSources），不能写死在视图里")
        XCTAssertTrue(wizard.contains("if model.selectableVendors.count > 1"),
                      "只有一种可选时不该画「选类型」这一步")
        XCTAssertFalse(wizard.contains("Vendor.allCases"),
                       "选类型不该再直接铺全部品牌")
        XCTAssertFalse(wizard.contains("supportBadge"),
                       "选项上不该再挂「已验证 / 已接入 · 未验证」这类状态标签")
    }

    /// ★ 「重新连接」到底要不要输密码，只由 Core 的判定说了算。
    ///
    /// 之前向导里写死了一句「请输入密码以重新连接」：本机凭据文件里存着密码也这么说，
    /// 用户只能再输一遍，而事后无法从界面上看出**为什么**要输。
    func testReconnectAsksForPasswordOnlyWhenThereIsNoStoredOne() throws {
        let appModel = try appModelCode()
        XCTAssertTrue(appModel.contains("ReconnectEntryState.route(rememberPassword:"),
                      "路由必须看「配置里勾了记住」与「本机真有密码」两件事")
        XCTAssertTrue(appModel.contains("reconnectUsingStoredCredential(id, otp: nil)"),
                      "有已保存密码时应当静默重连，不问用户")

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
    func testWizardWiresUpNearbyDevicesWithoutAutoConnecting() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(wizard.contains("LocalNetworkDiscovery()"),
                      "向导要起一个设备发现器")
        XCTAssertTrue(wizard.contains("nearbySection"),
                      "要有「附近的设备」这一块")
        XCTAssertTrue(wizard.contains("model.applyDiscoveredDevice(device)"),
                      "选中设备要交给模型预填")
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

    /// ★ 引导页里按下全局快捷键只表示「这个快捷键能用」，不弹搜索浮窗。
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
                      "开着时只做标记")
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

    /// ★ 版本号只能有一个出处。
    ///
    /// 设置页读一次 `Bundle.main`、关于面板再读一次，两处格式迟早分叉，
    /// 同一次安装里出现两个版本号说法。两边都必须走 `AppVersion`。
    func testAboutPanelAndSettingsShareOneVersionSource() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        guard let about = braceBlock(after: "static func show()", in: app) else {
            return XCTFail("缺少 AboutPanel.show")
        }
        XCTAssertTrue(about.contains("AppVersion.shortVersion"),
                      "关于面板的短版本也要走 AppVersion")
        XCTAssertTrue(about.contains("AppVersion.buildNumber"),
                      "关于面板的构建号也要走 AppVersion")
        XCTAssertFalse(about.contains("CFBundleShortVersionString"),
                       "关于面板不该自己再读一次 Bundle 键名")
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
    /// 而 DS1621+ 有三块网卡（.88 / .152 / 192.168.3.4），不按序列号归并就是「三台 NAS」。
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
    /// 用户那台 `192.168.1.88`（不广播 mDNS 的群晖）大约第 16 秒就被探到了，
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
        XCTAssertTrue(changedQuery.contains("localProvider.folders=localFolders"),
                      "搜索前必须把当前选的文件夹交给 provider")
        XCTAssertTrue(changedQuery.contains("localProvider.mode=localSearchMode"),
                      "搜索方式必须和文件夹一起给，否则 provider 判不出该走哪条路")
        // 两条必须同处一次赋值：分开写在别处的话，改了一个另一个还是旧的。
        XCTAssertTrue(changedQuery.contains("localProvider.folders=localFolders;localProvider.mode=localSearchMode"),
                      "方式要与文件夹在同一处装配，避免只有定义、没有调用点")
    }
}
