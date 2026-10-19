import XCTest
import AppKit
@testable import FlashFindCore

/// 快捷键修饰键映射与校验规则。
///
/// ## 为什么要为这段映射专门写测试
///
/// 录制快捷键时，AppKit 给的是 `NSEvent.ModifierFlags`（一整包原始位），
/// 要转成 `GlobalShortcutSpec.modifiers` 自己的位定义。这段映射若内联在
/// AppModel 的录制回调里，靠 `event.modifierFlags.contains(.command)` 逐个判断
/// ——**没法测**（要造 NSEvent），也就意味着没人能保证存下来的组合和按下的组合一致。
///
/// 现在映射下沉到 `GlobalShortcutSpec.modifiers(cocoaFlags:)`，这里的测试直接拿
/// `NSEvent.ModifierFlags(...).rawValue` 的**真值**来对照：Cocoa 哪天改了位定义，
/// 这个测试立刻红，而不是等用户在设置里录一次才发现存错了键。
final class GlobalShortcutSpecTests: XCTestCase {

    /// ★ 用 Cocoa 自己的定义验证四个键的位，不复制常量。
    func testModifierMappingMatchesCocoaDefinitions() {
        // 这一条是整套测试的地基：常量写错的话，下面几条都会跟着错，
        // 但它们各自只查一个键，看不出「整体错位」。所以单键和组合都要测。
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: NSEvent.ModifierFlags.command.rawValue),
                       GlobalShortcutSpec.command)
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: NSEvent.ModifierFlags.shift.rawValue),
                       GlobalShortcutSpec.shift)
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: NSEvent.ModifierFlags.option.rawValue),
                       GlobalShortcutSpec.option)
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: NSEvent.ModifierFlags.control.rawValue),
                       GlobalShortcutSpec.control)
    }

    func testCombinedModifiers() {
        let flags = NSEvent.ModifierFlags([.command, .shift]).rawValue
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: flags),
                       GlobalShortcutSpec.command | GlobalShortcutSpec.shift)

        let all = NSEvent.ModifierFlags([.command, .shift, .option, .control]).rawValue
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: all),
                       GlobalShortcutSpec.command | GlobalShortcutSpec.shift
                        | GlobalShortcutSpec.option | GlobalShortcutSpec.control)
    }

    /// 不相关的位必须被丢掉。
    ///
    /// 否则「大写锁定开着时录的 ⌥Space」和「没开时录的 ⌥Space」会存成两个值，
    /// 用户看到的是「同一个组合有时生效有时不生效」。
    func testUnrelatedFlagsAreIgnored() {
        let caps = NSEvent.ModifierFlags([.option, .capsLock]).rawValue
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: caps), GlobalShortcutSpec.option)

        let fn = NSEvent.ModifierFlags([.command, .function]).rawValue
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: fn), GlobalShortcutSpec.command)
    }

    func testNoModifiersYieldsZero() {
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: NSEvent.ModifierFlags([]).rawValue), 0)
        XCTAssertEqual(GlobalShortcutSpec.modifiers(cocoaFlags: 0), 0)
    }

    // MARK: - 校验规则（这些是界面上直接给用户的拒绝理由）

    func testRejectsBareKeyWithoutCommandOptionOrControl() {
        let space = GlobalShortcutSpec(keyCode: 49, modifiers: 0)
        XCTAssertNotNil(space.validationMessage, "不带 ⌘/⌥/⌃ 的组合会抢走正常输入，必须拒绝")
    }

    func testRejectsSystemReservedCombinations() {
        // ⌘Space 是系统输入法切换，⌃Space 同理。
        XCTAssertNotNil(GlobalShortcutSpec(keyCode: 49, modifiers: GlobalShortcutSpec.command).validationMessage)
        XCTAssertNotNil(GlobalShortcutSpec(keyCode: 49, modifiers: GlobalShortcutSpec.control).validationMessage)
    }

    func testDefaultShortcutIsValid() {
        XCTAssertNil(GlobalShortcutSpec.default.validationMessage)
        XCTAssertEqual(GlobalShortcutSpec.default.modifiers, GlobalShortcutSpec.option)
    }

    func testDisplayNameIncludesModifierSymbols() {
        let name = GlobalShortcutSpec(keyCode: 49, modifiers: GlobalShortcutSpec.option).displayName
        XCTAssertTrue(name.contains("⌥"), "显示名要带上修饰键符号，实际：\(name)")
        XCTAssertTrue(name.contains("Space"), "显示名要带上按键名，实际：\(name)")
    }
}
