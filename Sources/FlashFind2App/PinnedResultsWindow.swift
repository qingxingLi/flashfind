import AppKit
import SwiftUI
import FlashFindCore

/// 「钉在桌面上」的那一批搜索结果长什么样。
///
/// 用户 2026-10-28：搜索结果默认在搜索框下方，**可以拖到任意位置并钉在桌面上**，
/// 保留这一次的结果；随后搜索框可以继续搜下一组，下一组也能钉。
///
/// ## 2026-10-28 追加：钉住之后筛选还在
///
/// 用户：「钉住以后保留文件类型和文件位置的筛选」。于是这一块**照旧有**
/// 顶部类型条与左侧位置侧边栏，初始选中项就是钉住那一刻的限定。
/// 改了之后在**这一批结果里**就地重筛（`SearchResultFilter`），不重新搜索——
/// 钉住的意义就是「这一批不变」，重新搜一次等于把它变成另一个东西。
///
/// ★ 题头因此不再写位置名：位置在这一块里是可改的，题头那句话会当场变成谎话。
struct PinnedResultsView: View {
    let snapshot: PinnedResults
    @ObservedObject var model: AppModel
    /// 这块窗口的高度：**开窗时定死**，之后不再变。
    ///
    /// ★★ 2026-10-28 报障：「现在选择钉住搜索结果的区域位置会随机的跳一下」。
    ///   原来高度由「筛完还剩几行」算，而 SwiftUI 是在窗口**已经显示之后**
    ///   才把新高度同步给窗口的（`SearchPanelSizing` 挪上沿），于是第一帧的
    ///   高度只要与开窗时算的不一致（筛掉了几行、或首帧还没布局完），
    ///   窗口就会在眼前挪一下。现在高度算一次、传进来，窗口再也不动。
    ///   筛完行数变少时底下留白，「筛到空」也不会把窗口缩成一条。
    let height: CGFloat
    let close: () -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    /// 指针停在哪一行。钉住的窗口里没有键盘导航，悬停就是唯一的高亮来源。
    @State private var hoveredID: SearchResult.ID?
    /// 这一块里此刻的类型 / 位置限定（初值 = 钉住那一刻的限定）。
    @State private var fileType: SearchFileTypeCatalog.FileType?
    @State private var location: SearchTarget

    init(snapshot: PinnedResults, model: AppModel, height: CGFloat, close: @escaping () -> Void) {
        self.snapshot = snapshot
        self.model = model
        self.height = height
        self.close = close
        _fileType = State(initialValue: snapshot.fileType)
        _location = State(initialValue: snapshot.location)
    }

    private var style: SearchGlassStyle {
        SearchGlass.style(reduceTransparency: reduceTransparency)
    }

    /// 筛完之后真正显示的行。
    private var rows: [SearchResult] { snapshot.rows(fileType: fileType, location: location) }

