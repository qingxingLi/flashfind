import AppKit
import FlashFindCore

/// 本机这一侧的搜索来源：本机搜索方式（Spotlight / 指定文件夹）、
/// 已挂载的 SMB 共享发现，以及把挂载共享绑到某个 NAS 来源上。
///
/// 从 AppModel 里切出来的理由和 `ShortcutController`、`ResultActionController` 一样：
/// 这一块只依赖「偏好存在哪 / 挂载表怎么读 / 表单字段往哪写」几个入口，
/// 做成注入的闭包后就能独立于 AppModel 那 20 多个 `@Published` 存在。
///
/// 边界也和它们一样：**状态搬过来了，解析用的状态一个都没搬**。
/// 「当前选中的是哪个连接」「这个来源的 SMB 端点是什么」仍由宿主给闭包回答。
@MainActor
final class LocalSourceController: ObservableObject {
    @Published var localEnabled = true
    @Published var localFolders: [URL] = []
    @Published var localSearchMode: LocalSearchMode = .spotlight
    /// 本机搜索的**问题提示**（没有问题时为空串，设置页不占那一行）。
    ///
    /// 初值为空，检查由设置页出现时触发（`SettingsView.onAppear`）。
    /// 初值若写死成「正在检查本机搜索状态」，而启动时没有任何地方真的去检查，
    /// 那行字就会一直挂着，检查永远不会结束。
    @Published var localSearchAvailabilityMessage = ""

    private let preferences: any ClientPreferences
    private let isPreview: Bool
    private let fixtureMode: Bool

    init(preferences: any ClientPreferences, isPreview: Bool, fixtureMode: Bool) {
        self.preferences = preferences
        self.isPreview = isPreview
        self.fixtureMode = fixtureMode
    }

    // MARK: - 宿主注入的入口

    /// 状态栏文案。导入、绑定、发现共享的结果都走这里。
    var onStatus: (String) -> Void = { _ in }
    /// 影响搜索结果的配置变了：作废当前结果并重新发起。
    var onSearchReset: () -> Void = {}

    // MARK: - 启动装配

    func loadFromPreferences() {
        localEnabled = preferences.object(forKey: "ff2.localEnabled") as? Bool ?? true
        localFolders = (preferences.stringArray(forKey: "ff2.localFolders") ?? []).map { URL(fileURLWithPath: $0) }
        localSearchMode = LocalSearchMode(rawValue: preferences.string(forKey: "ff2.localSearchMode") ?? "") ?? .spotlight
    }

    /// 预览态的基线：不碰真实配置，本机文件夹一律空。
    func applyPreviewBaseline() { localEnabled = true; localFolders = [] }

    /// 可交互样例的基线：关掉本机搜索，让样例结果全部来自样例 NAS。
    func applyFixtureBaseline() {
        localEnabled = false
        localSearchAvailabilityMessage = "UI 样例：Spotlight 已关闭，可明确选择文件夹模式"
    }

    // MARK: - 本机搜索方式

    func refreshLocalSearchAvailability() {
        let context: LocalSearchText.Context = isPreview ? (fixtureMode ? .previewFixture : .preview) : .live
        if let text = LocalSearchText.availability(mode: localSearchMode, folderCount: localFolders.count, context: context) {
            localSearchAvailabilityMessage = text
            return
        }
        // 预览态不动文案；真实运行走到这里表示**设置本身没问题**——
        // 必须先把上一条提示清掉（比如刚从「Spotlight 关着」改成文件夹模式），
        // 否则那行解决问题后才该消失的灰字会一直留在设置页上。
        guard !isPreview else { return }
        localSearchAvailabilityMessage = ""
        // 只有 Spotlight 模式的下文才由系统索引探测决定。
        guard localSearchMode == .spotlight else { return }
        Task {
            let report = await SpotlightAvailability.inspect()
            guard localSearchMode == .spotlight else { return }
            localSearchAvailabilityMessage = report.attentionMessage ?? ""
        }
    }

    func setLocalSearchMode(_ mode: LocalSearchMode) {
        guard !isPreview || fixtureMode else { onStatus("UI 预览不修改真实搜索模式"); return }
        localSearchMode = mode
        preferences.set(mode.rawValue, forKey: "ff2.localSearchMode")
        // ★ 本机搜索开关也要一起落盘。
        //
        // 两个界面的「整台 Mac / 指定文件夹 / 不搜索」都把开关与方式一起改，
        // 而这里原来只写 `mode`：用户先选过「不搜索」（开关落盘为 false），
        // 之后再选「整台 Mac」，开关在内存里变回 true、磁盘上还是 false ——
        // 重启之后设置页又变回「不搜索这台 Mac」。改一次设置、重启就丢，
        // 而界面上看不出任何异常。
        preferences.set(localEnabled, forKey: "ff2.localEnabled")
        refreshLocalSearchAvailability()
        onSearchReset()
    }

    func localSettingsChanged() {
        guard !isPreview || fixtureMode else { return }
        preferences.set(localEnabled, forKey: "ff2.localEnabled")
        preferences.set(localFolders.map(\.path), forKey: "ff2.localFolders")
        refreshLocalSearchAvailability()
        onSearchReset()
    }

    func removeLocalFolder(_ folder: URL) {
        localFolders.removeAll { $0 == folder }
        localSettingsChanged()
    }

    func addLocalFolder() {
        if fixtureMode {
            localFolders.append(AppEnvironment.previewRoot.appendingPathComponent("SelectedFixtureFolder"))
            localSettingsChanged()
            onStatus("UI 样例：已选择虚构文件夹，不访问真实目录")
            return
        }
        guard !isPreview else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            // 网络卷不该混进本机搜索：它属于 NAS 来源，走本机文件夹会绕过索引服务。
            guard (try? url.resourceValues(forKeys: [.volumeIsLocalKey]).volumeIsLocal) == true else {
                onStatus("网络目录请在 NAS 设置中添加")
                continue
            }
            if !localFolders.contains(url) { localFolders.append(url) }
        }
        localSettingsChanged()
    }

}
