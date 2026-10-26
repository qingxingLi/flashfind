import Foundation

/// 首次启动引导（onboarding）的步骤、进度判定与持久化。
///
/// ## 为什么这些判定必须住在 Core
///
/// 引导的核心不是「翻到第几页」，而是**「这台机器现在的配置配好了没有」**：
/// 用户可能早就在系统设置里授过权、已经加过 NAS、快捷键本来就是默认的。
/// 判定写错的表现是引导说谎——明明已经配好了还要求用户再配一遍，
/// 或者明明什么都没配却显示「已准备好」。这两句谎话都在引导页最显眼的位置，
/// 而 App 层（executableTarget）测不了，所以判定一律放这里，用测试锁住。
public enum OnboardingStep: Int, CaseIterable, Sendable, Identifiable {
    case welcome = 0
    case shortcut
    case permissions
    case localScope
    case network
    case finish

    public var id: Int { rawValue }

    /// 页头标题。
    public var title: String {
        switch self {
        case .welcome: return "欢迎使用闪寻"
        case .shortcut: return "随时打开闪寻"
        case .permissions: return "允许闪寻找到你的文件"
        case .localScope: return "你想搜索这台 Mac 的哪些位置？"
        case .network: return "添加网络存储"
        case .finish: return "闪寻已经准备好了"
        }
    }

    /// 短名。用在「上次还没做完：权限、网络存储」这类列举里——
    /// 完整标题是句子，串起来读不通。
    public var shortTitle: String {
        switch self {
        case .welcome: return "欢迎"
        case .shortcut: return "快捷键"
        case .permissions: return "权限"
        case .localScope: return "本地搜索"
        case .network: return "网络存储"
        case .finish: return "完成"
        }
    }

    public var symbol: String {
        switch self {
        case .welcome: return "magnifyingglass"
        case .shortcut: return "keyboard"
        case .permissions: return "lock.shield"
        case .localScope: return "folder"
        case .network: return "externaldrive.connected.to.line.below"
        case .finish: return "checkmark.circle"
        }
    }

    public var next: OnboardingStep? { OnboardingStep(rawValue: rawValue + 1) }
    public var previous: OnboardingStep? { OnboardingStep(rawValue: rawValue - 1) }

    /// 这一步允不允许跳过。
    ///
    /// 只有完成页不可跳过 —— 权限、网络存储、快捷键**都不是**首次使用的必要条件，
    /// 卡在其中任何一步都会让「没有 NAS 的人装不上闪寻」。
    public var canSkip: Bool { self != .finish }

    /// 一共有几步（用于「第 N 步，共 M 步」与进度点）。
    public static var count: Int { allCases.count }
}

/// 引导要展示的**真实**配置状态。
///
/// 每一项都是从当前配置现算的，不是存下来的布尔。存布尔会出现
/// 「用户去系统设置里授了权，引导还显示未开启」这种只能靠退出重开来修的状态。
public struct OnboardingState: Equatable, Sendable {
    /// 全局快捷键已注册且可用。
    public var shortcutConfigured: Bool
    /// 快捷键的显示名（`⌥ Space` 这种），完成页要印出来。
    public var shortcutName: String
    public var fullDiskAccessGranted: Bool
    /// 本机搜索范围已选定（整台 Mac，或指定文件夹且至少选了一个）。
    public var localSearchConfigured: Bool
    /// 已经配好、可以参与搜索的网络存储显示名（空数组 ＝ 尚未添加）。
    public var networkSourceNames: [String]
    /// 这些来源的搜索位置（完成页里跟在名字后面）。
    public var networkLocations: [String]

    public init(shortcutConfigured: Bool, shortcutName: String, fullDiskAccessGranted: Bool,
                localSearchConfigured: Bool, networkSourceNames: [String], networkLocations: [String]) {
        self.shortcutConfigured = shortcutConfigured
        self.shortcutName = shortcutName
        self.fullDiskAccessGranted = fullDiskAccessGranted
        self.localSearchConfigured = localSearchConfigured
        self.networkSourceNames = networkSourceNames
        self.networkLocations = networkLocations
    }

    /// 从 App 层的原始事实算出引导状态。
    ///
    /// 「配好」的判据刻意**不包含「连得上」**：NAS 关机、不在同一网段都是常态，
    /// 把这些算进去会让用户在引导页上永远走不完一步。
    /// 判据只看「配置写全了没有」。
    public static func make(shortcutAvailable: Bool,
                            shortcutName: String,
                            fullDiskAccessGranted: Bool,
                            localEnabled: Bool,
                            localMode: LocalSearchMode,
                            localFolderCount: Int,
                            sources: [NASSourceConfig]) -> OnboardingState {
        let usable = sources.filter { $0.isSearchConfigured }
        return OnboardingState(
            shortcutConfigured: shortcutAvailable,
            shortcutName: shortcutName,
            fullDiskAccessGranted: fullDiskAccessGranted,
            localSearchConfigured: localEnabled && (localMode == .spotlight || localFolderCount > 0),
            networkSourceNames: usable.map(\.displayName),
            networkLocations: usable.flatMap { $0.scopes.map(NASSourceRowModel.scopeDisplayName) })
    }

