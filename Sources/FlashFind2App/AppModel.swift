import AppKit
import SwiftUI
import Combine
import FlashFindCore

@MainActor
final class AppModel: ObservableObject {
    /// 全局快捷键（P2-05）：录制、保存、事件监视器的生命周期全部归
    /// `ShortcutController`。这里只转发——设置界面与 App 入口一行都不用改。
    ///
    /// 为什么要桥接 `objectWillChange`：这些状态原本是 AppModel 自己的
    /// `@Published`，界面直接观察 AppModel；搬走之后如果不转发变更通知，
    /// 界面会「数据变了但界面不刷新」——这种缺陷编译期看不出来，只有手动录一次
    /// 快捷键才会发现。所以桥接不是可选项。
    private let shortcuts: ShortcutController
    private var shortcutBridge: AnyCancellable?
    var globalShortcut: GlobalShortcutSpec { shortcuts.spec }
    var shortcutStatus: String { shortcuts.status }
    var shortcutAvailable: Bool { shortcuts.available }
    var isRecordingShortcut: Bool { shortcuts.isRecording }
    /// 最近一次录制/注册失败属于「这个组合被占用」，而不是「组合本身不合法」。
    /// 引导页据此说人话（不抖 OSStatus），设置页照旧显示原文。
    var shortcutRegistrationRefused: Bool { shortcuts.registrationRefused }

