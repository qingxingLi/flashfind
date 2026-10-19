import Foundation

/// 经典钥匙串 → Data Protection 钥匙串的升迁。
///
/// ## 为什么会有这一层
///
/// Data Protection 钥匙串（`kSecUseDataProtectionKeychain`）要求 App 带
/// `keychain-access-groups` entitlement。试用包走 ad-hoc 签名、没有 entitlement，
/// 于是 `KeychainSecretStore` 会**自动退到经典钥匙串**——密码照样存得上，
/// 只是层级低一档（详见同名文件的实测状态码）。
///
/// 等签好 Developer ID、entitlement 到位，新写入自然会走 DP。但**已经躺在经典
/// 钥匙串里的那批密码不会自己跟过来**：升迁后的构建默认去 DP 侧读，
/// 读不到就是「密码不见了」，用户得一台一台重输。
///
/// ## 三条规矩
///
/// 1. **必须指名 account**。钥匙串不能枚举（`allAccounts` 会触碰系统授权），
///    所以「现在有哪些条目要搬」只能由调用方给——它手里有 NAS 来源列表。
/// 2. **先写 DP，再删经典**。跟明文迁移同一条规矩（`CredentialMigration`）：
///    顺序反过来等于先删掉唯一副本。
/// 3. **缺 entitlement 时整批中止**。这不是故障，是「这台包还没签上访问组」，
///    一条失败就是全部失败，没必要把剩下的都试一遍。
public enum KeychainTierMigration {

    public struct Failure: Sendable, Equatable {
        public let account: String
        public let reason: String
    }

    public struct Report: Sendable, Equatable {
        /// 本次尝试处理的 account。
        public var attempted: [String] = []
        /// 已搬到 DP 侧的 account（经典侧那一份随之删除）。
        public var moved: [String] = []
        public var failures: [Failure] = []
        /// 经典侧本来就没有这条：要么从没存过，要么已经搬走了。
        public var absentOnClassic: [String] = []
        /// entitlement 不到位，整批中止。**不是故障**，DP 那一档暂时用不了而已。
        public var abortedForMissingEntitlement = false

        public var isEmpty: Bool { attempted.isEmpty }
    }

    /// 把指名的 account 从经典钥匙串搬到 Data Protection 钥匙串。
    ///
    /// - Parameters:
    ///   - classic: 钉在 `.classic` 的钥匙串后端（读旧值、删旧值）。
    ///   - protection: 钉在 `.dataProtection` 的钥匙串后端（写新值）。
    ///   - accounts: 要搬的 account。**不枚举**，由调用方给出。
    ///
    /// 测试两端都传 `InMemorySecretStore`：这一组**不碰真钥匙串**。
    public static func migrate(from classic: SecretStore, to protection: SecretStore,
                               accounts: [String]) -> Report {
        var report = Report()
        for account in accounts where !account.isEmpty {
            report.attempted.append(account)
            guard let value = classic.read(account: account), !value.isEmpty else {
                report.absentOnClassic.append(account)
                continue
            }
            do {
                try protection.save(value, account: account)
            } catch let CredentialStoreError.keychainStatus(status)
                where status == errSecMissingEntitlement {
                // 一条缺 entitlement 就是全部缺：剩下的不用再试，
                // 也不该把「试了 N 次都失败」摊成 N 条失败记录。
                report.abortedForMissingEntitlement = true
                return report
            } catch {
                report.failures.append(Failure(account: account, reason: String(describing: error)))
                continue
            }
            // 走到这里 DP 侧已经有了。**这时候**才删经典侧那一份。
            // 删不掉不算失败：它已经冗余，留着也不会被读到（升迁后读的是 DP 侧）。
            classic.delete(account: account)
            report.moved.append(account)
        }
        return report
    }
}
