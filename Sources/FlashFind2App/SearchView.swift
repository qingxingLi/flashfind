import SwiftUI
import FlashFindCore

/// 搜索框那一块窗口的**页面**。
///
/// ## 2026-10-27 的模块化（历史）
///
/// 当时用户要求「搜索框一块、搜索结果一块，中间留 10pt 空白」，两块在**同一个窗口**里
/// 上下排开，本文件负责算整窗高度。
///
/// ## 2026-10-28：两块变成**两个窗口**
///
/// 用户：「钉住前后的搜索框和搜索结果都应该可以单独移动」。同一个窗口里两块永远一起动，
/// 所以这里只留搜索框那一块，结果那一块搬去 `SearchResultsPanel.swift` 自己的窗口。
/// 本文件因此只剩三件事：**画搜索框模块、算这一块的高度、收发键盘**。
///
/// ★ 位置与高度的联动也一并消失：这一块的高度只由「有没有键位提示」决定，
///   结果增减不再改变它的尺寸（它们已经不在一个窗口里）。
struct SearchView: View {
    @ObservedObject var model: AppModel
    @State private var settingsPage: SettingsPane = .search
    @State private var configuredPreviewSettings = false
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 辅助功能「降低透明度」：开着时遮罩回到不透明的老方案。
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// 搜索区的表面：玻璃 或 macOS 15 的老方案。判定在 Core，这里只取结论。
    private var glassStyle: SearchGlassStyle {
        #if DEBUG
        // `FF_UI_SEARCH_LEGACY=1`：在这台 macOS 27 上强制走老方案，
        // 用来核对「macOS 15 及以下保持原方案」到底长什么样。
        // 没有它，「向下兼容」只能靠读代码相信——那正是最容易骗自己的地方。
        if AppEnvironment.isPreview,
           ProcessInfo.processInfo.environment["FF_UI_SEARCH_LEGACY"] == "1" { return .legacy }
        #endif
        return SearchGlass.style(reduceTransparency: reduceTransparency)
    }

    // MARK: - 派生状态

    private var hasQuery: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var showsHint: Bool { !hasQuery && model.searchHintsVisible }

    // MARK: - 高度

    /// 键位提示占的高度。输入框一有内容它就收起，所以要跟着算，否则会多出一块空白。
    private var hintHeight: CGFloat { 38 }

    /// 这一块窗口的高度。
    ///
    /// ★ 与 `SearchFieldModule.height(showsHint:hintHeight:)` 必须同式：
    ///   那一边约束自己、这一边决定窗口，差一个常量就多出一条空白或被裁掉一截。
    private var fieldModuleHeight: CGFloat {
        SearchFieldModule.height(showsHint: showsHint, hintHeight: hintHeight)
    }

    // MARK: - 模块

    private var fieldModule: some View {
        SearchFieldModule(query: $model.query, focused: $focused,
                          searching: model.searching || pending,
                          submit: model.openSelectedResult,
                          research: model.changedQuery,
                          openSettings: openSettings,
                          showsHint: showsHint,
                          hintLines: SearchHintGuide.lines,
                          hintHeight: hintHeight,
                          style: glassStyle)
    }

    /// 关键词已输入、但还没有可显示的结果、也没报错 —— 也就是「正在搜」。
    private var pending: Bool {
        hasQuery && !model.canUseDisplayedResults && model.searchFailure == nil
    }

    var body: some View {
        fieldModule
            .frame(maxWidth: .infinity)
            .frame(height: fieldModuleHeight)
            .background(SearchPanelSizing(height: fieldModuleHeight, animate: !reduceMotion).frame(width: 0, height: 0))
            .background(keyboardScope)
            .onChange(of: model.query) { _ in model.changedQuery() }
            .onChange(of: model.scope) { _ in model.changedQuery() }
            // 没人理它也会自己消失：摆在那儿超过几秒就不是提示，是障碍。
            .onChange(of: model.searchHintsVisible) { visible in
                guard visible else { return }
                Task {
                    try? await Task.sleep(for: .seconds(8))
                    model.dismissSearchHints()
                }
            }
            .onAppear {
                model.showSearch(); focused = true
                applyPreviewHooks()
            }
            .onExitCommand { model.hideSearch() }
            .onReceive(NotificationCenter.default.publisher(for: .showFlashFind2)) { _ in focused = true }
            // 结果窗口关掉 / 点了「钉住」之后，键盘必须回到这里（见通知定义处）。
            .onReceive(NotificationCenter.default.publisher(for: .focusFlashFindField)) { _ in focused = true }
            // 设置是独立窗口而不是 sheet：sheet 会把设置挂在搜索浮窗下，
            // 没有红绿灯、没有独立关闭入口，用户会觉得「关不掉」。
            .onReceive(NotificationCenter.default.publisher(for: .openFlashFindSettings)) { _ in
                openSettings()
            }
            .onReceive(NotificationCenter.default.publisher(for: .closePreviewSettings)) { _ in
                if AppEnvironment.isPreview { SettingsWindow.shared.close() }
            }
    }

