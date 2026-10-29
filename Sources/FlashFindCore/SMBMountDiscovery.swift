import Foundation
import Darwin
import CryptoKit

/// 本机已挂载的 NAS 共享。
///
/// 名字沿用 `SMBMountCandidate`：它最初只收 smbfs，现在 smbfs / afpfs 都收
/// （见 `candidate(origin:mountPath:fileSystem:)`），但语义没变——
/// 「这台 Mac 上已经连好、能直接当路径用的一个共享」。
public struct SMBMountCandidate: Identifiable, Hashable, Sendable {
    public let id: String
    public let host: String
    public let shareName: String
    public let mountRoot: URL
    public let username: String?
    public let safeSMBURL: String
    public static func parse(origin: String, mountPath: String) -> SMBMountCandidate? {
        guard origin.hasPrefix("//"), var components = URLComponents(string: "smb:" + origin),
              let host = components.host, !host.isEmpty else { return nil }
        let shares = components.path.split(separator: "/")
        guard shares.count == 1, !mountPath.isEmpty, mountPath.hasPrefix("/"), mountPath != "/" else { return nil }
        let user = components.user
        // Neither origin nor password is retained, logged or offered for import.
        components.user = nil; components.password = nil; components.query = nil; components.fragment = nil
        guard let safe = components.url?.absoluteString else { return nil }
        let identity = safe + "\0" + mountPath + "\0" + (user ?? "")
        let id = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
        return SMBMountCandidate(id: id, host: host, shareName: String(shares[0]), mountRoot: URL(fileURLWithPath: mountPath),
                                 username: user?.isEmpty == false ? user : nil, safeSMBURL: safe)
    }
    /// 判断某个来源的 SMB 端点是不是这条挂载记录本身的共享。
    ///
    /// 判定原来写在 App 层（AppModel），那里**没有测试能覆盖**——
    /// App 是可执行目标，测试目标依赖不了它。四条约束（协议是 smb、
    /// 端点不带账号口令、主机相同、共享名是路径第一段）任何一条松掉
    /// 都会把别的共享绑到这个来源上，所以搬到这里用测试钉住。
    ///
    /// - Note: 端点里带 user/password 的一律不算匹配：那种 URL 不是
    ///   「这台机器已挂载的共享」，而是别人给的一条带凭据的连接串。
    public func matches(smbEndpoint: String) -> Bool {
        guard let url = URLComponents(string: smbEndpoint), url.scheme == "smb",
              url.user == nil, url.password == nil else { return false }
        return url.host?.lowercased() == host.lowercased()
            && url.path.split(separator: "/").first.map(String.init) == shareName
    }
    /// 这个来源能用到的挂载：主机精确匹配优先，认不出来时再按「共享名 + 登录账号」认亲。
    ///
    /// ## 为什么需要第二档（2026-10-29 真机报障）
    ///
    /// 用户来源里填的是**域名**（`nas.example.com`），Finder 里挂的是
    /// `smb://admin1@10.20.30.96/李青宇`。主机名永远对不上 ⇒ 旧实现一律当成
    /// 「没挂载」，双击打开浏览器。用户：「群晖登陆域名还是打不开本地的 smb 连接」。
    ///
    /// ★ 域名与 IP 之间**没有可靠的换算**，不能拿 DNS 判同一性：同一台机器上实测，
    ///   该域名被解析成代理的 fake-ip（`198.18.x.x`），反向解析挂载 IP 是 NXDOMAIN。
    ///   靠 DNS 只会在某些网络里灵、某些网络里静默不灵。
    ///
    /// 能用的旁证是「**谁在登录这个共享**」：SMB 的登录账号就是 NAS 账号，用户在同一台
    /// 设备上两处填的是同一个账号（同一台群晖不会给你两个不同的管理账号名）。
    /// 于是第二档要求：共享名相同 **且** 登录账号相同，**且命中的挂载只落在一台主机上**。
    ///
    /// ★ 为什么必须「唯一一台」：两台 NAS 都用同名管理账号挂着同名共享（`Photo` 这种
    ///   太常见）时，猜哪台都可能把用户带到**另一台设备上的同名文件**——看到的是别人的
    ///   照片、或者一个同名但内容不同的文件。那比老老实实打开网页糟得多，所以宁可退回网页。
    ///
    /// - Parameters:
    ///   - host: 来源主机（可能是域名、IP 或 QuickConnect ID）。
    ///   - shares: 本来源已授权的共享名（不带前导斜杠）。
    ///   - preferredUser: 本来源的登录账号（`smbUsername`，缺省时用 DSM 账号）。
    public static func matching(host: String, shares: Set<String>,
                                preferredUser: String?,
                                in mounts: [SMBMountCandidate]) -> [SMBMountCandidate] {
        let exact = mounts.filter {
            $0.host.caseInsensitiveCompare(host) == .orderedSame && shares.contains($0.shareName)
        }
        if !exact.isEmpty { return exact }
        guard let user = preferredUser?.trimmingCharacters(in: .whitespacesAndNewlines),
              !user.isEmpty else { return [] }
        let byAccount = mounts.filter {
            shares.contains($0.shareName)
                && $0.username?.caseInsensitiveCompare(user) == .orderedSame
        }
        guard !byAccount.isEmpty else { return [] }
        let hosts = Set(byAccount.map { $0.host.lowercased() })
        return hosts.count == 1 ? byAccount : []
    }

