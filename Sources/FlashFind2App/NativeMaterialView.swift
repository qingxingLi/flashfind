import AppKit
import SwiftUI
import FlashFindCore

/// Native fallback for macOS 15.6 / SDK 15.2. This is vibrancy, not Liquid Glass.
enum NativeMaterialView {
    static func makeView(hosting host: NSView) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .popover
        view.blendingMode = .behindWindow
        view.state = .active
        view.wantsLayer = true
        view.layer?.cornerRadius = SearchLayout.panelRadius
        view.layer?.masksToBounds = true
        // Shape the compositor and native window shadow, rather than just clipping a CALayer.
        let radius = SearchLayout.panelRadius
        let mask = NSImage(size: NSSize(width: radius * 2 + 1, height: radius * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        mask.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        mask.resizingMode = .stretch
        view.maskImage = mask
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        return view
    }
}

struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .underWindowBackground
        view.blendingMode = .behindWindow
        view.state = .followsWindowActiveState
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

enum SearchLayout {
    static let searchHeight: CGFloat = 64
    /// 模块圆角：**唯一出处**在 Core 的 `SearchModuleLayout`（两个模块必须同值）。
    static let panelRadius: CGFloat = SearchModuleLayout.moduleRadius
    static let moduleGap: CGFloat = SearchModuleLayout.moduleGap
    static let fileIconSize: CGFloat = 28
    static let rowHeight: CGFloat = 56
    /// 结果区一屏显示几行。
    ///
    /// ★ 唯一出处已搬到 Core 的 `SearchModuleLayout.resultsVisibleRows`：结果模块的
    ///   固定高度要用它算，App 这边再存一个数就会「算高度用 7、画列表用另一个 7」。
    static let maximumVisibleRows = SearchModuleLayout.resultsVisibleRows
    /// 打开失败提示条的高度（标题 + 最多两行正文 + 上下留白）。
    ///
    /// 必须由 `SearchView.panelHeight` 显式计入：浮窗高度是算出来的、不是内容撑的，
    /// 少算这一项，提示条就会被压成一条只露出标题和按钮的窄边（真机 bug）。
    /// 正文超过两行走 `help` 悬停看全文——这条只在出错时出现，
    /// 不该为罕见的长句把浮窗整体撑高。
    static let openFailureBannerHeight: CGFloat = 76
}