    /// 结果动作（打开 / 定位 / 快速查看 / 复制 / 失败提示）的实际持有者。
    ///
    /// 同样要桥接 `objectWillChange`：`openFailure` 是界面观察的状态，
    /// 提示条出不出来取决于这条通知。
    let resultActions = ResultActionController()
    private var resultActionBridge: AnyCancellable?
    /// 保持旧类型名：界面写的是 `model.openFailure`，不改动调用点。
    typealias OpenFailure = ResultActionController.Failure
    var openFailure: OpenFailure? {
        get { resultActions.failure }
        set { resultActions.failure = newValue }
    }
    @Published var query = ""
    @Published var results: [SearchResult] = []
    /// 本次搜索**去重后**匹配到的总条数。
    ///
    /// ★ 它与 `results.count` 不是一回事：`results` 最多
    /// `SearchResultLimit.perSearch`（200）条，而设备可能匹配到几千条。
    /// 状态栏写「200 / 1374 项」靠的就是这个数——只写 200 会让用户
    /// 以为目录里就这么多。
    @Published var matchedResultCount = 0
    /// 结果窗口（保留 top 200 + 累计总数 + 去重集合）。唯一写入点是
    /// `integrateResults(_:)`，**不许**绕开它直接改 `results`。
    var resultWindow = SearchResultWindow()
    @Published var selected: String?
    @Published var searchFailure: String?
    @Published var searchWarnings: [String] = []
    @Published var resultsAreCurrent = false
    @Published var searching = false
    @Published var status = ""
    @Published var enabled = true
    /// 总开关是否被用户**显式**设置过（R01）。
    ///
    /// 区分它才能既修好新装用户、又不违背关掉它的人：
    /// 只有从未设置过（全新安装）时才允许自动打开；用户显式关过就永远尊重。
    var masterSwitchIsExplicit = false
    @Published var scope: SearchScope = .all
    /// 当前生效的搜索限定（位置 + 文件类型）。
    ///
    /// ★ 它不是 `scope` 的替代品，而是**在 scope 之上的进一步收窄**：
    /// `scope` 决定「本机 / NAS / 全部」，`tokenBar` 决定「哪个来源的哪个根」
    /// 与「什么格式」。两个限定可叠加（侧边栏选一个位置 + 类型条选 pdf）。
    ///
    /// ★ 2026-10-28 之后搜索框里**不再画**这排标签，状态仍由它持有：
    ///   侧边栏高亮、类型条选中、`SearchRequestPlan` 的收窄都读它。
    @Published var tokenBar: SearchTokenBar = .empty
    /// 位置候选顺序（用户可在「设置 ▸ 搜索」里改）。
    ///
    /// ★ 判定（怎么重排、什么情况回落到默认）全在 Core 的
    /// `SearchQuickPickSettings` / `SearchCommandArrangement`。
    /// 这里只持有**当前值**并负责落盘 —— 与 `showExperimentalSources` 同一个套路。
    @Published private(set) var quickPick = SearchQuickPickSettings.empty
    /// 本机这一侧的来源（本机搜索方式、已挂载 SMB 共享、文件夹选择）。
    ///
    /// 状态搬走之后，界面观察的仍是 AppModel —— 所以和前几轮一样必须桥接
    /// `objectWillChange`：不桥接的话「设置里改了搜索方式但说明文字不更新」
    /// 这种缺陷编译期看不出来，只有手动点一遍才发现。
    let localSources: LocalSourceController
    private var localSourcesBridge: AnyCancellable?
    /// 界面外观（浅色 / 深色 / 跟随系统）。
    ///
    /// 判定在 Core 的 `AppearanceChoice`，落盘与应用在 `AppearanceController`，
    /// 这里只转发——和前几个 controller 一样的边界。
    private let appearance: AppearanceController
    private var appearanceBridge: AnyCancellable?
    /// 「允许 AI 使用闪寻」（高级页骨架）。
    ///
    /// 规则与判定在 Core（`AIAccessSettings` / `PermissionPolicy`，可测）；
    /// 这里只转发，让设置页能把 Toggle 绑到 `model.aiAccess.draft` 上。
    /// 跨文件 extension 要访问，所以不写 private。
    let aiAccess: AIAccessController
    private var aiAccessBridge: AnyCancellable?
    /// 权威端监听本体（Phase 9-lite）。设置页要问它两件事：助手在不在跑、
    /// 历史里有多少条。
    ///
    /// ★ 不在这里构造：它由 App 入口持有、在 `applicationDidFinishLaunching` 里注入。
    /// 弱引用是刻意的——监听的生命周期跟着 App，不该被模型延长；预览或测试里
    /// 没有注入时，设置页读到的是「未启动」，那是实话。
    weak var mcpAuthority: MCPAuthorityController?
    /// 设置页「外观」读写的就是这个值。
    var appearanceChoice: AppearanceChoice {
        get { appearance.choice }
        set { appearance.set(newValue) }
    }
    /// 启动时把上次选的外观应用上：用户选了深色，重启后必须还是深色。
    func applyAppearance() { appearance.apply() }
    var localEnabled: Bool {
        get { localSources.localEnabled }
        set { localSources.localEnabled = newValue }
    }
    var localFolders: [URL] { localSources.localFolders }
    var localSearchMode: LocalSearchMode { localSources.localSearchMode }
    var localSearchAvailabilityMessage: String { localSources.localSearchAvailabilityMessage }
    let preferences: any ClientPreferences
    /// 首次启动引导的痕迹（走没走完、停在哪一步）。
    ///
    /// 只存这两件事：「这台机器配好了没有」每次都现算（`onboardingState`），
    /// 因为用户可能早就在系统设置里授过权、或已经加过 NAS。
    let onboardingStore: OnboardingStore
    let credentialAccessAllowed: Bool
    let fixtureMode: Bool
    let cacheRoot: URL
    var searchTask: Task<Void, Never>?
    var spotlight: SpotlightProvider?
    let localProvider = LocalSearchProvider()
    /// 应用搜索：与 localProvider 并列，同属「本机」一侧——
    /// 立即出结果，不走 NAS 那条 600ms 防抖。
    let appProvider = AppSearchProvider()
    var providerCoordinator: SearchCoordinator?
    @Published var nativeSearchTimeoutSeconds = 60
    /// 「显示实验性搜索来源」（高级页）。
    ///
    /// 默认**关**：关着的时候向导只给正式开放的两项（群晖与 OpenList），
    /// 把「适配器在、但没在真机上验证过」的那几条路收起来
    /// （见 `ExperimentalSources`）。开关本身是可测逻辑，
    /// 放在 Core；这里只负责持久化与广播。
    @Published private(set) var showExperimentalSources = false
    /// 向导里当前可选的来源类型。
    var selectableVendors: [NASSourceConfig.Vendor] {
        ExperimentalSources.vendors(includingExperimental: showExperimentalSources)
    }
    func setShowExperimentalSources(_ value: Bool) {
        guard !AppEnvironment.isPreview || fixtureMode else { status = "UI 预览不修改真实设置"; return }
        showExperimentalSources = value
        preferences.set(value, forKey: ExperimentalSources.storageKey)
    }

    // ★ 2026-10-28：`applyQuickPick` 随「设置 ▸ 搜索 ▸ 搜索工具（位置顺序）」一起删了。
    //   `quickPick` 本身还在，而且**仍在生效**——`commandItems(for:)` 按它排侧边栏、
    //   并按它藏掉用户当年删过的位置。只是现在没有任何界面能改它，
    //   于是「写」这一侧（setter / 落盘）也就没有用处了。

    // MARK: 检查更新（实现在 AppModel+UpdateCheck.swift）
    //
    // 判定与文案全在 Core 的 `UpdateCheck` / `UpdateCheckText`（App 层不可测）。
    // 这里只留两个**存储**状态：extension 不能含存储属性，这是硬约束。

