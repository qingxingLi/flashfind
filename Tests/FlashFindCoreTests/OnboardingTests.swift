import XCTest
@testable import FlashFindCore

/// 首次启动引导：步骤、进度判定、完成汇总、中途退出与重新运行。
///
/// 这一批断言锁的是**「引导会不会说谎」**：
/// 用户可能早就在系统设置里授过权、已经加过 NAS、快捷键本来就是默认的。
/// 判定写成「看存下来的第几页」就会出现「明明配好了还要再配一遍」；
/// 判定写成「连得上才算配好」就会出现「NAS 关机就永远走不完这一步」。
final class OnboardingTests: XCTestCase {

    // MARK: - 步骤

    /// 六步，顺序固定。步数本身就是承诺：新用户愿意花在引导上的耐心是有限的。
    func testStepsAreSixAndInOrder() {
        XCTAssertEqual(OnboardingStep.count, 6)
        XCTAssertEqual(OnboardingStep.allCases.map(\.shortTitle),
                       ["欢迎", "快捷键", "权限", "本地搜索", "网络存储", "完成"])
        XCTAssertEqual(OnboardingStep.allCases.map(\.rawValue), Array(0...5))
    }

    /// ★ 第一步没有上一步、最后一步没有下一步，中间的都接得上。
    ///
    /// 「继续」到底会不会卡住、会不会跳过一步，全靠这个链条。
    func testStepChainIsClosedAtBothEnds() {
        XCTAssertNil(OnboardingStep.welcome.previous)
        XCTAssertNil(OnboardingStep.finish.next)
        for step in OnboardingStep.allCases.dropLast() {
            XCTAssertEqual(step.next?.previous, step, "\(step.shortTitle) 的下一步接不回自己")
        }
        XCTAssertEqual(OnboardingStep.allCases.compactMap(\.next).count, 5)
    }

    /// 每一步都要有标题、短名和图标，短名不许重复（要用来列举「还剩哪几件」）。
    func testEveryStepIsPresentable() {
        let shortTitles = OnboardingStep.allCases.map(\.shortTitle)
        XCTAssertEqual(Set(shortTitles).count, shortTitles.count, "短名重复会让「还剩…」读不通")
        XCTAssertFalse(OnboardingStep.allCases.contains { $0.title.isEmpty || $0.symbol.isEmpty })
    }

    /// ★ 除完成页外都可跳过。
    ///
    /// 这是整个引导最重要的一条产品约束：权限、网络存储、快捷键都不是
    /// 首次使用的必要条件。把任何一步做成必过，就会出现
    /// 「家里没有 NAS 的人装不上闪寻」。
    func testEveryStepExceptFinishCanBeSkipped() {
        XCTAssertEqual(OnboardingStep.allCases.filter { !$0.canSkip }, [.finish])
    }

    // MARK: - 从真实配置推导状态

    private func source(host: String = "192.168.1.96", username: String = "nasuser",
                        scopes: [String] = ["/示例共享文件夹", "/项目资料"],
                        name: String = "公司 NAS") -> NASSourceConfig {
        NASSourceConfig(name: name, vendor: .synology, host: host, port: 5001,
                        username: username, scopes: scopes)
    }

    private func state(shortcutAvailable: Bool = true,
                       fda: Bool = false,
                       localEnabled: Bool = true,
                       mode: LocalSearchMode = .spotlight,
                       folderCount: Int = 0,
                       sources: [NASSourceConfig] = []) -> OnboardingState {
        OnboardingState.make(shortcutAvailable: shortcutAvailable, shortcutName: "⌥ Space",
                             fullDiskAccessGranted: fda, localEnabled: localEnabled,
                             localMode: mode, localFolderCount: folderCount, sources: sources)
    }

    /// 默认那套（整台 Mac）就算配好了 —— 绝大多数用户不需要做任何事。
    func testWholeMacCountsAsConfigured() {
        XCTAssertTrue(state().localSearchConfigured)
    }

    /// 「只搜索指定文件夹」却一个文件夹都没选 = 搜不到任何东西，不算配好。
    func testFolderModeNeedsAtLeastOneFolder() {
        XCTAssertFalse(state(mode: .selectedFolders, folderCount: 0).localSearchConfigured)
        XCTAssertTrue(state(mode: .selectedFolders, folderCount: 2).localSearchConfigured)
    }