    private var sidebarEntries: [SearchSidebar.Entry] { model.sidebarEntries }
    private var sidebarSelectionID: String? {
        SearchSidebar.selectedID(for: location, in: sidebarEntries)
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            SearchResultsToolbar(fileType: fileType,
                                 selectType: selectType,
                                 style: style,
                                 canPin: false,
                                 pin: nil)
            HStack(spacing: 0) {
                SearchResultsSidebar(entries: sidebarEntries,
                                     selectedID: sidebarSelectionID,
                                     style: style,
                                     select: selectSidebarEntry(at:))
                Rectangle()
                    .fill(Color(nsColor: .separatorColor).opacity(0.55))
                    .frame(width: SearchModuleLayout.sidebarDividerWidth)
                    .frame(maxHeight: .infinity)
                    .accessibilityHidden(true)
                list
            }
        }
        .frame(width: SearchModuleLayout.pinnedWidth, height: height)
        .searchModuleSurface(style)
        // ★ 这里**故意**没有 `SearchPanelSizing`：窗口高度在开窗时已经定死，
        //   再让 SwiftUI 同步一次就是那个「钉住后跳一下」的来源（见 `height` 的注释）。
        .accessibilityElement(children: .contain)
        .accessibilityLabel("钉住的搜索结果：\(snapshot.title)，\(snapshot.countText(matching: rows.count))")
    }

    // MARK: - 筛选

    /// 点类型条某一段（换算仍在 Core 的 `SearchTypeBar`，视图不认 id 的字面值）。
    private func selectType(_ id: String) {
        let next = SearchTypeBar.fileType(for: id)
        guard next != fileType else { return }
        fileType = next
    }

    /// 点侧边栏第几行。
    private func selectSidebarEntry(at index: Int) {
        guard sidebarEntries.indices.contains(index) else { return }
        let next = sidebarEntries[index].target
        guard next != location else { return }
        location = next
    }

    // MARK: - 题头与列表

    /// 题头：既是信息行，也是这个窗口唯一的拖动把手。
    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "pin.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            Text(snapshot.title)
                .ffFont(.pinnedTitle)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(snapshot.countText(matching: rows.count))
                .ffFont(.pinnedCount).monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .semibold))
                    .frame(width: 22, height: 22)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
            .help("关闭（⌘W）")
            .accessibilityLabel("关闭")
        }
        .padding(.leading, SearchModuleLayout.fieldInset)
        .padding(.trailing, SearchModuleLayout.fieldInset - 8)
        .frame(height: SearchModuleLayout.pinnedHeaderHeight)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.45))
                .frame(height: 0.5)
        }
    }

    @ViewBuilder private var list: some View {
        if rows.isEmpty {
            // 筛到空要说清是「这一批里筛没了」，不是「没搜到过」。
            // 高度固定之后这里要**自己居中**：窗口不再跟着行数缩，文字若还贴着顶，
            // 底下就是一大片空玻璃，看起来像没画完。
            Text("这一批结果里没有符合当前筛选的文件")
                .ffFont(.pinnedEmpty)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(.vertical, SearchModuleLayout.pinnedListPadding)
        } else {
            ScrollView(.vertical) {
                LazyVStack(spacing: 0) {
                    ForEach(rows) { result in
                        row(result)
                    }
                }
                .padding(.vertical, SearchModuleLayout.pinnedListPadding)
            }
            .scrollIndicators(.automatic)
        }
    }

    private func row(_ result: SearchResult) -> some View {
        SearchResultRow(result: result,
                        isSelected: false,
                        style: style,
                        isHovered: hoveredID == result.id)
            .background {
                // 玻璃模式下 `SearchResultRow` 自己不画底色（结果模块里由滑动遮罩负责），
                // 而钉住的窗口里没有遮罩，所以悬停高亮由这里补一层很浅的底。
                if hoveredID == result.id, style == .glass {
                    RoundedRectangle(cornerRadius: SearchModuleLayout.rowLensRadius, style: .continuous)
                        .fill(.primary.opacity(0.06))
                        .padding(.horizontal, SearchModuleLayout.rowLensInset)
                        .padding(.vertical, 2)
                }
            }
            .contentShape(Rectangle())
            .onHover { inside in
                if inside { hoveredID = result.id }
                else if hoveredID == result.id { hoveredID = nil }
            }
            .onTapGesture(count: 2) { model.openPinned(result) }
            .contextMenu { menu(result) }
    }

    /// 菜单与结果模块里那一套同义：能打开、能定位、能复制。
    @ViewBuilder private func menu(_ result: SearchResult) -> some View {
        if result.hasWebOpenTarget {
            Button("打开", systemImage: "arrow.up.forward.square") { model.openPinned(result) }
            Divider()
            Button("复制网页链接", systemImage: "link") { model.copyPinnedWebLink(result) }
            Button("复制站点内路径", systemImage: "doc.on.doc") { model.copyPinned(result) }
        } else {
            Button("打开", systemImage: "arrow.up.forward.square") { model.openPinned(result) }
            Button("在 Finder 中显示", systemImage: "folder") { model.openPinned(result, reveal: true) }
            Button("快速查看", systemImage: "eye") { model.quickLookPinned(result) }
            Divider()
            Button("复制路径", systemImage: "doc.on.doc") { model.copyPinned(result) }
        }
        // 与主结果窗同一条口径：下载是显式动作，不进默认打开链。
        // 钉住窗里的行是**快照**，下载前会经 resolve 重新核来源与权限。
        if model.supportsDirectDownload(result) {
            Divider()
            Button("下载后打开", systemImage: "arrow.down.circle") { model.downloadAndOpen(result) }
            Button("下载到…", systemImage: "square.and.arrow.down") { model.downloadToFolder(result) }
        }
        Button("复制文件名", systemImage: "doc.on.clipboard") { model.copyName(result) }
    }
}

