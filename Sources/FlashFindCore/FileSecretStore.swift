import Foundation

/// 本机文件后端（当前生产落点）。
///
/// 两个不能丢的保护：
/// - **OSS-04** 读不出来就拒绝写入，绝不拿空表覆盖（见 `CredentialStoreProblem`）。
/// - **OSS-05** 写入走临时文件 → `replaceItemAt` 原子替换；先删后放会留下
///   「凭据文件不存在」的窗口，那一刻崩掉等于全丢。
public final class FileSecretStore: SecretStore, @unchecked Sendable {

    private let lock = NSLock()
    private let directory: URL
    /// 缓存的是**读取结论**而不是记录表：读失败也必须被记住，否则每次读取都要重新失败一遍。
    private var cached: LoadResult?

    public init(directory: URL? = nil) {
        self.directory = directory ?? Self.defaultDirectory
    }

    public static var defaultDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlashFind2", isDirectory: true)
    }

    public var fileURL: URL { directory.appendingPathComponent("credentials.json") }

    // MARK: - SecretStore

    public func save(_ value: String, account: String) throws {
        guard !account.isEmpty else { throw CredentialStoreError.invalidAccount }
        lock.lock(); defer { lock.unlock() }
        switch loadedLocked() {
        case .records(var records):
            records[account] = value
            try persistLocked(records, migrated: migratedLocked())
        case let .problem(problem):
            throw CredentialStoreError.storeUnreadable(problem)
        }
    }

    public func read(account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard case let .records(records) = loadedLocked() else { return nil }
        return nonEmpty(records[account])
    }

    @discardableResult
    public func delete(account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        switch loadedLocked() {
        case .records(var records):
            // 删不存在的条目不改文件；返回 true 保持「移除来源时无条件调用」的语义。
            guard records.removeValue(forKey: account) != nil else { return true }
            var migrated = migratedLocked()
            migrated.remove(account)
            do {
                try persistLocked(records, migrated: migrated)
                return true
            } catch {
                return false
            }
        case .problem:
            // 删除也要落盘，读不出来时不能删——否则又是拿空表覆盖。
            // 返回 false：「删除成功」会让人以为那条凭据确实没了。
            return false
        }
    }

    public func allAccounts() -> [String] {
        lock.lock(); defer { lock.unlock() }
        guard case let .records(records) = loadedLocked() else { return [] }
        return Array(records.keys).sorted()
    }

    public var unreadableReason: CredentialStoreProblem? {
        lock.lock(); defer { lock.unlock() }
        if case let .problem(problem) = loadedLocked() { return problem }
        return nil
    }

    public func auditableAccounts() -> [String]? { allAccounts() }

    public func existsForAudit(_ account: String) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        guard case let .records(records) = loadedLocked() else { return nil }
        return records[account] != nil
    }

    // MARK: - 迁移（明文 → 钥匙串）状态

    /// 已写入钥匙串、但**尚未被实际读取并验证**的 account。
    /// 验证成功（用钥匙串里的密码连上了）之后才把对应明文删掉。
    public var pendingVerification: Set<String> {
        lock.lock(); defer { lock.unlock() }
        return Set(migratedLocked())
    }

    /// 标记某条已写入钥匙串，等待验证。明文此时**保留**。
    public func markMigrated(_ account: String) {
        lock.lock(); defer { lock.unlock() }
        guard case let .records(records) = loadedLocked() else { return }
        var migrated = migratedLocked()
        migrated.insert(account)
        try? persistLocked(records, migrated: migrated)
    }

    /// 验证成功：删掉该条明文，并清掉等待标记。
    ///
    /// 与 `delete` 的区别：它对 records 与 migrated 一并生效，且**只在读取正常时**执行。
    @discardableResult
    public func dropPlaintextAfterVerification(_ account: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard case .records(var records) = loadedLocked() else { return false }
        records.removeValue(forKey: account)
        var migrated = migratedLocked()
        migrated.remove(account)
        do {
            try persistLocked(records, migrated: migrated)
            return true
        } catch {
            return false
        }
    }

    /// 取一条明文（迁移时读取用）。不触碰任何系统 API。
    public func plaintext(_ account: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard case let .records(records) = loadedLocked() else { return nil }
        return nonEmpty(records[account])
    }

    /// 清空后删除整个凭据文件。
    ///
    /// 迁移收尾用：全部明文都迁走并验证通过之后，留一个空的 `credentials.json`
    /// 只会让「这台机器上还有没有明文密码」变成一个要读 JSON 才知道的问题。
    /// 只有确认 records 与待验证集合都空了才调（判据在调用方）。
    public func removeStorageFile() throws {
        lock.lock(); defer { lock.unlock() }
        cached = .records([:])
        cachedMigrated = []
        guard FileManager.default.fileExists(atPath: fileURL.path) else { return }
        try FileManager.default.removeItem(at: fileURL)
    }

    // MARK: - 读写实现（调用方须已持锁）

    private enum LoadResult {
        case records([String: String])
        case problem(CredentialStoreProblem)
    }

    private struct Document: Codable {
        var version: Int
        var records: [String: String]
        /// 已写入钥匙串待验证的 account。可选以兼容 version 1 的旧文件。
        var migrated: [String]?
    }

    private static let currentVersion = 1

    private var cachedMigrated: Set<String> = []

    private func migratedLocked() -> Set<String> { cachedMigrated }

    private func loadedLocked() -> LoadResult {
        if let cached { return cached }
        let result: LoadResult
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            // 文件不在 = 第一次用。这是**唯一**可以当空表处理的情况。
            result = .records([:])
        } else {
            do {
                let data = try Data(contentsOf: fileURL)
                let document = try JSONDecoder().decode(Document.self, from: data)
                cachedMigrated = Set(document.migrated ?? [])
                result = document.version > Self.currentVersion
                    ? .problem(.newerVersion(document.version))
                    : .records(document.records)
            } catch is DecodingError {
                result = .problem(.undecodable)
            } catch {
                result = .problem(.unreadable)
            }
        }
        cached = result
        return result
    }

    private func persistLocked(_ records: [String: String], migrated: Set<String>) throws {
        let manager = FileManager.default
        // 在当前进程的 mask 下建目录，权限随后显式收紧，不依赖 umask。
        if !manager.fileExists(atPath: directory.path) {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true,
                                        attributes: [.posixPermissions: 0o700])
        }
        try? manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)

        let document = Document(version: Self.currentVersion, records: records,
                                migrated: migrated.isEmpty ? nil : migrated.sorted())
        let data = try JSONEncoder().encode(document)
        let temporary = directory.appendingPathComponent("credentials.json.tmp")
        try? manager.removeItem(at: temporary)
        guard manager.createFile(atPath: temporary.path, contents: data,
                                 attributes: [.posixPermissions: 0o600]) else {
            throw CredentialStoreError.writeFailed
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        // ★ 原子替换：新文件就位之前，旧的凭据文件一直存在。
        do {
            if manager.fileExists(atPath: fileURL.path) {
                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary,
                                              backupItemName: nil,
                                              options: .usingNewMetadataOnly)
            } else {
                try manager.moveItem(at: temporary, to: fileURL)
            }
        } catch {
            throw CredentialStoreError.writeFailed
        }
        try? manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)

        cached = .records(records)
        cachedMigrated = migrated
    }

    private func nonEmpty(_ value: String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        return value
    }
}
