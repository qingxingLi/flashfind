import Foundation

/// 应用版本号的**唯一出处**。
///
/// 「关于」面板和设置页「通用」都要显示版本。两边各自去读一次
/// `Bundle.main.infoDictionary`，迟早会分叉——一处读了 `CFBundleShortVersionString`
/// 忘了带构建号，另一处又用另一种格式拼出来，同一次安装里出现两个版本号说法。
/// 所以读取与格式化都收在这里，`AboutPanel` 与 `SettingsView` 共用。
///
/// 格式化刻意留成**纯函数** `displayText(short:build:)`：App 层拿不到可测的
/// `Bundle.main`（`FlashFind2App` 是 executableTarget，测试跑在自有 bundle 里），
/// 把拼装逻辑抽出来才测得到。
public enum AppVersion {

    /// 一行式展示：`1.0.0（1）`。
    ///
    /// 缺值时降级而不是摆空占位——版本号读不到时显示 `—`，
    /// 只有构建号时只显示构建号。短版本与构建号相同时不重复写两遍。
    public static func displayText(short: String?, build: String?) -> String {
        let s = (short ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let b = (build ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (s.isEmpty, b.isEmpty) {
        case (true, true): return "—"
        case (false, true): return s
        case (true, false): return b
        case (false, false): return s == b ? s : "\(s)（\(b)）"
        }
    }

    /// 短版本号（`CFBundleShortVersionString`）。源码直接跑的裸二进制没有
    /// Info.plist，这时给「开发构建」而不是空串。
    public static var shortVersion: String {
        value(for: "CFBundleShortVersionString") ?? "开发构建"
    }

    /// 构建号（`CFBundleVersion`）。
    public static var buildNumber: String {
        value(for: "CFBundleVersion") ?? "-"
    }

    /// 设置页显示的一行式文本。
    public static var current: String {
        let short = value(for: "CFBundleShortVersionString")
        let build = value(for: "CFBundleVersion")
        if short == nil && build == nil { return "开发构建" }
        return displayText(short: short, build: build)
    }

    private static func value(for key: String) -> String? {
        Bundle.main.infoDictionary?[key] as? String
    }
}
