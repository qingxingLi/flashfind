import AppKit
import SwiftUI
import Carbon
import FlashFindCore

extension Notification.Name {
    static let showFlashFind2 = Notification.Name("showFlashFind2")
    static let toggleFlashFind2 = Notification.Name("toggleFlashFind2")
    static let openFlashFindSettings = Notification.Name("openFlashFindSettings")
    static let closePreviewSettings = Notification.Name("closeFlashFindPreviewSettings")
    /// 浮窗已隐藏。控制器据此卸载「点击外部关闭」的事件监视。
    static let flashFindPanelHidden = Notification.Name("flashFindPanelHidden")
}

enum SearchScope: String, CaseIterable, Identifiable {
    case all = "全部", local = "本机", nas = "NAS"
    var id: String { rawValue }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ★ 凭据后端必须赶在 `model` 之前装配：存储属性按声明顺序初始化，
    /// 而 AppModel 起来就要读已保存的密码，晚一步它读到的就是空的内存后端。
    /// 不写进 `init` 是因为 init 的函数体在所有属性初始化**之后**才跑。
    private let credentialBackendInstalled: Void = {
        // GUI 的默认后端是**系统钥匙串**：密码不再以任何形式落到 ~/Library 下的明文文件。
        // FileSecretStore 只是迁移源（读旧明文用），它不再是正式 App 的存储落点。
        // 明文源必须挂进来：迁移要靠它读到旧 credentials.json 与「待验证」标记。
        CredentialStore.install(KeychainSecretStore(), plaintextSource: FileSecretStore())
    }()
    let model: AppModel = {
        #if DEBUG
        // Phase 6.3b-4 的跨进程装配验证：只换「偏好从哪儿来」与缓存落点，
        // 装配本身仍是产品那套（真 provider / 真协调器 / 真权威端）。
        if let launch = E2ELaunchMode.current {
            return AppModel(preferences: launch.preferences,
                            cacheDirectory: launch.cacheDirectory,
                            credentialAccessAllowed: false)
        }
        #endif
        if Bundle.main.object(forInfoDictionaryKey:"FlashFindAcceptanceRecording") as? String == "1" {
            return AppModel(preferences:InMemoryClientPreferences(values:["ff2.multiNAS.enabled":true,"ff2.localEnabled":true]),cacheDirectory:Bundle.main.bundleURL.deletingLastPathComponent().appendingPathComponent("RuntimeData/legacy-cache-unused"),credentialAccessAllowed:false)
        }
        return AppModel()
    }()
    private var searchPanel: SearchPanelController?
    private var previewDesktop: NSWindow?
    /// MCP 助手的权威端监听（Phase 6.1）。生命周期跟着 App：起来一次、退出时停。
    private let mcpAuthority = MCPAuthorityController()
    private let hotkeyRegistrar = GlobalHotKeyRegistrar()
    /// 关掉最后一个窗口**不等于**退出应用。
    ///
    /// 闪寻是常驻的搜索工具：关掉搜索浮窗只是「暂时不搜」，关掉设置只是
    /// 「改完了」，两件事都不是「我要退出」。真正退出走菜单「退出闪寻」或 ⌘Q。
    ///
    /// 不实现这一条，AppKit 会把「最后一个窗口关闭」当成退出信号，
    /// 进程随后以 **0** 退出。用户在界面上看到的就是「闪退」，
    /// 而**没有崩溃报告**——它不是崩溃；日志里只有这一串（实测 15:23:58）：
    ///
    /// ```
    /// window <...SearchPanel: 0x1559095f0> windowNumber=fbb6 finishing close
    /// [launchd] service inactive: application.com.flashfind.v2.…
    /// [runningboardd] termination reported by launchd (0, 0, 0)
    /// ```
    ///
    /// OTP 账号复现得最明显：向导关掉的那一刻，屏幕上最后一个窗口消失，
    /// 用户刚点完「登录」，看到的就是整台应用凭空不见。
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 旧明文 → 钥匙串的一次性迁移。只写不读（不读回校验）；
        // 明文删在最后：要等某次真实登录用新后端的密码连上了才删（见 confirmCredentialVerified）。
        // 这里不看返回报告：迁移可重入，这次没迁成的下次启动再试。
        if !AppEnvironment.isPreview {
            CredentialStore.migrateLegacyPlaintext()
            // 经典钥匙串 → Data Protection 钥匙串。今天所有构建都缺 entitlement，
            // 于是它每次都整批中止、什么都不做；签上 Developer ID 的那一天，
            // 同一句就会把老密码真的搬过去（顺序与规则见 KeychainTierMigration）。
            // account 必须指名：钥匙串不能枚举，来源列表只有这里有。
            CredentialStore.migrateKeychainTier(accounts: model.nasSources.map { $0.credentialAccount })
        }
        // 外观要在任何窗口出现之前应用：用户上次选了深色，重启后第一帧就得是深色，
        // 不能先闪一下浅色再变。启动路径上漏这一句，设置页里选了也不生效——
        // 那种缺陷编译能过、运行也不报错。
        model.applyAppearance()
        // AI 助手的 IPC 监听。放在这儿而不是 onboarding 之后：引导页可能停留很久，
        // 而 `flashfind-mcp` 可能在用户还没点完引导时就被客户端拉起来了。
        // 抢不到 socket（另一份闪寻在跑）时它自己会安静退出这条路径（§1.3.3.1）。
        //
        // 先注入再启动：设置页的「MCP 助手」那一行读的是这个对象上的 `lastStart`，
        // 顺序反了会读到 nil（显示「未启动」），而实际已经在监听了。
        model.mcpAuthority = mcpAuthority
        mcpAuthority.start(model: model)
        #if DEBUG
        // 权威端已经起来了，剩下的都是给真实用户看的东西（引导、搜索浮窗、
        // 全局快捷键）。测试启动模式在这里收手：窗口会抢焦点、还会按机器上
        // 当前的焦状态让用例时好时坏。
        if E2ELaunchMode.current?.isHeadless == true { return }
        #endif
        if AppEnvironment.isPreview, ProcessInfo.processInfo.environment["FF_UI_DESKTOP"] == "1" {
            if let screen = NSScreen.main, let url = NSWorkspace.shared.desktopImageURL(for: screen), let image = NSImage(contentsOf: url) {
                let backdrop = NSWindow(contentRect: screen.visibleFrame, styleMask: .borderless, backing: .buffered, defer: false)
                backdrop.level = .floating
                backdrop.isReleasedWhenClosed = false
                backdrop.ignoresMouseEvents = true
                let imageView = NSImageView(frame: screen.visibleFrame)
                imageView.image = image
                imageView.imageScaling = .scaleAxesIndependently
                backdrop.contentView = imageView
                backdrop.orderFrontRegardless()
                previewDesktop = backdrop
            }
        }
        searchPanel = SearchPanelController(model: model)
        // 预览构建照旧：直接显示搜索浮窗（截图/点验用），不弹引导。
        if AppEnvironment.isPreview {
            searchPanel?.show()
            if let seconds = ProcessInfo.processInfo.environment["FF_UI_LIFETIME"].flatMap(Double.init) {
                DispatchQueue.main.asyncAfter(deadline: .now() + min(120, max(5, seconds))) {
                    NotificationCenter.default.post(name: .closePreviewSettings, object: nil)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApplication.shared.terminate(nil) }
                }
            }
            return
        }
        // ★ 常驻应用：窗口全部关闭之后不许系统回收进程。
        //
        // macOS 的 Automatic Termination 会在「没有可见窗口」时把应用标记成
        // 可回收并**直接杀掉**。它不是崩溃，所以不产生崩溃报告——
        // 用户看到的就是「点完登录就闪退」，而我们翻遍
        // `~/Library/Logs/DiagnosticReports` 也找不到任何痕迹。
        //
        // 实测日志（2026-10-22 15:24:35，build 25）：
        //   window <NSWindow: 0x13aa6a650> finishing close
        //   [AutomaticTermination] Setting _kLSApplicationWouldBeTerminatedByTALKey=1
        //
        // 关窗路径现在也会把搜索浮窗放回来（见 `LastWindowClosePolicy`），
        // 但两件事解决的是不同的失败：浮窗管「看得见」，这句管「进程还在」。
        // 只做浮窗，关窗到浮窗出现之间仍有空窗期；只做这句，
        // 用户会盯着一片干净的桌面找不到入口。
        //
        // 放在 headless / preview 之后：那两条路径靠测试自己退出，
        // 不能被「永不回收」拖住。
        ProcessInfo.processInfo.disableAutomaticTermination(
            LastWindowClosePolicy.automaticTerminationDisabledReason)
        presentOnboardingOrSearch()
        hotkeyRegistrar.onPress = { [weak self] in
            guard let self else { return }
            if model.isRecordingShortcut { _ = model.applyGlobalShortcut(model.globalShortcut) }
            // 引导页里按一下只表示「这个快捷键能用」，不把搜索浮窗弹到引导前面去——
            // 那会把用户从正在做的事上顶走，而这一下正是他照着引导按的。
            else if OnboardingWindow.shared.isVisible { model.noteOnboardingShortcutPressed() }
            else { NotificationCenter.default.post(name: .toggleFlashFind2, object: nil) }
        }
        model.configureShortcutRegistrar { [weak self] spec in
            guard let self else { return "快捷键注册器不可用，请重新打开闪寻" }
            return self.hotkeyRegistrar.replace(with: spec)
        }
    }

    /// 首次启动先走引导，其余情况照旧直接开搜索浮窗。
    ///
    /// 不先走引导就打开搜索浮窗，新用户看到的是一个没有任何来源、
    /// 也搜不出东西的空搜索框，然后不知道下一步该做什么。
    private func presentOnboardingOrSearch() {
        guard model.onboardingStore.shouldAutoPresent else {
            searchPanel?.show()
            return
        }
        // 上次中途关掉了：问一句要不要接着配，而不是既不问也不管。
        if let prompt = model.onboardingStore.resumePrompt {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.messageText = prompt
            alert.informativeText = OnboardingProgress.resumeDetail(model.onboardingState,
                                                                   lastStep: model.onboardingStore.lastStep)
            alert.addButton(withTitle: "继续")
            alert.addButton(withTitle: "稍后")
            if alert.runModal() == .alertFirstButtonReturn {
                OnboardingWindow.shared.show(model: model, startAt: model.onboardingStore.lastStep ?? .welcome)
            }
            return
        }
        OnboardingWindow.shared.show(model: model)
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        searchPanel?.show()
        return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        mcpAuthority.stop()
        previewDesktop?.orderOut(nil)
        model.closeSearchProviders();model.cancelShortcutRecording(); hotkeyRegistrar.stop()
    }
}

