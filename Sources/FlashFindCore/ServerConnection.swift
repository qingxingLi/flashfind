import Foundation
import Security
import CryptoKit

public struct ServerSettings: Codable {
    public var address: URL
    public var username: String
    public var certificateSHA256: String
    public init(address: URL, username: String, certificateSHA256: String) {
        self.address = address; self.username = username; self.certificateSHA256 = certificateSHA256
    }
}

private final class CertificateDelegate: NSObject, URLSessionTaskDelegate {
    let host: String
    let fingerprint: String
    private let lock = NSLock()
    private var captured: String?
    var observed: String? { lock.lock(); defer { lock.unlock() }; return captured }
    init(host: String, fingerprint: String) { self.host = host; self.fingerprint = fingerprint.lowercased() }
    func urlSession(_ session: URLSession, didReceive challenge: URLAuthenticationChallenge,
                    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              challenge.protectionSpace.host == host, let trust = challenge.protectionSpace.serverTrust,
              let certificates = SecTrustCopyCertificateChain(trust) as? [SecCertificate],
              let certificate = certificates.first else { completionHandler(.performDefaultHandling, nil); return }
        let data = SecCertificateCopyData(certificate) as Data
        let observed = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        lock.lock(); captured = observed; lock.unlock()
        if !fingerprint.isEmpty && observed == fingerprint { completionHandler(.useCredential, URLCredential(trust: trust)) }
        else { completionHandler(.cancelAuthenticationChallenge, nil) }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public final class ServerConnection {
    private let settings: ServerSettings
    private let session: URLSession
    private let delegate: CertificateDelegate
    private var token: String?
    public init(settings: ServerSettings) throws {
        guard settings.address.scheme == "https", let host = settings.address.host,
              settings.address.user == nil, settings.address.password == nil else { throw FlashFindError.message("An HTTPS server address is required") }
        self.settings = settings
        delegate = CertificateDelegate(host: host, fingerprint: settings.certificateSHA256)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 120; configuration.timeoutIntervalForResource = 600
        configuration.urlCache = nil
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
    }
    deinit { session.invalidateAndCancel() }
    public func probeCertificate() async throws -> String {
        let request = URLRequest(url: settings.address.appendingPathComponent("health"))
        _ = try? await session.data(for: request)
        guard let certificate = delegate.observed else { throw FlashFindError.message("Unable to read the server certificate") }
        return certificate
    }
    private func request(_ path: String, query: [URLQueryItem] = []) throws -> URLRequest {
        var components = URLComponents(url: settings.address.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty { components.queryItems = query }
        var request = URLRequest(url: components.url!)
        if let token { request.setValue("Bearer " + token, forHTTPHeaderField: "Authorization") }
        return request
    }
    private func check(_ response: URLResponse, data: Data? = nil) throws {
        guard let http = response as? HTTPURLResponse else { throw FlashFindError.message("Invalid HTTP response") }
        guard http.statusCode == 200 else {
            let object = data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]
            throw HTTPFailure(status: http.statusCode, code: object?["error"] as? String)
        }
    }
    public func login(password: String) async throws {
        var request = try request("session")
        request.httpMethod = "POST"; request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONSerialization.data(withJSONObject: ["username": settings.username, "password": password])
        let (data, response) = try await session.data(for: request); try check(response, data: data)
        struct Session: Decodable { let token: String }
        token = try JSONDecoder().decode(Session.self, from: data).token
    }
    public func manifest() async throws -> Manifest {
        let (data, response) = try await session.data(for: request("manifest")); try check(response, data: data)
        let manifest = try JSONDecoder().decode(Manifest.self, from: data)
        guard manifest.schemaVersion == 1, Set(manifest.sources.map(\.id)).count == manifest.sources.count,
              manifest.capabilities.contains("upsert_v1"), manifest.capabilities.contains("delete_v1") else { throw FlashFindError.message("Unsupported manifest") }
        return manifest
    }
    public func snapshot(source: Source) async throws -> URL {
        let (url, response) = try await session.download(for: request("sources/\(source.id)/snapshot/\(source.snapshotID)"))
        do {
            let errorData = (response as? HTTPURLResponse)?.statusCode == 200 ? nil : try? Data(contentsOf: url)
            try check(response, data: errorData); return url
        } catch { try? FileManager.default.removeItem(at: url); throw error }
    }
    public func changes(source: Source, cursor: String, until: String?) async throws -> ChangePage {
        var query = [URLQueryItem(name: "generation", value: source.generation), URLQueryItem(name: "after_change_id", value: cursor), URLQueryItem(name: "limit", value: "1000")]
        if let until { query.append(URLQueryItem(name: "until_change_id", value: until)) }
        let (data, response) = try await session.data(for: request("sources/\(source.id)/changes", query: query)); try check(response, data: data)
        return try JSONDecoder().decode(ChangePage.self, from: data)
    }
}

public struct HTTPFailure: LocalizedError {
    public let status: Int
    public let code: String?
    public init(status: Int, code: String? = nil) { self.status = status; self.code = code }
    public var errorDescription: String? {
        switch status {
        case 401: return "NAS 账号或密码无效，或登录已过期"
        case 403: return "当前账号无权访问该目录"
        case 409: return "索引或权限已更新，请重新同步"
        case 429: return "登录尝试过多，请稍后再试"
        case 503 where code == "setup_required": return "NAS 索引服务尚未初始化，请先在管理页面完成初始化"
        case 503: return "暂时无法验证 NAS 文件权限，请检查 SMB 服务后重试"
        default: return "服务器返回 HTTP \(status)"
        }
    }
}

/// 凭据存储的**门面**，实现已迁到 `CredentialStore`（本机凭据文件）。
///
/// 名字保留 `SecureStorage` 而不改：它是 20 多处既有调用的入口，
/// 逐处改名换不来任何行为收益，只会把这一轮的改动面撑大。
/// 只把实现换掉 —— 语义（`save` / `read` / `delete`、读不到返回 nil）与钥匙串时代完全一致，
/// 因此调用方一行都不用动。
///
/// 实现已迁到 `CredentialStore`，后端由 App 装配（GUI 走系统钥匙串）。
///
/// 历史判断的来龙去脉见 `KeychainSecretStore`： 本机复测纠正了
/// 「ad-hoc 换 cdhash 必然弹窗」这条旧结论；真正的硬门槛是 Data Protection
/// 钥匙串要 entitlement，缺了会自动退到经典钥匙串（见同名文件的实测状态码）。
public enum SecureStorage {
    /// - Parameter reason: 哪一步动的（诊断用）。见 `CredentialStore.Mutation`。
    public static func save(_ value: String, account: String,
                            identity: CredentialIdentity? = nil,
                            reason: String = "未标注") throws {
        try CredentialStore.save(value, account: account, identity: identity, reason: reason)
    }
    /// `allowInteraction` 现在没有作用（存储不需要任何交互），保留只为不牵动调用方。
    ///
    /// `identity` 非空时按信封校验归属：**与目标不匹配的凭据视同不存在**。
    public static func read(account: String, identity: CredentialIdentity? = nil,
                            allowInteraction: Bool = false) -> String? {
        CredentialStore.read(account: account, identity: identity, allowInteraction: allowInteraction)
    }
    /// 删除已保存的凭据。移除 NAS 时调用，避免文件里留下无人认领的条目。
    ///
    /// - Parameter reason: 哪一步动的（诊断用）。
    @discardableResult
    public static func delete(account: String, reason: String = "未标注") -> Bool {
        CredentialStore.delete(account: account, reason: reason)
    }
}
