import Foundation

/// 密码框编辑时不回写绑定值，避免覆盖输入或移动光标。
public enum SecureFieldEcho {
    /// 判断是否需要将绑定值写回文本框。
    public static func shouldWrite(fieldValue: String, boundValue: String, isEditing: Bool) -> Bool {
        // 编辑中一律不回写：回写会移动光标与选区，并可能吞掉刚输入的字符。
        if isEditing { return false }
        return fieldValue != boundValue
    }
}
