import AppKit
import FlashFindCore

/// 设置页「高级 → 更新」背后的动作。
///
/// 判定、比较、文案全在 Core（`UpdateCheck` / `UpdateCheckText`），
/// 这里只做三件事：起一个任务、把结果写进 `@Published`、把链接交给系统打开。
/// App 层是 `executableTarget`、测试目标 import 不到，所以**这里越薄越好**——
/// 能测的判断都不该落在这个文件里。
extension AppModel {

    /// 查一次 GitHub 上的最新发布。
    ///
    /// 失败不弹窗：这是用户主动点的操作，结论就显示在按钮下面。
    /// 弹窗会把「这次没查成」放大成一件事故，而它通常只是网络抖了一下。
    func checkForUpdates() {
        guard !updateChecking else { return }
        updateChecking = true
        // 上一轮的结论先清掉：留着旧结果会让「正在检查」和「已是最新」同时出现在屏幕上。
        updateOutcome = nil
        let current = AppVersion.shortVersion
        Task { [weak self] in
            let outcome = await UpdateCheck.evaluate(current: current)
            guard let self else { return }
            self.updateOutcome = outcome
            self.updateChecking = false
        }
    }

    /// 把用户送到能下载的地方。
    ///
    /// 地址由 Core 决定（有新版本用返回体里的页面，否则用发版列表）；
    /// 这里没有可打开的东西就什么都不做，不弹「打不开」——
    /// 那个按钮本来就不会在没有地址时出现。
    func openReleasePage(for outcome: UpdateCheck.Outcome) {
        guard let url = UpdateCheckText.link(for: outcome) else { return }
        NSWorkspace.shared.open(url)
    }
}
