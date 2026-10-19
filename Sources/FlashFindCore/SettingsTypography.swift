import Foundation

/// 设置界面的字号阶梯（「不同等级的标题以不同的文字大小
/// 区分，当前也有区分但是不明显」）。
///
/// 原来的分段标题（「启动」「快捷键」「外观」…）与正文只差**字重**、字号相同，
/// 扫一眼分不出层级。现在四级字号严格递减，顺序固定为
/// 「页面标题 > 分段标题 > 正文 > 辅助说明」。
///
/// **页面标题取 17pt 的依据**：参照 macOS 系统设置「外观与语言」页。
/// 实测该页截图（1301px 宽、2x）：标题「外观与语言」5 个汉字共 146px、
/// 字高 27px，换算约 15.7pt；卡片行标签「外观」约 13pt。所以页面标题不再用 20pt
/// 那种偏大的值，取 17pt 贴近系统观感，同时仍比分段标题大一档。
///
/// 放在 Core 是为了让这条阶梯能被测试锁住：App 层是 executableTarget，
/// 字号写多大只能靠人眼看，而「眼看不明显」恰恰是用户会再次反馈的点。
public enum SettingsTypography {
    /// 页面内的大标题（如来源详情页的应用名）。
    ///
    /// 17pt：对齐 macOS 系统设置的页面标题（实测约 15.7pt）。再大就头重脚轻。
    public static let pageTitle: CGFloat = 17
    /// 分段标题：「启动」「快捷键」「外观」「权限」「关于」。
    public static let sectionHeader: CGFloat = 16
    public static let body: CGFloat = 13
    /// 辅助说明（页脚、次要信息）。
    public static let caption: CGFloat = 11
}
