import Foundation

/// 「浏览器授权码」这一格：什么时候出现在表单里、粘进来的串怎么洗。
///
/// 2026-10-29 用户改流程（原话：「飞牛的登陆流程更改下 不要弹窗 直接在图示位置
/// 生成获取授权码，点击后打开浏览器 然后再粘贴授权码 点击下方链接跳转搜索位置」）：
/// 授权码从**弹窗**改成「连接信息」里的内联一格 —— 左边一个「获取授权码」按钮
/// （点了就在浏览器打开授权页），右边一个输入框（粘页面上的那串）。
///
/// 判定与清洗放在 Core 而不是视图里：`FlashFind2App` 是 executableTarget，
/// 测试目标依赖不了它，写在那里的规则一行都测不了（项目里踩过太多次）。
public enum AuthorizeCodeField {

    /// 这个来源要不要在表单里摆授权码那一行。
    ///
    /// 判据是**登录方式**而不是「有没有账号密码框」：将来若出现第三种登录方式
    /// （比如设备码），用 `!requiresAccountPassword` 会把它一并算成浏览器授权，
    /// 于是给它摆一个永远用不上的授权码框 —— 那正是上一版给飞牛摆密码框的错。
    public static func isInline(for vendor: NASSourceConfig.Vendor) -> Bool {
        vendor.loginMethod == .browserAuthorization
    }

    /// 把用户粘进来的授权码洗干净。
    ///
    /// 从网页上复制常带尾随换行与首尾空格（页面上那串是分段显示的，三击选中
    /// 很容易带进来）。核心与设备是逐字节比对，多一个 `\n` 就会被判成
    /// 「授权码没有被接受」—— 用户看着屏幕上那串明明一模一样，却怎么都对不上。
    ///
    /// 只剪首尾、不动中间：码里不会有空格，但**不许**做「删掉所有空白」这种
    /// 想当然的处理，否则某天码里真出现分隔符就会被悄悄拼错。
    public static func normalize(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 归一化后的授权码，空则 nil。
    ///
    /// ★ `nil` 与 `""` 在核心那边**不是一回事**：`NASSearchProvider.login` 只在
    /// `authorizeCode` 非 nil 时才把它发给适配器。传空串等于「带着一个空码去换令牌」，
    /// 设备只会回一句拒绝 —— 而用户以为自己还没开始授权。
    public static func optional(_ raw: String) -> String? {
        let code = normalize(raw)
        return code.isEmpty ? nil : code
    }
}
