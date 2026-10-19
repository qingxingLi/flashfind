import Foundation

/// 搜索浮窗内一次按下的键盘上下文。
///
/// 只描述「按了什么、焦点在哪」，不含任何 AppKit 对象，
/// 因此可以在单元测试里穷举组合。
public struct SearchKeyContext: Equatable, Sendable {
    /// 虚拟键码（`NSEvent.keyCode`）。36=↩ 76=⌤ 49=Space 53=esc 8=C
    /// 125=↓ 126=↑ 116=pageUp 114=help/insert
    public var keyCode: UInt16
    /// 是否按住 ⌘
    public var hasCommand: Bool
    /// 是否按住 ⌥ / ⌃ / ⇧ 中的任意一个
    public var hasOtherModifier: Bool
    /// 焦点是否在搜索输入框里（field editor 是第一响应者）
    public var inSearchField: Bool
    public var inResults: Bool
    /// 输入法正在组字（有 marked text）
    public var isComposing: Bool

    public init(keyCode: UInt16, hasCommand: Bool, hasOtherModifier: Bool,
                inSearchField: Bool, inResults: Bool, isComposing: Bool) {
        self.keyCode = keyCode
        self.hasCommand = hasCommand
        self.hasOtherModifier = hasOtherModifier
        self.inSearchField = inSearchField
        self.inResults = inResults
        self.isComposing = isComposing
    }
}

/// 一次按键应该做什么。
public enum SearchKeyRoute: Equatable, Sendable {
    case move(Int)      // ↑ / ↓ 移动结果选择
    case submit         // ↩ 打开
    case reveal         // ⌘↩ 在 Finder 中显示
    case quickLook      // Space 快速查看
    case copyPath       // ⌘C 复制路径
    case hide           // esc 隐藏浮窗
    case passThrough    // 交还给系统与文本控件
}

/// 搜索浮窗的按键决策。
///
/// 为什么单独抽出来：这段逻辑以前直接写在 `NSEvent` 监视器里，
/// 于是「输入框里按空格会被当成快速查看快捷键吞掉」这种错误
/// 只能靠用户试出来。判定不含任何副作用，放在 Core 里可回归。
public enum SearchKeyRouter {
    /// 只有一个来源的键位表。改动务必同时补 `SearchKeyRouterTests`。
    public static func route(_ context: SearchKeyContext) -> SearchKeyRoute {
        // 输入法组字中（拼音候选未上屏）一律不抢，交给输入法。
        guard !context.isComposing else { return .passThrough }

        // ⌘ 组合键在浮窗内任何位置都生效，不受焦点限制。
        if context.hasCommand {
            switch context.keyCode {
            case 36, 76: return .reveal        // ⌘↩ Finder 中显示
            case 8: return .copyPath           // ⌘C 复制路径
            default: return .passThrough
            }
        }

        // 其余快捷键要求「焦点在搜索区」且未按任何修饰键，
        // 免得抢走 ⌘⇧F、⌥↑ 这类系统或文本组合。
        guard context.inSearchField || context.inResults, !context.hasOtherModifier else {
            return .passThrough
        }

        switch context.keyCode {
        // ↑↓ 在搜索区内**一律由我们接管**（包括焦点已在结果表时）。
        //
        // 两个坑叠在一起：
        //  1. 原来写的 `case 125, 116 where context.inSearchField`，
        //     Swift 的 `where` 只约束逗号分隔里的**最后一个** pattern，
        //     所以 125(↓) 其实是无条件命中的 —— 意图与行为并不一致；
        //  2. 但结论恰好是对的：事件已被监视器消费（return nil），
        //     结果表自己收不到按键，不会出现「我们移一格、List 又移一格」的双跳。
        // 因此这里**显式**让整组接管，把 1 的不一致去掉、保留 2 的结果。
        // 空格那条**不能**照抄这个策略，见下面。
        case 125, 116: return .move(1)
        case 126, 114: return .move(-1)
        case 36, 76: return .submit
        // ★ Space 只有在**焦点不在输入框**时才是快速查看。
        //
        // 以前这里是无条件的 `case 49: quickLook`，而 `inScope` 包含
        // 「焦点在输入框」这一支，于是用户在搜索框里打「2026 10 10」
        // 之类的空格会被事件监视器吞掉转成预览 —— 表现为「搜索框打不出空格」。
        // 空格是文件名的常见字符，必须放行给文本系统。
        case 49: return context.inSearchField ? .passThrough : .quickLook
        case 53: return .hide
        default: return .passThrough
        }
    }
}