/// 品牌图标：品牌「圆环 + 闪电」的单色模板版。
///
/// 素材由 `tools/make-menubar-icon.swift` 从 ShanXun.icns 派生
/// （亮度掩膜剔掉深色底板，只留亮部字形，纯黑 + 原始 alpha）。
/// `isTemplate = true` 让系统按明暗模式自动黑/白着色，
/// 这正是状态栏的配色约定——不许在代码里写死颜色。
///
/// 同一枚字形服务两处：状态栏（18pt）与搜索框前导图标（22pt， 
/// 用户要求「把搜索图标换成自己的」）。两处共用同一条换算与同一份底色处理，
/// 免得又一次「改了一处、另一处还是旧尺寸」；只有位图密度不同，
/// 因为 18pt 与 22pt 各自需要的像素数本来就不同。
enum StatusIcon {
    /// 搜索框前导图标：22pt。
    ///
    /// 用 24/48px 画布那一套（`ShanXunGlyph*`），不用状态栏那两套：
    /// 22pt 在 Retina 上要 44px 像素，而状态栏素材只有 36px——放大 1.22 倍、
    /// 边缘发虚。同一枚字形出两组密度，见 tools/make-menubar-icon.swift。
    static func searchFieldGlyph() -> NSImage {
        glyph(named: "ShanXunGlyph", height: BrandGlyphMetrics.searchFieldHeight)
    }