    /// 兜底值：模型已释放时（窗口正在收尾）也别让引导页拿到别的机器的状态。
    public static let empty = OnboardingState(shortcutConfigured: false, shortcutName: "",
                                              fullDiskAccessGranted: false, localSearchConfigured: false,
                                              networkSourceNames: [], networkLocations: [])
}

/// 完成页的一行。
public struct OnboardingSummaryLine: Equatable, Sendable {
    public let title: String
    public let value: String
    /// 补充说明。未达成时用它说「以后可以在设置里改」，
    /// 而不是把未达成渲染成错误——没加 NAS 不是错误。
    public let detail: String?
    public let done: Bool

    public init(title: String, value: String, detail: String? = nil, done: Bool) {
        self.title = title
        self.value = value
        self.detail = detail
        self.done = done
    }
}

/// 引导的进度判定与文案。
public enum OnboardingProgress {
    /// 这一步在当前配置下是否已经达成。
    ///
    /// 重新运行引导时，每一步的 ✓ 都来自这里——所以「权限早就在系统里开好了」
    /// 或「已经加过 NAS」都会被如实认出来。
    public static func isSatisfied(_ step: OnboardingStep, in state: OnboardingState) -> Bool {
        switch step {
        case .welcome: return true
        case .shortcut: return state.shortcutConfigured
        case .permissions: return state.fullDiskAccessGranted
        case .localScope: return state.localSearchConfigured
        case .network: return !state.networkSourceNames.isEmpty
        case .finish: return true
        }
    }

    /// 还没做完的步骤（不含欢迎页与完成页）。
    public static func unfinished(_ state: OnboardingState) -> [OnboardingStep] {
        OnboardingStep.allCases.filter { step in
            step != .welcome && step != .finish && !isSatisfied(step, in: state)
        }
    }

    /// 中途退出后下次启动的说明：还剩哪几件。
    ///
    /// 只说「还剩什么」，不判断「值不值得说」—— 要不要问这句话由
    /// `OnboardingStore.resumePrompt` 决定（它要求用户确实开始过）。
    ///
    /// - Returns: `nil` 表示没有未完成的步骤。
    public static func unfinishedDescription(_ state: OnboardingState) -> String? {
        let steps = unfinished(state)
        guard !steps.isEmpty else { return nil }
        return "上次还没做完：" + steps.map(\.shortTitle).joined(separator: "、")
    }

    /// 「继续完成闪寻设置？」问句下面那行说明。
    ///
    /// 停在完成页是另一种情况：配置早就齐了，只是没点「完成」——
    /// 这时候说「上次还没做完：…」是错的。
    public static func resumeDetail(_ state: OnboardingState, lastStep: OnboardingStep?) -> String {
        if lastStep == .finish { return "上次看完了设置汇总，还没点「完成」。" }
        return unfinishedDescription(state) ?? "上次的设置有几步还没做完。"
    }

    /// 完成页的汇总。顺序固定：快捷键 / 本地搜索 / 权限 / 网络存储。
    public static func summary(_ state: OnboardingState) -> [OnboardingSummaryLine] {
        [
            OnboardingSummaryLine(title: "快捷键",
                                  value: state.shortcutConfigured ? state.shortcutName : "尚未设置",
                                  detail: state.shortcutConfigured ? nil : "仍可从菜单栏打开闪寻",
                                  done: state.shortcutConfigured),
            OnboardingSummaryLine(title: "本地搜索",
                                  value: state.localSearchConfigured ? "这台 Mac" : "尚未选择",
                                  detail: state.localSearchConfigured ? nil : "以后可以在设置里选择",
                                  done: state.localSearchConfigured),
            OnboardingSummaryLine(title: "权限",
                                  value: state.fullDiskAccessGranted ? "已开启" : "稍后开启",
                                  detail: state.fullDiskAccessGranted ? nil : "桌面、文稿等受保护位置可能搜不到",
                                  done: state.fullDiskAccessGranted),
            OnboardingSummaryLine(title: "网络存储",
                                  value: state.networkSourceNames.isEmpty
                                      ? "尚未添加" : state.networkSourceNames.joined(separator: "、"),
                                  detail: state.networkSourceNames.isEmpty
                                      ? "以后可以在设置里添加" : locationsText(state),
                                  done: !state.networkSourceNames.isEmpty)
        ]
    }

