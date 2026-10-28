import Foundation

/// 搜索位置的**展示名**。
///
/// 只有一个特判：`"/"`。它表示「整个可见空间」——OpenList 那种根下挂着上千个
/// 文件夹的站点，适配器不再逐个列，只给这一个位置（见 `OpenListAdapter.shareRoots`）。
///
/// 为什么放进 Core 而不是各界面自己写：这个映射有两个消费方（添加向导的位置列表、
/// 来源状态摘要里的「搜索位置：…」）。两边各写一份的结果，就是同一天里
/// 一处显示「全部目录」、另一处显示空白 —— 而空白那一处用户会以为是没配置好。
///
/// 直接 `dropFirst()` 得到空串，正是旧写法在 `"/"` 上的表现。
public enum NASScopeLabel {
    /// 整根授权的逻辑路径。
    public static let wholeRoot = "/"
    /// 整根授权的展示名。
    public static let wholeRootName = "全部目录"

    /// 位置 → 展示名。普通位置去掉前导斜杠（`/照片` → `照片`），保持既有观感。
    public static func text(for scope: String) -> String {
        scope == wholeRoot ? wholeRootName : String(scope.dropFirst())
    }

    /// 是否「整根授权」。界面据此决定要不要再显示一行原始路径。
    public static func isWholeRoot(_ scope: String) -> Bool {
        scope == wholeRoot
    }
}
