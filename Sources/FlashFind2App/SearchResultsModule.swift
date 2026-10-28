import SwiftUI
import FlashFindCore

/// 结果模块要用的一小组派生值。
///
/// 页面（`SearchView`）要拿它算窗口高度、模块要拿它决定画什么——**只能算一次**，
/// 两处各算一遍迟早对不上（那类错表现为「面板高度比内容少一截」）。
struct SearchResultsContext: Equatable {
    var hasQuery: Bool
    var results: [SearchResult]
    var pending: Bool
    var showsStatus: Bool
}

/// **搜索结果模块**（文件边界 = 模块边界）。
///
/// 2026-10-27 用户要求拆模块：搜索框一块、搜索结果一块，中间留一道空白，
/// 代码上也分文件，以后单改某一块不会牵动另一块。
///
/// 这一块自带完整玻璃面（圆角与搜索框同值，见 `SearchModuleLayout`）。
/// 里面的行高亮是「跟随鼠标的玻璃遮罩」，不是系统选中色——理由与做法见
/// `SearchGlassChrome.swift` 与 `SearchResultRow.swift`。
struct SearchResultsModule: View {
    @ObservedObject var model: AppModel
    let context: SearchResultsContext
    let style: SearchGlassStyle
    /// 点了一行之后，让**搜索框**把焦点交出去。
    ///
    /// ★ 2026-10-28 结果从「搜索窗的第二块」变成**独立窗口**之后，这里不能再拿
    ///   `FocusState<Bool>.Binding`：那块画在另一个窗口里，绑着的是别人的焦点状态。
    ///   语义也正好变了——在结果窗口里点一行，输入框本来就不该有焦点；
    ///   真正要做的事只剩「告诉搜索框别再抢键盘」，所以传一个闭包。
    let leaveSearchField: () -> Void
    let openSettings: () -> Void
    /// 点类型条某一段。
    let selectType: (String) -> Void
    /// 点「钉住」：把这一批结果钉到桌面上。
    let pin: () -> Void

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// 遮罩当前的中心（第几行，可为小数）。**动画的中间值也在这里**，
    /// 因此每一行的缩放能跟着它逐帧变——这是「滑过去」和「瞬移」的区别。
    @State private var lensPosition: CGFloat = 0
    @State private var lensVisible = false
    /// 指针停在哪一行。只有它能改遮罩位置（键盘选中项只做兜底）。
    @State private var hoveredResultID: SearchResult.ID?
    /// 指针是否还在列表范围内。用来区分「在两行之间挪」与「真的离开了」：
    /// 前者不许把遮罩收掉，否则每跨一行都会闪一下。
    @State private var pointerInList = false
    /// 预览钩子 `FF_UI_SELECT` 只生效一次。
    @State private var previewSelectionApplied = false
    /// 预览钩子 `FF_UI_LENS_SWEEP` 是否已在跑。
    @State private var previewSweeping = false

    private var hasQuery: Bool { context.hasQuery }
    private var visibleResults: [SearchResult] { context.results }
    private var pending: Bool { context.pending }

    /// 侧边栏什么时候在。
    ///
    /// 「只挂一条打开失败提示」的时候还没有搜索结果，摆一排位置也没有意义。
    private var showsSidebar: Bool { hasQuery }

    /// 当前「页」的标识：换位置 = 换一页。
    ///
    /// ★ 它是 `pageContent` 的 `.id`，也是页面切换动画的触发值：
    /// 用一个**已经存在的状态**（当前位置）做页标识，而不是另立一份 `@State`——
    /// 另立一份迟早会与真实限定不同步（那才是最难查的那种错）。
    private var pageID: String {
        model.sidebarSelectionID ?? "page:none"
    }

    /// 换页的过渡。
    ///
    /// 用户要「苹果要求的切换动画效果」：这里用的是**淡入淡出 + 新页面自下方浮起 10pt**，
    /// 不是整页横滑。理由很实际——浮窗只有两三百点高，横滑会像整块被拽走；
    /// 而淡入配合侧边栏里那块滑动的高亮，读起来就是「内容换了一页」。
    /// 开了「减少动态效果」时直接换，不做任何位移。
    private var pageTransition: AnyTransition {
        guard !reduceMotion else { return .identity }
        return .asymmetric(insertion: .opacity.combined(with: .offset(y: 10)),
                           removal: .opacity)
    }