    /// 上一次检查的结论。`nil` = 这次打开设置后还没查过。
    ///
    /// 不在打开设置时自动查：只进来改个快捷键的人，不该顺带产生一次网络请求。
    @Published var updateOutcome: UpdateCheck.Outcome?
    /// 正在查。按钮据此禁用并换文案。
    @Published var updateChecking = false

    // MARK: 登录时启动（实现在 AppModel+LaunchAtLogin.swift）
    //
    // 动作在 `AppModel+LaunchAtLogin.swift`；下面两个是存储属性，
    // 留在主文件——Swift 的 extension 不能含存储属性。


    /// 「登录时启动闪寻」。真值来自系统（`SMAppService`），不是本地偏好——
    /// 用户可能在「系统设置 ▸ 通用 ▸ 登录项」里直接改掉，这里必须以系统的为准。
    @Published var launchAtLogin = LaunchAtLogin.isEnabled
    /// 注册失败时系统给的原因。界面如实显示，不假装成功。
    @Published var launchAtLoginMessage: String?

    // MARK: - 原生 NAS 来源（实现在 AppModel+NativeSources.swift）
    //
    // 桥接层装配、Provider 重建、向导状态转发都在 `AppModel+NativeSources.swift`。
    // 下面留下的是**存储**状态：Swift 的 extension 不能含存储属性，
    // 这是分文件 extension 的硬约束，不是设计取舍。
    //
    // 桥接层装配、Provider 重建、向导状态转发：产品主路径上与 NAS 直接
    // 打交道的部分都在这里，随 Stage 3A 搬走。


    /// NAS 连接管理（P2-02）：桥接层与 Provider 的生死归它管。
    let nasConnectionManager = NASConnectionManager()
    /// 诊断落盘（P2-01）：从本类里分出去，规则只留一处。
    let diagnostics = NASDiagnosticsController()
    @Published var nativeNASStatus = "尚未添加 NAS"
    /// 添加 / 编辑 NAS 来源的向导（P2 续）：草稿、连接尝试、证书确认、搜索位置
    /// 全部归 `NASSourceWizardController`，本类只保留转发属性与转发方法。
    ///
    /// ★ 这一轮**连状态一起搬了**（`nasSources` / `nativeProviders` / `draftSource` …），
    /// 因为向导的二十来个状态彼此咬合，只搬动作会换来一堆互相引用的回调。
    /// 界面写的是 `model.xxx`，所以这里的转发属性必须保留同名，且**必须桥接
    /// `objectWillChange`** —— 不桥接的表现是「向导里点了连接，界面一点反应都没有」，
    /// 编译能过、也不报错。
    /// 不写 private：向导转发已搬到 `AppModel+Wizard.swift`，跨文件 extension
    /// 看不到本文件的 private。同一模块内 internal 已是最小可见范围。
    let wizard: NASSourceWizardController
    var wizardBridge: AnyCancellable?
    /// 共享的后台挂载服务。跨来源复用，避免每台 NAS 各挂一次。
    let mountService = SMBMountService()
    /// 逐来源的「连接意图」登记。
    ///
    /// 静默自动连接与向导都是「先建 Provider → discover → login → selectScopes → 最后才
    /// install」。用户在连接进行中点「断开」时，只关掉管理器里当前那个 Provider 是**不够**的：
    /// 那条在飞的连接握着另一个实例，它晚到的成功照样会 install —— 而 install 会发布
    /// 「Provider 集合变化」，上层据此整体重建搜索协调器，于是刚断开的来源复活、
    /// **其它来源在飞的查询被一起取消**（用户看到的就是「断开一台，全部断开」）。
    ///
    /// 与向导**共用同一个实例**（`wizard.connectIntent`）：两边各持一份就会漏作废。
    let connectIntent = SourceConnectIntent()
    /// 每个来源正在跑的静默连接任务。断开时连同意图一起取消。
    var connectTasks: [String: Task<Void, Never>] = [:]


    // MARK: - 向导转发（实现在 AppModel+Wizard.swift）
    //
    // 这一块随 Stage 3A 搬到同目录的 `AppModel+Wizard.swift`：它只依赖 `wizard`，
    // 不碰搜索与连接状态，是 AppModel 里最容易先分出去的一块。
    // 这里只留指路，实现与注释都在那边（行为未改，调用点未动）。
    // MARK: - 来源操作：诊断、重连、断开（实现在 AppModel+SourceActions.swift）
    //
    // 这一组原本挂在「向导转发」MARK 下面，标注与内容对不上；
    // 随 Stage 3A 搬到 `AppModel+SourceActions.swift`。

    // MARK: - 窗口与 Provider 收尾

    /// 打开独立设置窗口。菜单栏、搜索浮窗的空状态按钮都走这里。
    func openSettingsWindow() {
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show(model: self, page: .search)
    }

