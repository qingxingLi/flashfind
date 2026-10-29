import Foundation
import Darwin

/// WebDAV 的远端目录与本机挂载点。
public struct WebDAVMountCandidate: Sendable {
    public let endpoint: URL
    public let mountRoot: URL
    /// 用于匹配挂载的登录账号，不保存口令。
    public let username: String?

    /// 只有 /dav 根及其子目录对应 OpenList 的搜索路径。
    public var isDAVEndpoint: Bool {
        let path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return path == "dav" || path.hasPrefix("dav/")
    }

    /// /dav 后的逻辑根；空值表示整站。
    public var logicalRoot: String {
        let path = endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard path == "dav" || path.hasPrefix("dav/") else { return path }
        return String(path.dropFirst(3))
    }

    public init(endpoint: URL, mountRoot: URL) {
        self.init(endpoint: endpoint, mountRoot: mountRoot, username: endpoint.user)
    }

    public static func parse(origin: String, mountPath: String) -> Self? {
        guard var components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.query == nil, components.fragment == nil,
              mountPath.hasPrefix("/"), mountPath != "/" else { return nil }
        let user = components.user
        components.user = nil; components.password = nil
        guard let endpoint = components.url else { return nil }
        return Self(endpoint: endpoint, mountRoot: URL(fileURLWithPath: mountPath), username: user)
    }

    private init(endpoint: URL, mountRoot: URL, username: String?) {
        self.endpoint = endpoint
        self.mountRoot = mountRoot
        self.username = username.flatMap { $0.isEmpty ? nil : $0 }
    }

    /// 先匹配站点，再匹配同账号的唯一主机，最后匹配协议和端口相同的唯一匿名根挂载。
    /// 不用 DNS 认亲：代理可能返回虚拟 IP；候选不唯一时回退网页。
    public static func matching(origin: WebOrigin, preferredUser: String?,
                                in mounts: [Self]) -> [Self] {
        let exact = mounts.filter { origin.admits($0.endpoint) }
        if !exact.isEmpty { return exact }
        let user = preferredUser?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let user, !user.isEmpty {
            let byAccount = mounts.filter {
                $0.username?.caseInsensitiveCompare(user) == .orderedSame
            }
            if !byAccount.isEmpty,
               Set(byAccount.map { $0.endpoint.host?.lowercased() ?? "" }).count == 1 {
                return byAccount
            }
        }
        let anonymous = mounts.filter {
            $0.username == nil
                && $0.endpoint.scheme?.lowercased() == origin.scheme
                && ($0.endpoint.port ?? WebOrigin.defaultPort(for: origin.scheme)) == origin.port
                && $0.logicalRoot.isEmpty
        }
        return anonymous.count == 1 ? anonymous : []
    }

    public static func discover() -> [Self] {
        var entries: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&entries, MNT_NOWAIT)
        guard count > 0, let entries else { return [] }
        return (0..<Int(count)).compactMap { index in
            var entry = entries[index]
            let type = withUnsafePointer(to: &entry.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            guard type == "webdav" else { return nil }
            let origin = withUnsafePointer(to: &entry.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let path = withUnsafePointer(to: &entry.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            return parse(origin: origin, mountPath: path)
        }
    }
}
