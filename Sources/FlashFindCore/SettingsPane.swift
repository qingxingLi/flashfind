import Foundation

/// 设置窗口的一级导航：三页，顶部横向分段控件。
///
/// ## 为什么是三页
///
/// **「搜索」和「搜索来源」回答的是同一个问题**——「去哪儿搜」：
///
/// * 搜索页给出本机范围（整台 Mac / 指定文件夹）；
/// * 来源页给出网络位置（哪几台 NAS、哪几个共享）。
///
/// 用户想的是「我要搜这几个地方」，而不是「先想清楚这是本地还是网络」。
/// 分成两页的结果是：加了一台 NAS 之后，得跳到另一页才能调整搜索行为；
/// 判断「为什么搜不到」时也要在两页之间来回看。合并成一页后，
/// **「搜什么」集中在一处**，剩下的两页职责清晰：
///
/// * **通用** —— 应用怎么启动、快捷键、权限；
/// * **搜索** —— 搜哪些地方、怎么显示结果；
/// * **高级** —— 诊断与实验性开关。
///
/// 放在 Core 而不是 App 层，是因为 App 层是 `executableTarget`、测试目标
/// import 不到，而「最多三页、不含权限/外观/关于/搜索来源」这条契约值得被测试锁住。
///
/// 三页的排列顺序就是这里的声明顺序——视图直接遍历 `allCases`，
/// 不另建一份顺序表。
public enum SettingsPane: String, CaseIterable, Identifiable, Sendable {
    case general = "通用"
    case search = "搜索"
    case advanced = "高级"

    public var id: String { rawValue }
}

/// 设置窗口标题。
///
/// 按 macOS 惯例：窗口叫「设置」，页面名由标题栏承担——
/// 标题里再写一遍产品名就跟页面名重复了。
public enum SettingsWindowTitle {
    public static let text = "设置"
}