    func closeSearchProviders() {
        providerCoordinator?.cancel()
        wizard.discardPendingProvider()
        sharedBridge?.shutdown()
    }

    // MARK: - 搜索会话状态与可用性判定
    //
    // 一次搜索「当前看到的是不是还能用的结果」全靠这一组判定：
    // 查询词、范围、启用的来源、显示隐藏文件，任何一项变了，旧结果就不再对应
    // 当前状态，由 `canUseDisplayedResults` 拦下，不拿过期结果冒充。

    var queryID = UUID()
    var hiddenAt: Date?
    /// 把搜索浮窗从屏幕上收起来的回调，由 `SearchPanelController` 注入。
    ///
    /// AppModel 不持有面板实例，所以不能自己 `orderOut`。此前它拿
    /// `NSApplication.shared.keyWindow` 顶替，可是点在**其它应用**上时
    /// 闪寻已失去前台、keyWindow 常常是 nil —— 于是出现「点了外面，
    /// 浮窗还杵在那儿」。收哪个窗口只有面板自己确定，这件事交回给它。
    var hidePanel: (() -> Void)?
    /// 把搜索浮窗放回来的回调，同样由 `SearchPanelController` 注入。
    ///
    /// 与 `hidePanel` 必须成对存在：打开设置/向导时会 `hideSearch()` 收掉浮窗，
    /// 如果关窗路径不还回来，屏幕上就一个窗口都没有了 —— macOS 会把这种应用
    /// 判成空闲并**直接回收**（Automatic Termination，不是崩溃、没有崩溃报告）。
    /// 用户看到的就是「点完登录闪退」。判定规则在 `LastWindowClosePolicy`。
    var showPanel: (() -> Void)?
    /// 结果那一块窗口此刻是不是 key。
    ///
    /// ★ 2026-10-28 结果搬进独立窗口之后才需要它：键盘路由判「用户在结果区操作」
    ///   靠的是「焦点不在输入框」，而输入框的 `FocusState` **不会**因为用户点了
    ///   另一个窗口就变 false —— 不读这个真实的窗口状态，点完结果按 ↑↓ / 空格
    ///   会全部落空（表现为「点了结果之后键盘就死了」）。
    @Published var resultsWindowIsKey = false
    /// 此刻该不该有「结果那一块」。
    ///
    /// 判定在 Core（`SearchModuleLayout.showsContentModule`），这里只是把
    /// 两个入参取出来——窗口控制器与 SwiftUI 视图都读它，避免各算一遍。
    var hasSearchContent: Bool {
        SearchModuleLayout.showsContentModule(hasQuery: !keywordIsEmpty,
                                              hasOpenFailure: openFailure != nil)
    }
    var contextRevision: UInt64 = 0
    var displayedRevision: UInt64?
    var displayedQuery = ""
    var displayedScope: SearchScope = .all
    /// 已发布结果时对应的限定（位置 + 类型）。
    ///
    /// ★ 它必须参与 `canUseDisplayedResults` 的比对：限定一变，
    /// 上一轮的结果就**不是**这一轮的结果了。不比对的话，用户刚把位置
    /// 从「照片」切到「文档」，界面上还挂着照片那一轮的结果 ——
    /// 看起来像「位置限定没生效」。
    var displayedTokenBar: SearchTokenBar = .empty
    var canUseDisplayedResults: Bool {
        resultsAreCurrent && displayedRevision == contextRevision && displayedQuery == query
            && displayedScope == scope && displayedTokenBar == tokenBar
    }
    /// 至少有一个 NAS 来源可以真正参与搜索。
    var hasSelectedNASSource: Bool { enabled && hasUsableNativeSource }
    var nasSearchAvailabilityMessage: String {
        if nasSources.isEmpty {
            return "还没有添加 NAS。到「搜索来源」里添加一台，就可以连它上面的文件一起搜。"
        }
        if nasSources.allSatisfy({ !$0.isConnectConfigured }) {
            return "请先填写 NAS 的地址和账号。"
        }
        if nasSources.allSatisfy({ !$0.enabled }) {
            return "NAS 搜索来源已全部关闭，可在「搜索来源」里重新启用。"
        }
        // 顺序很重要：先说「正在连」，再说缺什么。
        // 反过来会把「已配置好、正在连接」误报成「请选择搜索位置」——
        // 用户明明选过了，却被反复要求再选一次。
        // 用状态记录判断而不是问 Provider：要区分「正在连」与「连不上」，
        // 只有前者是等待中、值得让用户稍候。
        if nasSourceStatus.values.contains(where: { $0.health == .connecting }) {
            return "正在连接 NAS，本地搜索结果不受影响。"
        }
        // 「启用 + 已填地址 + 但没选位置」才提示选位置。
        // 这里必须用 scopes（多选）而不是 scope：单值在多选下会漏判。
        if nasSources.contains(where: { $0.enabled && $0.isConnectConfigured && $0.scopes.isEmpty }) {
            return "请为已添加的 NAS 选择搜索位置。"
        }
        if !hasUsableNativeSource {
            // 已配置完整却连不上——多半是没连，不是没配。
            if nasSources.contains(where: { $0.enabled && $0.isConnectConfigured }) {
                return "还没有连上的 NAS。请在「搜索来源」里点「重新连接」。"
            }
            return "还没有可搜索的 NAS。"
        }
        return "请启用已配置的 NAS 搜索来源"
    }
    var searchStatusMessage: String { searchWarnings.isEmpty ? status : searchWarnings.joined(separator: "；") }

