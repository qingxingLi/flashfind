import AppKit

/// Native fallback for macOS 15.6 / SDK 15.2. This is vibrancy, not Liquid Glass.
enum NativeMaterialView {
    static func makeView() -> NSVisualEffectView {
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
        return view
    }
}

enum SearchLayout {
    static let searchHeight: CGFloat = 64
    static let panelRadius: CGFloat = 20
    static let fileIconSize: CGFloat = 32
    static let rowHeight: CGFloat = 64
    static let maximumVisibleRows = 6
    /// 打开失败提示条的高度（标题 + 最多两行正文 + 上下留白）。
    ///
    /// 必须由 `SearchView.panelHeight` 显式计入：浮窗高度是算出来的、不是内容撑的，
    /// 少算这一项，提示条就会被压成一条只露出标题和按钮的窄边（真机 bug）。
    /// 正文超过两行走 `help` 悬停看全文——这条只在出错时出现，
    /// 不该为罕见的长句把浮窗整体撑高。
    static let openFailureBannerHeight: CGFloat = 76
}
