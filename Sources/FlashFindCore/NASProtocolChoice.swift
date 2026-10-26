import Foundation

/// 连接协议的两选一：加密（HTTPS）还是明文（HTTP）。
///
/// ## 为什么不是开关
///
/// 原来这里是个 `Toggle`，绑的是「是否用明文 HTTP」，标签在开/关两种状态下
/// 分别写「使用明文 HTTP（不加密）」/「使用加密连接 HTTPS」。
///
/// 这么写的后果是**文案与开关方向相反**：开关关着的时候，标签写着
/// 「使用加密连接 HTTPS」—— 用户看到的是「一个叫"使用加密"的开关，当前是关的」，
/// 于是把「勾上」读成「启用加密」。可实际上勾上会把 `usePlainHTTP` 置成 `true`，
/// 真的切到了**明文**。想用加密的人会拿到明文连接，而界面看上去一切正常。
///
/// 「关掉 = 生效」这件事本身也不是开关该有的样子：开关天生表达
/// 「某项功能开着」，而协议是**二选一**，两个选项都是有效状态、只是安全性不同。
///
/// ## 因此
///
/// 改成两段并列的选择器：两个选项都写在脸上，当前用的那个被选中。
/// 没有需要推断的地方，也不存在"勾上会变成相反的东西"。
///
/// 判定放在 Core：App 层是 `executableTarget`，测试目标 import 不到，
/// 而「哪个选项对应加密、哪个对应明文」是每次连接都会走的路径。
public enum NASProtocolChoice: String, CaseIterable, Identifiable, Sendable {
    /// 加密连接（HTTPS）。
    case https
    /// 明文连接（HTTP，账号密码不加密）。
    case plainHTTP

    public var id: String { rawValue }

    /// 界面上显示的选项名。
    ///
    /// 两个选项都用**协议名 + 安全性**的说法，不用「使用…」这种动作句式：
    /// 动作句式配两段选择器会让人以为「点了会去做某件事」，
    /// 而这里选的就是当前生效的协议本身。
    public var title: String {
        switch self {
        case .https: return "加密 HTTPS"
        case .plainHTTP: return "明文 HTTP"
        }
    }

    /// 由「实际是否走明文」推出选择项。
    public init(usesPlainHTTP: Bool) {
        self = usesPlainHTTP ? .plainHTTP : .https
    }

    /// 这一项对应的是不是明文连接。
    public var usesPlainHTTP: Bool { self == .plainHTTP }
}
