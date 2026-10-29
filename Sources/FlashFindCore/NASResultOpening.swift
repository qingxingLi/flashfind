import Foundation

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

    /// 超时兜底只映射路径，不访问可能阻塞的网络卷；文件是否存在由打开动作确认。
    public static func unverifiedFallbackTarget(for row: SearchResult, vendor: NASSourceConfig.Vendor,
                                                origin: WebOrigin, locator: NASLocator,
                                                smbMounts: [SMBMountCandidate],
                                                webDAVMounts: [WebDAVMountCandidate]) throws -> SearchOpenTarget {
        try target(for: row, vendor: vendor, origin: origin, locator: locator,
                   smbMounts: smbMounts, webDAVMounts: webDAVMounts, verify: false)
    }

    /// - Parameter verify: 是否核验文件真实存在（含符号链接逃逸检查）。
    ///   传 `false` 只做语义映射，见 `unverifiedFallbackTarget` 的说明。
    public static func target(for row: SearchResult, vendor: NASSourceConfig.Vendor,
                              origin: WebOrigin, locator: NASLocator,
                              smbMounts: [SMBMountCandidate], webDAVMounts: [WebDAVMountCandidate],
                              verify: Bool = true) throws -> SearchOpenTarget {
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
            // OpenList 只认 WebDAV 挂载；来源域名与挂载地址可以不同。
            for mount in WebDAVMountCandidate.matching(origin: origin, preferredUser: locator.preferredSMBUser,
                                                       in: webDAVMounts) where mount.isDAVEndpoint {
                if let local = localFile(row.path, remoteRoot: mount.logicalRoot,
                                         mountRoot: mount.mountRoot, verify: verify) {
                    return .mountedFile(local)
                }
            }
            return .webURL(fallback)
        case .synology:
            guard let share = row.path.split(separator: "/").first.map(String.init) else {
                throw FlashFindError.message("无效的共享路径")
            }
            // 匹配规则允许来源域名与挂载地址不同，再优先选当前账号。
            let mounts = SMBMountCandidate.matching(host: locator.host, shares: [share],
                                                    preferredUser: locator.preferredSMBUser,
                                                    in: smbMounts)
                .sorted {
                    ($0.username == locator.preferredSMBUser ? 0 : 1) < ($1.username == locator.preferredSMBUser ? 0 : 1)
                }
            for mount in mounts {
                if let local = localFile(row.path, remoteRoot: "/" + share, mountRoot: mount.mountRoot, verify: verify) {
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
        case .fnos:
            // 飞牛的设备路径不能直接映射到挂载点，只使用核心返回的共享名和相对路径。
            return localMountedTarget(for: row, locator: locator, smbMounts: smbMounts, verify: verify)
                .map { .mountedFile($0) } ?? row.openTarget
        default:
            return row.openTarget
        }
    }

    /// 飞牛设备路径不对应挂载目录；仅按结果提供的共享名和相对路径定位。
    public static func localMountedTarget(for row: SearchResult, locator: NASLocator,
                                          smbMounts: [SMBMountCandidate],
                                          verify: Bool = true) -> URL? {
        guard case .smbLocation(let smb) = row.openTarget else { return nil }
        let parts = smb.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let share = parts[0]
        let inside = Array(parts.dropFirst())
        let mounts = SMBMountCandidate.matching(host: locator.host, shares: [share],
                                                preferredUser: locator.preferredSMBUser,
                                                in: smbMounts)
        for mount in mounts {
            if let local = localFile(segments: inside, mountRoot: mount.mountRoot, verify: verify) {
                return local
            }
        }
        return nil
    }

    /// 按「相对段」拼接挂载点（飞牛那种路径坐标与挂载点结构无关的情形）。
    private static func localFile(segments: [String], mountRoot: URL, verify: Bool = true) -> URL? {
        guard !segments.isEmpty,
              segments.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              RelativePath.isSafe(segments.joined(separator: "/")) else { return nil }
        let file = segments.reduce(mountRoot) { $0.appendingPathComponent($1) }
        guard verify else { return file }
        let root = mountRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = file.resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/"),
              FileManager.default.fileExists(atPath: target.path) else { return nil }
        return target
    }

    private static func localFile(_ path: String, remoteRoot: String, mountRoot: URL,
                                  verify: Bool = true) -> URL? {
        guard remoteRoot.isEmpty || path == remoteRoot || path.hasPrefix(remoteRoot + "/") else { return nil }
        let inside = remoteRoot.isEmpty ? String(path.dropFirst()) : RelativePath.relative(path, under: remoteRoot)
        guard inside.isEmpty || RelativePath.isSafe(inside) else { return nil }
        // 路径归属与 `..` 已在上面用纯字符串判完；不核验时不能再碰文件系统 ——
        // 网络卷的 stat 可能等上百秒，而这里正是超时兜底那条路。
        guard verify else {
            return inside.isEmpty ? mountRoot : mountRoot.appendingPathComponent(inside)
        }
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
        // 飞牛在 verifiedOpenTarget 中处理挂载和回退。
        guard vendor == .synology || vendor == .openlist else { return row.openTarget }
        guard let origin = webOrigin else { throw FlashFindError.message("来源地址无效") }
        let snapshot = locatorSnapshot
        // `getmntinfo` 只读内核里的挂载表（本机实测 0.0ms），两段共用一次。
        let smbMounts = vendor == .synology ? (try? SMBMountCandidate.discover()) ?? [] : []
        let davMounts = vendor == .openlist ? WebDAVMountCandidate.discover() : []
        // 网络卷核验可能超时，兜底先保留已匹配的挂载路径。
        let fallback = try NASResultOpening.unverifiedFallbackTarget(
            for: row, vendor: vendor, origin: origin, locator: snapshot,
            smbMounts: smbMounts, webDAVMounts: davMounts)
        // 实机网络卷的 stat 曾等待 127 秒；两秒内核验不完就用上面的兜底。
        return try await NASResultOpening.checkMounts(fallback: fallback) {
            try NASResultOpening.target(for: row, vendor: vendor, origin: origin, locator: snapshot,
                                        smbMounts: smbMounts, webDAVMounts: davMounts)
        }
    }
}