/// 管理所有「钉住的搜索结果」窗口。
///
/// 每次点「钉住」新建一块，互不影响：用户可以连着钉三批、并排比对。
///
/// ★ 为什么用 `NSPanel` + `.floating`：用户要「钉在桌面上」——
///   切到别的 App 之后这批结果还得看得见（这正是钉住与「留在这里」的区别）。
///   `canJoinAllSpaces` 让它在切 Space 时也跟着，否则「钉住」只在当前桌面成立。
@MainActor
final class PinnedResultsWindows {
    static let shared = PinnedResultsWindows()

    private var panels: [UUID: NSPanel] = [:]
    /// 打开的先后顺序：新窗口按这个顺序错开摆放，不叠成一摞。
    private var order: [UUID] = []
    private weak var model: AppModel?
    private var keyMonitor: Any?

    /// 钉住一批结果。返回是否真的开了一块（空列表不会开）。
    ///
    /// `anchor` = **搜索框那一块**的 frame（拿不到时回落成 key window）。
    func present(_ snapshot: PinnedResults, model: AppModel, near anchor: NSRect?) -> Bool {
        guard !snapshot.isEmpty, panels[snapshot.id] == nil else { return false }
        self.model = model
        let height = snapshot.windowHeight(rowCount: snapshot.rows(fileType: snapshot.fileType,
                                                                  location: snapshot.location).count,
                                           rowHeight: SearchLayout.rowHeight)
        let panel = makePanel(for: snapshot, model: model, height: height)
        let size = panel.frame.size
        // ★ 摆位的三条规矩（2026-10-28 实测出来的）：
        //
        // 1. 首选锚点那块窗口的**下方**，不是「跟它左下角对齐」——对齐左下角时
        //    一块六百多高的结果窗会往上长，正好把搜索框盖住；
        // 2. 下方放不下（默认位置下方只剩 628，10 行要 644）就摆到**上方**：
        //    贴边会把窗口顶上 28pt，题头正好被搜索框压住——**连拖都拖不动**；
        // 3. 上方也放不下才退回「贴进可见区域」，此时允许压住搜索框，
        //    用户把它拖走就好。
        let base: NSPoint
        if let anchor, let visible = (NSScreen.screens.first { $0.visibleFrame.intersects(anchor) } ?? NSScreen.main)?.visibleFrame {
            let below = anchor.minY - SearchModuleLayout.moduleGap - size.height
            let above = anchor.maxY + SearchModuleLayout.moduleGap
            if below >= visible.minY + 12 {
                base = NSPoint(x: anchor.minX, y: below)
            } else if above + size.height <= visible.maxY - 12 {
                base = NSPoint(x: anchor.minX, y: above)
            } else {
                base = NSPoint(x: anchor.minX, y: below)
            }
        } else {
            base = NSPoint(x: (NSScreen.main?.visibleFrame.midX ?? 600) - size.width / 2,
                           y: (NSScreen.main?.visibleFrame.midY ?? 400))
        }
        // 每多一块就往下、往右错开一点：钉第二块时它不会正好盖住第一块。
        let offset = CGFloat(order.count % 6) * 26
        // ★★ 位置与尺寸**一次摆齐**，而且在 `orderFront` 之前：
        //   先上屏再挪就是用户看到的「跳一下」。高度已经在 `height` 里定死，
        //   视图侧不再有 `SearchPanelSizing`，所以上屏之后不会再被改一次。
        let origin = clamped(NSPoint(x: base.x + offset, y: base.y - offset), size: size)
        panel.setFrame(NSRect(origin: origin, size: size), display: false)
        // 让 SwiftUI 把第一帧布局跑完（`defer: false` 的窗口此刻还没有内容）：
        // 布局若在上屏后才发生，macOS 会按内容的固有尺寸再调一次窗口。
        panel.contentView?.layoutSubtreeIfNeeded()
        panels[snapshot.id] = panel
        order.append(snapshot.id)
        installKeyMonitorIfNeeded()
        NSApplication.shared.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        return true
    }

