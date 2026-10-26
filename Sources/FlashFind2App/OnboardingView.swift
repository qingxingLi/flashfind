import AppKit
import SwiftUI
import FlashFindCore

/// 首次启动引导。
///
/// 先完成初始化，在快捷键步骤用搜索浮窗演示操作。
///
/// 六步，每步只解决一件事：认识用途 → 设快捷键 → 开权限 → 选本地范围 →
/// （可选）加网络存储 → 汇总 → 直接开始搜。
///
/// 几条自我约束：
/// - **不出现实现细节**：没有 DSM / SMB / WebDAV / 端口 / API 这些词，
///   地址与品牌识别交给添加来源的向导去问；
/// - **能跳的都让跳**：权限、网络存储、快捷键试按都不是必须的，
///   首次使用被卡在某一页是最坏的结果；
/// - **不摆假状态**：每一步的「已完成」来自 `OnboardingProgress`，
///   实时查真实配置（用户可能早就授过权、已经加过 NAS）。
struct OnboardingView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: OnboardingController

    var body: some View {
        VStack(spacing: 0) {
            page
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 720, height: 520)
        .background(Color(nsColor: .windowBackgroundColor))
        // 用户是被我们送去系统设置里开权限的。回到闪寻时自己重查一次，
        // 而不是让他回来点一个「我已经开好了」——那是在让用户替程序做检测。
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            controller.noteAppBecameActive()
        }
    }

    @ViewBuilder private var page: some View {
        switch controller.step {
        case .welcome:
            WelcomeStep()
        case .shortcut:
            ShortcutStep(model: model, controller: controller)
        case .permissions:
            PermissionStep(revision: controller.activationRevision)
        case .localScope:
            LocalScopeStep(model: model, satisfied: controller.currentStepSatisfied)
        case .network:
            NetworkStep(model: model, satisfied: controller.currentStepSatisfied)
        case .finish:
            FinishStep(lines: controller.summary)
        }
    }

    // MARK: - 底部：进度点 + 稍后 / 继续

    /// 底部次要按钮的文案。`nil` 表示这一步不给「跳过」——
    /// 「哪些步可跳过」这个判定在 Core（`OnboardingStep.canSkip`），
    /// 这里只负责措辞。
    private var skipTitle: String? {
        guard controller.step.canSkip else { return nil }
        switch controller.step {
        case .welcome: return "稍后设置"
        case .network: return "暂不添加"
        default: return "稍后"
        }
    }

    private var primaryTitle: String {
        switch controller.step {
        case .welcome: return "开始"
        case .finish: return "完成"
        default: return "继续"
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases) { step in
                    Circle()
                        .fill(step == controller.step ? Color.accentColor : Color(nsColor: .tertiaryLabelColor))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityIdentifier("onboarding-progress")

            Spacer(minLength: 16)

            if controller.step.previous != nil {
                FFSecondaryButton("上一步") { controller.goBack() }
                    .accessibilityIdentifier("onboarding-back")
            }
            if let skipTitle {
                FFSecondaryButton(skipTitle) { controller.advance() }
                    .accessibilityIdentifier("onboarding-skip")
            }
            FFPrimaryButton(primaryTitle) { primaryAction() }
                .keyboardShortcut(.defaultAction)
                .accessibilityIdentifier("onboarding-primary")
        }
        .padding(.horizontal, 24).padding(.vertical, 16)
    }

    private func primaryAction() {
        if controller.step == .shortcut {
            OnboardingWindow.shared.showSearchDemo()
            return
        }
        guard controller.step == .finish else { controller.advance(); return }
        controller.finish()
        OnboardingWindow.shared.close()
        // §「完成以后不要直接结束」：立刻把主搜索窗口打开并聚焦，
        // 让第一次真实搜索就发生在引导结束的下一秒。
        NSApp.activate(ignoringOtherApps: true)
        NotificationCenter.default.post(name: .showFlashFind2, object: nil)
    }
}

/// 引导各步共用的页头（图标 + 标题 + 一句说明 + 右上角「已完成」）。
private struct OnboardingPage<Content: View>: View {
    let step: OnboardingStep
    var subtitle: String?
    var satisfied = false
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: step.symbol)
                    .font(.system(size: 24, weight: .regular))
                    .foregroundStyle(.secondary)
                    .frame(width: 32, height: 30, alignment: .center)
                VStack(alignment: .leading, spacing: 4) {
                    Text(step.title).font(.system(size: 20, weight: .semibold))
                    if let subtitle {
                        Text(subtitle)
                            .font(.callout).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 8)
                // 重新运行引导时：这一步的真实配置已经达成了就如实说，
                // 而不是假装用户还得再配一遍。
                if satisfied {
                    Label("已完成", systemImage: "checkmark.circle.fill")
                        .font(.callout).foregroundStyle(.green)
                        .accessibilityIdentifier("onboarding-step-done")
                }
            }
            ScrollView {
                content().frame(maxWidth: .infinity, alignment: .leading)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 30).padding(.top, 34).padding(.bottom, 20)
    }
}

