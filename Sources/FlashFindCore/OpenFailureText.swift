import Foundation

/// 打开 / 定位 / 快速查看失败时，把底层错误翻译成「用户下一步该做什么」。
///
/// 与 `NASSearchFailureText` 是两条链路，但必须共用同一套中文：
/// 同一个 `SessionExpired`，搜索失败说「登录已过期…」而打开失败说「SessionExpired」
/// 是自相矛盾的界面。所以这里处理完挂载类错误后，其余一律交回
/// `NASSearchFailureText`，不另立一张表。
///
/// 为什么它值得单独存在（而不是留在 AppModel 里的 private 静态方法）：
/// 放在 App 层就一行测试都写不了（executableTarget 依赖不进来），
/// 而「用户看到的是什么」恰恰是最该被测试锁住的东西。
public enum OpenFailureText {
    /// 用户可见主句。
    public static func describe(_ error: Error) -> String {
        // 挂载类错误自带成句的原因（含「445 端口不可达」这种具体到端口的话），
        // 比按类型猜出来的准，优先用。
        if let mount = error as? SMBMountService.MountError {
            return mount.errorDescription ?? "无法连接共享"
        }
        if let flash = error as? FlashFindError {
            switch flash {
            case let .message(text):
                return text
            case let .coreFailure(kind, reason, apiCode):
                // ★ 这里必须走中文表，不能用 `localizedDescription`：
                // `coreFailure.errorDescription` 返回的是 **kind**
                // （Models.swift 里刻意如此，因为既有代码要靠它做字符串判断），
                // 直接显示就是把 "AuthenticationFailed" 甩给用户。
                // 打开链路目前还抛不到 coreFailure，但一旦 provider 的定位
                // 改成走核心请求就会到这一步——先堵上。
                return NASSearchFailureText.describe(kind: kind, apiCode: apiCode, reason: reason)
            }
        }
        return error.localizedDescription
    }

    /// 可手动连接的 `smb://` 地址；没有则 nil。
    ///
    /// 非空时提示条上才出现「在访达中连接」按钮。闪寻自己绝不替用户弹连接框——
    /// 用公网域名连 NAS 时 445 通常没有公网映射，自动弹出来只会是一次必败的等待。
    public static func manualConnectURL(_ error: Error) -> String? {
        (error as? SMBMountService.MountError)?.manualConnectURL
    }

    /// 提示条上那句话 + 是否带「在访达中连接」。两件事一次算完，
    /// 避免调用方漏掉其中一个（漏了 smbURL 用户就没有可点的出路）。
    public static func banner(_ error: Error) -> (message: String, smbURL: String?) {
        (describe(error), manualConnectURL(error))
    }
}
