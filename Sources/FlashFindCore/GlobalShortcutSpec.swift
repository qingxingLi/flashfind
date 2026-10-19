import Foundation

public struct GlobalShortcutSpec: Codable, Equatable, Sendable {
    public var keyCode: UInt32
    public var modifiers: UInt32
    public static let command: UInt32 = 256
    public static let shift: UInt32 = 512
    public static let option: UInt32 = 2048
    public static let control: UInt32 = 4096

    // Cocoa `NSEvent.ModifierFlags` 的原始位。放在这里而不是录制那段代码里，
    // 是为了让「按键事件 → 快捷键」这段映射**可被测试**：Core 测试会拿
    // `NSEvent.ModifierFlags(...).rawValue` 真值来对照，Cocoa 哪天改了位定义，
    // 那个测试立刻红，而不是等到用户按下组合键才发现存错了。
    public static let cocoaCommand: UInt = 1 << 20
    public static let cocoaOption: UInt = 1 << 19
    public static let cocoaControl: UInt = 1 << 18
    public static let cocoaShift: UInt = 1 << 17

    /// Cocoa 修饰键原始位 → 本结构的 modifiers。
    ///
    /// 只取这四个键：其它位（如 CapsLock、Fn）不该进快捷键定义，
    /// 否则同一个组合会因为大写锁定开着而存成两个不同的值。
    public static func modifiers(cocoaFlags: UInt) -> UInt32 {
        var out: UInt32 = 0
        if cocoaFlags & cocoaCommand != 0 { out |= command }
        if cocoaFlags & cocoaShift != 0 { out |= shift }
        if cocoaFlags & cocoaOption != 0 { out |= option }
        if cocoaFlags & cocoaControl != 0 { out |= control }
        return out
    }
    public static let `default` = GlobalShortcutSpec(keyCode: 49, modifiers: option)
    public init(keyCode: UInt32, modifiers: UInt32) { self.keyCode = keyCode; self.modifiers = modifiers }
    public var validationMessage: String? {
        let supported = Self.command | Self.shift | Self.option | Self.control
        guard keyCode < 128, modifiers & ~supported == 0 else { return "无法使用这个按键组合" }
        guard modifiers & (Self.command | Self.option | Self.control) != 0 else { return "请同时按住 ⌘、⌥ 或 ⌃，避免影响正常输入" }
        guard ![36, 48, 51, 53, 54, 55, 56, 57, 58, 59, 60, 61, 62, 63, 76, 117].contains(keyCode) else { return "请选择字母、数字、空格或功能键；返回与编辑按键保留原生行为" }
        if modifiers == Self.command || modifiers == (Self.command | Self.shift) {
            if [0, 6, 7, 8, 9, 12, 13, 43, 49].contains(keyCode) { return "这个组合通常用于系统或文本编辑，请选择其他快捷键" }
        }
        if keyCode == 49 && modifiers == Self.control { return "⌃Space 通常用于切换输入法，请选择其他快捷键" }
        return nil
    }
    public var displayName: String {
        let symbols = [(Self.control, "⌃"), (Self.option, "⌥"), (Self.shift, "⇧"), (Self.command, "⌘")]
        let keys: [UInt32: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"−",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",49:"Space",50:"`",64:"F17",79:"F18",80:"F19",90:"F20",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",105:"F13",106:"F16",107:"F14",109:"F10",111:"F12",113:"F15",118:"F4",120:"F2",122:"F1"]
        return symbols.filter { modifiers & $0.0 != 0 }.map(\.1).joined() + (keys[keyCode] ?? "键\(keyCode)")
    }
}