    /// 状态栏图标：18pt。它的素材就是为 18pt 画的（18/36px，正好齐平）。
    static let menuBar: NSImage = glyph(named: "ShanXunMenuIcon",
                                        height: BrandGlyphMetrics.menuBarHeight)

    /// 两处共用同一条换算路径：等比缩放 + 模板着色 + 读屏说明。
    private static func glyph(named name: String, height: CGFloat) -> NSImage {
        let url = Bundle.main.url(forResource: name + "@2x", withExtension: "png")
            ?? Bundle.main.url(forResource: name, withExtension: "png")
        if let url, let image = NSImage(contentsOf: url) {
            image.isTemplate = true
            // 画布 24px（@1x）/ 48px（@2x）；宽按字形比例算，不许拉变形。
            image.size = BrandGlyphMetrics.fittedSize(naturalWidth: image.size.width,
                                                      naturalHeight: image.size.height,
                                                      height: height)
            image.accessibilityDescription = "闪寻"
            return image
        }
        // 兜底：素材缺失（如 swift run 裸跑）时退回系统放大镜，图标位不能空着。
        return NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: "闪寻")!
    }
}

@main
struct FlashFind2App: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene {
        MenuBarExtra {
            SearchMenuView(model: delegate.model)
        } label: {
            Image(nsImage: StatusIcon.menuBar)
        }
    }
}

