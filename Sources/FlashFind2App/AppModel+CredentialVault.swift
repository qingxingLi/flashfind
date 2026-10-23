import Foundation
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// 凭据合并（1.1.5）。只在升级后的第一次启动做一次。
//
// 背景：系统钥匙串的访问授权是**按条目**记的，且认的是 App 的 cdhash
// （`codesign -d -r-` 显示 `designated => cdhash H"…"`）。1.1.4 及以前一台 NAS
// 存一条条目，于是每换一个版本，用户就要为每台 NAS 各点一次「始终允许」——
// 两台两次、三台三次。合并成一条之后，问几次与 NAS 台数无关。
// ─────────────────────────────────────────────────────────────────────────────

extension AppModel {

    /// 把老布局（一台 NAS 一条条目）的凭据搬进合并条目。
    ///
    /// **必须排在 `autoConnectSavedSources()` 之前**：那一步会按老布局读密码，
    /// 而每读一条就是一次系统授权。顺序反了，用户要先为一轮「马上要被搬走」的
    /// 老条目授权，紧接着再为新条目授权一次，白点一轮。
    func consolidateCredentialsIfNeeded() {
        guard !AppEnvironment.isPreview else { return }
        var accounts = nasSources.map { $0.credentialAccount }
        // 旧键规则（`<地址>|<账号>`）那批也要搬：它们不搬的话永远留在老布局里，
        // 而任何一个还认得它的旧构建都会继续弹窗。
        accounts += nasConnections.compactMap { $0.legacyCredentialAccount }
        guard !accounts.isEmpty else { return }
        let report = CredentialStore.consolidateIntoVault(accounts: accounts)
        guard report.changed else { return }
        // 只记条数与账号键（不含密码、不含地址），出事时能对着日志核对。
        diagnostics.append([
            "at": ISO8601DateFormatter().string(from: Date()),
            "event": "consolidateCredentials",
            "detail": "已合并 \(report.moved.count) 条"
                + (report.leftBehind.isEmpty ? "" : "；老条目未删净 \(report.leftBehind.count) 条")
                + (report.failures.isEmpty ? "" : "；失败 \(report.failures.count) 条"),
        ])
    }
}