    /// 关掉本机搜索也算一种明确选择，但**不算**「本地搜索配好了」。
    func testDisabledLocalSearchIsNotConfigured() {
        XCTAssertFalse(state(localEnabled: false).localSearchConfigured)
    }

    /// ★ 判据是「配置写全了没有」，不是「连得上」。
    ///
    /// NAS 关机、不在同一网段都是常态。把它们算进去，用户就会在引导页上
    /// 永远走不完「网络存储」这一步，而真正的原因（机器没开）他并不会想到。
    func testSourceCountsWhenConfiguredEvenIfNotConnected() {
        let configured = state(sources: [source()])
        XCTAssertEqual(configured.networkSourceNames, ["公司 NAS"])
        // 位置去前导斜杠：`/项目资料` 是 DSM 的写法，不是产品概念。
        XCTAssertEqual(configured.networkLocations, ["示例共享文件夹", "项目资料"])
    }

    /// 地址或账号没填全的来源不算已添加。
    func testIncompleteSourceDoesNotCount() {
        XCTAssertTrue(state(sources: [source(host: "")]).networkSourceNames.isEmpty)
        XCTAssertTrue(state(sources: [source(username: "")]).networkSourceNames.isEmpty)
    }

    /// 地址账号都填了、只是还没选搜索位置：不算配好（它确实搜不到东西）。
    func testSourceWithoutScopesDoesNotCount() {
        XCTAssertTrue(state(sources: [source(scopes: [])]).networkSourceNames.isEmpty)
    }

    // MARK: - 每步是否达成

    func testStepSatisfactionComesFromConfiguration() {
        let nothing = state(shortcutAvailable: false)
        XCTAssertFalse(OnboardingProgress.isSatisfied(.shortcut, in: nothing))
        XCTAssertFalse(OnboardingProgress.isSatisfied(.permissions, in: nothing))
        XCTAssertFalse(OnboardingProgress.isSatisfied(.network, in: nothing))
        XCTAssertTrue(OnboardingProgress.isSatisfied(.welcome, in: nothing), "欢迎页没有可达成的内容")

        let everything = state(fda: true, sources: [source()])
        for step in OnboardingStep.allCases {
            XCTAssertTrue(OnboardingProgress.isSatisfied(step, in: everything),
                          "\(step.shortTitle) 在配置齐全时应显示已完成")
        }
    }

    /// 「上次还没做完：…」要按真实配置列举，而不是按停在第几页。
    func testUnfinishedComesFromConfiguration() {
        // 快捷键配好了、权限没开、选了「指定文件夹」却一个都没挑、也没有 NAS。
        let partial = state(shortcutAvailable: true, fda: false, mode: .selectedFolders, folderCount: 0)
        XCTAssertEqual(OnboardingProgress.unfinished(partial), [.permissions, .localScope, .network])
        XCTAssertEqual(OnboardingProgress.unfinishedDescription(partial),
                       "上次还没做完：权限、本地搜索、网络存储")

        // 换成默认的「整台 Mac」之后，本地搜索这一步就不再算没做。
        XCTAssertEqual(OnboardingProgress.unfinished(state(shortcutAvailable: true)),
                       [.permissions, .network])
    }

    /// 全部配好之后就没有「还剩什么」可说了。
    ///
    /// 这句只在「中途退出过」的场合被用到（`resumePrompt` 要求用户确实开始过），
    /// 所以首次启动不会被它打扰。
    func testNoUnfinishedDescriptionWhenEverythingIsDone() {
        XCTAssertNil(OnboardingProgress.unfinishedDescription(state(fda: true, sources: [source()])))
        XCTAssertTrue(OnboardingProgress.unfinished(state(fda: true, sources: [source()])).isEmpty)
    }

    // MARK: - 完成页汇总