// MARK: - 01 欢迎

private struct WelcomeStep: View {
    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 0)
            Image(systemName: "magnifyingglass")
                .font(.system(size: 54, weight: .light))
                .foregroundStyle(Color.accentColor)
            Text(OnboardingStep.welcome.title)
                .font(.system(size: 24, weight: .semibold)).padding(.top, 24)
            Text("快速找到这台 Mac 和网络存储中的文件。")
                .font(.body).foregroundStyle(.secondary).padding(.top, 10)
            Text("一个搜索框，搜索 Mac、NAS 和网络文件")
                .font(.callout).foregroundStyle(.tertiary).padding(.top, 26)
            Spacer(minLength: 0)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 02 快捷键

private struct ShortcutStep: View {
    @ObservedObject var model: AppModel
    @ObservedObject var controller: OnboardingController

    var body: some View {
        OnboardingPage(step: .shortcut,
                       subtitle: "无论正在使用哪个应用，都可以通过快捷键打开搜索。",
                       satisfied: controller.currentStepSatisfied) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(spacing: 14) {
                    Text("打开闪寻").font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    Button {
                        if model.isRecordingShortcut { model.cancelShortcutRecording() }
                        else { model.beginShortcutRecording() }
                    } label: {
                        Text(model.isRecordingShortcut ? "按下组合键…" : model.globalShortcut.displayName)
                            .font(.system(.title3, design: .rounded))
                            .monospacedDigit()
                            .frame(minWidth: 130)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .help("点这里直接录制新的快捷键")
                    .accessibilityIdentifier("onboarding-shortcut-record")
                }

                HStack(spacing: 10) {
                    Button("使用默认快捷键") { _ = model.resetGlobalShortcut() }
                        .controlSize(.small)
                        .accessibilityIdentifier("onboarding-shortcut-default")
                    if model.isRecordingShortcut {
                        Button("取消录制") { model.cancelShortcutRecording() }.controlSize(.small)
                    }
                }

                // 被占用时不许静默接受，也不许把 OSStatus 抖给新用户看。
                if let failure = failureMessage {
                    Label(failure, systemImage: "exclamationmark.circle")
                        .font(.callout).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("onboarding-shortcut-failure")
                }

                Divider()
                trial
            }
        }
        // 换了组合之后，上一次「试按成功」不再代表新的这一对。
        .onChange(of: model.globalShortcut) { _ in controller.resetShortcutTrial() }
    }

    /// 失败时的说法。
    ///
    /// 只报**真失败**：`shortcutStatus` 现在只在出问题时才有内容
    ///（正常注册与保存成功都留空），但仍然要求 `available == false` 才显示，
    /// 免得将来有人往里塞一句说明就变成一行红字吓人。
    private var failureMessage: String? {
        if model.shortcutRegistrationRefused { return OnboardingShortcutText.conflict }
        if !model.shortcutAvailable, !model.shortcutStatus.isEmpty { return model.shortcutStatus }
        return nil
    }

    @ViewBuilder private var trial: some View {
        if controller.shortcutWorked {
            Label("快捷键可用", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .accessibilityIdentifier("onboarding-shortcut-worked")
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text("试一下：按 \(model.globalShortcut.displayName)").font(.callout)
                Text("按一次打开搜索演示。也可以点击「继续」，快速看看搜索、空格预览与范围选择。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityIdentifier("onboarding-shortcut-trial")
        }
    }
}

// MARK: - 03 权限

private struct PermissionStep: View {
    /// 每次从系统设置切回闪寻都会变一次。用它当输入，逼这一页重算授权状态。
    let revision: Int

    private var granted: Bool { FullDiskAccess.isGranted }

    var body: some View {
        OnboardingPage(step: .permissions,
                       subtitle: "闪寻需要「完全磁盘访问」才能搜索桌面、文稿这类受保护的位置。",
                       satisfied: granted) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    Image(systemName: granted ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(granted ? Color.green : Color.secondary)
                    Text("完全磁盘访问").font(.callout)
                    Text(granted ? "已开启" : "尚未开启")
                        .font(.callout).foregroundStyle(.secondary)
                    Spacer(minLength: 8)
                    if !granted {
                        Button("打开系统设置") { FullDiskAccess.openSettings() }
                            .controlSize(.large)
                            .accessibilityIdentifier("onboarding-open-fda")
                    }
                }
                .id(revision)

                if !granted {
                    Text("打开之后回到闪寻，这里会自己变成「已开启」——不用回来点什么确认。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("不开也能继续：只是桌面、文稿这些受保护的位置可能搜不到。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - 04 本地搜索范围

private struct LocalScopeStep: View {
    @ObservedObject var model: AppModel
    let satisfied: Bool
    @State private var choice: LocalScopeChoice = .wholeMac

    var body: some View {
        OnboardingPage(step: .localScope,
                       subtitle: "默认搜整台 Mac，多数人不需要改。",
                       satisfied: satisfied) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(LocalScopeChoice.allCases) { item in
                    Button { apply(item) } label: {
                        HStack(alignment: .top, spacing: 10) {
                            Image(systemName: item == choice ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(item == choice ? Color.accentColor : Color.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(.callout)
                                if let detail = item.detail {
                                    Text(detail).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                            Spacer(minLength: 0)
                        }
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier("onboarding-local-" + item.rawValue)
                }

                if choice == .selectedFolders {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(model.localFolders, id: \.path) { folder in
                            HStack(spacing: 8) {
                                Image(systemName: "folder").foregroundStyle(.secondary)
                                Text(folder.path).font(.callout)
                                    .lineLimit(1).truncationMode(.middle)
                                Spacer(minLength: 8)
                                Button { model.removeLocalFolder(folder) } label: {
                                    Image(systemName: "minus.circle")
                                }
                                .buttonStyle(.borderless)
                                .help("从搜索范围里移除")
                            }
                        }
                        // 只能通过系统的选择面板挑文件夹：手工输路径既容易打错，
                        // 也没法确认那个目录到底存不存在。
                        Button("添加文件夹…") { model.addLocalFolder() }
                            .accessibilityIdentifier("onboarding-local-add-folder")
                    }
                    .padding(.leading, 24)
                }

                // 有问题才说话（Core 的 `LocalSearchText` 已经保证正常态为空）。
                if !model.localSearchAvailabilityMessage.isEmpty {
                    Label(model.localSearchAvailabilityMessage, systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .onAppear { syncFromModel(); model.refreshLocalSearchAvailability() }
        .onChange(of: model.localSearchMode) { _ in syncFromModel() }
        .onChange(of: model.localEnabled) { _ in syncFromModel() }
    }

    private func syncFromModel() {
        choice = LocalScopeChoice.resolve(localEnabled: model.localEnabled, mode: model.localSearchMode)
    }

    private func apply(_ item: LocalScopeChoice) {
        choice = item
        model.localEnabled = item.enabled
        // 关闭时不动 mode：用户关掉本机搜索不等于放弃挑好的方式。
        if item.enabled { model.setLocalSearchMode(item.mode) } else { model.localSettingsChanged() }
    }
}

// MARK: - 05 网络存储（可跳过）

private struct NetworkStep: View {
    @ObservedObject var model: AppModel
    let satisfied: Bool

    private var added: [NASSourceConfig] { model.nasSources.filter { !$0.hostName.isEmpty } }
    /// 加过地址、但还没选搜索位置的那些——它们在结果里不会出现，要说出来。
    private var incomplete: [NASSourceConfig] { added.filter { $0.scopes.isEmpty } }

    var body: some View {
        OnboardingPage(step: .network,
                       subtitle: "闪寻也可以搜索 NAS 和其他网络文件。没有的话直接跳过，以后随时能加。",
                       satisfied: satisfied) {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(added) { source in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: source.scopes.isEmpty ? "circle.dashed" : "checkmark.circle.fill")
                            .foregroundStyle(source.scopes.isEmpty ? Color.secondary : Color.green)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(source.displayName) 已添加").font(.callout)
                            let locations = source.scopes.map(NASSourceRowModel.scopeDisplayName)
                            Text(locations.isEmpty ? "还没有选择搜索位置"
                                                   : "搜索位置：" + locations.joined(separator: "、"))
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 0)
                    }
                }

                Button {
                    model.addSource()
                    NSApp.activate(ignoringOtherApps: true)
                    NASWizardWindow.shared.show(model: model)
                } label: {
                    Label(added.isEmpty ? "添加网络存储…" : "再添加一个…", systemImage: "plus")
                }
                .controlSize(.large)
                .accessibilityIdentifier("onboarding-add-source")

                if !incomplete.isEmpty {
                    Text("还没选搜索位置的存储不会出现在搜索结果里。")
                        .font(.caption).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Text("不知道地址？添加时点「附近的设备」查找；也可以直接输入地址。")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

// MARK: - 06 完成

private struct FinishStep: View {
    let lines: [OnboardingSummaryLine]

    var body: some View {
        OnboardingPage(step: .finish, subtitle: "随时可以在菜单栏的「设置…」里改。") {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(lines, id: \.title) { line in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Image(systemName: line.done ? "checkmark.circle.fill" : "circle.dashed")
                            .foregroundStyle(line.done ? Color.green : Color.secondary)
                        Text(line.title).font(.callout).frame(width: 68, alignment: .leading)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(line.value).font(.callout)
                            if let detail = line.detail {
                                Text(detail).font(.caption).foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
        }
    }
}