    var body: some View {
        VStack(spacing: 0) {
            // ★ 2026-10-28：类型条从搜索框模块搬到这里，成为结果模块的第一行
            //   （用户：「搜索结果顶部文件类型」）。右侧那枚「钉住」也在这一行。
            SearchResultsToolbar(fileType: model.tokenBar.fileType,
                                 selectType: selectType,
                                 style: style,
                                 canPin: !visibleResults.isEmpty,
                                 pin: pin)
            HStack(spacing: 0) {
                if showsSidebar {
                    SearchResultsSidebar(entries: model.sidebarEntries,
                                         selectedID: model.sidebarSelectionID,
                                         style: style,
                                         select: { model.selectSidebarEntry(at: $0) })
                    // 分隔线要**看得见但不像边框**：两边的行都有自己的余白，
                    // 所以细到 0.5pt 就够。用系统的分隔色而不是「黑 8%」——
                    // 后者在深色玻璃基本消失（截图里验过），侧边栏与结果区会糊成一片。
                    Rectangle()
                        .fill(Color(nsColor: .separatorColor).opacity(0.55))
                        .frame(width: SearchModuleLayout.sidebarDividerWidth)
                        .frame(maxHeight: .infinity)
                        .accessibilityHidden(true)
                }
                VStack(spacing: 0) {
                    pageStack
                    // 打开失败不是搜索失败，因此单独一层，不占用结果区的空状态，
                    // 也不参与「换位置」的页面切换——它跟位置无关。
                    if let failure = model.openFailure {
                        OpenFailureBanner(failure: failure,
                                          onRetry: { model.retryOpenCurrentResult() },
                                          onConnectInFinder: failure.smbURL.map { url in { model.connectInFinder(url) } },
                                          onDismiss: { model.openFailure = nil })
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .searchModuleSurface(style)
        .onChange(of: model.results) { _ in
            applyPreviewSelectionIfRequested()
            syncLensToSelection()
        }
        // 换了一页：上一条选中项、遮罩位置都属于旧页面，必须清掉。
        // 不清的话新页面会先闪一下「上一页第 5 行」的遮罩，再被校正回来。
        .onChange(of: pageID) { _ in
            hoveredResultID = nil
            lensVisible = false
            lensPosition = 0
        }
        .onAppear {
            applyPreviewSelectionIfRequested()
            syncLensToSelection()
            startPreviewLensSweepIfRequested()
        }
    }

    /// 会随「位置」整页替换的那一层。
    ///
    /// `.id(pageID)` 是这里的承重点：同一个 `id` 的视图被换掉时，SwiftUI 才会
    /// 真的把旧页面移出、新页面移入（`transition` 才有对象可动）；
    /// 不给 id 的话内容只是被就地改写，那次「换页」看起来就是列表原地刷新。
    private var pageStack: some View {
        ZStack {
            pageContent
                .id(pageID)
                .transition(pageTransition)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(reduceMotion ? nil : .spring(response: 0.32, dampingFraction: 0.86),
                   value: pageID)
    }

    @ViewBuilder private var pageContent: some View {
        VStack(spacing: 0) {
            if hasQuery {
                if visibleResults.isEmpty {
                    emptyState.frame(maxHeight: .infinity, alignment: .top)
                } else {
                    resultsList
                }
                if context.showsStatus {
                    SearchStatusBar(message: model.searchFailure ?? model.searchStatusMessage,
                                    count: model.canUseDisplayedResults ? model.results.count : 0,
                                    total: model.canUseDisplayedResults ? model.matchedResultCount : 0,
                                    updating: model.searching || pending, warnings: model.searchWarnings,
                                    canShowMore: model.canUseDisplayedResults && model.canShowMoreResults,
                                    showMore: { model.showMoreResults() },
                                    configureSources: openSettings)
                }
            }
        }
    }

    // MARK: - 结果列表

    /// 结果列表。
    ///
    /// ## 为什么不用 `List`
    ///
    /// 用户要求把「悬停的灰底 + 选中的蓝底」换成一块**跟着鼠标滑动的
    /// 半透明玻璃遮罩**，并且遮罩移动时边缘的字要能看到「放大—缩小」。
    /// `List` 的选中底色是系统画的，既改不成玻璃，也拿不到它的滑动时机；
    /// 而遮罩要逐帧改变每一行的缩放，需要一个**位置连续变化**的数值——
    /// 那就得自己管布局。行高是固定的 `SearchLayout.rowHeight`，
    /// 所以「第 N 行 = N × 行高」这条换算在 `LazyVStack` 里是精确的。
    ///
    /// 键盘行为没有因此改变：`List` 被点中时焦点会离开输入框，
    /// 这里由 `select(_:)` 显式交还（见那里的注释）。
    private var resultsList: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                ZStack(alignment: .topLeading) {
                    // 遮罩画在行**下面**：文字不能被玻璃糊住，只让底下一层变。
                    // 缩放（`searchLensMagnification`）负责「字变大变小」，
                    // 玻璃本身负责折射与高光，两件事各管一半。
                    if style == .glass {
                        SearchGlassLens()
                            .frame(maxWidth: .infinity)
                            .frame(height: SearchLayout.rowHeight - 6)
                            .padding(.horizontal, SearchModuleLayout.rowLensInset)
                            .offset(y: lensPosition * SearchLayout.rowHeight + 3)
                            .opacity(lensVisible ? 1 : 0)
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                    }
                    LazyVStack(spacing: 0) {
                        ForEach(Array(visibleResults.enumerated()), id: \.element.id) { index, result in
                            resultRow(result, index: index)
                        }
                    }
                }
                .padding(.vertical, 6)
            }
            .opacity(model.canUseDisplayedResults || !hasQuery ? 1 : 0.55)
            .onHover { inside in
                pointerInList = inside
                guard !inside else { return }
                // 真离开列表：遮罩回到键盘选中项；没有选中项就淡出。
                hoveredResultID = nil
                syncLensToSelection()
            }
            .onChange(of: model.selected) { id in
                if let id, model.canUseDisplayedResults { proxy.scrollTo(id) }
                syncLensToSelection()
            }
        }
    }

    private func resultRow(_ result: SearchResult, index: Int) -> some View {
        SearchResultRow(result: result,
                        isSelected: model.selected == result.id,
                        style: style,
                        isHovered: hoveredResultID == result.id,
                        lensPosition: lensPosition,
                        lensRow: index,
                        lensActive: style == .glass && lensVisible && !reduceMotion)
            .id(result.id)
            .contentShape(Rectangle())
            .disabled(!model.canUseDisplayedResults)
            .onHover { inside in updateHover(result.id, index: index, inside: inside) }
            // 双击打开。必须写在单击**前面**，否则单击会先把双击吃掉。
            .onTapGesture(count: 2) { model.openCurrentResult(result) }
            .onTapGesture(count: 1) { select(result) }
            .contextMenu { resultMenu(result) }
    }

    /// 菜单本身就是「这条结果能做什么」的说明书。
    /// 打开时检测本机挂载，未挂载则使用网页；复制链接仍保留网页地址。
    @ViewBuilder private func resultMenu(_ result: SearchResult) -> some View {
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

    /// 鼠标点选一条结果。
    ///
    /// 焦点要明确交还出去（`leaveSearchField()`）：`List` 时代点一行会把第一响应者
    /// 交给结果表，于是「方向键 / 空格作用于结果、打字不再进搜索框」。
    /// 换成 `ScrollView` 之后行本身不可聚焦，不主动交还的话焦点还留在输入框——
    /// 用户点完一行再按空格，只会往关键词里插一个空格（行为倒退）。
    private func select(_ result: SearchResult) {
        model.selected = result.id
        leaveSearchField()
    }

    // MARK: - 遮罩

    /// 指针进入/离开某一行。
    ///
    /// ★ 只有**指针**能决定「指到哪」，键盘选中项只是遮罩的**兜底位置**：
    /// 指针还在列表里时按住 ↓ 换选中，遮罩不该甩开鼠标跑到别的行去。
    private func updateHover(_ id: SearchResult.ID, index: Int, inside: Bool) {
        if inside {
            hoveredResultID = id
            moveLens(to: index)
        } else if hoveredResultID == id {
            hoveredResultID = nil
            // 指针还在列表里（只是挪到了行间空隙或下一行）就先别收遮罩：
            // 每跨一行闪一下，看起来像坏了。真离开由列表那层的 onHover 负责。
            guard !pointerInList else { return }
            syncLensToSelection()
        }
    }

    /// 把遮罩挪到第 `index` 行。位置变化交给 spring，位移由 `.offset` 插值、
    /// 「字变大变小」由 `SearchLensMagnification` 的 `animatableData` 逐帧算。
    private func moveLens(to index: Int) {
        guard style == .glass else { return }
        if reduceMotion { lensVisible = true; lensPosition = CGFloat(index); return }
        lensVisible = true
        withAnimation(.spring(response: 0.30, dampingFraction: 0.82)) {
            lensPosition = CGFloat(index)
        }
    }

    /// 指针离开列表、也没有选中项时，遮罩淡出（不做位移动画）。
    private func hideLens() {
        guard lensVisible else { return }
        withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { lensVisible = false }
    }

    /// 遮罩回到键盘选中项。选中项被清掉（换关键词、清空）时淡出。
    private func syncLensToSelection() {
        guard hoveredResultID == nil else { return }
        guard let selected = model.selected,
              let index = visibleResults.firstIndex(where: { $0.id == selected })
        else { hideLens(); return }
        moveLens(to: index)
    }

    // MARK: - 空状态

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
            // ★ 文案在 Core（`SearchEmptyHint`）：位置一换，说的就不是同一句话。
            //   侧边栏选了「公司 nas」时只说「试试更短的关键词」是不够的——
            //   用户要知道**是这个位置里没有**，并且有一条「换回全部」的出路。
            SearchStateView(symbol: "doc.text.magnifyingglass",
                            title: SearchEmptyHint.title(query: model.query),
                            detail: SearchEmptyHint.detail(locationTitle: model.limitedLocationTitle))
        }
    }

    private var searchIsEnabled: Bool {
        (model.localEnabled && model.scope != .nas) || (model.enabled && model.scope != .local)
    }

    /// 当前输入是否还不满足 NAS 的最小字符要求。
    private var isBelowNASMinimum: Bool { !NASQueryPolicy.accepted(model.query) }

    // MARK: - 预览钩子

    /// 预览构建里预先选中第 N 条结果：`FF_UI_SELECT=2`（从 0 数起）。
    ///
    /// 截图需要它：遮罩只在「指针停着」或「有选中项」时出现，而取证据时
    /// 屏幕常常是锁着的（锁屏下键鼠全归 loginwindow，模拟不了悬停）。
    /// 发布构建里这段被编译掉。
    private func applyPreviewSelectionIfRequested() {
        #if DEBUG
        guard AppEnvironment.isPreview, !previewSelectionApplied,
              let raw = ProcessInfo.processInfo.environment["FF_UI_SELECT"],
              let index = Int(raw), visibleResults.indices.contains(index) else { return }
        previewSelectionApplied = true
        model.selected = visibleResults[index].id
        #endif
    }

    /// 预览构建里让选中项自己往下走：`FF_UI_LENS_SWEEP=0.6`（每次停 0.6 秒）。
    ///
    /// ★ 为什么必须有它：**首尾两张截图证明不了遮罩会不会滑动**——瞬移也能满足
    /// 「第一张在第 1 行、第二张在第 5 行」。要证明「滑过去」只能连续截帧，
    /// 中间帧里必须能看到遮罩停在两行之间、以及被压小的那一行。
    /// 锁屏下没法用鼠标制造悬停，所以让程序自己换选中项。
    private func startPreviewLensSweepIfRequested() {
        #if DEBUG
        guard AppEnvironment.isPreview,
              let raw = ProcessInfo.processInfo.environment["FF_UI_LENS_SWEEP"],
              let interval = Double(raw), interval > 0, !previewSweeping else { return }
        previewSweeping = true
        Task { @MainActor in
            var step = 0
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(interval))
                let limit = min(visibleResults.count, SearchLayout.maximumVisibleRows)
                guard limit > 1 else { continue }
                step = (step + 1) % limit
                model.selected = visibleResults[step].id
            }
        }
        #endif
    }
}