private struct SearchMenuView: View {
    @ObservedObject var model: AppModel
    var body: some View {
        Button("打开闪寻") { NotificationCenter.default.post(name: .showFlashFind2, object: nil) }
        if !model.nasSources.isEmpty {
            Divider()
            // 菜单栏只显示「这台 NAS 现在能不能搜」，不展开配置细节。
            // 配置仍然只在设置窗口里做。
            ForEach(model.nasSources.filter { $0.enabled }) { source in
                let ready = model.nativeProviders[source.id]?.ready ?? false
                Label(source.displayName, systemImage: ready ? "checkmark.circle" : "circle.dashed")
                    .help(ready ? "可以搜索" : model.sourceStatus(source.id).message)
            }
        }
        Divider()
        Button("设置…") { model.openSettingsWindow() }
            .keyboardShortcut(",", modifiers: .command)
        // 引导只自动出现一次；之后想再看一遍只能从这里进。
        // 「重新运行」不重置任何配置——只清「已完成」标记（见 `OnboardingStore.rerun`）。
        Button("重新运行欢迎引导…") { model.restartOnboarding() }
        Divider()
        // 「关于」不再占设置里的一级页面（macOS 惯例是放在应用菜单）。
        // 闪寻是只挂状态栏的 accessory，没有可点的菜单栏，所以入口放在这里。
        Button("关于闪寻") { AboutPanel.show() }
        Button("退出闪寻") { NSApplication.shared.terminate(nil) }
    }
}

/// 标准「关于」面板。
///
/// 用系统的 `orderFrontStandardAboutPanel` 而不是自绘：图标、版式、
/// 版本行的排版都由系统负责，最贴近 macOS 原生，
/// 也省掉一整套要跟着系统外观走的自定义视图。
enum AboutPanel {
    static func show() {
        // 版本号读取与格式化统一走 `FlashFindCore.AppVersion`：设置页「通用」
        // 也显示同一个值，两处各读一次 Bundle 迟早会出现两种说法。
        let version = AppVersion.shortVersion

        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        let credits = NSAttributedString(
            string: "快速搜索这台 Mac 和网络存储中的文件。",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor,
                         .paragraphStyle: paragraph])

        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [
            .applicationName: "闪寻",
            .applicationVersion: version,
            // 空串是故意的，不是漏填：不传这一项，系统会把 Info.plist 里的
            // 内部序号填进括号，面板显示成「版本 1.0.1 (19)」；传空串才会整段消失。
            // （三种写法都截图实测过：不传 → (19)、空串 → 只有 1.0.1、
            // 传同一个版本号 → (1.0.1)。）内部序号不进界面。
            .version: "",
            .credits: credits,
        ])
    }
}
