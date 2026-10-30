import AppKit
import FlashFindCore

/// 光标下面那块**盖满整屏的高层窗口**是不是截图工具的选区遮罩。
///
/// ## 为什么需要这一层（2026-10-30 报障）
///
/// 用户：「闪寻无法被截图，一截图就直接消失了，只能拍照给你看下颜色对比」。
/// 截图工具（系统 ⌘⇧5、微信 ⌘⇧A 一类）会把闪寻挤成「非前台」，于是它在选区上
/// 按下鼠标的那一下落进了我们补挂的全局点击监视里 —— 浮窗被当成「点了外面」收掉，
/// 选区才画到一半，截出来的图里当然没有闪寻。
///
/// 判据本身在 Core（`SearchClickOutside.blocksDismissal`，可测），这里只负责
/// 把「光标下最上面那块别的 App 的窗口」取出来。窗口列表是**由前到后**排的，
/// 所以第一个落点命中的就是用户看到的那一块。
enum ScreenOverlayProbe {

    /// 这一点的点击要不要放行（截图遮罩上不算「点了外面」）。
    static func blocksDismissal(at point: CGPoint) -> Bool {
        guard let screen = NSScreen.screens.first(where: { $0.frame.contains(point) }) ?? NSScreen.main
        else { return false }
        let options: CGWindowListOption = [.optionOnScreenOnly, .excludeDesktopElements]
        guard let windows = CGWindowListCopyWindowInfo(options, kCGNullWindowID) as? [[String: Any]]
        else { return false }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        for window in windows {
            // 自己那几块窗口走另一套判定（frame 豁免），别在这里再判一次。
            if (window[kCGWindowOwnerPID as String] as? pid_t) == ownPID { continue }
            guard let layer = window[kCGWindowLayer as String] as? Int,
                  let bounds = window[kCGWindowBounds as String] as? [String: Any],
                  let rect = CGRect(dictionaryRepresentation: bounds as CFDictionary),
                  rect.contains(point) else { continue }
            return SearchClickOutside.blocksDismissal(windowLayer: layer,
                                                      windowBounds: rect,
                                                      screen: screen.frame)
        }
        return false
    }
}
