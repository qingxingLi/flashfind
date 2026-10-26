import Foundation
import Darwin

/// WebDAV 的远端目录与本机挂载点；不把它混入 SMB 共享候选。
public struct WebDAVMountCandidate: Sendable {
    public let endpoint: URL
    public let mountRoot: URL

    public static func parse(origin: String, mountPath: String) -> Self? {
        guard var components = URLComponents(string: origin),
              let scheme = components.scheme?.lowercased(), ["http", "https"].contains(scheme),
              components.host?.isEmpty == false, components.query == nil, components.fragment == nil,
              mountPath.hasPrefix("/"), mountPath != "/" else { return nil }
        components.user = nil; components.password = nil
        guard let endpoint = components.url else { return nil }
        return Self(endpoint: endpoint, mountRoot: URL(fileURLWithPath: mountPath))
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

/// 打开时核验挂载；失去挂载或文件已不存在时保留网页出口，不发起自动挂载。
public enum NASResultOpening {
    /// 内核的网络文件 stat 无法取消；只让首个结果生效，超时后的核验不会再触发动作。
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<SearchOpenTarget, Error>?
        init(_ continuation: CheckedContinuation<SearchOpenTarget, Error>) { self.continuation = continuation }
        func finish(_ result: Result<SearchOpenTarget, Error>) {
            lock.lock()
            let current = continuation
            continuation = nil
            lock.unlock()
            current?.resume(with: result)
        }
    }

    static func checkMounts(fallback: SearchOpenTarget, timeout: TimeInterval = 2,
                            resolve: @escaping @Sendable () throws -> SearchOpenTarget) async throws -> SearchOpenTarget {
        try await withCheckedThrowingContinuation { continuation in
            let pending = Pending(continuation)
            DispatchQueue.global(qos: .userInitiated).async { pending.finish(Result { try resolve() }) }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                pending.finish(.success(fallback))
            }
        }
    }

    public static func target(for row: SearchResult, vendor: NASSourceConfig.Vendor,
                              origin: WebOrigin, locator: NASLocator,
                              smbMounts: [SMBMountCandidate], webDAVMounts: [WebDAVMountCandidate]) throws -> SearchOpenTarget {
        guard row.sourceID == locator.sourceID, locator.contains(path: row.path),
              row.path.hasPrefix("/"), RelativePath.isSafe(String(row.path.dropFirst())) else {
            throw FlashFindError.message("目标不在此来源的授权目录中，请重新搜索")
        }
        switch vendor {
        case .openlist:
            guard case .webURL(let fallback) = row.openTarget,
                  origin.admits(fallback), fallback.path == row.path,
                  fallback.user == nil, fallback.password == nil,
                  fallback.query == nil, fallback.fragment == nil else {
                throw FlashFindError.message("没有有效的网页打开地址，请重新搜索")
            }
            // 同站点的 /dav 才对应 OpenList 逻辑路径；同主机 SMB 完全不参与。
            for mount in webDAVMounts where origin.admits(mount.endpoint) {
                let path = mount.endpoint.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
                guard path == "dav" || path.hasPrefix("dav/") else { continue }
                let remoteRoot = String(path.dropFirst(3))
                if let local = localFile(row.path, remoteRoot: remoteRoot, mountRoot: mount.mountRoot) {
                    return .mountedFile(local)
                }
            }
            return .webURL(fallback)
        case .synology:
            guard let share = row.path.split(separator: "/").first.map(String.init) else {
                throw FlashFindError.message("无效的共享路径")
            }
            let mounts = smbMounts.sorted {
                ($0.username == locator.preferredSMBUser ? 0 : 1) < ($1.username == locator.preferredSMBUser ? 0 : 1)
            }
            for mount in mounts where mount.host.lowercased() == locator.host.lowercased() && mount.shareName == share {
                if let local = localFile(row.path, remoteRoot: "/" + share, mountRoot: mount.mountRoot) {
                    return .mountedFile(local)
                }
            }
            var url = URLComponents()
            url.scheme = origin.scheme; url.host = origin.host; url.port = origin.port; url.path = "/"
            let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
            let path = row.path.addingPercentEncoding(withAllowedCharacters: unreserved)!
            url.queryItems = [URLQueryItem(name: "launchApp", value: "SYNO.SDS.App.FileStation3.Instance"),
                              URLQueryItem(name: "launchParam", value: "openfile=" + path)]
            guard let fallback = url.url else { throw FlashFindError.message("无法生成网页打开地址") }
            return .webURL(fallback)
        default:
            return row.openTarget
        }
    }

    private static func localFile(_ path: String, remoteRoot: String, mountRoot: URL) -> URL? {
        guard remoteRoot.isEmpty || path == remoteRoot || path.hasPrefix(remoteRoot + "/") else { return nil }
        let inside = remoteRoot.isEmpty ? String(path.dropFirst()) : RelativePath.relative(path, under: remoteRoot)
        guard inside.isEmpty || RelativePath.isSafe(inside) else { return nil }
        let root = mountRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = (inside.isEmpty ? root : root.appendingPathComponent(inside)).resolvingSymlinksInPath().standardizedFileURL
        guard target.path == root.path || target.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }
}

extension NASSearchProvider {
    public func preferredOpenTarget(_ row: SearchResult) async throws -> SearchOpenTarget {
        let vendor = config.vendor
        guard vendor == .synology || vendor == .openlist else { return row.openTarget }
        guard let origin = webOrigin else { throw FlashFindError.message("来源地址无效") }
        let snapshot = locatorSnapshot
        let fallback = try NASResultOpening.target(for: row, vendor: vendor, origin: origin, locator: snapshot,
                                                   smbMounts: [], webDAVMounts: [])
        // 实机网络卷的 stat 曾等待 127 秒；两秒内核验不完就使用网页。
        return try await NASResultOpening.checkMounts(fallback: fallback) {
            try NASResultOpening.target(for: row, vendor: vendor, origin: origin, locator: snapshot,
                                        smbMounts: vendor == .synology ? (try? SMBMountCandidate.discover()) ?? [] : [],
                                        webDAVMounts: vendor == .openlist ? WebDAVMountCandidate.discover() : [])
        }
    }
}
