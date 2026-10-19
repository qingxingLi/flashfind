import Foundation
import FlashFindCore

/// 首次启动引导的**步骤状态**。
///
/// 有意做得很薄：这里只管「停在哪一步」「试按过快捷键没有」，
/// 真正要展示的配置状态每次都从宿主现算（`facts`），不在这里缓存。
///
/// 缓存过一次就会过期——用户在系统设置里授了权、跳回来时引导还写着「尚未开启」，
/// 只能靠退出重开来修。这类状态一律现算。
@MainActor
final class OnboardingController: ObservableObject {
    @Published private(set) var step: OnboardingStep
    /// 用户在引导页里成功按过一次全局快捷键。
    @Published private(set) var shortcutWorked = false
    /// 每次闪寻重新获得前台焦点 +1。
    ///
    /// 权限页靠它重算「完全磁盘访问」：用户是被我们送去系统设置里开的开关，
    /// 回来必须自己发现已经开好了，不能让他按一个「我已经开好了」的按钮
    /// （那是在让用户替程序做检测）。
    @Published private(set) var activationRevision = 0

    let store: OnboardingStore
    /// 宿主提供的实时状态。返回的每一项都必须现算。
    private let facts: () -> OnboardingState

    init(preferences: any ClientPreferences,
         startAt: OnboardingStep = .welcome,
         facts: @escaping () -> OnboardingState) {
        self.store = OnboardingStore(preferences: preferences)
        self.step = startAt
        self.facts = facts
    }

    var state: OnboardingState { facts() }
    var summary: [OnboardingSummaryLine] { OnboardingProgress.summary(state) }
    /// 当前这一步在当前配置下是否已经达成（重新运行时用来显示「已完成」）。
    var currentStepSatisfied: Bool { OnboardingProgress.isSatisfied(step, in: state) }
    var index: Int { step.rawValue + 1 }
    var count: Int { OnboardingStep.count }

    /// 下一步。可跳过的那几步（快捷键 / 权限 / 网络存储）走的也是这条路径——
    /// 跳过不改任何配置，只是往前走。
    func advance() {
        guard let next = step.next else { return }
        step = next
        store.rememberStep(step)
    }

    func goBack() {
        guard let previous = step.previous else { return }
        step = previous
        store.rememberStep(step)
    }

    /// 关闭窗口时调用：记住停在哪一步，下次可以接着来。
    func noteStepLeft() { store.rememberStep(step) }

    func finish() { store.markCompleted() }

    func noteShortcutWorked() { shortcutWorked = true }

    /// 换了快捷键之后，原来那次「试按成功」不再代表新的组合。
    func resetShortcutTrial() { shortcutWorked = false }

    func noteAppBecameActive() { activationRevision += 1 }
}
