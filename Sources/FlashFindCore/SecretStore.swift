import Foundation

/// 后端为何读不出来。`nil` 表示可读。
///
/// **OSS-04**：读不出来就必须拒绝一切写入。把「读不出来」折叠成「空表」会让下一次保存
/// 拿「空表 + 这一条」整个覆盖掉其余 NAS 的密码，且界面毫无提示。
public enum CredentialStoreProblem: Sendable, Equatable {
    case unreadable
    case undecodable
    case newerVersion(Int)
    /// 钥匙串后端给出的原因（状态码原文），例如权限或 entitlement 问题。
    case keychain(String)

    /// 给用户看的一句话。不含路径，不含任何密文。
    public var summary: String {
        switch self {
        case .unreadable:
            return "本机凭据读不出来"
        case .undecodable:
            return "本机凭据已损坏，读不懂里面的内容"
        case let .newerVersion(version):
            return "本机凭据是更新版本的闪寻写入的（版本 \(version)）"
        case let .keychain(reason):
            return "系统钥匙串读不出来（\(reason)）"
        }
    }
}

/// 凭据后端抽象。调用方只认这个协议，换后端不动调用点。
///
/// 已实现的后端：`InMemorySecretStore`（默认、测试）、`FileSecretStore`（当前生产）、
/// `KeychainSecretStore`（已实现，**暂未装配**）。
public protocol SecretStore: Sendable {
    func save(_ value: String, account: String) throws
    func read(account: String) -> String?
    /// 删除。删不存在的条目**也算成功**——移除来源时会无条件调用。
    @discardableResult func delete(account: String) -> Bool
    func allAccounts() -> [String]
    /// 当前为何读不出来（OSS-04 判据）。永远可读的后端返回 `nil`。
    var unreadableReason: CredentialStoreProblem? { get }

    /// 仅用于变更审计的枚举。钥匙串后端返回 `nil`——枚举一次就是一次系统授权。
    func auditableAccounts() -> [String]?
    /// 条目是否存在（判断「删了一条不存在的」要不要算变更）。
    /// 钥匙串后端返回 `nil` 表示不查：宁可不报变更，也不额外弹一次窗。
    func existsForAudit(_ account: String) -> Bool?
}

/// 进程内后端。测试用，也是未装配任何后端时的默认落点。
///
/// 进程退出即消失——这不是缺陷，是「不落盘」本身。
public final class InMemorySecretStore: SecretStore, @unchecked Sendable {

    private let lock = NSLock()
    private var records: [String: String] = [:]

    public init() {}

    public func save(_ value: String, account: String) throws {
        guard !account.isEmpty else { throw CredentialStoreError.invalidAccount }
        lock.lock()
        records[account] = value
        lock.unlock()
    }

    public func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return nonEmpty(records[account])
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        lock.lock()
        records.removeValue(forKey: account)
        lock.unlock()
        return true
    }

    public func allAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return Array(records.keys).sorted()
    }

    public var unreadableReason: CredentialStoreProblem? { nil }

    public func auditableAccounts() -> [String]? { allAccounts() }

    public func existsForAudit(_ account: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return records[account] != nil
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