    func testSummaryHasFourRowsInAFixedOrder() {
        let lines = OnboardingProgress.summary(state(fda: true, sources: [source()]))
        XCTAssertEqual(lines.map(\.title), ["快捷键", "本地搜索", "权限", "网络存储"])
        XCTAssertTrue(lines.allSatisfy(\.done))
        XCTAssertEqual(lines[1].value, "这台 Mac")
        XCTAssertEqual(lines[2].value, "已开启")
        XCTAssertEqual(lines[3].value, "公司 NAS")
        XCTAssertEqual(lines[3].detail, "搜索位置：示例共享文件夹、项目资料")
    }

    /// ★ 没加 NAS 不是错误：如实写「尚未添加」，并告诉用户以后在哪加。
    func testMissingNetworkSourceIsNotAnError() {
        let lines = OnboardingProgress.summary(state())
        let network = lines.first { $0.title == "网络存储" }
        XCTAssertEqual(network?.value, "尚未添加")
        XCTAssertEqual(network?.detail, "以后可以在设置里添加")
        XCTAssertEqual(network?.done, false)
        XCTAssertEqual(lines.first { $0.title == "权限" }?.value, "稍后开启")
    }

    /// 搜索位置很多时不要铺满整页。
    func testSummaryTruncatesLongLocationLists() {
        let many = state(sources: [source(scopes: ["/a", "/b", "/c", "/d", "/e"])])
        let detail = OnboardingProgress.summary(many).first { $0.title == "网络存储" }?.detail
        XCTAssertEqual(detail, "搜索位置：a、b、c、…")
    }

    // MARK: - 中途退出与重新运行

    private func store() -> (OnboardingStore, InMemoryClientPreferences) {
        let preferences = InMemoryClientPreferences()
        return (OnboardingStore(preferences: preferences), preferences)
    }

    /// 全新安装：自动出现引导，没什么可「继续」。
    func testFreshInstallPresentsOnboarding() {
        let (store, _) = store()
        XCTAssertTrue(store.shouldAutoPresent)
        XCTAssertFalse(store.completed)
        XCTAssertNil(store.lastStep)
        XCTAssertNil(store.resumePrompt, "一次都没开始过时不该问「继续完成」")
    }

    /// 中途退出：记住停在哪一步，下次问一句。
    func testClosingMidFlowRemembersTheStep() {
        let (store, _) = store()
        store.rememberStep(.permissions)
        XCTAssertEqual(store.lastStep, .permissions)
        XCTAssertFalse(store.completed, "只是关了个窗口，不能算走完")
        XCTAssertTrue(store.shouldAutoPresent)
        XCTAssertEqual(store.resumePrompt, "继续完成闪寻设置？")

        // 停在欢迎页等于还没开始。
        store.rememberStep(.welcome)
        XCTAssertNil(store.lastStep)
        XCTAssertNil(store.resumePrompt)
    }

    /// 停在完成页要记住：配置都齐了，只是没点「完成」。
    func testStoppingAtFinishStillAsksToContinue() {
        let (store, _) = store()
        store.rememberStep(.finish)
        XCTAssertEqual(store.lastStep, .finish)
        XCTAssertEqual(store.resumePrompt, "继续完成闪寻设置？")
        XCTAssertEqual(OnboardingProgress.resumeDetail(state(fda: true, sources: [source()]),
                                                      lastStep: .finish),
                       "上次看完了设置汇总，还没点「完成」。")
    }

    /// 走完就不再自动出现，也不再问。
    func testCompletedRunNeverPresentsAgain() {
        let (store, _) = store()
        store.rememberStep(.network)
        store.markCompleted()
        XCTAssertTrue(store.completed)
        XCTAssertFalse(store.shouldAutoPresent, "引导只自动出现一次")
        XCTAssertNil(store.lastStep)
        XCTAssertNil(store.resumePrompt)
    }