    // MARK: - 构造与启动加载

    init(preferences: (any ClientPreferences)? = nil, cacheDirectory: URL? = nil, credentialAccessAllowed: Bool = true,
         ) {
        fixtureMode = AppEnvironment.isPreview && ProcessInfo.processInfo.environment["FF_UI_INTERACTIVE"] == "1"
        self.preferences = fixtureMode ? InMemoryClientPreferences() : (preferences ?? AppEnvironment.defaults)
        // ★ 紧跟着 preferences 读：命令面板的顺序/快捷键是**用户配置**，
        //   预览包与截图也要照它渲染（放到后面会被预览分支的 early return 跳过，
        //   于是「设置里排好了、预览里还是默认顺序」——那正是要拿预览排除的假象）。
        quickPick = SearchQuickPickSettings.load(from: self.preferences)
        self.credentialAccessAllowed = credentialAccessAllowed && !AppEnvironment.isPreview
        // ★ wizard 必须在下面任何捕获 self 的闭包之前构造好：
        // Swift 的初始化分析把「闭包捕获 self」也算作使用 self，
        // 晚一步就会报 used before being initialized。
        wizard = NASSourceWizardController(preferences: self.preferences)
        localSources = LocalSourceController(preferences: self.preferences,
                                             isPreview: AppEnvironment.isPreview, fixtureMode: fixtureMode)
        appearance = AppearanceController(preferences: self.preferences,
                                          isPreview: AppEnvironment.isPreview, fixtureMode: fixtureMode)
        aiAccess = AIAccessController(preferences: self.preferences,
                                      isPreview: AppEnvironment.isPreview, fixtureMode: fixtureMode)
        cacheRoot = cacheDirectory ?? (AppEnvironment.isPreview ? AppEnvironment.previewRoot : FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/FlashFind2"))
        // 快捷键的读取与恢复在 ShortcutController 里（连同「已存数据无效」的提示），
        // 装配放在 preferences 确定之后立刻做，保证界面首次渲染时状态已就位。
        shortcuts = ShortcutController(preferences: self.preferences)
        // 与 wizard 同理：下面 `shortcutBridge` 的闭包捕获了 self，
        // 所有存储属性必须在它之前初始化完，否则报 used before being initialized。
        onboardingStore = OnboardingStore(preferences: self.preferences)
        shortcutBridge = shortcuts.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // ★ 这条闭包捕获 self，所以必须等上面所有存储属性初始化完之后才能写。
        // 向导里「设备要动态码」时弹的那扇窗，与详情页「重新登录…」用的是同一扇：
        // 两条路各弹各的，迟早会走出两套文案与两种行为（同 kind 不得两种说法）。
        wizard.otpPrompter = { [weak self] name, failure in
            self?.promptForOTP(sourceName: name, failure: failure)
        }
        // ★ 飞牛（fnOS）的浏览器授权在**向导里不再弹窗**（2026-10-29 用户改流程）：
        //   授权码是「连接信息」表单里的一格，浏览器由向导在拿到授权地址时直接打开
        //   （见 `NASSourceWizardController.loginHandlingAuthorization`）。
        //   所以这里**没有** `wizard.authorizeCodePrompter` —— 向导不借弹窗。
        //   弹窗那条路只留给没有任何表单的后台重连（设置页「登录」），
        //   它走的是 AppModel 自己的 `promptForAuthorizeCode`。
        // 动作要用的三个入口都由宿主提供：解析当前行（要读权限/来源开关）、
        // 解析文件 URL（要读 provider 与挂载绑定）、状态与浮窗收起。
        resultActions.resolveRow = { [weak self] row in self?.currentResult(row) }
        resultActions.preferredOpenTarget = { [weak self] row in
            guard let self else { throw FlashFindError.message("已退出") }
            return try await self.preferredOpenTarget(row)
        }
        resultActions.fileURL = { [weak self] row in
            guard let self else { throw FlashFindError.message("已退出") }
            return try await self.fileURL(row)
        }
        resultActions.fileURLWithoutMounting = { [weak self] row in
            guard let self else { throw FlashFindError.message("已退出") }
            return try self.fileURLWithoutMounting(row)
        }
        resultActions.downloadToTemp = { [weak self] row in
            guard let self else { throw FlashFindError.message("已退出") }
            guard let sourceID = row.sourceID,
                  let provider = self.nativeProviders.values.first(where: { $0.source.id == sourceID }) else {
                throw FlashFindError.message("此结果来自已下线的搜索来源，无法下载")
            }
            return try await NASSearchProvider.downloadRowToTemp(row, bridge: provider.bridge,
                                                                 sourceID: provider.source.id)
        }
        resultActions.supportsDownloadRow = { [weak self] row in
            guard let self, let sourceID = row.sourceID,
                  let provider = self.nativeProviders.values.first(where: { $0.source.id == sourceID }) else { return false }
            return provider.config.vendor == .fnos
        }
        resultActions.onStatus = { [weak self] text in self?.status = text }
        resultActions.onHidePanel = { [weak self] in self?.hideSearch() }
        resultActionBridge = resultActions.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        // 本机来源：状态与搜索重置由本类回答（旧连接管理的表单/挂载绑定入口
        // 已随自研服务端线一起移除——那条线没有任何界面调用方）。
        localSources.onStatus = { [weak self] text in self?.status = text }
        localSources.onSearchReset = { [weak self] in self?.invalidate(); self?.changedQuery() }
        localSourcesBridge = localSources.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        localSources.loadFromPreferences()
        // 外观：预览态下拒绝修改要说一句，所以接上 onStatus；桥接同前几个 controller。
        appearance.onStatus = { [weak self] text in self?.status = text }
        appearanceBridge = appearance.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        appearance.loadFromPreferences()
        // AI 访问：默认关、不预勾任何来源。同样要桥接 `objectWillChange`，
        // 否则「拨了开关但界面不刷新」，而这条偏偏是权限开关，界面骗人代价更大。
        aiAccessBridge = aiAccess.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        aiAccess.load()
        // 向导要用的入口：桥接层、挂载服务、超时预算、Provider 装配、
        // 核心来源清理、搜索重置。其余（凭据读写、连接尝试闸门、Provider 字典）
        // 都在 controller 内部。
        wizard.makeBridge = { [weak self] in self?.sharedBridge }
        wizard.resolveMountService = { [weak self] in self?.mountService ?? SMBMountService() }
        wizard.queryBudgetSeconds = { [weak self] in self?.nativeSearchTimeoutSeconds ?? 60 }
        wizard.ensureCoordinator = { [weak self] in self?.ensureProviderCoordinator() }
        wizard.rebuildProviders = { [weak self] in self?.rebuildNativeProviders() }
        wizard.onInvalidate = { [weak self] in self?.invalidate() }
        wizard.onSearch = { [weak self] in self?.changedQuery() }
        wizard.attachAutoReconnect = { [weak self] provider in self?.attachAutoReconnect(provider) }
        wizard.resetCore = { [weak self] sourceID in
            await self?.nasConnectionManager.resetCoreSource(sourceID)
        }
        wizard.installProvider = { [weak self] provider in self?.nasConnectionManager.install(provider) }
        wizard.ensureNASSearchEnabled = { [weak self] in self?.ensureNASSearchEnabled() }
        // ★ 向导与 AppModel **共用同一个**连接意图登记表：
        // 两边各持一份的话，「断开」只作废了自己那一份，向导手里那份照样能把
        // 刚断开的来源 install 回来。共享一个实例之后，`disconnectSource` 一次
        // 作废对两条连接路径同时生效。
        wizard.connectIntent = self.connectIntent
        wizardBridge = wizard.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
        if AppEnvironment.isPreview {
            enabled = false; localSources.applyPreviewBaseline()
            if fixtureMode {
                enabled = true; localSources.applyFixtureBaseline()
                query = ProcessInfo.processInfo.environment["FF_UI_QUERY"] ?? ""
                changedQuery()
                #if DEBUG
                applyPreviewSampleResultsIfRequested()
                #endif
                return
            }
            query = ProcessInfo.processInfo.environment["FF_UI_QUERY"] ?? ""
            changedQuery()
            #if DEBUG
            applyPreviewSampleResultsIfRequested()
            #endif
            return
        }
        let defaults = self.preferences
        // ★ R01：全新安装时下面两个 key 都不存在，而 `bool(forKey:)` 对**不存在**的 key
        // 返回 false —— 总开关会被初始化成关闭，于是用户走完向导、来源卡片显示已连接，
        // 搜索却一次都不请求 NAS，而那个开关在设置页还点不动。
        // 「从未写过」与「显式关过」必须分开：只有 `object(forKey:)` 的 nil 能区分二者。
        let storedMaster = defaults.object(forKey: NASMasterSwitch.storageKey) as? Bool
        let legacyMaster = defaults.object(forKey: NASMasterSwitch.legacyKey) as? Bool
        masterSwitchIsExplicit = storedMaster != nil || legacyMaster != nil
        enabled = NASMasterSwitch.resolve(stored: storedMaster, legacy: legacyMaster)
        showExperimentalSources = ExperimentalSources.resolve(
            stored: defaults.object(forKey: ExperimentalSources.storageKey) as? Bool)
        loadNativeSources()
        ensureProviderCoordinator()
        // 启动不访问真实钥匙串；已保存的来源等待用户主动登录授权。
        autoConnectSavedSources()
    }

    // MARK: - 静默自动连接（实现在 AppModel+QuietConnect.swift）
    //
    // 启动后自动连接、以及连接进行中用户改主意时的作废判定，
    // 随 Stage 3A 搬走。

    #if DEBUG
    /// 预览构建：造 N 条样例结果，用来看**结果列表**长什么样。
    ///
    /// 为什么需要它：预览态下本机搜索是关的、NAS 又没真连，`FF_UI_QUERY` 只能
    /// 得到一张空状态图。而这一轮要验的恰恰是「结果行的遮罩」「悬停时字变大变小」，
    /// 没有行就什么都验不了。名字与路径都是编的，只走视图，不发任何请求。
    ///
    /// `FF_UI_SAMPLE_RESULTS=6`。发布构建里整个方法被编译掉。
    func applyPreviewSampleResultsIfRequested() {
        guard AppEnvironment.isPreview,
              let raw = ProcessInfo.processInfo.environment["FF_UI_SAMPLE_RESULTS"],
              let count = Int(raw), count > 0 else { return }
        let names = ["季度报告-2026Q3.pdf", "项目周报-第43周.docx", "设计规范-玻璃材质.md",
                     "发布会演讲稿.txt", "财务汇总-2026.xlsx", "客户访谈记录-10月.pdf",
                     "架构评审纪要.md", "年度预算草案.numbers"]
        let dirs = ["/Users/Shared/团队文档/2026", "/Users/Shared/项目/闪寻", "/Users/Shared/会议"]
        let now = Date()
        // ★ 走 `setFixtureResults` 而不是直接赋 `results`：
        //   ① 排序用真实的 `SearchResultMerge.precedes`（score 主导）；
        //   ② 状态栏的「N 项」来自窗口，不是 `results.count` 的巧合。
        //   score 也真的算：不算是 0，排序就退回旧的 rank 口径，
        //   截图只能证明「能摆几行」，证明不了「按匹配度与时间排」。
        setFixtureResults((0..<min(count, names.count)).map { index in
            let name = names[index]
            let directory = dirs[index % dirs.count]
            let path = directory + "/" + name
            var row = SearchResult(id: "sample-\(index)", name: name, relativePath: path,
                                   sourceID: nil, sourceName: "此 Mac", kind: "file",
                                   size: Int64(1024 * (index + 3)),
                                   localURL: URL(fileURLWithPath: path),
                                   rank: index)
            row.modifiedDate = now.addingTimeInterval(-86_400 * Double(index))
            row.score = SearchRanking.score(name: name, path: path, query: query,
                                            modified: row.modifiedDate, now: now).score
            return row
        })
        resultsAreCurrent = true
        // 样例结果不该带真实告警：否则状态栏写「请先填写 NAS 的地址和账号」，
        // 看截图的人会以为那是新界面的一部分。
        searchWarnings = []
        // 同理：`status` 里还挂着「已添加 NAS 1；请填写 HTTPS 索引地址…」那种
        // 预览装配过程的回执，也不是界面的一部分。
        status = ""
        displayedRevision = contextRevision
        displayedQuery = query
        displayedScope = scope
        displayedTokenBar = tokenBar
    }

    /// 预览构建：造 240 条结果，用来看**上限生效时**的状态栏与结果区。
    ///
    /// 为什么需要它：预览壳的 fixture 只回 4 条（搜索什么都一样），
    /// 「200 / 240 项」这个状态永远到不了，而它正是这轮改动的可见部分。
    /// 数字也不是编的：240 条真的走 `setFixtureResults` → `SearchResultWindow.fixture`，
    /// 被同一个 `perSearch` 截到 200，总数照实记 240。
    ///
    /// `FF_UI_TRUNCATED=1`。发布构建里整个方法被编译掉。
    func applyPreviewTruncatedResultsIfRequested() {
        guard AppEnvironment.isPreview,
              ProcessInfo.processInfo.environment["FF_UI_TRUNCATED"] == "1" else { return }
        let now = Date()
        let total = SearchResultLimit.perSearch + 40
        setFixtureResults((0..<total).map { index in
            let name = "项目资料-\(String(format: "%03d", index)).pdf"
            let path = "/Users/Shared/项目/\(name)"
            var row = SearchResult(id: "trunc-\(index)", name: name, relativePath: path,
                                   sourceID: nil, sourceName: "此 Mac", kind: "file",
                                   size: 2048 + Int64(index), localURL: nil, rank: 2)
            row.modifiedDate = now.addingTimeInterval(-86_400 * Double(index))
            row.score = SearchRanking.score(name: name, path: path, query: query,
                                            modified: row.modifiedDate, now: now).score
            return row
        })
        resultsAreCurrent = true
        searchWarnings = []
        status = ""
        displayedRevision = contextRevision
        displayedQuery = query
        displayedScope = scope
        displayedTokenBar = tokenBar
    }

    /// 预览构建：把结果清空，只看「没有找到」那套提示。
    ///
    /// 为什么需要它：预览壳里挂着一台 fixture 来源，**任何**关键词都能搜到四条
    /// 假文件（fixture 不按关键词过滤），于是「无结果提示」这个状态在预览态
    /// 永远到不了——而它恰好是这一轮要验的东西（提示里要指出「在哪个位置没找到」）。
    /// 这个钩子只清结果、不动搜索状态，`hasQuery` 仍为真，界面因此落在空状态上。
    ///
    /// `FF_UI_EMPTY_RESULTS=1`。发布构建里整个方法被编译掉。
    func applyPreviewEmptyResultsIfRequested() {
        guard AppEnvironment.isPreview,
              ProcessInfo.processInfo.environment["FF_UI_EMPTY_RESULTS"] == "1" else { return }
        clearResultsForPreviewScreenshot()
    }

    /// 把结果清空（预览截图用，不做环境变量判断）。
    ///
    /// 单独抽出来是给 `FF_UI_SIDEBAR_SWEEP` 用的：那一组连拍要证明「换页有动画」，
    /// 而动画要**两页内容不一样**才看得出来（内容相同的话交叉淡化等于没变化）。
    /// 预览态没有真搜索，只好由这里模拟「这一页有结果、那一页空着」。
    func clearResultsForPreviewScreenshot() {
        clearResults()
        searchWarnings = []
        status = ""
        resultsAreCurrent = true
        displayedRevision = contextRevision
        displayedQuery = query
        displayedScope = scope
        displayedTokenBar = tokenBar
    }
    #endif

    // 「读取已保存的原生 NAS 来源」随 Stage 3A 并入 `AppModel+NativeSources.swift`。

    // MARK: - 全局快捷键转发（实现在 ShortcutController）

    func configureShortcutRegistrar(_ register: @escaping (GlobalShortcutSpec) -> String?) {
        shortcuts.configureRegistrar(register)
    }
    @discardableResult
    func applyGlobalShortcut(_ spec: GlobalShortcutSpec) -> Bool { shortcuts.apply(spec) }
    @discardableResult
    func resetGlobalShortcut() -> Bool { shortcuts.reset() }
    func beginShortcutRecording() { shortcuts.beginRecording() }
    func cancelShortcutRecording() { shortcuts.cancelRecording() }

    // MARK: - 本机来源转发（实现在 AppModel+LocalSources.swift）

    // MARK: - 首次启动引导（动作在 AppModel+Onboarding.swift，状态留在主文件）

    /// 由引导窗口在展示时装配（存储属性，extension 放不下，所以留在主文件）。
    var pushOnboardingShortcutPressed: (() -> Void)?

    // 「首次搜索的键位提示」的动作随 Stage 3A 并入 `AppModel+SearchSession.swift`；
    // 状态留在这里——Swift 的 extension 不能含存储属性。

    /// 主搜索窗首次出现时那行键位提示是否可见。
    @Published var searchHintsVisible = false

    // MARK: - 浮窗会话（实现在 AppModel+SearchSession.swift）
    //
    // 关闭再打开时保留多久旧结果、什么时候必须清空、键位提示显示几次，
    // 是一组关于「这一次会话」的判定，随 Stage 3A 搬走。
    // MARK: - 结果定位与打开（实现在 AppModel+ResultActions.swift）
    //
    // 「搜到了但打不开」是这类工具最容易丢分的地方：结果解析、挂载、
    // Finder 定位、快速查看、复制路径全在这一块，随 Stage 3A 搬走。
}
