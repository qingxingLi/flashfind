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
    /// 搜索框处于**命令模式**（文本以 `/` 开头，命令面板已展开）。
    ///
    /// ★ 这个上下文存在的意义：命令模式下回车是「执行这条命令」，
    /// 不是「打开下面那条选中的结果」。不区分的话，用户在面板里选中一个位置
    /// 按回车，去打开的却是下面那条文件结果 —— 面板看着在，回车却不听它的。
    public var inCommandMode: Bool
    /// 搜索框最前面有没有已选定的限定（位置 / 类型）。
    public var hasSearchToken: Bool
    /// 输入框里除限定之外还有没有关键词。
    ///
    /// ★ 只有**关键词为空**时删除键才轮得到限定：那时它删的是用户刚打的字，
    /// 抢过来会变成「输入框删不动字」。
    public var keywordEmpty: Bool

    public init(keyCode: UInt16, hasCommand: Bool, hasOtherModifier: Bool,
                inSearchField: Bool, inResults: Bool, isComposing: Bool,
                inCommandMode: Bool = false,
                hasSearchToken: Bool = false,
                keywordEmpty: Bool = true) {
        self.keyCode = keyCode
        self.hasCommand = hasCommand
        self.hasOtherModifier = hasOtherModifier
        self.inSearchField = inSearchField
        self.inResults = inResults
        self.isComposing = isComposing
        self.inCommandMode = inCommandMode
        self.hasSearchToken = hasSearchToken
        self.keywordEmpty = keywordEmpty
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
    // ── 命令模式（`/` 唤起命令面板）──
    /// ↑ / ↓ 在命令候选之间移动。
    case commandMove(Int)
    /// ↩ 执行当前选中的命令。
    case commandSubmit
    /// esc 退出命令模式（回到普通搜索，而不是关掉整个浮窗）。
    case commandCancel
    /// 数字键 0–9 直接选中对应候选。
    case commandPick(Int)
    // ── 前置限定 ──
    /// 删除键删掉搜索框最前面那排限定里的一个。
    case deleteSearchToken
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

        // ★ 命令模式先于所有普通路由判定。
        //
        // 顺序不能反：命令模式下 ↩ 是「执行命令」，↑↓ 是「在候选之间移动」，
        // esc 是「退出命令模式」。若先走普通分支，回车会去打开文件结果，
        // esc 会把整个浮窗关掉——命令面板将完全无法用键盘操作。
        if context.inCommandMode {
            switch context.keyCode {
            case 125, 116: return .commandMove(1)
            case 126, 114: return .commandMove(-1)
            case 36, 76: return .commandSubmit
            case 53: return .commandCancel
            default:
                // ★ 命令模式下数字键**一律被接管**，不进输入框。
                //
                // 手指就在数字键上：面板已经把编号写在脸上了，还要求用户
                // 用方向键挪到那一条再回车，等于白给的信息不用。
                // 代价是筛不出名字里带数字的位置（极少见），可以接受。
                if let digit = Self.digitKeyCodes[context.keyCode] { return .commandPick(digit) }
                return .passThrough
            }
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
        // ★ 删除键删掉前置的限定，但只在「没得删的字」时才轮到它。
        //
        // 关键词还在 ⇒ 删除键属于文本编辑，抢过来就是「输入框删不动字」。
        case 51: return context.hasSearchToken && context.keywordEmpty ? .deleteSearchToken : .passThrough
        case 53: return .hide
        default: return .passThrough
        }
    }

    /// 主键盘区数字键的虚拟键码 → 数字。
    ///
    /// 键码不是连续的（5 和 6 之间隔着 22/23 的错位），查表比算偏移可靠。
    private static let digitKeyCodes: [UInt16: Int] = [
        29: 0, 18: 1, 19: 2, 20: 3, 21: 4, 23: 5, 22: 6, 26: 7, 28: 8, 25: 9,
    ]
}

/// 方向键选中结果后，Space 作用于结果；重新输入时回到文本编辑。
public struct SearchResultNavigation: Equatable, Sendable {
    public private(set) var isActive = false
    public init() {}

    public mutating func record(_ route: SearchKeyRoute, hasResult: Bool) {
        switch route {
        case .move: isActive = hasResult
        case .quickLook: break
        default: isActive = false
        }
    }

    public mutating func reset() { isActive = false }
}