    /// 把键盘作用域挂到这一块上。
    ///
    /// 键盘作用域单独成块：十几个闭包全写进 `body` 会让类型检查爆掉，
    /// 表现为「compiler is unable to type-check this expression」。
    private var keyboardScope: some View {
        SearchKeyboardScope(enabled: true,
                            // ★ 两个窗口共用一个监视器：事件落在结果窗上也算「在搜索区里」。
                            accepts: { SearchWindowRegistry.shared.contains($0) },
                            searchFocused: focused,
                            query: model.query,
                            // ★ 这里问的是「**有没有可选的条目**」，不是「已经选中了没有」。
                            //
                            // 真实搜索路径不会自动选中第一条（只有 fixture 会），
                            // `selected` 一直是 nil，直到用户按下 ↓ 才被 `moveResultSelection` 写上。
                            // 而 `Coordinator` 记录导航状态用的是**按键那一刻**的快照：
                            // 若这里依赖 `selectedResult != nil`，第一次按 ↓ 时快照必为 false
                            // ⇒ 导航不激活 ⇒ 紧接着按空格仍然只打出一个空格，
                            // 用户必须按两次方向键才看得到预览（「空格没反应」的另一种复现）。
                            hasSelectableResult: model.canUseDisplayedResults && !model.results.isEmpty,
                            // 焦点在哪一块上。
                            //
                            // 判据必须自己给：`ScrollView` 不是 `NSTableView`，
                            // 监视器沿响应链找不到表格，会误判成「哪儿都不在」而全放行。
                            // ★ 2026-10-28 起结果在**另一个窗口**里：输入框的 `FocusState`
                            //   不会因为点了另一个窗口就变 false，所以必须问窗口本身的状态。
                            resultsActive: resultsActive,
                            move: model.moveResultSelection,
                            submit: { model.dismissSearchHints(); model.openSelectedResult() },
                            reveal: { model.dismissSearchHints(); model.revealSelectedResult() },
                            quickLook: { model.dismissSearchHints(); model.quickLookSelectedResult() },
                            copyPath: { if let row = model.selectedResult { model.copy(row) } },
                            hide: model.hideSearch,
                            hasSearchToken: model.hasSearchToken,
                            keywordEmpty: model.keywordIsEmpty,
                            deleteSearchToken: { model.deleteSearchToken() })
            .frame(width: 0, height: 0)
    }

    private var resultsActive: Bool {
        let focusIsElsewhere = !focused || model.resultsWindowIsKey
        return focusIsElsewhere && model.canUseDisplayedResults && !model.results.isEmpty
    }

    /// 打开独立设置窗口（带红绿灯，可自由切换与关闭）。
    private func openSettings() {
        settingsPage = Self.previewSettingsPage ?? .search
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show(model: model, page: settingsPage)
    }

    // MARK: - 预览钩子