    private static func locationsText(_ state: OnboardingState) -> String? {
        let locations = state.networkLocations
        guard !locations.isEmpty else { return nil }
        let shown = locations.count > 3 ? Array(locations.prefix(3)) + ["…"] : locations
        return "搜索位置：" + shown.joined(separator: "、")
    }
}

/// 引导走过的痕迹。
///
/// 只记两件事：有没有走完、停在哪一步。**不记**「权限开没开」这类事实——
/// 那些每次都现算（见 `OnboardingState.make`），存下来就会过期。
public final class OnboardingStore {
    public enum Key {
        public static let completed = "ff2.onboarding.completed.v1"
        public static let lastStep = "ff2.onboarding.lastStep.v1"
    }

    private let preferences: any ClientPreferences

    public init(preferences: any ClientPreferences) { self.preferences = preferences }

    /// 引导是否走过一遍。
    ///
    /// 这里的 `?? false` 与 R01 那个坑不冲突：R01 要求区分「没设过」与
    /// 「显式关掉」，是因为它们代表两种相反的意图；这里两者都该显示引导，
    /// 没有歧义。读的还是 `object(forKey:)`，只是默认值恰好是 false。
    public var completed: Bool { preferences.object(forKey: Key.completed) as? Bool ?? false }

    /// 上次停在哪一步（没走过或已走完为 nil）。
    public var lastStep: OnboardingStep? {
        guard let raw = preferences.object(forKey: Key.lastStep) as? Int else { return nil }
        return OnboardingStep(rawValue: raw)
    }

    /// 首次启动是否该自动出现引导。
    public var shouldAutoPresent: Bool { !completed }

    /// 中途退出后再启动时的问句。
    ///
    /// - Returns: `nil` ＝ 不用问。走完了不问；一次都没开始过也不问
    ///   （那是首次启动，直接进引导，没有什么可「继续」的）。
    public var resumePrompt: String? {
        guard !completed, lastStep != nil else { return nil }
        return "继续完成闪寻设置？"
    }

    /// 停在哪一步。
    ///
    /// 只有欢迎页不记：停在欢迎页等于「还没开始」，下次直接从头进入引导。
    /// 停在完成页要记 —— 用户是看完了汇总、还没点「完成」就关的窗。
    public func rememberStep(_ step: OnboardingStep) {
        guard step != .welcome else {
            preferences.set(nil, forKey: Key.lastStep)
            return
        }
        preferences.set(step.rawValue, forKey: Key.lastStep)
    }

    public func markCompleted() {
        preferences.set(true, forKey: Key.completed)
        preferences.set(nil, forKey: Key.lastStep)
    }

    /// 「重新运行欢迎引导…」。
    ///
    /// **只清「已完成」标记**：已有 NAS、快捷键、搜索文件夹、权限一律不动。
    /// 这条是引导最容易做错的地方——把「再看一遍」理解成「恢复出厂」。
    public func rerun() {
        preferences.set(false, forKey: Key.completed)
        preferences.set(nil, forKey: Key.lastStep)
    }
}

/// 录制快捷键失败时的说法。
///
/// 注册器那边会把 OSStatus 一起抖出来（`这个快捷键已被占用或系统拒绝注册（-9868）…`），
/// 那句话对**设置页**是对的——那里用户已经在排查了，多一个数字有用。
/// 引导页不行：新用户第一次见到闪寻，一个错误码只会让他觉得「这软件坏了」。
public enum OnboardingShortcutText {
    /// 组合被系统或别的应用占用。
    public static let conflict = "这个快捷键可能已被其他功能使用。请选择其他快捷键。"
}

/// 首次搜索的键位提示。
///
/// 只在第一次用搜索窗时出现一次，输入或操作后消失，之后不再出现。
/// 不做第二套教程：用户真正需要的是「怎么选中、怎么打开」，四个键位够用。
public enum SearchHintGuide {
    public static let storageKey = "ff2.searchHints.shown.v1"

    /// 与 `SearchKeyRouter` 的实际绑定一致（改键位请同时改这里）。
    ///
    /// 输入时保留空格；先用方向键或点击选择结果后，Space 才用于预览。
    public static let lines = ["↑ ↓ 选择", "Space 预览", "Return 打开", "⌘ Return 在 Finder 中显示"]

    public static func shouldShow(preferences: any ClientPreferences) -> Bool {
        !(preferences.object(forKey: storageKey) as? Bool ?? false)
    }

    public static func markShown(preferences: any ClientPreferences) {
        preferences.set(true, forKey: storageKey)
    }
}
