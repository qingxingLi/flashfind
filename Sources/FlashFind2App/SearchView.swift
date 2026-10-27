import SwiftUI
import FlashFindCore

struct SearchView: View {
    @ObservedObject var model: AppModel
    @State private var settingsPage: SettingsPane = .search
    @State private var configuredPreviewSettings = false
    @State private var lastResultsHeight: CGFloat = 0
    @FocusState private var focused: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var hasQuery: Bool { !model.query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
    private var pending: Bool { !model.isCommandModeActive && hasQuery && !model.canUseDisplayedResults && model.searchFailure == nil }
    private var visibleResults: [SearchResult] {
        hasQuery && model.searchFailure == nil ? model.results : (model.canUseDisplayedResults ? model.results : [])
    }
    private var searchIsEnabled: Bool {
        (model.localEnabled && model.scope != .nas) || (model.enabled && model.scope != .local)
    }

    private var showsStatus: Bool { !visibleResults.isEmpty || !model.searchWarnings.isEmpty }

    private var expandedHeight: CGFloat {
        guard hasQuery, !model.isCommandModeActive else { return 0 }
        if visibleResults.isEmpty {
            let height: CGFloat = (model.searchFailure != nil || (model.scope == .nas && !model.hasSelectedNASSource) ? 148 : 112) + (showsStatus ? 32 : 0)
            return model.searchFailure == nil && (pending || model.searching) ? max(height, lastResultsHeight) : height
        }
        return CGFloat(min(visibleResults.count, SearchLayout.maximumVisibleRows)) * SearchLayout.rowHeight + 12 + 32
    }
    private var panelHeight: CGFloat {
        SearchLayout.searchHeight + expandedHeight + hintHeight + openFailureBannerHeight + commandPaletteHeight
    }

    /// 命令面板占的高度。
    ///
    /// 它不在 `expandedHeight` 里（那是指结果区），必须自己加进来 ——
    /// 少算了这一截，面板会被浮窗底边切掉一多半，用户只看到两行候选。
    private var commandPaletteHeight: CGFloat {
        guard model.isCommandModeActive else { return 0 }
        // ★ 行数上限必须与面板实际显示的行数一致，否则面板会被浮窗底边切掉
        // （数字能按到哪、就得显示到哪，两者是同一个数）。
        let rows = max(1, min(model.filteredCommandItems.count, model.commandMaximumVisible))
        let rowHeight: CGFloat = 34
        // 有已限定位置时上方还有一条状态行（28pt）+ 一条分隔线。
        let header: CGFloat = model.locationLabel == nil ? 0 : 29
        // 上下内边距各 4pt。
        return header + CGFloat(rows) * rowHeight + 8
    }
    /// 打开失败提示条占的高度。它不是结果区的一部分，也不在 `expandedHeight` 里，
    /// 所以必须自己加进浮窗高度——否则提示条会被挤成一条窄边，正文整段被切掉。
    private var openFailureBannerHeight: CGFloat {
        model.openFailure == nil ? 0 : SearchLayout.openFailureBannerHeight
    }

    /// 首次使用的键位提示占的高度。输入框一有内容它就收起，所以要跟着算高度，
    /// 否则面板会多出一块空白。
    private var hintHeight: CGFloat { showsHint ? 38 : 0 }
    /// 键盘作用域单独成块：十几个闭包全写进 `body` 会让类型检查爆掉，
    /// 表现为「compiler is unable to type-check this expression」。
    private var keyboardScope: some View {
        SearchKeyboardScope(enabled: true, searchFocused: focused,
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
                            move: model.moveResultSelection,
                            submit: { model.dismissSearchHints(); model.openSelectedResult() },
                            reveal: { model.dismissSearchHints(); model.revealSelectedResult() },
                            quickLook: { model.dismissSearchHints(); model.quickLookSelectedResult() },
                            copyPath: { if let row = model.selectedResult { model.copy(row) } },
                            hide: model.hideSearch,
                            commandMode: model.isCommandModeActive,
                            commandMove: { model.moveCommandSelection($0) },
                            commandSubmit: { model.executeSelectedCommand() },
                            commandCancel: { model.cancelCommandMode() },
                            commandPick: { model.pickCommand($0) },
                            hasSearchToken: model.hasSearchToken,
                            keywordEmpty: model.keywordIsEmpty,
                            deleteSearchToken: { model.deleteSearchToken() })
            .frame(width: 0, height: 0)
    }

    private var showsHint: Bool { !hasQuery && model.searchHintsVisible }

    private var searchField: some View {
        SearchFieldView(query: $model.query, focused: $focused,
                        searching: model.searching || pending, syncing: model.syncing,
                        submit: model.openSelectedResult,
                        research: model.changedQuery,
                        tokens: model.searchTokens,
                        deleteToken: { model.deleteSearchToken($0) })
    }

    private var commandPalette: some View {
        SearchCommandPaletteView(items: model.filteredCommandItems,
                                 selection: model.commandSelection,
                                 keyboardNavigationRevision: model.commandKeyboardNavigationRevision,
                                 activeTargetLabel: model.locationLabel,
                                 numbers: model.commandNumbers,
                                 maximumVisible: model.commandMaximumVisible,
                                 onHover: { model.hoverCommand(at: $0) },
                                 onPick: { index in
                                     model.pickCommand(at: index)
                                     // 点完把焦点还给输入框：选完位置通常还要接着打字，
                                     // 不还焦点的话用户得再点一次输入框才开始输入。
                                     focused = true
                                 })
    }

    var body: some View {
        VStack(spacing: 0) {
            searchField
            if showsHint { hintStrip }
            // ★ 命令模式：显示候选面板，不显示结果列表。
            //
            // 命令模式下没有真实搜索（`changedQuery` 短路了），所以这里
            // 也没有结果可显示 —— 两件事必须同时成立，否则会看到
            // 「上面是命令面板、下面是上一轮的结果」。
            if model.isCommandModeActive {
                Divider().padding(.horizontal, 16).opacity(0.45)
                commandPalette
            } else if hasQuery {
                Divider().padding(.horizontal, 16).opacity(0.45)
                if visibleResults.isEmpty { emptyState.frame(maxHeight: .infinity, alignment: .top) }
                else {
                    resultsList
                }
                if showsStatus {
                    SearchStatusBar(message: model.searchFailure ?? model.searchStatusMessage,
                                    count: model.canUseDisplayedResults ? model.results.count : 0,
                                    updating: model.searching || pending, warnings: model.searchWarnings,
                                    configureSources: openSettings)
                }
            }
            // 打开失败不是搜索失败，因此单独一层，不占用结果区的空状态。
            if let failure = model.openFailure {
                OpenFailureBanner(failure: failure,
                                  onRetry: { model.retryOpenCurrentResult() },
                                  onConnectInFinder: failure.smbURL.map { url in { model.connectInFinder(url) } },
                                  onDismiss: { model.openFailure = nil })
            }
        }
        .frame(maxWidth: .infinity).frame(height: panelHeight)
        .background(SearchPanelSizing(height: panelHeight, animate: !reduceMotion).frame(width: 0, height: 0))
        .background(keyboardScope)
        .onChange(of: model.query) { _ in
            if !hasQuery { lastResultsHeight = 0 }
            model.changedQuery()
        }
        .onChange(of: model.results) { results in
            if !results.isEmpty {
                lastResultsHeight = CGFloat(min(results.count, SearchLayout.maximumVisibleRows)) * SearchLayout.rowHeight + 44
            }
        }
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
            if !model.results.isEmpty { lastResultsHeight = expandedHeight }
            if AppEnvironment.isPreview, ProcessInfo.processInfo.environment["FF_UI_SETTINGS"] == "1", !configuredPreviewSettings {
                configuredPreviewSettings = true
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { openSettings() }
            }
        }
        .onExitCommand { model.hideSearch() }
        .onReceive(NotificationCenter.default.publisher(for: .showFlashFind2)) { _ in focused = true }
        .onReceive(NotificationCenter.default.publisher(for: .openFlashFindSettings)) { _ in
            openSettings()
        }
        .onReceive(NotificationCenter.default.publisher(for: .closePreviewSettings)) { _ in
            if AppEnvironment.isPreview { SettingsWindow.shared.close() }
        }
        // 设置是独立窗口而不是 sheet：sheet 会把设置挂在搜索浮窗下，
        // 没有红绿灯、没有独立关闭入口，用户会觉得「关不掉」。
        .onReceive(NotificationCenter.default.publisher(for: .openFlashFindSettings)) { _ in
            openSettings()
        }
    }

