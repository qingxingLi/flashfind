import Foundation

/// 长按 ⌘Q 才能退出的策略（纯逻辑，不引 AppKit、不含计时器与界面）。
///
/// 用户 2026-11-13 原话：「在加入一个长按 command+Q 才能退出闪寻的设定，
/// 长按时有一个转圈关闭中的动画，圈走到头关闭闪寻，防止误操作关闭软件。」
///
/// ★ 判据只有一条：**进度走到 1 才允许退出**。短按、长按途中松手、系统发来的
/// 按键重复事件、多按了其它修饰键，都不算一次有效长按。
public enum QuitHoldPolicy {
    /// `kVK_ANSI_Q`。Core 不引 AppKit，写数字（与 `GlobalShortcutSpec` 键位表一致）。
    public static let quitKeyCode: UInt16 = 12
    public static let holdDuration: TimeInterval = 1.2
    public static let tickInterval: TimeInterval = 1.0 / 60

    /// 这是不是一次**新的** ⌘Q 按下。
    ///
    /// - `isRepeat`: 长按会让系统不断重发 keyDown；重复事件不许重启计时，
    ///   否则圈永远走不到头。
    /// - `hasOtherModifiers`: ⌘⇧Q / ⌘⌥Q 不是退出手势，放行给系统/其它功能。
    public static func isQuitKeyDown(keyCode: UInt16, hasCommand: Bool,
                                     hasOtherModifiers: Bool, isRepeat: Bool) -> Bool {
        keyCode == quitKeyCode && hasCommand && !hasOtherModifiers && !isRepeat
    }

    public static func progress(elapsed: TimeInterval,
                                duration: TimeInterval = holdDuration) -> Double {
        guard duration > 0 else { return 1 }
        return min(1, max(0, elapsed / duration))
    }

    public static func shouldTerminate(progress: Double) -> Bool { progress >= 1 }
}
