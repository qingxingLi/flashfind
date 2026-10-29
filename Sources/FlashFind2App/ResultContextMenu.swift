import SwiftUI
import FlashFindCore

/// 结果行的右键菜单。**两个窗口共用这一份**（搜索结果窗、钉住的窗口）。
///
/// 收成一份的理由（2026-10-29 用户报障）：两份菜单各自分叉以后，三个品牌的
/// 右键长得不一样 —— 飞牛有「下载」，群晖和 OpenList 没有；OpenList 的结果
/// 连「在 Finder 中显示」都没有。「菜单里有哪些项」的判定已经搬进 Core
/// （`ResultMenuPlan`），这里只负责把每一项画成按钮、接到动作上。
///
/// `pinned` 为真时，解析走**快照**版本（`resolve` 只核来源与权限，不要求
/// 这行还在当前结果里）——钉住的那一批本来就不在结果里。
struct ResultContextMenu: View {
    let result: SearchResult
    let pinned: Bool
    let model: AppModel

    var body: some View {
        let items = ResultMenuPlan.items(for: result)
        ForEach(items) { item in
            if ResultMenuPlan.separatorBefore(item, in: items) { Divider() }
            button(item)
        }
    }

    @ViewBuilder private func button(_ item: ResultMenuItem) -> some View {
        switch item {
        case .open:
            Button("打开", systemImage: "arrow.up.forward.square") { open(reveal: false) }
        case .reveal:
            Button("在 Finder 中显示", systemImage: "folder") { open(reveal: true) }
        case .quickLook:
            Button("快速查看", systemImage: "eye") { pinned ? model.quickLookPinned(result) : model.quickLook(result) }
        case .downloadAndOpen:
            Button("下载后打开", systemImage: "arrow.down.circle") { model.downloadAndOpen(result) }
        case .downloadToFolder:
            Button("下载到…", systemImage: "square.and.arrow.down") { model.downloadToFolder(result) }
        case .copyPath:
            // 网页来源复制的是站点内路径（`/A0002/…`），标题要如实说清 ——
            // 粘到浏览器地址栏里是找不到页面的，那是另一个菜单项。
            Button(result.hasWebOpenTarget ? "复制站点内路径" : "复制路径", systemImage: "doc.on.doc") {
                pinned ? model.copyPinned(result) : model.copy(result)
            }
        case .copyWebLink:
            Button("复制网页链接", systemImage: "link") {
                pinned ? model.copyPinnedWebLink(result) : model.copyWebLink(result)
            }
        case .copyName:
            Button("复制文件名", systemImage: "doc.on.clipboard") { model.copyName(result) }
        }
    }

    private func open(reveal: Bool) {
        pinned ? model.openPinned(result, reveal: reveal) : model.openCurrentResult(result, reveal: reveal)
    }
}