    public static func discover() throws -> [SMBMountCandidate] {
        var mounts: UnsafeMutablePointer<statfs>?
        let count = getmntinfo(&mounts, MNT_NOWAIT)
        guard count > 0, let mounts else { throw FlashFindError.message("无法读取本机挂载表：" + String(cString: strerror(errno))) }
        var found: [SMBMountCandidate] = []
        for index in 0..<Int(count) {
            var mount = mounts[index]
            let type = withUnsafePointer(to: &mount.f_fstypename) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let origin = withUnsafePointer(to: &mount.f_mntfromname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            let path = withUnsafePointer(to: &mount.f_mntonname) { String(cString: UnsafeRawPointer($0).assumingMemoryBound(to: CChar.self)) }
            if let candidate = candidate(origin: origin, mountPath: path, fileSystem: type) { found.append(candidate) }
        }
        return found.sorted { $0.mountRoot.path < $1.mountRoot.path }
    }

    /// 一条挂载记录能不能算「这台 Mac 上已经连好的共享」。
    ///
    /// `smbfs` 与 `afpfs` 都算：打开文件用的是挂载后的**文件系统路径**，
    /// 与传输协议无关。老款群晖（DS124 这类）很多人是早年用 AFP 连的，
    /// 只认 smbfs 会让它「能搜到、点开却报尚未连接共享」——真机 bug。
    ///
    /// 别的文件系统一律不算：本地磁盘、NFS、WebDAV 与「这台 NAS 的这个共享」
    /// 不是一回事，误认会把结果解析到不相干的目录里。
    public static func candidate(origin: String, mountPath: String, fileSystem: String) -> SMBMountCandidate? {
        guard fileSystem == "smbfs" || fileSystem == "afpfs" else { return nil }
        return parse(origin: origin, mountPath: mountPath)
    }
}

/// Test stores can be in memory, so model regressions never touch production preferences.
public protocol ClientPreferences: AnyObject {
    func object(forKey key: String) -> Any?
    func set(_ value: Any?, forKey key: String)
}
extension UserDefaults: ClientPreferences {}
public extension ClientPreferences {
    func string(forKey key: String) -> String? { object(forKey: key) as? String }
    func bool(forKey key: String) -> Bool { object(forKey: key) as? Bool ?? false }
    func stringArray(forKey key: String) -> [String]? { object(forKey: key) as? [String] }
    func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
}

public final class InMemoryClientPreferences: ClientPreferences {
    private var values: [String: Any]
    public init(values: [String: Any] = [:]) { self.values = values }
    public func object(forKey key: String) -> Any? { values[key] }
    public func set(_ value: Any?, forKey key: String) { values[key] = value }
}
