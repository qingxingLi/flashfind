import AppKit

/// 「此刻鼠标左键按着吗」——判定「这次窗口移动是用户拖的吗」时唯一的输入源。
///
/// 判定本身在 Core（`WindowDragIntent`，可测），这里只负责把 AppKit 的位掩码
/// 翻译成一个布尔值：`pressedMouseButtons` 的 bit 0 就是左键。
///
/// ★ 为什么不用「正在程序化摆位」的标志去猜：那种标志永远赶不上
///   `didMove` 的时序，细节见 `WindowDragIntent` 的说明。
enum PointerButton {
    static var isDown: Bool { NSEvent.pressedMouseButtons & 1 != 0 }
}
