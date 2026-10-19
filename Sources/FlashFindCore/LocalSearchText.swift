import Foundation

/// 本机搜索「这样设置会不会搜不到东西」的提示文案。
///
/// 原来这三段分支写在 AppModel 里，而 AppModel 测不了（App 是可执行目标）。
/// 文案是用户判断「为什么搜不到本机文件」的唯一依据，说错一句就会让人
/// 以为是闪寻坏了，所以把它挪进 Core 用测试锁住。
///
/// ## 只说话，不占地方
///
/// 这个函数**只在「按当前设置必然搜不到」时返回文案**，正常情况返回 `nil`。
///
/// 「已选文件夹且选了若干个」时若也说一句
/// 「仅搜索已明确选择的 N 个本机文件夹；无需系统索引」，那句话本身没说错，
/// 但右侧就是刚列出来的那几个文件夹，用户已经亲眼看到了 —— 于是它变成
/// 设置页上一行永远存在、永远不产生动作的灰字，纯噪音。「Spotlight 索引正常」
/// 同理。改成：**没问题就不说话。**
public enum LocalSearchText {
    /// 界面所处的运行环境。预览态下的文案与真实运行态不同，必须分开给。
    public enum Context: Sendable {
        /// 纯预览（Xcode Preview / 截图）：**不改动**已有文案，返回 nil。
        case preview
        /// 可交互样例（FF_UI_INTERACTIVE）：给样例文案。
        case previewFixture
        /// 真实运行。
        case live
    }

    /// - Returns: 需要用户处理的提示；`nil` 表示**没有什么要说的**。
    ///   调用方对 `nil` 的处理按环境而不同：
    ///   1. 预览态 —— 不动已有文案（那句话可能是上次真实运行留下的）；
    ///   2. 真实运行的 Spotlight 模式 —— 交给系统索引探测结果说话；
    ///   3. 真实运行且设置没问题 —— 要把上一条提示**清掉**，别留残影。
    public static func availability(mode: LocalSearchMode, folderCount: Int, context: Context) -> String? {
        switch context {
        case .preview:
            return nil
        case .previewFixture:
            // 样例态是给人看的，凡有说法一律说出来，方便截图核对。
            guard mode == .selectedFolders else { return "UI 样例：系统 Spotlight 已关闭" }
            return folderCount == 0 ? "UI 样例：请选择具体文件夹" : nil
        case .live:
            // Spotlight 模式：能不能搜由系统索引状态决定，这里无话可说。
            guard mode == .selectedFolders else { return nil }
            // 没选文件夹时必须说「不会自动扫描全盘」：
            // 只说「请选择」会让人以为不选也能搜，于是永远搜不到东西。
            guard folderCount > 0 else { return "请选择具体本机文件夹；不会自动扫描全盘" }
            return nil
        }
    }
}