    /// ★ 「重新运行欢迎引导…」**只**清「已完成」标记，不动任何配置。
    ///
    /// 这条是这类入口最常见的错法：把「再看一遍」做成「恢复出厂设置」。
    /// 用户点它的时候往往只是想确认一下设置在哪。
    func testRerunKeepsEveryExistingSetting() {
        let preferences = InMemoryClientPreferences(values: [
            "ff2.localEnabled": true,
            "ff2.localSearchMode": LocalSearchMode.selectedFolders.rawValue,
            "ff2.localFolders": ["/Users/someone/Documents"],
            OnboardingStore.Key.completed: true,
            "ff2.globalShortcut.v1": Data([0x01, 0x02])
        ])
        let store = OnboardingStore(preferences: preferences)
        store.rerun()

        XCTAssertFalse(store.completed, "重新运行＝再看一遍")
        XCTAssertTrue(store.shouldAutoPresent)
        XCTAssertNil(store.lastStep)
        XCTAssertEqual(preferences.object(forKey: "ff2.localEnabled") as? Bool, true)
        XCTAssertEqual(preferences.object(forKey: "ff2.localSearchMode") as? String,
                       LocalSearchMode.selectedFolders.rawValue)
        XCTAssertEqual(preferences.object(forKey: "ff2.localFolders") as? [String],
                       ["/Users/someone/Documents"])
        XCTAssertNotNil(preferences.object(forKey: "ff2.globalShortcut.v1"),
                        "快捷键不能因为重跑引导就丢")
    }

    /// 没设过 completed 时读作「没走完」—— 与 R01 那处不同，这里两者都该显示引导。
    func testCompletedDefaultsToFalseAndIsStoredAsBool() {
        let (store, preferences) = store()
        XCTAssertFalse(store.completed)
        store.markCompleted()
        XCTAssertEqual(preferences.object(forKey: OnboardingStore.Key.completed) as? Bool, true)
    }

    // MARK: - 快捷键冲突的说法

    /// 引导页对新人只说人话，不抖错误码。
    func testShortcutConflictMessageIsWrittenForNewUsers() {
        XCTAssertTrue(OnboardingShortcutText.conflict.contains("已被其他功能使用"))
        XCTAssertFalse(OnboardingShortcutText.conflict.contains("("), "不许把 OSStatus 摆在新用户面前")
        XCTAssertFalse(OnboardingShortcutText.conflict.contains("注册"))
    }

    // MARK: - 首次搜索的键位提示

    func testSearchHintsShowExactlyOnce() {
        let preferences = InMemoryClientPreferences()
        XCTAssertTrue(SearchHintGuide.shouldShow(preferences: preferences))
        SearchHintGuide.markShown(preferences: preferences)
        XCTAssertFalse(SearchHintGuide.shouldShow(preferences: preferences))
        SearchHintGuide.markShown(preferences: preferences)
        XCTAssertFalse(SearchHintGuide.shouldShow(preferences: preferences), "重复标记不该翻回来")
    }

    /// 提示的四条键位要和实际绑定对得上（见 `SearchKeyRouter`）。
    func testSearchHintLinesMatchRealBindings() {
        XCTAssertEqual(SearchHintGuide.lines.count, 4)
        XCTAssertEqual(SearchHintGuide.lines, ["↑ ↓ 选择", "Return 打开", "Space 快速查看", "⌘ Return 在 Finder 中显示"])
    }

    // MARK: - 本机搜索范围的三选一

    /// ★ 三选一与开关/方式的映射只有一处。设置页与引导页共用，不许各写一份。
    func testLocalScopeChoiceMapsToTheTwoStoredFacts() {
        XCTAssertEqual(LocalScopeChoice.resolve(localEnabled: false, mode: .spotlight), .off)
        XCTAssertEqual(LocalScopeChoice.resolve(localEnabled: false, mode: .selectedFolders), .off)
        XCTAssertEqual(LocalScopeChoice.resolve(localEnabled: true, mode: .spotlight), .wholeMac)
        XCTAssertEqual(LocalScopeChoice.resolve(localEnabled: true, mode: .selectedFolders), .selectedFolders)

        XCTAssertTrue(LocalScopeChoice.wholeMac.enabled)
        XCTAssertTrue(LocalScopeChoice.selectedFolders.enabled)
        XCTAssertFalse(LocalScopeChoice.off.enabled)
        XCTAssertEqual(LocalScopeChoice.wholeMac.mode, .spotlight)
        XCTAssertEqual(LocalScopeChoice.selectedFolders.mode, .selectedFolders)
        XCTAssertEqual(LocalScopeChoice.allCases.count, 3)
        XCTAssertEqual(Set(LocalScopeChoice.allCases.map(\.title)).count, 3)
    }
}