    /// 预览构建里「到不了的状态」全部由环境变量造出来。
    ///
    /// ★ 为什么必须挂在 onAppear：这些状态在真实使用里要么要点一下、要么要真实搜索，
    ///   而取证据时常常是锁屏/无人值守（键鼠事件全归 loginwindow）。
    private func applyPreviewHooks() {
        #if DEBUG
        // `FF_UI_HINTS=1`：强制显示首屏键位提示。
        //
        // 提示只在「第一次打开」出现，而 `showSearchHintsIfNeeded` 在预览态是直接
        // 返回的（`!AppEnvironment.isPreview`）——不强制的话，「提示行与搜索框同属
        // 一块玻璃、高度也要算上它」这件事**永远截不到**，只能靠读代码相信。
        if AppEnvironment.isPreview,
           ProcessInfo.processInfo.environment["FF_UI_HINTS"] == "1" {
            model.searchHintsVisible = true
        }
        // `FF_UI_TYPE=n`：预先选中类型条第 n 段（0 = 全部）。
        // `FF_UI_SIDEBAR=n`：预先选中侧边栏第 n 行（0 = 全部位置）。
        //
        // ★ 只改限定状态，**不重搜**：预览态没有真实搜索，
        // `changedQuery()` 会把 `FF_UI_SAMPLE_RESULTS` 造的样例结果清空，
        // 截图就只剩一张空状态。这两个钩子只用来验外观。
        //
        // 侧边栏要有内容，先得造来源：`FF_UI_SOURCES=N`（自身也带幂等保护，
        // 没设就什么都不做）。以前它只挂在「打开设置」那条路上，
        // 于是想截侧边栏还得先把设置窗叫出来。
        if AppEnvironment.isPreview {
            model.loadPreviewSavedSourcesIfRequested()
        }
        if AppEnvironment.isPreview,
           let raw = ProcessInfo.processInfo.environment["FF_UI_TYPE"],
           let index = Int(raw),
           SearchTypeBar.entries.indices.contains(index) {
            if let type = SearchTypeBar.entries[index].fileType {
                model.tokenBar.setFileType(type)
            } else {
                model.tokenBar.clear(.fileType)
            }
        }
        if AppEnvironment.isPreview,
           let raw = ProcessInfo.processInfo.environment["FF_UI_SIDEBAR"],
           let index = Int(raw) {
            let entries = model.sidebarEntries
            if entries.indices.contains(index) {
                model.tokenBar.setLocation(entries[index].target)
            }
        }
        // `FF_UI_EMPTY_RESULTS=1`：清空结果，只看「没有找到」那套提示
        // （预览壳的 fixture 来源对任何关键词都回四条假文件，否则这个状态到不了）。
        // 必须放在上面两个钩子**之后**：它会把「结果属于当前限定」这件事重新认领一次。
        model.applyPreviewEmptyResultsIfRequested()
        // `FF_UI_TRUNCATED=1`：造 240 条结果，看上限（200）生效时的状态栏。
        // 与 `FF_UI_EMPTY_RESULTS` 互斥（都改结果），所以排在其后、谁后谁生效。
        model.applyPreviewTruncatedResultsIfRequested()
        // `FF_UI_DEMO=1`：三台不同厂商的样例来源 + 跨来源结果，演「一次搜索问多台设备」。
        // 与上面两个改结果的钩子互斥，排在它们之后（谁后谁生效）。
        model.applyPreviewDemoResultsIfRequested()
        // `FF_UI_PIN=1`：程序自己钉一次，用来取「钉住的窗口」的证据。
        //
        // ★ 为什么必须有钩子：钉住是一次点击，而锁屏/无人值守时点不了
        //   （键鼠事件全归 loginwindow）。它同时把「钉住之后搜索框真的空出来」
        //   这件事一并演出来——两张截图就是一个前后对照。
        if AppEnvironment.isPreview,
           ProcessInfo.processInfo.environment["FF_UI_PIN"] == "1" {
            // `FF_UI_DEMO_SECOND=查询词`：钉住一批之后**换一个词接着搜**——钉住窗
            // 挪到搜索框上方（下方被新结果占住，即 present 摆位规矩 2 的情形），
            // 结果模块换成第二组。三步各自等上一节拍，避免互相抢主线程。
            let secondQuery = ProcessInfo.processInfo.environment["FF_UI_DEMO_SECOND"]
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) {
                if secondQuery != nil { model.trimPreviewDemoResultsForPinningIfRequested() }
                model.pinCurrentResults()
            }
            if let secondQuery, !secondQuery.isEmpty {
                // ★ 结果注入必须比设词晚一拍：程序里改 `query` 会经 SwiftUI 绑定
                //   再触发一次 `changedQuery()`，同一拍注入的结果会被它覆盖回
                //   通用夹具（实测踩过：列表显示的是 fixtures 而不是第二组）。
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                    model.applyPreviewDemoSecondQueryIfRequested()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) {
                    model.applyPreviewDemoSecondResultsOnly()
                }
                DispatchQueue.main.asyncAfter(deadline: .now() + 2.9) {
                    PinnedResultsWindows.shared.demoMovePanelsAboveField()
                }
            }
        }
        #endif
        if AppEnvironment.isPreview, ProcessInfo.processInfo.environment["FF_UI_SETTINGS"] == "1", !configuredPreviewSettings {
            configuredPreviewSettings = true
            // `FF_UI_SOURCES=N`：造 N 台已保存的来源，设置页的来源列表与详情才有内容可截。
            model.loadPreviewSavedSourcesIfRequested()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openSettings() }
        }
    }

    /// 预览构建里可以直接停在某一页：`FF_UI_SETTINGS_PAGE=AI`（取页面名，与
    /// `SettingsPane.rawValue` 一致）。截图与点验用，**发布构建里这段被编译掉**。
    ///
    /// 没有它，「打开设置」永远落在搜索页，AI 页那几张截图只能靠手点——而手点的
    /// 结果没法复现，也没法在改动前后各截一张来比。
    private static var previewSettingsPage: SettingsPane? {
        #if DEBUG
        guard AppEnvironment.isPreview,
              let raw = ProcessInfo.processInfo.environment["FF_UI_SETTINGS_PAGE"] else { return nil }
        return SettingsPane(rawValue: raw)
        #else
        return nil
        #endif
    }
}
