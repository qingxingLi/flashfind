import Foundation

/// 登录凭据的取值规则（向导链路）。
///
/// ## 为什么搬到 Core
///
/// 原来这段判定写在 App 层的 `connectDraft()` 里，于是**测不了**——
/// `FlashFind2App` 是 executableTarget，SwiftPM 的 testTarget 依赖不了它。
///
/// 而它恰好藏过一个死循环（2026-10-24 用户报障）：
/// 弹窗里拿到的动态码存进一处，但「密码从钥匙串取」的那一路把码**丢了**，
/// 于是重连仍然不带码 ⇒ 服务端仍然回 402 ⇒ 又弹一次 ⇒ **无限弹窗**。
/// 「密码框里手输」那条路没这个问题（本来就带码），
/// 于是现象长得像「只有空密码才会一直弹」，其实根因在**取值的那一路**。
///
/// 规则本身在 Core 里 ⇒ 有单元测试 ⇒ 这一类错不会再靠人工点一遍才发现。
public enum NASCredentialPick {

    /// 挑一条能用的密码来源，并**始终带上动态码**。
    ///
    /// - Parameters:
    ///   - typedPassword: 用户这次在密码框里输入的内容（空串 = 没输）。
    ///   - storedPassword: 钥匙串里已保存的密码。**调用方**负责先判断
    ///     「允许沿用已存密码吗」（地址/账号改过就不许沿用），这里只管取。
    ///   - otp: 弹窗里拿到的动态码（空串 = 这次还没要）。
    /// - Returns: 选中的密码与动态码；两个来源都没有密码时返回 `nil`。
    public static func pick(typedPassword: String,
                            storedPassword: String?,
                            otp: String?) -> (password: String, otp: String?)? {
        // 空串不算「有码」：把空串当码发出去，服务端会回 402，
        // 于是又弹一次窗 —— 与没带码时一模一样。
        let code = (otp?.isEmpty == false) ? otp : nil

        // 手输的优先：用户可能刚改了密码。
        if !typedPassword.isEmpty {
            return (typedPassword, code)
        }
        // 已保存的次之：否则每次编辑都要把密码重新敲一遍。
        if let stored = storedPassword, !stored.isEmpty {
            // ★ 动态码在这里**也必须**带上。
            // 这一行就是死循环的修法：漏掉它 ⇒ 重连不带码 ⇒ 服务端再回 402 ⇒ 再弹一次。
            return (stored, code)
        }
        return nil
    }

    /// 「登录不靠密码」品牌（fnOS）**没有**独立的取值函数：
    /// 它的凭据就是 sessionSecret 原样进 `password`、otp 恒为 nil，
    /// 两行就能写清的逻辑不值得一个包装（2026-10-29 审查收敛）。
    /// 判定「哪些品牌走这条路」住在向导的分支里，那里有上下文。
}

/// 连接成功之后，凭据槽位里该存哪一串东西。
///
/// 槽位的语义是「**下次登录所需的那一串东西**」，不是「密码」：
/// 账密品牌是密码，飞牛（fnOS）则是 OAuth 换来的 refresh token
/// （它根本没有密码）。核心在登录成功后会把后者交上来（`sessionSecret`）。
///
/// ★ 判定放在 Core 而不是向导里，因为它藏过一个「看起来成功、其实没存上」的形态：
///   对飞牛存用户输入的密码，存到的是空串 —— 界面一路显示「已记住」，
///   下次启动照样要重新授权，而用户无从判断是没存上还是被清了。
public enum NASCredentialSave {
    /// - Parameters:
    ///   - sessionSecret: 核心交上来的续期凭据；账密品牌恒为 `nil`。
    ///   - typedPassword: 用户这次输入的密码。
    /// - Returns: 该存的那一串；两者都为空时返回 `nil`（调用方应当如实报「没存上」，
    ///   而不是存一个空串假装成功）。
    public static func pick(sessionSecret: String?, typedPassword: String) -> String? {
        if let secret = sessionSecret?.trimmingCharacters(in: .whitespacesAndNewlines),
           !secret.isEmpty { return secret }
        if !typedPassword.isEmpty { return typedPassword }
        return nil
    }
}