    /// 首次使用的一次性键位提示。
    ///
    /// 极轻量：一行小字，没有图标、没有按钮、没有第二页。用户一动手（输入、
    /// 打开、快速查看）或者等它几秒，自己就没了；之后**不再出现**。
    /// 做第二套教程只会变成每次打开都挡在结果前面的东西。
    private var hintStrip: some View {
        HStack(spacing: 14) {
            ForEach(SearchHintGuide.lines, id: \.self) { line in
                Text(line).font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18)
        .frame(height: hintHeight)
        .accessibilityIdentifier("search-hint-guide")
    }

    /// 打开独立设置窗口（带红绿灯，可自由切换与关闭）。
    private func openSettings() {
        settingsPage = Self.previewSettingsPage ?? .search
        NSApp.activate(ignoringOtherApps: true)
        SettingsWindow.shared.show(model: model, page: settingsPage)
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

    private var resultsList: some View {
        ScrollViewReader { proxy in
            List(visibleResults, selection: $model.selected) { result in
                SearchResultRow(result: result, isSelected: model.selected == result.id).tag(result.id).id(result.id)
                    .listRowSeparator(.hidden)
                    .disabled(!model.canUseDisplayedResults)
                    .onTapGesture(count: 2) { model.openCurrentResult(result) }
                    .contextMenu {
                        // 菜单本身就是「这条结果能做什么」的说明书。
                        // 打开时检测本机挂载，未挂载则使用网页；复制链接仍保留网页地址。
                        if result.hasWebOpenTarget {
                            Button("打开", systemImage: "arrow.up.forward.square") { model.openCurrentResult(result) }
                            Divider()
                            Button("复制网页链接", systemImage: "link") { model.copyWebLink(result) }
                            Button("复制站点内路径", systemImage: "doc.on.doc") { model.copy(result) }
                        } else {
                            Button("打开", systemImage: "arrow.up.forward.square") { model.openCurrentResult(result) }
                            Button("在 Finder 中显示", systemImage: "folder") { model.openCurrentResult(result, reveal: true) }
                            Button("快速查看", systemImage: "eye") { model.quickLook(result) }
                            Divider()
                            Button("复制路径", systemImage: "doc.on.doc") { model.copy(result) }
                        }
                        Button("复制文件名", systemImage: "doc.on.clipboard") { model.copyName(result) }
                    }
            }
            .listStyle(.inset).scrollContentBackground(.hidden)
            .padding(.top, 6)
            .opacity(model.canUseDisplayedResults || !hasQuery ? 1 : 0.55)
            .onChange(of: model.selected) { id in
                if let id, model.canUseDisplayedResults { proxy.scrollTo(id) }
            }
        }
    }

    @ViewBuilder private var emptyState: some View {
        if !hasQuery {
            SearchStateView(symbol: "magnifyingglass", title: "搜索文件", detail: "输入名称，搜索这台 Mac 和已连接的 NAS")
        } else if model.searchFailure != nil, !model.searching, !pending {
            VStack(alignment: .leading, spacing: 0) {
                SearchStateView(symbol: "exclamationmark.triangle", title: "搜索暂时不可用",
                                detail: model.searchFailure ?? "")
                Button("打开搜索来源设置") { openSettings() }
                    .padding(.leading, 53).padding(.bottom, 12)
            }
        } else if !searchIsEnabled {
            SearchStateView(symbol: "slider.horizontal.3", title: "搜索来源已关闭",
                            detail: "在设置里打开「此 Mac」或「NAS」")
        } else if model.scope == .nas, !model.hasSelectedNASSource {
            // NAS 不可用时要说清「本地不受影响」，而不是笼统报错。
            VStack(alignment: .leading, spacing: 0) {
                SearchStateView(symbol: "externaldrive", title: "NAS 搜索尚未就绪",
                                detail: model.localEnabled && model.scope == .all
                                    ? model.nasSearchAvailabilityMessage + " 本机搜索不受影响。"
                                    : model.nasSearchAvailabilityMessage)
                Button("打开搜索来源设置") { openSettings() }
                    .padding(.leading, 53).padding(.bottom, 12)
            }
        } else if isBelowNASMinimum {
            // 1 个字符时不是错误，只是提示继续输入。
            SearchStateView(symbol: "text.cursor", title: "继续输入以搜索 NAS",
                            detail: "NAS 搜索至少需要 2 个字符。本机结果照常显示。")
        } else if model.searching || pending {
            // NAS 还在跑但已经有本机结果时不算空状态，这里只在真无结果时出现。
            SearchStateView(symbol: "magnifyingglass", title: "正在搜索", detail: "正在查找匹配的文件与文件夹", loading: true)
        } else {
            SearchStateView(symbol: "doc.text.magnifyingglass", title: "没有找到“\(model.query)”",
                            detail: "试试更短的关键词，或到设置里确认搜索位置")
        }
    }

    /// 当前输入是否还不满足 NAS 的最小字符要求。
    private var isBelowNASMinimum: Bool { !NASQueryPolicy.accepted(model.query) }
}
