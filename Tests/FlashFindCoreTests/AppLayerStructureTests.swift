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

    /// 读 Core 源码。用于「App 层必须调用 Core 的某条规则」这类断言——
    /// 需要同时看两边，才能证明规则真的在 Core 里而不是在 App 里另写了一份。
    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/\(name)"),
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
    ///
    /// ★ 2026-10-27 改口：搜索窗拆成两个模块后，高度分成了
    /// `contentModuleHeight`（第二块的内容 = 结果 + 提示条 + 命令面板）与
    /// `panelHeight`（＝搜索框 + 空白 + 第二块）。原来那条「`panelHeight` 里必须出现
    /// `openFailureBannerHeight`」会被这次拆分判红——提示条现在算在第一层里。
    /// 改成锁**两层各缺一不可**：第二块要含提示条，窗口要把第二块整块加上。
    func testOpenFailureBannerOwnsItsHeightAndLeavesWithTheQuery() throws {
        // ★ 2026-10-28 改口：结果那一块搬进**独立窗口**（`SearchResultsPanel.swift`），
        //   高度不再由页面做「搜索框 + 空白 + 结果」的加法，而是每块窗口各算各的。
        //   原来锁的「panelHeight 里要把第二块整块加上」这条已经没有对象了；
        //   换成锁**同两件事的新落点**：结果窗口的高度里要含提示条，
        //   两块窗口之间的那道空白仍由 `moduleGap` 决定（现在是**窗口之间**的距离）。
        let resultsPage = codeOnly(try appSource("SearchResultsPanel.swift"))
        let content = try XCTUnwrap(braceBlock(after: "private var contentModuleHeight", in: resultsPage),
                                    "找不到 contentModuleHeight")
        XCTAssertTrue(content.contains("openFailureBannerHeight"),
                      "结果模块的高度必须算上提示条，否则提示条撑不开、被切成窄边")

        let sizing = try XCTUnwrap(braceBlock(after: "private var expandedHeight", in: resultsPage),
                                   "找不到 expandedHeight")
        XCTAssertFalse(sizing.contains("openFailureBannerHeight"),
                       "提示条高度不能在两处各加一遍，否则列表与提示条之间会多出一条空白")

        let controller = codeOnly(try appSource("SearchPanelController.swift"))
        let place = try XCTUnwrap(braceBlock(after: "private func placeResultsBelowField()", in: controller),
                                  "找不到 placeResultsBelowField")
        XCTAssertTrue(place.contains("SearchModuleLayout.moduleGap"),
                      "两块窗口之间那道空白仍由 Core 的 moduleGap 决定（现在是窗口间距）")

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

    /// ★ 本机来源的两件事只能住在 controller 里：偏好读写、本机文件夹选择。
    ///
    /// （挂载表发现已随「导入已挂载 SMB 共享」流程一起移除——那条流程是
    /// 自研服务端线的配套 UX，没有任何界面调用方。SMB 挂载的现行入口在
    /// Core 的 `SMBMountService` 与打开结果时的自动挂载，不归这里。）
    ///
    /// `NSOpenPanel` 本身不能拿来做断言——所以挑只属于「本机文件夹」的
    /// `volumeIsLocalKey`（网络卷不许进本机搜索）作标记。
    func testLocalSourceMechanicsLiveOnlyInController() throws {
        let appModel = try appModelCode()
        XCTAssertFalse(appModel.contains("volumeIsLocalKey"),
                       "选择本机文件夹（含排除网络卷）应归 LocalSourceController")
        XCTAssertFalse(appModel.contains("ff2.localSearchMode"),
                       "本机搜索方式的偏好读写应归 LocalSourceController")

        let controller = codeOnly(try appSource("LocalSourceController.swift"))
        XCTAssertTrue(controller.contains("volumeIsLocalKey"))
        XCTAssertTrue(controller.contains("ff2.localSearchMode"))
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
            // ★ 要整词匹配：`selectedSourceID` 会被复数形式的 `selectedSourceIDs`
            // （另一个字段）误伤——后者不在此列。
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
                      "账号密码品牌的详情页必须保留重连入口，且走 reconnectSource 统一判定")
        // 飞牛没有账号密码：同一张卡换成「授权 / 浏览器授权 + 重新授权…」，
        // 走**同一个** `reconnectSource` —— 换个说法可以，入口不许丢。
        XCTAssertTrue(settings.contains("Button(\"重新授权…\") { model.reconnectSource(source.id) }"),
                      "浏览器授权品牌的详情页同样要保留重连入口")
        XCTAssertTrue(settings.contains("if source.vendor.requiresAccountPassword"),
                      "「账号」这张卡必须按登录方式分叉：飞牛没有账号可展示")
        // 行上的那些生命周期按钮不该回来。
        for removed in ["Button(\"断开\")", "Button(\"重新连接\")", "FFSecondaryButton(\"管理…\")", "Button(\"刷新状态\")"] {
            XCTAssertFalse(settings.contains(removed),
                           "来源行上的生命周期按钮 \(removed) 已按 UI 简化撤下")
        }
    }

    /// ★ 授权弹窗要把闪寻自己的窗口收起来，结束后**无条件**放回。
    ///
    /// 2026-10-29 用户截图：弹窗 + 设置窗 + 向导窗正好把浏览器里的授权页整个挡死，
    /// 得手动挪开窗口才看得见。「把浏览器叫到前台」不够——`runModal` 的 modal
    /// session 会把 App 重新激活，闪寻的窗口随即又压回浏览器上方。
    ///
    /// 这里锁三件事：收（orderOut）、只收闪寻自己的窗口（层级 ≤ floating，
    /// 别把弹窗自己或系统窗口收了）、放回（orderFront，且倒序保住原上下顺序）。
    func testAuthorizationPromptHidesAndRestoresFlashFindWindows() throws {
        let source = codeOnly(try appSource("AppModel+SourceActions.swift"))
        XCTAssertTrue(source.contains("hideWindowsBehindAuthorizationAlert(except: alertWindow)"),
                      "授权弹窗前必须收起闪寻自己的窗口")
        XCTAssertTrue(source.contains("for window in NSApp.orderedWindows where window !== alertWindow"),
                      "不许把授权弹窗自己也收起来")
        XCTAssertTrue(source.contains("window.level.rawValue <= NSWindow.Level.floating.rawValue"),
                      "只收闪寻自己的窗口：floating 以上是系统窗口（菜单、状态栏面板），不许碰")
        XCTAssertTrue(source.contains("window.orderOut(nil)"),
                      "收起用 orderOut：close 会触发窗口关闭策略，把设置窗真的关掉")
        XCTAssertTrue(source.contains("for window in hiddenBehindAlert.reversed() { window.orderFront(nil) }"),
                      "弹窗结束后必须把窗口放回去，倒序才能保住原来谁在上面")
    }

    /// ★ 飞牛的授权码必须**内联在「连接信息」表单里**，向导不许再弹窗。
    ///
    /// 2026-10-29 用户改流程，原话：「飞牛的登陆流程更改下 不要弹窗 直接在图示位置
    /// 生成获取授权码，点击后打开浏览器 然后再粘贴授权码 点击下方链接跳转搜索位置」。
    ///
    /// 这条锁的是「流程又退回弹窗」：弹窗那一版还能正常用，功能测试全绿，
    /// 只有用户点开向导才会发现多了一扇窗、还把浏览器挡在后面。
    func testWizardCollectsAuthorizeCodeInlineInsteadOfInAPrompt() throws {
        let view = codeOnly(try appSource("NASSourceWizardView.swift"))
        XCTAssertTrue(view.contains("AuthorizeCodeField.isInline(for: model.draftSource.vendor)"),
                      "要不要摆授权码那一行必须问 Core，不许在视图里写 `vendor == .fnos`")
        XCTAssertTrue(view.contains("$model.draftAuthorizeCode"),
                      "输入框必须绑到草稿字段，否则用户粘的码传不进连接流程")
        XCTAssertTrue(view.contains("accessibilityIdentifier(\"nas-authorize-code\")"),
                      "授权码框要有固定标识（抓界面问题靠它定位）")
        XCTAssertTrue(view.contains("model.requestDraftAuthorizeCode()"),
                      "必须有「获取授权码」这个入口，否则用户不知道去哪拿码")

        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertFalse(controller.contains("authorizeCodePrompter"),
                       "向导不许再借授权弹窗（用户明确要求不要弹窗）")
        XCTAssertTrue(controller.contains("authorizeCode: AuthorizeCodeField.optional(draftAuthorizeCode)"),
                      "表单里那串码必须洗完交给核心（空串要落成 nil）")
        XCTAssertTrue(controller.contains("NSWorkspace.shared.open(url)"),
                      "撞上授权态必须直接把浏览器打开，而不是等用户再点一次")
        XCTAssertTrue(controller.contains("ConnectionFailureText.authorizeInlinePrompt"),
                      "状态行必须指回表单里那一格，文案住 Core")
        XCTAssertTrue(controller.contains("guard outcome == .connected else"),
                      "「等授权码」不是失败：不许走失败收尾去覆盖状态行")
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

    /// ★ 带授权码回来的那一轮**绝不能** reset 或 discover。
    ///
    /// PKCE 的 verifier 存在核心那个会话的适配器实例上：`resetSource` 会删掉它、
    /// `discover` 会重建它。任一动作之后，设备只回「授权流程已过期」——
    /// 而用户看着自己刚粘的码完全正确，只会怀疑自己复制错了。
    ///
    /// 弹窗那一版里两段 login 在同一轮跑，这件事是**天然成立**的；
    /// 2026-10-29 改成内联之后，两段之间隔着用户去浏览器的操作（跨两轮
    /// `connectDraft`），于是就变成必须显式保证的东西 —— 这正是本用例守的点。
    func testAuthorizeCodeRoundResumesTheSameCoreSession() throws {
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        XCTAssertTrue(controller.contains("let resumingAuthorization = credential.authorizeCode != nil"),
                      "必须显式判出「这是带码回来的第二轮」")
        XCTAssertTrue(controller.contains("$0.host == effective.hostName && $0.port == effective.port"),
                      "端点变了（用户改了地址/端口）就不能拿旧 verifier 去换令牌")
        XCTAssertTrue(controller.contains("if !resumingAuthorization {"),
                      "resume 分支必须跳过 reset 与 discover 各自那道闸")
        XCTAssertTrue(controller.contains("pendingAuthorizationEndpoint = (config.hostName, config.port)"),
                      "发挑战时必须记下端点，否则第二轮判不出该不该复用会话")
        XCTAssertTrue(controller.contains("pendingAuthorizationEndpoint = nil"),
                      "成功/失败/取消都必须让标记失效，否则下一轮会跳过 discover 直接登录")
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
    /// ★ 断言切在输入行 `row` 的花括号块里：整份文件 `contains` 会被
    /// 别处的同名调用满足（本项目在 build 12 / build 13 已经栽过两次）。
    ///
    /// ★ 2026-10-27 改口两处：① 搜索窗按模块拆文件，输入行搬到
    /// `SearchFieldModule.swift`；② 切块锚点由 `HStack(spacing: 14)` 换成
    /// `row` 属性——键位提示那一行用的是同一个 spacing，且出现在前面，
    /// `braceBlock` 会先把它切走（那样这条断言查的是提示行，必红）。
    func testSearchFieldShowsBrandGlyphNotSystemMagnifier() throws {
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        XCTAssertFalse(field.contains("Image(systemName: \"magnifyingglass\")"),
                       "搜索框前导图标不许再用系统放大镜，要用自家图标")

        let row = try body(of: "row", in: field)
        guard !row.isEmpty else {
            return XCTFail("搜索框模块必须有输入行：`private var row: some View`")
        }
        XCTAssertTrue(row.contains("StatusIcon.searchFieldGlyph()"),
                      "前导图标必须取品牌字形：\(row)")
        XCTAssertTrue(row.contains("foregroundStyle(.secondary)"),
                      "品牌字形要压到系统搜索框同档灰度，不许用原色黑")
        // ★ 2026-10-27 改口：这枚图标从「装饰」变成了**入口**。
        //
        // 用户要求「搜索框的闪寻图标设计成可以点击的，点击后进入设置界面」。
        // 所以它不能再标 `accessibilityHidden(true)`——装饰对读屏隐藏是对的，
        // 入口按钮必须能被读出来。这里改成锁三件事：是个真按钮、接的是
        // `openSettings`、名字能被读屏拿到（图标按钮没有文字）。
        XCTAssertTrue(row.contains("Button(action: openSettings)"),
                      "闪寻图标必须是个真按钮，接注入的 openSettings：\(row)")
        XCTAssertTrue(row.contains(".help(") && row.contains(".accessibilityLabel("),
                      "图标按钮要同时有悬停名字与读屏名字")
        XCTAssertFalse(row.contains("accessibilityHidden(true)"),
                       "它现在是入口，不许再对读屏隐藏")

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
    /// 断言全部切到输入行 `row` 的花括号块内：那个块里同时住着
    /// 品牌字形、清除按钮和更多菜单，整函数 `contains` 会被别的控件满足。
    ///
    /// ★ 2026-10-27 改口：文件拆成 `SearchFieldModule.swift`，切块锚点由
    /// `HStack(spacing: 14)` 换成 `row`（键位提示行用同一个 spacing，会先被切走）。
    func testSearchFieldResearchButtonIsWiredForReal() throws {
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        let row = try body(of: "row", in: field)
        guard !row.isEmpty else {
            return XCTFail("搜索框模块必须有输入行：`private var row: some View`")
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

    /// ★ 品牌图标只许走 `VendorIcon`（黑白品牌标记），不许各写各的 SF Symbol。
    ///
    /// 2026-10-29 用户要求「换成黑白风格的他们自己的主题图标」：向导卡片、页头、
    /// 设置页来源行、来源详情页四处一起换。四处各写 `Image(systemName: vendor.symbol)`
    /// 时，漏一处就有一处继续显示泛化的硬盘图标 —— 除了截图没有别的办法发现，
    /// 而截图只会看主要那两屏。
    ///
    /// ★ 定稿形态 = **从原图描出来的轮廓 + 固定白底黑图形**（用户 2026-10-29 提供
    /// `VendorMarkView.swift`）。所以这里守的是「描摹」与「固定黑白」两件事，
    /// 而不是上一版的「跟随 foregroundStyle」—— 那一版在深色模式下会把标记反相成白图形，
    /// 三家标志的负形（DSM 的镂空字母）就看不出来了。
    /// 搜索框占位文案 = 品牌名「闪寻」（用户 2026-10-29：「搜索文件与文件夹换成品牌名『闪寻』」）。
    ///
    /// 这条守两件事，而且**两件必须一起**：
    /// · 视觉占位只写「闪寻」—— 那框里只放得下两个汉字，全称会把光标挤到很右边；
    /// · 读屏标签仍是「搜索文件与文件夹」—— 读屏用户听到「闪寻」不知道这框要干什么。
    /// 只守前者会出现「为了好看把无障碍也改了」，只守后者则文案改不回来。
    func testSearchFieldPlaceholderIsTheBrandName() throws {
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        XCTAssertTrue(field.contains("TextField(\"闪寻\""),
                      "占位文案应为品牌名「闪寻」，不是功能描述")
        XCTAssertFalse(field.contains("TextField(\"搜索文件与文件夹\""),
                       "占位文案已改品牌名，别又改回全称")
        XCTAssertTrue(field.contains("accessibilityLabel(\"搜索文件与文件夹\")"),
                      "读屏标签要保留功能描述：光念「闪寻」说不出这个框干什么")
    }

    func testVendorIconsGoThroughTheSharedMarkView() throws {
        for file in ["NASSourceWizardView.swift", "SettingsView.swift"] {
            let text = codeOnly(try appSource(file))
            XCTAssertFalse(text.contains("vendor.symbol"),
                           "\(file) 不该再自己拼 vendor.symbol —— 品牌图标走 VendorIcon")
            XCTAssertTrue(text.contains("VendorIcon("),
                          "\(file) 应通过 VendorIcon 画品牌图标")
        }
        // 缩放基准取自 Core；图形本身是描出来的闭合轮廓。
        let mark = codeOnly(try appSource("VendorMarkView.swift"))
        XCTAssertTrue(mark.contains("VendorMark.designSize"),
                      "缩放基准只能取自 Core，否则各处的标记会各缩各的")
        XCTAssertTrue(mark.contains("tracedPath("),
                      "三家轮廓必须走 `tracedPath`（从用户给的原始截图描出来的闭合多边形）："
                      + "手绘过三版都不成立 —— 字母糊成一团、牛角像鹿角、环的缺口方向放反")
        XCTAssertTrue(mark.contains("closeSubpath"),
                      "描摹出来的轮廓必须闭合，否则 fill 会把缺口补上或漏填")
        XCTAssertTrue(mark.contains("eoFill"),
                      "群晖的「DSM」是负形（镂空），必须用 even-odd 填充")
        // 单色剪影：浅色模式黑、深色模式白，且**不铺底色**（白底贴片在深色界面上像贴纸）。
        XCTAssertTrue(mark.contains("colorScheme"),
                      "标记要按深浅色选黑/白：浅色黑图形、深色白图形，不铺白底")
        XCTAssertTrue(mark.contains(".color(ink)"),
                      "填充色只能来自 `ink`（黑/白二选一），不许换成跟随 foregroundStyle")
        XCTAssertFalse(mark.contains("with: .foreground"),
                      "不许跟随 foregroundStyle —— 被外层染成强调色，三家又变同一套图标")
        XCTAssertFalse(mark.contains("accentColor"),
                      "品牌图标不许染强调色：一旦变蓝，三家又变成同一套图标")
        XCTAssertFalse(mark.contains("background(Color.white)"),
                      "不许再垫白色底块 —— 深色模式下是块白贴纸")
    }

    /// ★ 这是一条**三步**的向导，而且步数只能由 Core 出。
    ///
    /// 2026-10-28 用户报障：「点击连接后选择搜索位置就结束了，所以这是一个三步的动作，
    /// 不是你顶部写的四步」。原来的四步是这么数出来的：选来源（第 1 步）→
    /// 手填地址（第 2 步）→ 连接信息 → 选搜索位置，而其中两步同在一屏上。
    ///
    /// 现在「选来源」与「填连接信息」分成两页，页数 = 三步，页码文案走
    /// `SourceWizardFlow.subtitle(for:)`；视图里再写死一遍就会被这条抓到。
    func testWizardIsThreePagesAndCountComesFromCore() throws {
        let wizard = codeOnly(try appSource("NASSourceWizardView.swift"))

        XCTAssertTrue(wizard.contains("SourceWizardFlow.subtitle(for: page)"),
                      "「第 N 步，共 M 步」必须由 Core 出，视图不许自己拼")
        for stale in ["共 4 步", "共4步", "共四步"] {
            XCTAssertFalse(wizard.contains(stale),
                           "视图里又出现了写死的步数：\(stale)")
        }
        XCTAssertTrue(wizard.contains("SourceWizardFlow.enteringPage"),
                      "打开时落在哪一页要问 Core（新建 / 编辑 / 已连接三种）")

        // 三个页面各有一块，不许再把它们上下堆在同一屏。
        for name in ["sourcePage", "connectionPage", "scopePage"] {
            XCTAssertTrue(wizard.contains("var \(name)"),
                          "缺了 \(name)：向导又回到「一屏堆完」了")
        }

        // 第 1 步（来源页）里只能有来源入口，不许再挂连接信息。
        let sourcePage = try XCTUnwrap(braceBlock(after: "var sourcePage", in: wizard),
                                       "取不到 sourcePage 的块，本条断言失去意义")
        XCTAssertTrue(sourcePage.contains("typeEntrySection"),
                      "第 1 步要列出来源")
        XCTAssertFalse(sourcePage.contains("connectionSection"),
                       "第 1 步不许再把连接信息挂在下面——那正是「四步」的来源")

        // 点一张来源卡就翻页：这是「翻页」而不是「同屏展开」的判据。
        let vendorEntry = try XCTUnwrap(braceBlock(after: "func vendorEntry", in: wizard),
                                        "取不到 vendorEntry 的块")
        XCTAssertTrue(vendorEntry.contains("go(to: .connection)"),
                      "选中来源后必须翻到连接信息那一页")

        // 连上之后自动翻到选位置：否则按了「连接」界面看起来毫无变化。
        XCTAssertTrue(wizard.contains(".onChange(of: model.draftConnected)"),
                      "连接成功要自动翻页")
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

        // 字段标签**按来源不同**（OpenList 是「站点地址」、群晖是「IP / 域名」），
        // 所以它不能写死在视图里 —— 2026-10-28 起由 Core 的
        // `SourceConnectionLabels` 出，视图只负责按当前来源取一份。
        XCTAssertTrue(wizard.contains("SourceConnectionLabels.forVendor(model.draftSource.vendor)"),
                      "字段标签必须跟着来源走，不能在视图里写死一套")
        XCTAssertTrue(wizard.contains("labels.addressLabel"),
                      "地址栏的标签要取自 Core 那一份")
        XCTAssertTrue(try coreSource("SourceWizardFlow.swift").contains("\"IP/域名\""),
                      "群晖那一套标签仍应是「IP/域名」")
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
        // ★ 2026-10-27：空状态随结果模块搬到 `SearchResultsModule.swift`。
        let view = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertFalse(view.contains("确认 NAS 的搜索位置"),
                       "空状态提示不该把搜索位置说成只有 NAS 才需要确认")
        // ★★ 同日再改口：文案搬进 Core 了（`SearchEmptyHint`）。
        //
        // 原因不是「搬个家」：位置一换，说的就不是同一句话——侧边栏选了
        // 「公司 nas」时，用户要知道**是这个位置里没有**，还得有「换回全部」
        // 这条出路。两句话必须能被断言，所以它们在 Core（`SearchSidebarTests`
        // 逐句锁着），App 层只负责把它们摆上来。
        XCTAssertTrue(view.contains("SearchEmptyHint.title("),
                      "标题必须来自 Core，不许在视图里再拼一遍")
        XCTAssertTrue(view.contains("SearchEmptyHint.detail("),
                      "正文必须来自 Core —— 它要跟着「当前位置」变")
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

    /// ★ 设置界面的表面走**自绘卡片**，一级导航只由 Core 的四页驱动。
    ///
    /// 2026-10-27 用户改口（上一版正好相反）：浅色不要再是「大片灰白阴影」，
    /// 要**纯白底**，原来卡片投影的位置换成一个**玻璃遮罩**；深色维持原样。
    /// 分组表单（`Form` + `.formStyle(.grouped)`）的卡片底色与投影是系统画的，
    /// 改不动，所以表单整体换成 `SettingsCard`（表面策略在 Core 的
    /// `SettingsSurface`，浅色/深色两套各由断言钉住）。
    ///
    /// 这条同时守住「不许倒退」：`Form` 一旦回来，说明有人又去用系统那套投影了。
    func testSettingsUsesGlassCardsInsteadOfGroupedForm() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("SettingsCard("),
                      "设置页的分组要用 SettingsCard（纯白底上的玻璃遮罩）")
        XCTAssertFalse(settings.contains(".formStyle(.grouped)"),
                       "分组表单的卡片投影正是这次要去掉的东西，不许退回 Form")
        XCTAssertFalse(settings.contains("FFSettingsSection"),
                       "设置页不该再用向导那套 FFSettingsSection")
        XCTAssertFalse(settings.contains("NASSourceCard"),
                       "每台 NAS 一张大卡片的写法已撤下")

        // 卡片表面必须在 App 层**只有一处**：四个页面各写一份配色，
        // 就会出现「通用页是白的、搜索页还是灰的」这种半拉子改动。
        let chrome = codeOnly(try appSource("SettingsChrome.swift"))
        XCTAssertTrue(chrome.contains("SettingsCardSurface"),
                      "卡片表面要收在 SettingsChrome 里")
        XCTAssertTrue(chrome.contains("SettingsSurface.style(isDark:"),
                      "浅色/深色两套表面必须问 Core 要，不许在视图里拍脑袋")
        XCTAssertEqual(settings.components(separatedBy: "SettingsCardSurface()").count - 1, 0,
                       "设置页只许用 SettingsCard，不要自己拼表面")
    }

    /// ★ 设置页卡片与搜索模块**同一套玻璃**（2026-10-27 深夜：「设置页 UI 界面跟着搜索这一块走」）。
    ///
    /// 守三件事，缺一件用户就会看出来：
    /// ① 材质同一句 `glassEffect(.regular)`；
    /// ② 圆角取 `style.cardRadius`（Core 里引用的是 `SearchModuleLayout.moduleRadius`，
    ///    视图里不许再出现 `cornerRadius: 12` 这种拍脑袋的数字）；
    /// ③ **`clipShape` 必须在** —— 玻璃自带一圈外阴影，白天正是因为那个灰边
    ///    才换成材质的；裁掉之后高卡右缘才是纯白（采样 255）。
    func testSettingsCardUsesTheSameGlassAsTheSearchModules() throws {
        let chrome = codeOnly(try appSource("SettingsChrome.swift"))
        guard let surface = braceBlock(after: "struct SettingsCardSurface", in: chrome) else {
            return XCTFail("缺少 SettingsCardSurface")
        }
        XCTAssertTrue(surface.contains("glassEffect(.regular"),
                      "浅色卡片要用与搜索模块同一套 Liquid Glass")
        XCTAssertTrue(surface.contains("clipShape"),
                      "★ 玻璃自带的外阴影必须裁掉，否则卡片边缘发灰")
        XCTAssertTrue(surface.contains("style.cardRadius"), "圆角取策略里的值，不在视图里另写")
        XCTAssertFalse(surface.contains("cornerRadius: 12"), "圆角不许在视图里拍脑袋")
        XCTAssertTrue(chrome.contains("SearchGlass.isAvailable && !reduceTransparency"),
                      "「降低透明度」打开时不铺真玻璃（与搜索区同一条规矩）")
    }

    /// ★ 向导的分组底与设置页卡片**同一套形状**：同一圆角、同一句玻璃、同一道描边。
    ///
    /// 2026-10-27 深夜用户定「向导一起跟随」。之前向导是 12 圆角、无描边，
    /// 而设置页是另一套 —— 两个窗口并排看根本不是一套东西。
    func testWizardSectionFollowsTheSettingsCardShape() throws {
        let components = codeOnly(try appSource("FFComponents.swift"))
        guard let section = braceBlock(after: "struct FFSettingsSection", in: components) else {
            return XCTFail("缺少 FFSettingsSection")
        }
        XCTAssertTrue(section.contains("SearchModuleLayout.moduleRadius"),
                      "向导卡片圆角要跟搜索模块同值（不许再写 12）")
        XCTAssertTrue(section.contains("glassEffect(.regular"),
                      "向导卡片与设置页同一句玻璃")
        XCTAssertTrue(section.contains("clipShape"), "同样要裁掉玻璃自带的外阴影")
        XCTAssertTrue(section.contains("reduceTransparency"),
                      "降低透明度时不铺真玻璃")
        XCTAssertFalse(section.contains("cornerRadius: 12"), "12 圆角已撤掉")
    }

    /// ★ 搜索框与搜索结果现在是**两块独立窗口**，各自一块完整的玻璃面。
    ///
    /// 2026-10-27 用户要求模块化：「搜索框一个文件，搜索结果一个文件，
    /// 设置一个文件，这样以后可以单独修改某一个而不会影响其他」。
    /// 2026-10-28 再进一步：「钉住前后的搜索框和搜索结果都应该可以单独移动」——
    /// 同一窗口里的两块永远一起动，所以两块各自成了 `NSPanel`。
    ///
    /// 这条守的是**边界**而不是长相：页面里一旦出现列表/遮罩/表面，就说明
    /// 「单改一块不影响另一块」已经不成立了。
    func testSearchFieldAndResultsLiveInTwoSeparateWindows() throws {
        let page = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(page.contains("SearchFieldModule("), "搜索框那一块要装搜索框模块")
        XCTAssertFalse(page.contains("SearchResultsModule("),
                       "★ 结果已经搬进自己的窗口；页面里再排一块就等于又绑回同一个窗口")
        XCTAssertFalse(page.contains("LazyVStack"), "结果列表属于结果模块，不许写回页面")
        XCTAssertFalse(page.contains("SearchGlassLens"), "遮罩属于结果模块")
        XCTAssertFalse(page.contains("searchModuleSurface"),
                       "模块表面由模块自己画；页面再画一层就又是「一块大玻璃」")

        let resultsPage = codeOnly(try appSource("SearchResultsPanel.swift"))
        XCTAssertTrue(resultsPage.contains("SearchResultsModule("), "结果那一块要装结果模块")
        XCTAssertFalse(resultsPage.contains("SearchFieldModule("),
                       "两块窗口各住各的模块，不许互相装")

        // 两块窗口各自能拖、各自没有表面、各自上沿固定。
        let controller = codeOnly(try appSource("SearchPanelController.swift"))
        let resultsController = codeOnly(try appSource("SearchResultsPanel.swift"))
        for source in [controller, resultsController] {
            XCTAssertTrue(source.contains("isMovableByWindowBackground = true"),
                          "两块窗口都要能单独拖（用户：「都应该可以单独移动」）")
            XCTAssertTrue(source.contains("hasShadow = false"),
                          "透明窗口的阴影按窗口矩形画，会把圆角糊成方的")
        }
        XCTAssertTrue(controller.contains("SearchWindowRegistry"),
                      "★ 键盘监视器要知道「两块窗口都算搜索区」，否则点过结果之后键盘就死了")
        XCTAssertTrue(controller.contains("register(field: panel, results: results.panel)"),
                      "两块窗口是**两个实例**：登记表里必须是两个不同的 panel")

        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        XCTAssertTrue(field.contains(".searchModuleSurface("), "搜索框自己就是一块完整玻璃面")
        XCTAssertFalse(field.contains("SearchGlassLens()"),
                       "★ 不许再在搜索框里套第二层胶囊——那正是「四周还有遮罩」的来源")

        let results = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertTrue(results.contains(".searchModuleSurface("), "结果区是一块独立的模块")

        // 圆角只有一处出处：两个模块都不许自己传 radius。
        XCTAssertFalse(field.contains("cornerRadius:"), "搜索框不许自己定圆角")
        XCTAssertFalse(results.contains("cornerRadius:"), "结果模块不许自己定圆角")
        XCTAssertTrue(codeOnly(try appSource("SearchGlassChrome.swift")).contains("SearchModuleLayout.moduleRadius"),
                      "模块圆角取自 Core")
    }

    /// ★★ 点外面收窗：豁免名单只能收**看得见**的窗口（2026-10-28 报障）。
    ///
    /// 报障原话：「搜索结果钉住后,关闭搜索结果,搜索框不再点击任意位置关闭」。
    /// `orderOut` **不清 frame**：结果窗一收起来，那块 680×470 的矩形仍然停在
    /// 搜索框正下方（钉住窗关掉之后同理），于是「看起来是空桌面」的地方被一个
    /// 看不见的窗口豁免掉了，用户点哪儿都不收窗。
    ///
    /// 判定本身已搬进 Core（`SearchClickOutsideTests` 覆盖），这里守的是
    /// **接线**：App 层必须把「可见」筛对，并且不许再自己判某一块窗口的 frame。
    func testClickOutsideIgnoresHiddenWindowsAndDelegatesToCore() throws {
        let controller = codeOnly(try appSource("SearchPanelController.swift"))
        let body = try XCTUnwrap(braceBlock(after: "private func dismissIfClickOutside", in: controller),
                                 "找不到 dismissIfClickOutside")
        XCTAssertTrue(body.contains("SearchClickOutside.shouldDismiss("),
                      "判定必须走 Core：App 层再拼一套，两边迟早不一致")
        XCTAssertTrue(body.contains("$0.isVisible"),
                      "★ 豁免名单必须逐窗判 isVisible：隐藏窗口的 frame 留在原地不动")
        XCTAssertTrue(body.contains("$0.canBecomeKey"),
                      "菜单/提示这类辅助窗口弹出时也「可见」，不许被当成自家窗口")
        XCTAssertFalse(body.contains("results.panel.frame"),
                       "★ 结果窗的 frame 不许单独豁免——它收起来之后 frame 不变，"
                       + "正是这条报障的根因")
    }

    /// ★★ 结果区的**尺寸与边框**（2026-10-28 用户报障后的两条硬约束）。
    ///
    /// 报障原话：
    /// 1. 「搜索结果的区域大小固定，否则切换的时候侧边栏大小频繁跳动，影响筛选」；
    /// 2. 「目前动态玻璃效果如果屏幕是纯白背景时显示效果不好……建议增强一下边框的显示效果」。
    ///
    /// 两条都是「改回去也能编译、只是变丑」的那种退化，所以各钉一条结构闸：
    /// 高度只能取 Core 的固定值（且不许再出现结果条数），描边必须画在
    /// `clipShape` 之后（画在背景里会被白底吃掉，正是报障的形态）。
    func testResultsPanelIsFixedSizeAndModuleSurfaceCarriesAnEdge() throws {
        let page = codeOnly(try appSource("SearchResultsPanel.swift"))
        let expanded = try XCTUnwrap(braceBlock(after: "private var expandedHeight", in: page),
                                     "找不到 expandedHeight")
        XCTAssertTrue(expanded.contains("SearchModuleLayout.resultsListHeight"),
                      "结果区高度只能取 Core 的固定值")
        XCTAssertFalse(expanded.contains("results.count"),
                       "★ 高度不许再随结果条数变——那正是切换时侧边栏跳动的原因")
        XCTAssertFalse(expanded.contains("maximumVisibleRows"),
                       "连「min(条数, 最多几行)」也不需要了：一屏固定就是这么多行")
        XCTAssertFalse(page.contains("lastResultsHeight"),
                       "为「搜索中别缩回去」留的那份高度缓存已经没用了；留着高度又变回变量")

        let layout = codeOnly(try appSource("NativeMaterialView.swift"))
        XCTAssertTrue(layout.contains("maximumVisibleRows = SearchModuleLayout.resultsVisibleRows"),
                      "App 侧的「一屏几行」必须引用 Core 的同名常量，不许各存一个数")

        // 描边：必须在 clipShape **之后**，且深浅色都问 Core。
        let chrome = codeOnly(try appSource("SearchGlassChrome.swift"))
        guard let surfaceStart = chrome.range(of: "struct SearchModuleSurface") else {
            return XCTFail("找不到 SearchModuleSurface")
        }
        let surface = String(chrome[surfaceStart.lowerBound...])
        guard let clip = surface.range(of: ".clipShape(shape)"),
              let edge = surface.range(of: "overlay { edge(shape) }") else {
            return XCTFail("模块表面必须 clipShape 之后再画描边")
        }
        XCTAssertLessThan(clip.lowerBound, edge.lowerBound,
                          "★ 描边要画在裁剪**之后**：画在背景里会被圆角剪掉，白底上等于没画")
        XCTAssertTrue(surface.contains("SearchGlassEdge.outer(dark: isDark)"),
                      "外描边必须按深浅外观取 Core 的值（白底上得是深色线）")
        XCTAssertTrue(surface.contains("allowsHitTesting(false)"),
                      "描边是表面的一部分，参与命中测试就又拖不动窗口了")
        XCTAssertTrue(chrome.contains("init(glassStroke stroke: SearchGlassEdge.Stroke)"),
                      "Core 的描边取值要有唯一的颜色换算入口")
    }

    /// ★ 类型条**搬进结果模块顶部**，右边多一枚「钉住」（2026-10-28 用户改口）。
    ///
    /// 用户原话：「把文件类型和搜索结果模块放在一起，搜索结果顶部文件类型，
    /// 侧边文件位置」。上一版它长在搜索框模块下方（用户自己 2026-10-27 定的
    /// 「此功能为搜索框模块的功能」），这一版整块搬到结果模块。
    ///
    /// 锁四件事：**位置**（结果模块第一行，不是搜索框里）、**清单来自 Core**、
    /// **高度算进结果模块**（少算就会被模块底边裁掉）、**搜索框里不许再留一份**。
    func testTypeBarLivesAtTheTopOfTheResultsModule() throws {
        let toolbar = codeOnly(try appSource("SearchResultsToolbar.swift"))
        XCTAssertTrue(toolbar.contains("SearchTypeBar.entries"),
                      "★ 类型清单只能来自 Core（`SearchTypeBar`）：各写一份就会「条上有压缩包、别处没有」")
        XCTAssertTrue(toolbar.contains("SearchTypeBar.selectedID("),
                      "选中的是哪一段也由 Core 判定")
        XCTAssertTrue(toolbar.contains("selectType("), "点某一段要回调出去")
        XCTAssertTrue(toolbar.contains("canPin"), "工具条右侧还有「钉住」")

        let results = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertTrue(results.contains("SearchResultsToolbar("),
                      "★ 类型条必须长在结果模块里（用户：「搜索结果顶部文件类型」）")
        let body = try XCTUnwrap(braceBlock(after: "var body: some View {", in: results))
        guard let toolbarCall = body.range(of: "SearchResultsToolbar(") else {
            return XCTFail("结果模块的 body 里没有工具条")
        }
        guard let sidebarCall = body.range(of: "SearchResultsSidebar(") else {
            return XCTFail("结果模块的 body 里没有侧边栏")
        }
        XCTAssertLessThan(toolbarCall.lowerBound, sidebarCall.lowerBound,
                          "类型条在**顶部**：它必须排在「侧边栏 + 结果」那一行之前")

        // 搜索框模块里不许再留一份（两处各画一条，改一处就会对不上）。
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        XCTAssertFalse(field.contains("SearchTypeBar"),
                       "★ 类型条已经从搜索框模块搬走，不许留副本")
        XCTAssertFalse(field.contains("SearchModuleLayout.typeBarHeight"),
                       "高度也随之搬走：搜索框模块只剩输入行")

        // 页面算窗口高度时必须把类型条那一截算进**结果模块**。
        // ★ 2026-10-28：结果搬进独立窗口后，「算高度」这件事跟着搬到
        //   `SearchResultsPanel.swift`（`contentModuleHeight`）。
        let page = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(page.contains("SearchFieldModule.height("),
                      "页面必须调用模块的高度算法，不许各写一份")
        let resultsPage = codeOnly(try appSource("SearchResultsPanel.swift"))
        let content = try XCTUnwrap(braceBlock(after: "private var contentModuleHeight", in: resultsPage))
        XCTAssertTrue(content.contains("SearchModuleLayout.typeBarHeight"),
                      "★ 类型条高度必须算进结果模块，否则它会被模块底边裁掉一半")

        // 品牌图标仍是入口（这条没变，一起守着）。
        XCTAssertTrue(field.contains("Button(action: openSettings)"),
                      "品牌图标必须接 openSettings")
        XCTAssertTrue(field.contains("let openSettings: () -> Void"),
                      "打开设置由外部注入：视图不许自己去抓 SettingsWindow")
        XCTAssertFalse(field.contains("accessibilityHidden(true)"),
                       "图标是入口，不许对读屏隐藏")
    }

    /// ★★ 「钉在桌面上」：结果模块能变成一块独立的置顶窗口，⌘W 关掉。
    ///
    /// 用户原话（2026-10-28）：「搜索结果默认第一次打开是在搜索框下方，
    /// 但是可以拖动到任意位置并钉在桌面上，保留此次搜索结果，
    /// 此时打开搜索框可以继续进行下一组的搜索……关闭时可以用 command+w 的方式关闭，
    /// 非钉住状态下，和搜索框关闭的逻辑一样」。
    ///
    /// 这里锁的是**四件会静默失效的事**：
    /// 1. 窗口层级必须是 `.floating`（不置顶的话「钉住」等于没钉）；
    /// 2. `.canJoinAllSpaces`（切桌面就找不到 = 没钉住）；
    /// 3. ⌘W 有真正的处理器（无标题栏窗口 `performClose` 只会响一声）；
    /// 4. 快照是**抄下来的行**（盯着 `model.results` 的话，下一组搜索一来内容就变了）。
    func testPinnedResultsWindowStaysOnTopAndClosesWithCommandW() throws {
        let pinned = codeOnly(try appSource("PinnedResultsWindow.swift"))
        XCTAssertTrue(pinned.contains("panel.level = .floating"),
                      "钉住必须置顶：用户切到别的 App 之后还要看得见")
        XCTAssertTrue(pinned.contains(".canJoinAllSpaces"),
                      "切 Space 时也要跟着，否则「钉住」只在当前桌面成立")
        XCTAssertTrue(pinned.contains("isMovableByWindowBackground = true"),
                      "钉住的窗口要能拖（用户：「并且拖动」）")
        XCTAssertTrue(pinned.contains("charactersIgnoringModifiers?.lowercased() == \"w\""),
                      "⌘W 必须真的被处理：无标题栏窗口的 performClose 只会响一声")
        XCTAssertTrue(pinned.contains("close(id)"), "⌘W 要关掉当前那块窗口本身")
        // ★ 2026-10-28 改口：行的来源从 `ForEach(snapshot.rows)` 变成
        //   「筛完之后的那一批」（`snapshot.rows(fileType:location:)`），
        //   但「内容来自快照、不是 model.results」这条不许松。
        XCTAssertTrue(pinned.contains("snapshot.rows(fileType: fileType, location: location)"),
                      "窗口内容是**快照**的行（再按两个限定就地筛），不许直接绑 model.results")
        XCTAssertFalse(pinned.contains("model.results"),
                       "★ 盯着 model.results 的话，下一组搜索一来这块窗口里的内容就跟着变了")

        // ★ 钉住之后筛选仍要保留，而且能改（2026-10-28 用户追加）。
        XCTAssertTrue(pinned.contains("SearchResultsToolbar("),
                      "钉住的窗口顶部要有类型条")
        XCTAssertTrue(pinned.contains("SearchResultsSidebar("),
                      "钉住的窗口左侧要有位置侧边栏")
        XCTAssertTrue(pinned.contains("initialValue: snapshot.fileType"),
                      "初始选中项 = 钉住那一刻的类型限定，否则一开出来就被重置成「全部」")
        XCTAssertTrue(pinned.contains("initialValue: snapshot.location"),
                      "位置同理")
        // ★★ 2026-10-28 改口（用户报障：「钉住后位置会随机跳一下」「切换时侧边栏跳动」）：
        //   高度不再是「筛完几行就是几行」——那样窗口会在上屏后被 SwiftUI 再改一次尺寸，
        //   改尺寸时上沿固定，看起来就是跳。现在高度在开窗时算一次、传进来，之后不动。
        XCTAssertTrue(pinned.contains("let height: CGFloat"),
                      "窗口高度由开窗时算一次传进来，视图不许再自己按行数算")
        XCTAssertFalse(pinned.contains("SearchPanelSizing"),
                       "★ 钉住窗里不许再有尺寸同步：上屏后改尺寸就是「跳一下」的来源")
        XCTAssertTrue(pinned.contains("snapshot.rows(fileType: snapshot.fileType"),
                      "开窗高度要按**首屏真的会显示的那批行**算（先筛再量），否则第一帧就会缩一次")

        // 快照本身在 Core：条数与高度都由同一份数据算。
        let core = codeOnly(try coreSource("PinnedResults.swift"))
        XCTAssertTrue(core.contains("public let rows: [SearchResult]"),
                      "快照要把行抄下来（不是下标、不是引用）")
        XCTAssertTrue(core.contains("windowHeight(rowCount: Int, rowHeight: CGFloat)"),
                      "窗口高度必须由快照行数算出来：算不出来就会被切掉最后一行")
        XCTAssertTrue(core.contains("public let fileType: SearchFileTypeCatalog.FileType?"),
                      "快照要记住类型限定，否则窗口一开出来就把它抹掉了")
        XCTAssertTrue(core.contains("public let location: SearchTarget"),
                      "位置限定同理")

        // 钉住动作：先取快照、再清空搜索会话。
        // ★ 2026-10-28 起它在 AppModel 里（结果那一块窗口也能触发钉住）。
        let modelCode = try appModelCode()
        let pin = try XCTUnwrap(braceBlock(after: "func pinCurrentResults()", in: modelCode))
        let snapshot = try XCTUnwrap(pin.range(of: "currentPinnedResults()"))
        let clear = try XCTUnwrap(pin.range(of: "clearSearchSession()"))
        XCTAssertLessThan(snapshot.lowerBound, clear.lowerBound,
                          "★ 顺序不能反：先取快照再清空，否则钉出来是一块 0 项的玻璃")
        XCTAssertTrue(pin.contains("focusFlashFindField"),
                      "★ 钉完要把键盘交回搜索框：用户是在结果窗里点的图钉，那块窗口马上消失")

        // 钉住的行不在当前结果里了，打开动作必须走快照解析这条路。
        XCTAssertTrue(modelCode.contains("func openPinned("),
                      "钉住的行要能打开：解析入口必须是快照版（不要求还在 results 里）")
    }

    /// ★ 「继续搜索」：200 条只是第一批，状态栏要给一条继续的路。
    ///
    /// 用户 2026-10-28：「限制 200 结果后，如对结果不满意，可以选择继续搜索」。
    ///
    /// ★ 关键判据是**按钮只在池子里还有东西时出现**：一直显示的话，
    /// 点到最后一批之后按钮还在，点了没反应——这正是本项目最怕的假状态。
    func testStatusBarOffersContinueSearchOnlyWhileCandidatesRemain() throws {
        let bar = codeOnly(try appSource("SearchStateView.swift"))
        XCTAssertTrue(bar.contains("SearchResultLimit.continueTitle"),
                      "按钮文案取自 Core，界面不许另写一句")
        let button = try XCTUnwrap(braceBlock(after: "if canShowMore, let showMore", in: bar))
        XCTAssertTrue(button.contains("Button(action: showMore)"),
                      "★ 没有点击动作的按钮等于没做")

        let results = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertTrue(results.contains("model.canShowMoreResults"),
                      "按钮的可见性必须问模型（池子里还有没有），不许写死 true")
        XCTAssertTrue(results.contains("model.showMoreResults()"),
                      "点击要接到模型上那条「再放一批」")

        // 上限与步长都只有 Core 一处出处。
        let core = codeOnly(try coreSource("SearchResultLimit.swift"))
        XCTAssertTrue(core.contains("public static let step = perSearch"),
                      "步长与首批同值，且只在这一处出现")
        XCTAssertFalse(results.contains("200"),
                       "界面不许再写死 200：调大调小只改 Core")
    }

    /// ★★ 模块表面**不许吞掉窗口拖动**（2026-10-28 报障：「闪寻搜索框不能拖动了」）。
    ///
    /// 成因：`NSPanel.isMovableByWindowBackground` 会不会真的拖，取决于光标下面
    /// 那个视图是否允许「窗口背景拖动」。模块化之后两块模块各自铺满整窗，
    /// 表面是一块 `shape.fill` —— 在 SwiftUI 看来那是**内容**，
    /// 于是整块面板从「空白可拖」变成「实心不可拖」，一个可抓的位置都不剩。
    ///
    /// 修法必须写死在这里：表面**不参与命中测试**。只加回 `shape.fill` 而不带
    /// 这一句，拖动会再次静默失效（编译过、截图也看不出）。
    func testModuleSurfaceDoesNotSwallowWindowDrag() throws {
        let chrome = codeOnly(try appSource("SearchGlassChrome.swift"))
        let surface = try XCTUnwrap(braceBlock(after: "struct SearchModuleSurface", in: chrome))
        XCTAssertTrue(surface.contains(".allowsHitTesting(false)"),
                      "★ 表面必须 allowHitTesting(false)，否则整块面板拖不动")
        // ★ 必须落在 `.background {` **之后**、`clipShape` **之前**：
        //   放到 clipShape 后面只是改了内容的命中测试，表面照样把窗口背景吞掉。
        let background = try XCTUnwrap(surface.range(of: ".background {"))
        let clip = try XCTUnwrap(surface.range(of: ".clipShape("))
        let hit = try XCTUnwrap(surface.range(of: ".allowsHitTesting(false)"))
        XCTAssertLessThan(background.lowerBound, hit.lowerBound,
                          "命中测试要让在表面（background）上")
        XCTAssertLessThan(hit.lowerBound, clip.lowerBound,
                          "★ 表面在 clipShape 之前就铺好了：这一句必须在两者之间")

        let panel = codeOnly(try appSource("SearchPanelController.swift"))
        XCTAssertTrue(panel.contains("isMovableByWindowBackground = true"),
                      "面板本身仍要声明「可以拖背景」，两条缺一不可")
    }

    /// ★ 结果模块里多了一列侧边栏，换位置要有**页面切换动画**（2026-10-27 晚）。
    ///
    /// 用户原话：「新增侧边栏功能 从侧边栏可以选择搜索位置 默认是全部 依次往下排列
    /// 做成抽屉式的感觉 点击切换有页面切换动画 切换后显示该位置的文件 ……
    /// 侧边栏不要突出搜索框左右宽度 宽度保持一致」。
    ///
    /// 四件事在这里锁住：**在结果模块里**、**吃同一份位置候选**、**宽度不撑窗口**、
    /// **换页真有 transition + 动画**（只有 `.id()` 没有 `transition` 的话，那次切换
    /// 看起来就是列表原地刷新——这正是「看着像没动画」的典型写法）。
    func testResultsModuleHasASidebarWithAnimatedPageSwitch() throws {
        let results = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertTrue(results.contains("SearchResultsSidebar("),
                      "侧边栏要挂在结果模块里（模块 = 一列侧边栏 + 结果页）")
        XCTAssertTrue(results.contains("model.sidebarEntries"),
                      "★ 侧边栏必须吃 AppModel 那份位置候选（与 `\\` 面板同源），不许自己列一遍")
        XCTAssertTrue(results.contains(".transition(pageTransition)"),
                      "★ 只有 `.id()` 不叫页面切换：没有 transition 就是原地刷新")
        XCTAssertTrue(results.contains("pageID"),
                      "页标识要有一个明确的来源（当前位置），不许另立一份 @State")

        // 侧边栏宽度来自 Core，并且不许把窗口撑宽（它是 HStack 的一列）。
        let sidebarCode = codeOnly(try appSource("SearchResultsSidebar.swift"))
        XCTAssertTrue(results.contains("SearchModuleLayout.sidebarWidth") ||
                      sidebarCode.contains("SearchModuleLayout.sidebarWidth"),
                      "侧边栏宽度取自 Core（与模块圆角同一个出处）")

        let sidebar = sidebarCode
        XCTAssertFalse(sidebar.contains("\"全部位置\""),
                       "侧边栏不许自己写死「全部位置」那一行：条目全部来自 SearchSidebar.entries")
        XCTAssertTrue(sidebar.contains("matchedGeometryEffect"),
                      "选中底要会滑动（抽屉感就靠这一口气：瞬移看起来像两个列表）")
        XCTAssertTrue(sidebar.contains("select("),
                      "点一行要回调出去，由 AppModel 统一换算成位置限定")

        // ★★ 每一行都写自己的来源名（2026-10-29 报障：飞牛「存储空间 2」下面整片空白）。
        // 上一版按「同一个来源只在组首行写一次」处理，视图自己维护一张分组表 ⇒
        // 同源的第二个位置丢掉的不只是重复的设备名，还有它自己的「未连接」状态。
        // 判定搬进 Core 之后，视图只消费结果；这里守的是「别又搬回去」。
        XCTAssertTrue(sidebar.contains("SearchSidebar.subtitleRows"),
                      "★ 副标题该不该画必须问 Core（subtitleRows）：视图自己分组就会重新丢掉同源第二行")
        XCTAssertFalse(sidebar.contains("groupStarts"),
                       "「同源只在组首行写一次」已废弃：它会把第二行的来源名与「未连接」一起省掉")
    }

    /// ★ 搜索结果区用**跟随鼠标的玻璃遮罩**，不是系统的选中蓝 / 悬停灰。
    ///
    /// 2026-10-27 用户要求：「搜索结果和搜索框保持一致，均为动态玻璃效果；
    /// 可以跟随鼠标和移动选择当前的目标，设置一个更加透明的玻璃遮罩替换当前的
    /// 灰色背景和蓝色背景；遮罩移动时能够在边缘位置明显看到字体逐渐放大和缩小的效果；
    /// 根据 mac 15 以下系统保持原方案不变。」
    ///
    /// 结构上必须成立的三件事，少一件效果就没了：
    /// 1. 结果列表**不是 `List`**——`List` 的选中底色是系统画的，改不成玻璃，
    ///    也拿不到「遮罩滑到哪」的时机；
    /// 2. 遮罩是列表里**一个**共用视图（`SearchGlassLens`），不是每行自己画一层；
    /// 3. 缩放走 Core 的 `SearchLens` 曲线（`searchLensMagnification`），
    ///    不许在视图里写 `scaleEffect(1.05)`——那样「边缘变小」这一档永远没有。
    func testSearchResultsUseASlidingGlassLensInsteadOfListSelection() throws {
        let results = codeOnly(try appSource("SearchResultsModule.swift"))
        XCTAssertFalse(results.contains("List(visibleResults, selection:"),
                       "★ 结果列表不许再用 List：系统选中蓝与「改不成玻璃」是同一条根因")
        XCTAssertTrue(results.contains("LazyVStack"),
                      "结果区改用 LazyVStack（行高固定，第 N 行 = N × 行高）")
        XCTAssertTrue(results.contains("SearchGlassLens()"),
                      "遮罩必须是那一块共用的玻璃")
        XCTAssertTrue(results.contains("lensPosition:"),
                      "列表要把遮罩位置传给每一行（缩放由行内的文字块算）")

        let page = codeOnly(try appSource("SearchView.swift"))
        XCTAssertTrue(page.contains("SearchGlass.style(reduceTransparency:"),
                      "玻璃 / 老方案的判定只能问 Core")
        XCTAssertTrue(page.contains("@Environment(\\.accessibilityReduceTransparency)"),
                      "★ 辅助功能「降低透明度」必须参与判定，否则玻璃会绕过无障碍设置")

        // 行把「离遮罩多远」接过去，缩放只作用在文字块上（整行放大 5.5% 会把行尾标签顶出可视区）。
        let row = codeOnly(try appSource("SearchResultRow.swift"))
        XCTAssertTrue(row.contains("lensPosition"), "行要知道遮罩在哪，才能算自己的缩放")
        XCTAssertTrue(row.contains("searchLensMagnification("),
                      "缩放挂在文字块上，不是整行")

        // 老方案的两片底色必须是系统常量：自绘之后若写成死颜色，
        // 浅色/深色两套外观与「选中时字转白」都会跟系统对不上。
        let chrome = codeOnly(try appSource("SearchGlassChrome.swift"))
        XCTAssertTrue(chrome.contains(".selectedContentBackgroundColor"),
                      "老方案的选中蓝要用系统色")
        XCTAssertTrue(chrome.contains(".quaternaryLabelColor"),
                      "老方案的悬停灰要用系统色")
        XCTAssertTrue(chrome.contains("#available(macOS 26.0, *)"),
                      "玻璃调用必须有运行期门")
        XCTAssertTrue(chrome.contains("#if compiler(>=6.2)"),
                      "玻璃调用必须有编译期门（旧工具链要编得过）")
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

    /// ★ 一级导航是顶部**玻璃分段控件**：间距拉开、选中块会滑过去。
    ///
    /// 2026-10-27 用户要求：「间距拉开，切换页面出现动态玻璃的切换效果」。
    /// 系统 `Picker(.segmented)` 给不了滑动的选中块（换页就是硬切），
    /// 所以导航自绘成 `SettingsPanePicker`。锁住的是四条底线：
    /// 1. 页面集合仍唯一来自 Core（`SettingsPane.allCases`，不许写死四个字符串）；
    /// 2. 每一段仍挂 `settings-nav-` 标识，键盘与 VoiceOver 靠它定位；
    /// 3. 选中块靠 `matchedGeometryEffect` **滑**过去，并且服从「减少动态效果」；
    /// 4. 旧的侧栏那一套（split view / 侧栏样式 / 列宽 / `List(selection:)`）不许回来。
    func testTopLevelNavigationIsASlidingGlassPicker() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("SettingsPanePicker(selection: $pane)"),
                      "一级导航要用 SettingsPanePicker（玻璃分段控件）")
        for gone in ["NavigationSplitView", ".listStyle(.sidebar)",
                     "navigationSplitViewColumnWidth", "List(selection: $pane)"] {
            XCTAssertFalse(settings.contains(gone),
                           "侧栏的 \(gone) 已随导航收敛撤掉")
        }

        let chrome = codeOnly(try appSource("SettingsChrome.swift"))
        guard let picker = braceBlock(after: "struct SettingsPanePicker", in: chrome) else {
            return XCTFail("缺少一级导航的 SettingsPanePicker")
        }
        XCTAssertTrue(picker.contains("ForEach(SettingsPane.allCases) { item in"),
                      "四页必须由 Core 的 SettingsPane 遍历出来，不许在视图里另写一份")
        XCTAssertTrue(picker.contains("settings-nav-"),
                      "每一段都要挂 settings-nav- 标识，键盘导航与 VoiceOver 靠它定位")
        XCTAssertTrue(picker.contains(".accessibilityLabel(\"设置页面\")"),
                      "控件的用途对 VoiceOver 要说得出来（原来靠 Picker 的标签）")
        XCTAssertTrue(picker.contains(".accessibilityAddTraits(isSelected ? [.isSelected] : [])"),
                      "选中态要作为无障碍状态播报，不能只靠颜色")
        XCTAssertTrue(picker.contains("matchedGeometryEffect"),
                      "★ 选中块要**滑**过去：同一块玻璃在四段之间移动，这才是「动态玻璃」")
        XCTAssertTrue(picker.contains("glassEffect"),
                      "选中块要是玻璃，不是一块白底方块")
        XCTAssertTrue(picker.contains("accessibilityReduceMotion"),
                      "「减少动态效果」打开时不许还滑：这一档系统设置里也是直接落位")
        XCTAssertFalse(picker.contains("Image(systemName:"),
                      "四页的页名自带解释，分段上不必再摆图标")
        // 「间距拉开」：段本身要有左右留白，否则还是系统控件那种挤在一起的样子。
        XCTAssertTrue(picker.contains(".padding(.horizontal, 26)"),
                      "段与段之间要拉开：每一段自己带 26pt 左右留白")
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
        // 标题文字由 `SettingsCard` 统一给出（字号来自 Core 的字号阶梯），分段本身没变。
        XCTAssertTrue(settings.contains("SettingsCard(\"网络存储\")"),
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

    /// ★★ 「输入命令」整套删掉之后的守卫（2026-10-28 用户报障）。
    ///
    /// 用户原话：「输入命令的功能取消了 但是下拉框还在」。实际发生的是：
    /// 蓝色标签删掉了，但 `\` / `/` 仍然会解析成命令模式、仍然会弹面板——
    /// 界面上于是只剩一个**没有来由**的下拉框。
    ///
    /// 这条是**反向守卫**：断言「整套东西都不在了」，因为把任何一处加回来，
    /// 用户看到的下拉框就会再出现一次，而别的断言全都还是绿的。
    /// 判据是**文件与符号都不存在**，不是「某处没调用」——
    /// 后者太容易靠改一个 if 就绕过去。
    func testCommandInputAndItsPaletteAreGoneEntirely() throws {
        // 1. 面板视图文件必须已经删掉。
        let pkgRoot = URL(fileURLWithPath: (#filePath as NSString).deletingLastPathComponent)
            .deletingLastPathComponent().deletingLastPathComponent()
        let appDir = pkgRoot.appendingPathComponent("Sources/FlashFind2App")
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: appDir.appendingPathComponent("SearchCommandPaletteView.swift").path),
                       "命令面板视图必须删掉，否则它还会被某处引用回来")

        // 2. App 层不许再有命令模式的状态、判定或视图调用。
        for file in ["AppModel+SearchCommand.swift", "AppModel+SearchView.swift",
                     "SearchView.swift", "SearchResultsModule.swift", "SearchKeyboardScope.swift"] {
            guard let code = try? codeOnly(appSource(file)) else { continue }
            for forbidden in ["SearchCommandPaletteView", "isCommandModeActive",
                              "SearchCommandParser", "commandSelection",
                              "commandKeyboardNavigationRevision"] {
                XCTAssertFalse(code.contains(forbidden),
                               "\(file) 里还留着命令模式的痕迹：\(forbidden)")
            }
        }

        // 3. Core 侧：解析器与键盘路由的命令分支也一并删掉。
        let catalog = codeOnly(try coreSource("SearchCommandCatalog.swift"))
        XCTAssertFalse(catalog.contains("SearchCommandParser"),
                       "命令前缀的解析器必须删掉：留着它就随时能被重新接上界面")
        let router = codeOnly(try coreSource("SearchKeyRouter.swift"))
        XCTAssertFalse(router.contains("inCommandMode"),
                       "键盘路由不许再有命令模式这个上下文")
        XCTAssertFalse(router.contains(".commandSubmit"),
                       "键盘路由不许再有「执行命令」这条分支")

        // 4. `changedQuery` 不再为命令模式短路：输入就是关键词。
        let code = try appModelCode()
        guard let body = braceBlock(after: "func changedQuery()", in: code) else {
            return XCTFail("找不到 changedQuery")
        }
        XCTAssertFalse(body.contains("isCommandModeActive"),
                       "输入 `/` 或 `\\` 现在就是普通关键词，不许再短路搜索")
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

    /// ★ 输入行里**不许再有**那排蓝色限定标签（2026-10-27 用户决定删掉）。
    ///
    /// 历史：这排标签是 `\` / `/` 命令设下的限定的可视化（1.1.16 起，用户当时
    /// 要求「用蓝色字体更小一号把选择的内容放置在最前边」，摆在关键词后面
    /// 会被看成关键词的一部分）。到这一版，位置有了左侧边栏、类型有了下方
    /// 类型条 —— 同一件事的第三个入口，还白占输入框宽度，用户遂定「可以删除」。
    ///
    /// ★ 这是**反向守卫**：断言「不出现」比断言「出现」更需要守住 ——
    /// 有人把标签加回来时，界面上会多出第三份重复的限定展示（卡片、侧边栏、
    /// 类型条已经各有一份），而其它断言全都还是绿的。
    /// 限定的**状态**仍在（`tokenBar`），只是不再在输入行里画出来。
    func testSearchFieldCarriesNoTokenChips() throws {
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        for forbidden in ["tokenStrip", "deleteToken", "Color.accentColor", "SearchTokenBar"] {
            XCTAssertFalse(field.contains(forbidden),
                           "搜索框不许再画蓝色限定标签：\(forbidden)")
        }
        // 输入行里只剩「图标 + 输入框 + 清除 + 重搜」，限定不再是其中一员。
        let rowCode = try body(of: "row", in: field)
        XCTAssertFalse(rowCode.contains("tokens"), "输入行不许再接收限定列表")
        XCTAssertTrue(rowCode.contains("TextField("), "输入行本体必须还在")

        // 只删视图、把参数留成没人用的死参数，同样是残留。
        XCTAssertFalse(field.contains("let tokens:"), "不许留下没人用的 tokens 参数")
        XCTAssertFalse(field.contains("let deleteToken:"), "不许留下没人用的 deleteToken 参数")
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

    /// ★ 标签没了，但**删除键撤限定**那条要留着（用户只让删标签，没让改键）。
    ///
    /// 1.1.16 起有两条删限定的路径：点标签（删被点的那一枚）与删除键（LIFO）。
    /// 标签删掉之后点击那条整体消失，只剩删除键 —— 它的判定必须在 Core
    /// （`keywordEmpty` 不成立时不许抢键，否则输入框删不动字），
    /// App 层不许自己写「删哪个」。
    func testTokenChipClicksAreGoneButBackspaceStillUndoesOneLimit() throws {
        let field = codeOnly(try appSource("SearchFieldModule.swift"))
        XCTAssertFalse(field.contains("deleteToken"), "点击删限定随标签一起去掉了")

        let model = codeOnly(try appSource("AppModel+SearchCommand.swift"))
        XCTAssertFalse(model.contains("var searchTokens"), "视图不再需要限定列表，模型也不许留")
        XCTAssertFalse(model.contains("func deleteSearchToken(_ slot:"),
                       "按槽位删的入口已经没人调了，留着就是死代码")
        XCTAssertTrue(model.contains("slotToRemoveOnBackspace"),
                      "删除键仍要走 Core 的判定（关键词非空时不抢键）")
        XCTAssertTrue(model.contains("func deleteSearchToken()"),
                      "删除键这条入口要留着")

        let view = codeOnly(try appSource("SearchView.swift"))
        XCTAssertFalse(view.contains("model.searchTokens"), "视图不许再读限定列表")
        XCTAssertTrue(view.contains("deleteSearchToken: { model.deleteSearchToken() }"),
                      "键盘删除键仍接到无参那条")
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
        // 2026-10-27 起分组表单换成自绘卡片（纯白底 + 玻璃遮罩），
        // 行组件从 `LabeledContent` 变成 `SettingsLabeledRow`：布局还是「左标签右值」。
        XCTAssertTrue(general.contains("SettingsLabeledRow(\"版本\")"),
                      "版本号按「左标签右值」的一行呈现，不自绘")
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
    func testGeneralPaneChecksForUpdatesThroughCore() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let general = braceBlock(after: "private var generalForm: some View", in: settings) else {
            return XCTFail("缺少通用页")
        }
        XCTAssertTrue(general.contains("SettingsCard(\"关于\")"),
                      "版本和更新应集中在通用页的「关于」")
        XCTAssertTrue(general.contains("AppVersion.current"),
                      "这一节要显示当前版本，用户才知道在跟哪儿比")
        XCTAssertTrue(general.contains("model.checkForUpdates()"),
                      "检查更新按钮要真的接上动作")
        XCTAssertTrue(general.contains("updateResultRow("),
                      "结论要摆在按钮下面，不另开窗口")
        XCTAssertTrue(settings.contains("UpdateCheckText.message(for:"),
                      "结论文案走 Core，不在视图里拼字符串")
        XCTAssertTrue(general.contains("check-for-updates"),
                      "按钮要挂无障碍标识，键盘与 VoiceOver 靠它定位")
        XCTAssertFalse(general.contains("api.github.com"),
                       "仓库地址只能有一处（Core 的 UpdateCheck）")
        XCTAssertFalse(general.contains("URLSession"),
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
        XCTAssertTrue(settings.contains("SettingsLabeledRow(\"外观\")"),
                      "外观行要左标签右选择器一行排布，和系统设置一致")

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
    /// 但是不明显」。这里锁两件事：标题真的用了 Core 的阶梯，
    /// 且字号比正文大一档（否则等于没改）。
    ///
    /// 2026-10-28：字号 + 字重 + 字距统一收口到 `.ffFont(.settingsSectionHeader)`，
    /// 视图里不再直接出现 `SettingsTypography`。所以断言改成检查这个入口，
    /// 并回到 Core 侧核对它**确实**引用 `SettingsTypography.sectionHeader` 且是半粗——
    /// 只检查 `.settingsSectionHeader` 这个名字，等于没锁住「字号来自阶梯」这件事。
    func testSectionHeadersUseTheSharedTypographyScale() throws {
        // 2026-10-27：分组表单换成自绘卡片，分段标题从 `sectionHeader(...)` 这个
        // helper 挪进了 `SettingsCard`。字号出处仍然只有一处，换了个地方而已。
        let chrome = codeOnly(try appSource("SettingsChrome.swift"))
        guard let card = braceBlock(after: "struct SettingsCard", in: chrome) else {
            return XCTFail("找不到 SettingsCard")
        }
        XCTAssertTrue(card.contains(".ffFont(.settingsSectionHeader)"),
                      "分段标题必须走统一的字体阶梯")

        let core = try clientFile("Sources/FlashFindCore/FlashFindTypography.swift")
        // 样式常量是 `static let xxx = FlashFindTextStyle(...)`，不是花括号块，
        // 所以按「从这一项到下一项」切片，而不是 braceBlock。
        guard let headerStart = core.range(of: "settingsSectionHeader"),
              let headerEnd = core.range(of: "settingsBody",
                                         range: headerStart.upperBound..<core.endIndex) else {
            return XCTFail("Core 侧没有登记 settingsSectionHeader")
        }
        let header = String(core[headerStart.lowerBound..<headerEnd.lowerBound])
        XCTAssertTrue(header.contains("SettingsTypography.sectionHeader"),
                      "分段标题字号必须来自 SettingsTypography，不许另写一个数")
        XCTAssertTrue(header.contains("weight: 0.6"),
                      "分段标题保留半粗字重，与正文拉开层次")

        // 页面里不许再各写一份标题字号：一处改了另一处没改，同一页会出现两个层级。
        for file in ["SettingsView.swift"] {
            let source = codeOnly(try appSource(file))
            XCTAssertFalse(source.contains("SettingsTypography.sectionHeader"),
                           "\(file) 里的分段标题要交给 SettingsCard，不要自己排字号")
        }

        let scale = try clientFile("Sources/FlashFindCore/SettingsTypography.swift")
        XCTAssertTrue(scale.contains("sectionHeader"), "Core 侧必须登记 sectionHeader 这一级")
        XCTAssertTrue(scale.contains("pageTitle") && scale.contains("body") && scale.contains("caption"),
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
        // ★ 判据跟着实现改（2026-10-29）：原先还全局禁 `otp: nil)`，那只是因为
        //   授权品牌那条路当时被包在 `pickForBrowserAuthorization` 里。包装已按
        //   审查意见删除，授权品牌（fnOS）那条路**本来就该**是 `otp: nil`
        //   —— 它没有动态码这回事，这不是「忘了带」。
        //   真正要守的是账密那条路：Core 给了码就必须原样带上。
        XCTAssertTrue(controller.contains("PendingCredential(password: picked.password, otp: picked.otp)"),
                      "账密那条路必须把 Core 给出的动态码原样带上")
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

    /// ★ 位置候选的顺序必须来自「同一份用户设置」。
    ///
    /// ★ 2026-10-28 两轮删减之后，这条只剩**读**的一半：
    ///   命令面板没了，设置页那栏「搜索工具 ▸ 命令快捷键（位置顺序）」也没了
    ///   （用户原话：「没有用了」），所以拖动 / 删除 / 替换 / 恢复默认四个写入口
    ///   全部消失。但 `quickPick` **仍在生效**——侧边栏照它排、并照它藏掉用户
    ///   当年删过的位置。删掉这几条断言，等于让老用户的排序静默失效。
    func testLocationOrderStillComesFromTheSavedSettings() throws {
        let code = try appModelCode()
        let items = try body(of: "commandItems", in: code)
        XCTAssertTrue(items.contains("SearchCommandArrangement.arrange("),
                      "候选顺序必须走 Core 的重排，不能只按目录自然顺序")
        XCTAssertTrue(items.contains("quickPick.order(for: kind)"),
                      "顺序要取用户设置；取错了侧边栏的顺序就是白存")
        XCTAssertTrue(items.contains("hidden: quickPick.hiddenIDs(for: kind)"),
                      "★ 用户当年删掉的候选必须在这一层滤掉：过滤器一删，它们会全部回到侧边栏")

        // ★ 写入口必须**一个都不剩**（2026-10-28）。留着就是一条既没有界面、
        //   也没有测试能走到的死路——而且它会让「顺序还能改」这件事看起来还成立。
        for gone in ["func quickPickRows(", "func canResetQuickPick(", "func moveQuickPick(",
                     "func deleteQuickPick(", "func replaceQuickPick(", "func quickPickReplacements(",
                     "func resetQuickPick(", "func applyQuickPick("] {
            XCTAssertFalse(code.contains(gone),
                           "\(gone) 的入口已经删掉：设置页不再有位置顺序这一栏")
        }

        // 设置页那张卡片也要真的消失，不是藏起来。
        let settings = codeOnly(try appSource("SettingsView.swift"))
        let searchForm = try body(of: "searchForm", in: settings)
        XCTAssertFalse(searchForm.contains("QuickPickSettingsSection("),
                       "「搜索工具 ▸ 命令快捷键」整张卡片必须删掉")
        XCTAssertFalse(searchForm.contains("命令快捷键"),
                       "卡片里的那一行也不许留")
    }

    /// 搜索位置列表的「全选 / 取消全选」：按钮在标题行，判定在 Core，提交走同一条管线。
    ///
    /// 三条各自防一种退化：
    /// 1. 按钮被塞进列表里当一行数据 —— 会和「这一行能不能勾」混淆；
    /// 2. 判定被搬回 App 层 —— executableTarget 测不到，等于没测；
    /// 3. 批量入口自己写集合、绕开 `applyDraftScopes` —— 串行化与过期响应丢弃全部失效，
    ///    快速连点「全选 / 取消全选」会出现「界面显示 A、核心绑了 B」。
    /// 给「选择搜索位置」截图用的预览钩子只能在预览包里生效。
    ///
    /// 它会直接造一份「已连接、有 N 个共享」的草稿 —— 这些状态正常只能由真连上
    /// 一台设备才成立。若少了 `AppEnvironment.isPreview` 这道门，正式包里就能被
    /// 一个环境变量顶出一台假 NAS，界面还会显示「已连接，可以搜索了」。
    func testPreviewWizardDraftHookIsPreviewOnly() throws {
        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        let hook = try body(of: "loadPreviewWizardDraftIfRequested", in: controller)
        XCTAssertTrue(hook.contains("guard AppEnvironment.isPreview"),
                      "★ 预览钩子第一句就必须是「只在预览包里」")
        XCTAssertTrue(hook.contains("FF_UI_WIZARD"),
                      "钩子变量名改成别的，截图脚本与文档就对不上了")
        // 造出来的状态只能停在草稿里，不许顺手把真实来源也写进去。
        XCTAssertFalse(hook.contains("nasSources"),
                       "★ 预览钩子不许碰真实来源列表")
    }

    func testWizardOffersBulkScopeSelectionThroughCore() throws {
        let view = codeOnly(try appSource("NASSourceWizardView.swift"))
        let section = try body(of: "sharesSection", in: view)

        XCTAssertTrue(section.contains("trailing: {"),
                      "全选 / 取消全选要挂在标题行右侧，不是列表里的一行")
        for label in ["\"全选\"", "\"取消全选\""] {
            XCTAssertTrue(section.contains(label), "搜索位置顶部缺了 \(label) 按钮")
        }
        XCTAssertTrue(section.contains("model.selectAllDraftScopes()"), "全选没有接到模型上")
        XCTAssertTrue(section.contains("model.clearAllDraftScopes()"), "取消全选没有接到模型上")
        XCTAssertTrue(section.contains("model.offersBulkDraftScopeSelection"),
                      "位置只有一个时不该出现这两颗按钮，这个判断要由 Core 出")
        XCTAssertTrue(section.contains("model.canSelectAllDraftScopes"),
                      "「全选」可不可点要由 Core 判")
        XCTAssertTrue(section.contains("model.canClearAllDraftScopes"),
                      "「取消全选」可不可点要由 Core 判")
        XCTAssertFalse(section.contains("Set("),
                       "★ 界面里出现集合运算，说明判定被搬回了 App 层")

        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        let selectAll = try body(of: "selectAllDraftScopes", in: controller)
        XCTAssertTrue(selectAll.contains("ScopeBulkSelection.selectAll(available: draftAvailableShares)"),
                      "全选的集合必须由 Core 的 ScopeBulkSelection 算")
        let clearAll = try body(of: "clearAllDraftScopes", in: controller)
        XCTAssertTrue(clearAll.contains("ScopeBulkSelection.clearAll()"),
                      "取消全选也要走 Core，不许在控制器里写死空数组")
        for bulk in [selectAll, clearAll] {
            XCTAssertTrue(bulk.contains("applyDraftScopes("),
                          "批量入口必须走与单点勾选同一条提交管线")
            XCTAssertFalse(bulk.contains("draftSource.scopes ="),
                           "★ 批量入口不许自己写集合：绕开 applyDraftScopes 就等于绕开串行化")
        }
        XCTAssertTrue(controller.contains("private func applyDraftScopes("),
                      "三处入口共用的提交管线必须只有一个")

        let offered = try body(of: "offersBulkDraftScopeSelection", in: controller)
        XCTAssertTrue(offered.contains("ScopeBulkSelection.isOffered(available: draftAvailableShares)"),
                      "是否提供批量入口要由 Core 判")
        let canSelect = try body(of: "canSelectAllDraftScopes", in: controller)
        XCTAssertTrue(canSelect.contains("ScopeBulkSelection.canSelectAll(") ,
                      "「全选」的可用性要由 Core 判")
        let canClear = try body(of: "canClearAllDraftScopes", in: controller)
        XCTAssertTrue(canClear.contains("ScopeBulkSelection.canClearAll("),
                      "「取消全选」的可用性要由 Core 判")
    }

    /// 设备名称必须能在**连上以后**改。
    ///
    /// 2026-10-27 报障：名称只在「添加搜索来源」向导里出现过一次，连上之后再没有地方改。
    /// 三条断言各自防一种退化：
    /// 1. 名称行消失或变回只读文本 —— 又回到「没地方改」；
    /// 2. 改名顺手重建 Provider —— 掉线（行为侧由
    ///    `NASProviderHandoffTests.testRenameKeepsSessionAndUpdatesDisplayName` 守着）；
    /// 3. 改名顺手 invalidate / 重搜 —— 改个名字把用户刚搜出来的结果清掉。
    func testSourceDetailAllowsRenamingWithoutReconnecting() throws {
        let view = codeOnly(try appSource("SettingsView.swift"))
        // 2026-10-27：详情页顶部改成一张「身份卡」——图标 + 名称 + 开关，
        // 名称输入行与状态都在 `identity(_:)` 里。断言跟着代码走。
        let detail = try body(of: "identity", in: view)

        XCTAssertTrue(detail.contains("SettingsLabeledRow(\"名称\")"),
                      "来源详情里没有「名称」行：连上以后仍然没地方改名")
        XCTAssertTrue(detail.contains("source-detail-name"),
                      "名称输入框要有稳定的无障碍标识，否则真机点验与 AX 脚本都定位不到")
        XCTAssertTrue(detail.contains(".textFieldStyle(.roundedBorder)"),
                      "★ 名称必须是可输入的 TextField，不是只读的 Text")
        XCTAssertTrue(detail.contains("model.renameSource("),
                      "名称没有接到模型上，打字不会落盘")
        XCTAssertTrue(detail.contains("model.nasSources.first(where:"),
                      "★ 绑定必须在 get 里现取模型：闭包捕获的 `source` 是本次求值的值拷贝，"
                      + "写入后要等整页重算才更新，中间那一帧会把用户刚敲的字符盖回去")

        let controller = codeOnly(try appSource("NASSourceWizardController.swift"))
        let rename = try body(of: "renameSource", in: controller)
        XCTAssertTrue(rename.contains("NASSourceRename.isRename("),
                      "要不要写盘、要不要同步 Provider，得由 Core 的规则判")
        XCTAssertTrue(rename.contains("NASSourceRename.normalized("),
                      "名字的规范化（换行折空格）必须走 Core，不许在控制器里自己拼")
        XCTAssertTrue(rename.contains("persistSources()"),
                      "改完名字要落盘，否则重启就回去了")
        XCTAssertTrue(rename.contains("updateDisplayName("),
                      "已连接的那台必须立刻换名字，否则结果行的来源徽标还是旧名")
        for forbidden in ["rebuildNativeProviders()", "invalidate()", "changedQuery()"] {
            XCTAssertFalse(rename.contains(forbidden),
                           "★ renameSource 里出现 \(forbidden)：改名会掉线或清空当前结果。"
                           + "名字不参与连接身份（sourceID 由 id 派生），没有任何理由动它们")
        }
    }

    /// 搜索结果批**必须**走 Core 的合并，一次赋值。
    ///
    /// 这条守的是「结果一多就卡」的复发路径：
    /// ① 逐条 `results.append(row)` ⇒ 每行发一次 `objectWillChange`；
    /// ② 在闭包里自己 `sort` ⇒ 排序规则出现第二份（与 Core 的 tie-break 不一致）。
    /// 两者都能跑通、界面也能出结果，只有结果上千条时才表现为卡顿。
    ///
    /// ★ 2026-10-28 改口：合并**入口**从 `SearchResultMerge.apply` 换成了
    /// `integrateResults(_:)`——它背后是 Core 的 `SearchResultWindow`，
    /// 顺序/去重/重排判据仍在 `SearchResultMerge` 里，另外多管了
    /// 「只留前 200」与「总共匹配多少」。断言因此改成两层：
    /// App 层只许调用 `integrateResults`，窗口内部才许出现 `SearchResultMerge.apply`。
    func testSearchBatchMergeGoesThroughCoreAndAssignsOnce() throws {
        let code = codeOnly(try appSource("AppModel+SearchSession+Results.swift"))
        XCTAssertTrue(code.contains("integrateResults(event.results)"),
                      "结果批必须走 `integrateResults`（上限、去重、总数、一次赋值都在 Core 的窗口里）")
        XCTAssertTrue(code.contains("resultWindow.integrate(incoming)"),
                      "★ `integrateResults` 必须真的调 Core 的 `SearchResultWindow.integrate`，"
                      + "不许在这里再拼一遍排序")
        let window = codeOnly(try coreSource("SearchResultLimit.swift"))
        XCTAssertTrue(window.contains("SearchResultMerge.apply(existing: all, incoming: incoming)"),
                      "★ 窗口内部必须复用 `SearchResultMerge`：排两套顺序会让「合并 == 一次排完」这条不变量失效")
        XCTAssertFalse(code.contains("results.append("),
                       "★ 事件闭包里逐条 append：每行一次 objectWillChange，结果上千条时界面开始卡")
        XCTAssertFalse(code.contains("results.sort"),
                       "★ 排序规则只许有一份：闭包里再 sort 一次，就等于放弃了 Core 的 tie-break")
        // 上限与总数只能经窗口，不许在 App 层另写一个 200。
        XCTAssertFalse(code.contains(".prefix(200)"),
                       "★ 200 只许出现在 `SearchResultLimit.perSearch` 一处，界面与模型都不许再写一遍")
    }

    /// 设置页切页不许「内容漂移」。
    ///
    /// 2026-10-28 用户报「设置页切换的时候不同页面的对齐有问题，里边的内容会出现漂移」。
    /// 成因两条，都只在切换那一瞬间可见，静态截图看不出来：
    /// ① `ScrollView` 的滚动偏移被下一页继承（四页高度不同，偏移被夹紧又回弹）；
    /// ② 四个页面展开在同一个 `VStack` 里，`pane` 一变 SwiftUI 会按位置插值，
    ///    卡片从旧页的位置滑到新页的位置。
    /// 判据：内容带 `.id(pane)`（成为「替换」而不是「插值」）+ 切页 `scrollTo` 回顶。
    func testSettingsPaneSwitchReplacesContentAndScrollsToTop() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))

        XCTAssertTrue(settings.contains(".id(pane)"),
                      "★ 内容没有 `.id(pane)`：切页时 SwiftUI 会把新旧两页按位置插值（内容漂移）")
        XCTAssertTrue(settings.contains("ScrollViewReader"),
                      "切页回顶需要 `ScrollViewReader`：缺了它只能继承上一页的滚动偏移")
        XCTAssertTrue(settings.contains("proxy.scrollTo(SettingsLayout.topAnchor"),
                      "★ 切页必须 `scrollTo` 回顶，否则从滚到一半的长页切到短页就是「漂移」")

        // 回顶与交叉淡入不许各带动画：一边滑一边淡，看起来仍是在飘。
        XCTAssertTrue(settings.contains("transaction.animation = nil"),
                      "回顶要用无动画事务，否则会与 0.16s 的淡入叠成「边滑边淡」")

        // 四页必须共用同一套根容器（同一间距、同一套卡片），否则左右边缘会各偏一点。
        for name in ["generalForm", "searchForm", "aiForm", "advancedForm"] {
            let block = try XCTUnwrap(braceBlock(after: "var \(name)", in: settings),
                                      "取不到 \(name) 的块，本条断言失去意义")
            XCTAssertTrue(block.contains("VStack(alignment: .leading, spacing: 22)"),
                          "\(name) 的根容器与其它三页不一致（间距/对齐会各偏一点）")
        }

        // ★★ 真凶：占位滚动条。
        //
        // 内容超一屏的那一页会出现 legacy 滚动条，它**占掉 15pt 宽度**，
        // 居中的卡片整体左移 7.5pt、自己也窄 15pt；另外三页不超一屏 ⇒
        // 切页时内容左右跳一下。实测 @2x：搜索页内容左缘 113px、高级页 128px。
        // 判据：设置页必须把 NSScrollView 的 scrollerStyle 设成 `.overlay`。
        XCTAssertTrue(settings.contains("SettingsOverlayScrollers()"),
                      "★ 设置页的 ScrollView 必须挂 `SettingsOverlayScrollers`："
                      + "否则「内容超一屏的页」比别的页窄 15pt、整体左移 7.5pt")
        let chrome = codeOnly(try appSource("SettingsChrome.swift"))
        XCTAssertTrue(chrome.contains("scrollerStyle = .overlay"),
                      "★ 滚动条必须改成 overlay（不占宽度）；改成 legacy 就会让长页内容整体左移")
        XCTAssertTrue(chrome.contains("view.window?.contentView"),
                      "★ 要从窗口根视图找 NSScrollView：`.background` 挂上去的视图是它的兄弟，"
                      + "`enclosingScrollView` 会拿到 nil（第一版就是这么没生效的）")
        XCTAssertFalse(settings.contains(".scrollIndicators(.hidden)"),
                       "不许用「隐藏指示器」糊过去：那是把「还能往下滚」的唯一提示也删了")
    }
}
