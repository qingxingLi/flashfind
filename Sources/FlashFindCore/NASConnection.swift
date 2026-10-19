import Foundation

public struct NASConnectionProfile: Codable, Identifiable {
    public var id: String
    public var name: String
    public var address: String
    public var username: String
    public var certificateSHA256: String
    public var enabled: Bool
    public var syncPaused: Bool
    public var rememberPassword: Bool
    public var selectedSourceIDs: Set<String>
    public var bindings: [String: MountBinding]
    public var legacyCredentialAccount: String?
    public var credentialAccount: String { CredentialAccount.profile(id: id, address: address, username: username) }
    /// 这条凭据的目标身份。旧路径同样要绑身份：换地址或端口后不该再套用旧密码。
    public var credentialIdentity: CredentialIdentity {
        let url = URL(string: address)
        return CredentialIdentity(host: url?.host ?? "", port: url?.port ?? 0, username: username)
    }
    public var cacheProfile: String { AccountProfile.key(address: address, username: username) }
    public init(id: String = UUID().uuidString, name: String = "新 NAS", address: String = "",
                username: String = "", certificateSHA256: String = "", enabled: Bool = false,
                syncPaused: Bool = false, rememberPassword: Bool = false,
                selectedSourceIDs: Set<String> = [], bindings: [String: MountBinding] = [:], legacyCredentialAccount: String? = nil) {
        self.id = id; self.name = name; self.address = address; self.username = username
        self.certificateSHA256 = certificateSHA256; self.enabled = enabled; self.syncPaused = syncPaused
        self.rememberPassword = rememberPassword; self.selectedSourceIDs = selectedSourceIDs; self.bindings = bindings
        self.legacyCredentialAccount = legacyCredentialAccount
    }
}

public enum NASConnectionPhase: String { case unconfigured, idle, connecting, syncing, online, offline, error, disconnected, paused }
public struct NASConnectionState {
    public var failureKind: NASFailureKind?
    public var phase: NASConnectionPhase = .idle
    public var message: String = "尚未连接；尚无可搜索缓存"
    public var sources: [Source] = []
    public var lastSync: Date?
    public var cachedSourceIDs: Set<String> = []
    public var hasCache = false
    public var canSearch = false
    public var canSync = false
    public init() {}
}

public extension NASConnectionProfile {
    var isConfigured: Bool {
        guard let url = URL(string: address), url.scheme == "https", url.host != nil,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return true
    }
}
