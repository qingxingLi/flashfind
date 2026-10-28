import Foundation

/// 设备名称（来源名）的规则。
///
/// 名字是**纯展示字段**：它不参与连接身份、不进 `sourceID`、不进钥匙串条目。
/// 因此改名的代价必须小到可以逐键落盘——不重连、不清空当前结果、不重启核心。
///
/// 判定放在 Core 而不是设置页：`FlashFind2App` 是 executableTarget，测试依赖不上，
/// 写在界面里等于没测（这条是踩过的）。
public enum NASSourceRename {

    /// 用户输入 → 落盘文本。
    ///
    /// 只做一件事：**把换行与制表折成空格**。名字在列表行、详情标题、
    /// 结果行徽标、AI 授权列表里都是单行展示；粘进一个带换行的名字，
    /// 那几处会当场错行（`lineLimit(1)` 只截不折，详情标题那个 `Text` 会整段撑高）。
    ///
    /// ★ **刻意不去首尾空白**。界面是「逐键落盘」的（见 `isRename(stored:to:)`），
    /// 落盘时 trim 会让「中间带空格」的名字打不出来：
    /// 用户输 `NAS `（尾部空格）→ 存成 `NAS` → 输入框跟着变成 `NAS` → 再输 `01`
    /// 得到的是 `NAS01`，而不是想要的 `NAS 01`。
    /// 首尾空白的收敛交给展示层——`NASSourceConfig.displayName` 已经 trim，
    /// 整串空白也回落到品牌名。
    ///
    /// - Returns: 折好换行的文本。空串表示「用默认名」，这是合法状态。
    public static func normalized(_ raw: String) -> String {
        var out = ""
        out.reserveCapacity(raw.count)
        var lastWasSpace = false
        for ch in raw {
            if ch.isNewline || ch == "\t" {
                // 连着的换行只折一个空格：逐键落盘时 `\r\n` 若按字符各换一次，
                // 每按一次回车都会多出一个空格。
                if !lastWasSpace { out.append(" "); lastWasSpace = true }
            } else {
                out.append(ch)
                lastWasSpace = false
            }
        }
        return out
    }

    /// 这次输入是否真的改动了落盘内容——用来避免「点进输入框再点走」时的无谓写盘。
    ///
    /// ★ 比较的是**规范化之后的原文**，不是界面上的显示名。若拿显示名（trim 过的）
    /// 来比，`NAS` → `NAS ` 会被判成「没变」而丢掉用户刚敲的空格，
    /// 输入框随即被重置——那正是「名字里打不出空格」的成因。
    public static func isRename(stored: String, to raw: String) -> Bool {
        normalized(raw) != stored
    }
}
