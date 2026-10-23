import Foundation

/// 应用版本号的**唯一出处**。
///
/// 「关于」面板和设置页「通用」都要显示版本。两边各自去读一次
/// `Bundle.main.infoDictionary`，迟早会分叉——一处读了 `CFBundleShortVersionString`、
/// 另一处又拼成别的说法，同一次安装里出现两个版本号。
/// 所以读取与格式化都收在这里，`AboutPanel` 与 `SettingsView` 共用。
///
/// 界面只认短版本（`1.0.1`），**不带构建号**。构建号是内部序号：同一个 `1.0.1`
/// 会为了修 bug 重打若干次（build 18、19…），摆进界面只会让用户看到一串对不上
/// 任何东西的数字，还得有人解释它是什么。构建号仍留在 Info.plist 的
/// `CFBundleVersion` 里，打包脚本与 CI 拿它比对，但**不进界面**。
///
/// 格式化刻意留成**纯函数** `displayText(short:)`：App 层拿不到可测的
/// `Bundle.main`（`FlashFind2App` 是 executableTarget，测试跑在自有 bundle 里），
/// 把拼装逻辑抽出来才测得到。
public enum AppVersion {

    /// 一行式展示的版本号：`1.0.1`。
    ///
    /// 缺值时降级而不是摆空占位——读不到版本就显示 `—`，
    /// 两端的空白要剪掉，Info.plist 里多敲一个空格不该显示成 ` 1.0.1 `。
    public static func displayText(short: String?) -> String {
        let s = (short ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        return s.isEmpty ? "—" : s
    }

    /// 短版本号（`CFBundleShortVersionString`）。源码直接跑的裸二进制没有
    /// Info.plist，这时给「开发构建」而不是空串。
    public static var shortVersion: String {
        value(for: "CFBundleShortVersionString") ?? "开发构建"
    }

    /// 设置页显示的一行式文本。
    public static var current: String {
        guard let short = value(for: "CFBundleShortVersionString") else { return "开发构建" }
        return displayText(short: short)
    }

    /// 给协议与日志用的**机器可读**版本号：`1.1.3`。
    ///
    /// ★ 与 `current` 是同一个事实（`CFBundleShortVersionString`）的两种形态，所以
    /// 两者都在这里读，别处不许再读一次 Info.plist。区别只在缺值时：
    /// 界面要中文的「开发构建」，而 MCP 的 `serverInfo.version` 进的是客户端配置与
    /// 日志，塞中文会让配对、比较、排序全部失效，因此回落成 ASCII 的 `0.0.0-dev`。
    public static var machineReadable: String {
        value(for: "CFBundleShortVersionString") ?? "0.0.0-dev"
    }

    private static func value(for key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}
