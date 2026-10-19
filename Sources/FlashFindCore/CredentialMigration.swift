import Foundation

/// 明文凭据 → 其它后端的迁移。
///
/// ## 两条约束（来自/38 的实测教训）
///
/// 1. **只写不读**：写入目标后端后**不读回校验**。读回就是一次系统授权，正是要躲的东西。
///    成功与否看写入返回，正确性留给下一次真实登录去证明。
/// 2. **明文删在最后**：迁移成功只标记「待验证」；等到**用新后端的密码真的连上了**，
///    才删掉明文副本。否则万一新后端读不出来，密码就两头落空。
///
/// 调用方必须**先取得用户确认**再调 `migrate`——它不该在启动路径上自动发生。
public enum CredentialMigration {

    public struct Failure: Sendable, Equatable {
        public let account: String
        public let reason: String
    }

    public struct Report: Sendable, Equatable {
        /// 本次尝试写入的 account。
        public var attempted: [String] = []
        /// 写入成功、已标记为「待验证」的 account。
        public var added: [String] = []
        public var failures: [Failure] = []
        /// 先前已迁移、本次跳过的 account。
        public var skippedAlreadyMigrated: [String] = []

        public var isEmpty: Bool { attempted.isEmpty }
    }

    /// 把文件后端里的明文写入目标后端。
    ///
    /// - Parameters:
    ///   - source: 明文所在的文件后端。只做文件 IO，不触碰任何系统 API。
    ///   - destination: 目标后端。测试传 `InMemorySecretStore`，**不要让测试碰真钥匙串**。
    public static func migrate(from source: FileSecretStore, to destination: SecretStore) -> Report {
        var report = Report()
        let pending = source.pendingVerification
        for account in source.allAccounts() {
            report.attempted.append(account)
            if pending.contains(account) {
                report.skippedAlreadyMigrated.append(account)
                continue
            }
            guard let value = source.plaintext(account) else {
                report.failures.append(Failure(account: account, reason: "明文读不出来"))
                continue
            }
            do {
                try destination.save(value, account: account)
                source.markMigrated(account)
                report.added.append(account)
            } catch {
                report.failures.append(Failure(account: account, reason: String(describing: error)))
            }
        }
        return report
    }

    /// 已写入目标后端、但还没被真实登录验证过的 account。
    public static func pendingVerification(in source: FileSecretStore) -> Set<String> {
        source.pendingVerification
    }
}