    func close(_ id: UUID) {
        guard let panel = panels.removeValue(forKey: id) else { return }
        order.removeAll { $0 == id }
        panel.orderOut(nil)
        panel.close()
        if panels.isEmpty { removeKeyMonitor() }
    }

    func closeAll() {
        for id in order { close(id) }
    }

    /// 当前开着几块（预览与核对用）。
    var count: Int { panels.count }

    private func makePanel(for snapshot: PinnedResults, model: AppModel, height: CGFloat) -> NSPanel {
        let panel = PinnedResultsPanel(contentRect: NSRect(x: 0, y: 0,
                                                           width: SearchModuleLayout.pinnedWidth,
                                                           height: height),
                                       styleMask: [.borderless], backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // 与搜索浮窗同一条：窗口自己没有表面，玻璃由视图里那块模块画。
        // 透明窗的阴影按**窗口矩形**算，会把圆角外填成一整块方影，所以关掉。
        panel.hasShadow = false
        panel.level = .floating
        panel.isMovableByWindowBackground = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.appearance = AppEnvironment.previewAppearance
        panel.title = snapshot.title
        let root = PinnedResultsView(snapshot: snapshot, model: model, height: height) { [weak self] in
            self?.close(snapshot.id)
        }
        let host = NSHostingView(rootView: root)
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host
        return panel
    }

    /// 把窗口放进当前屏幕的可见区域，别钉到屏幕外面去。
    private func clamped(_ origin: NSPoint, size: NSSize) -> NSPoint {
        let screen = NSScreen.screens.first { $0.visibleFrame.contains(origin) } ?? NSScreen.main
        guard let frame = screen?.visibleFrame else { return origin }
        return NSPoint(x: min(max(origin.x, frame.minX + 12), frame.maxX - size.width - 12),
                       y: min(max(origin.y, frame.minY + 12), frame.maxY - size.height - 12))
    }

    /// ⌘W 关掉**当前这块**钉住的窗口。
    ///
    /// ★ 为什么不用菜单项 / `performClose:`：这是无标题栏的 `NSPanel`，
    ///   没有关闭按钮，`performClose` 对它就是一声系统提示音。
    ///   监视器只看「key window 是不是我们开的」，别的窗口（设置、搜索框）一概不碰。
    private func installKeyMonitorIfNeeded() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self else { return event }
            let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
            guard flags == .command,
                  event.charactersIgnoringModifiers?.lowercased() == "w",
                  let window = event.window,
                  let id = self.panels.first(where: { $0.value === window })?.key else { return event }
            self.close(id)
            return nil
        }
    }

    private func removeKeyMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

/// 无标题栏的结果窗口：能成为 key（否则 ⌘W 收不到），但不出现在窗口菜单里。
private final class PinnedResultsPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}
