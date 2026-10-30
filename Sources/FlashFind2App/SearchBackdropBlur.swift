import AppKit
import SwiftUI
import FlashFindCore

/// 模块底面那块**真高斯模糊**（浅色外观用）。
///
/// 用户 2026-10-30：「浅色模式改成底部背景高斯模糊质感」。
///
/// 浅色下不再用 `.glassEffect(.regular)`——它把背景洗成一片白，糊掉的只是「颜色」，
/// 看不到「质感」。这里直接上系统的 `NSVisualEffectView`：`blendingMode = .behindWindow`
/// 才是真的把**窗口后面**的东西模糊掉，壁纸的颜色和形状都还在，只是一片糊。
///
/// ★ `state = .active`：这块玻璃属于浮窗和钉住窗，App 不在前台时用户照样看得见；
///   跟着激活态走（`.followsWindowActiveState`）会变成半明半暗，钉住的窗口尤其难看。
///
/// ★★ 圆角**在这里自己裁一次**，不完全指望外面那层 `.clipShape(shape)`：
///   半径从外面传（`SearchModuleLayout.moduleRadius`），不在这里另写一个数，
///   所以仍是同一份真相、只是两处应用。
///
///   ★★ 2026-10-30 实测（原来这里写着「SwiftUI 的 clipShape 裁不到这块 AppKit
///   材质，所以必须自己裁」——**那句是错的**）：
///
///   用 `FF_UI_BACKDROP_NO_ROUND=1` 把这层自己的 `cornerRadius` 设成 0、
///   `masksToBounds` 设成 false，浅色下重拍并与正常图逐像素比对：
///
///   | 区域 | 最大通道差 | 平均 |
///   | --- | --- | --- |
///   | 搜索框左上角 180×180 | 18 | 0.05 |
///   | 搜索框右上角 180×180 | 18 | 0.05 |
///   | 结果窗左下角 180×180 | 34 | 0.07 |
///
///   也就是：这层的圆角关掉之后，**边缘只有 1–2pt、肉眼看不出的差异**——外层
///   `SearchModuleSurface` 的 `.clipShape(shape)` 基本把它裁住了，剩下的那点泄漏
///   说明「跨 AppKit 边界的裁剪」确实不是完全可靠。所以这道自我裁剪留着（双保险），
///   但它**不是**用户报的那个「矩形」的修复——那个是悬停光晕漏裁（见 `SearchHoverVeil`）。
///
///   ★ 第一版这里写过「差 0」，那是**量错了**：位图缓冲第 0 行本来就是图像顶部，
///   脚本又翻了一次，比的是镜像位置（下方背景，当然一样）。修正坐标后才有上面这组数字。
struct SearchBackdropBlur: NSViewRepresentable {
    /// 模糊用哪种材质。**同一个桌面三选一实拍**定的 `.popover`：
    ///
    /// | 材质 | 透出来的程度 | 观感 |
    /// | --- | --- | --- |
    /// | `underWindowBackground` | 只有右边缘有点颜色 | 一块浅灰纸，谈不上质感 |
    /// | **`popover`** | 壁纸暖色成片透出 | 就是「背景高斯模糊」 |
    /// | `underPageBackground` | 比第一个更平 | 更接近不透明 |
    ///
    /// 证据：`04-测试与验收/UI-搜索框抬高与深色玻璃-20261030/截图-浅色模糊材质三选一.png`。
    var material: NSVisualEffectView.Material = .popover
    /// 与模块圆角同源（`SearchModuleLayout.moduleRadius`）。
    var cornerRadius: CGFloat = SearchModuleLayout.moduleRadius

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
        round(view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        round(view)
    }

    private func round(_ view: NSVisualEffectView) {
        #if DEBUG
        // 红证钩子 `FF_UI_BACKDROP_NO_ROUND=1`：把这层自己的圆角**故意弄失效**。
        //
        // 为什么需要它：用户 2026-10-30 报「玻璃遮罩边框没有圆角、有很明显的矩形」，
        // 而本机四角怎么拍都是圆的（见 `04-测试与验收/UI-结果窗摆位与圆角-20261030/`）。
        // 复现不了就没法证明「补的裁剪真的在修那个现象」。这个钩子把
        // 「真机上 layer 圆角丢了」这一种情况按死，看它到底长什么样——
        // 如果照片里的矩形就是它，那修复方向才定得住。
        if AppEnvironment.isPreview,
           ProcessInfo.processInfo.environment["FF_UI_BACKDROP_NO_ROUND"] == "1" {
            view.wantsLayer = true
            view.layer?.cornerRadius = 0
            view.layer?.masksToBounds = false
            // 必须留下痕迹：没有它，「四角没变」这件事分不清是「外层兜住了」
            // 还是「钩子压根没生效」——两种结论方向相反。
            NSLog("[backdrop] NO_ROUND 已生效（这层的圆角被故意关掉）")
            return
        }
        #endif
        view.wantsLayer = true
        view.layer?.cornerRadius = cornerRadius
        view.layer?.cornerCurve = .continuous
        view.layer?.masksToBounds = true
    }
}
