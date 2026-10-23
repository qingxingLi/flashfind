import Foundation

/// 把「一台 NAS 一条条目」的老数据搬进**合并条目**（`CredentialVault`）。
///
/// ## 为什么必须搬
///
/// 系统钥匙串的授权是**按条目**记的，且认的是 App 的 cdhash。换一个版本，
/// 每一条老条目都要重新问一次——用户的感受就是「两台 NAS 输两次、三台输三次」。
/// 合并之后不管存几台，一次启动最多问一次。
///
/// ## 三条规矩（与 `KeychainTierMigration` 同源）
///
/// 1. **先写新、再删旧**。顺序反了等于先删掉唯一副本。
/// 2. **必须指名 account**。老布局枚举一次就是一次系统授权，所以「有哪些要搬」
///    只能由调用方（握着 NAS 来源列表的那一层）给。
/// 3. **删不掉不算搬成功，但也不算失败**。新的一份已经在合并条目里，
///    老条目留着只是冗余（会多一条历史授权记录），单独报出来让上层知道。
public enum VaultConsolidation {

    public struct Report: Sendable, Equatable {
        /// 本次尝试处理的 account。
        public var attempted: [String] = []
        /// 已写进合并条目、且老条目已删干净的 account。
        public var moved: [String] = []
        /// 已写进合并条目，但老条目没删掉（冗余，不是数据丢失）。
        public var leftBehind: [String] = []
        /// 老布局里本来就没有这条。
        public var absent: [String] = []
        public var failures: [String] = []

        public var isEmpty: Bool { attempted.isEmpty }
        public var changed: Bool { !moved.isEmpty || !leftBehind.isEmpty }
    }

    /// - Parameters:
    ///   - legacy: 老布局（一 account 一条）的来源。
    ///   - vault: 合并布局的目的地。两个都传 `SecretStore`，
    ///     所以测试里可以用内存后端把顺序与失败分支全跑一遍。
    public static func run(from legacy: SecretStore, to vault: SecretStore,
                           accounts: [String]) -> Report {
        var report = Report()
        for account in accounts where !account.isEmpty {
            if report.attempted.contains(account) { continue }   // 来源列表可能重复
            report.attempted.append(account)
            guard let value = legacy.read(account: account), !value.isEmpty else {
                report.absent.append(account)
                continue
            }
            do {
                try vault.save(value, account: account)
            } catch {
                // 写不进去就**绝不删旧的**：删了就是唯一副本没了。
                report.failures.append(account)
                continue
            }
            // 再确认一次新的一份真的在那儿，才允许动老的。
            guard vault.read(account: account) != nil else {
                report.failures.append(account)
                continue
            }
            if legacy.delete(account: account) {
                report.moved.append(account)
            } else {
                report.leftBehind.append(account)
            }
        }
        return report
    }
}
