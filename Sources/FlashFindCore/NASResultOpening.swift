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
            // 这里允许「只按共享名认」：它没有账号证据，退路又只是一张登录页。
            if let local = localMountedTarget(for: row, locator: locator, smbMounts: smbMounts,
                                              allowShareNameOnly: true, verify: verify) {
                return .mountedFile(local)
            }
            // 设备侧共享表没覆盖这条路径（它的 `file.share.list` 只回这个账号看得到的
            // 那几个共享）时，退回「按本机挂载的共享名认」—— 见下面的说明。
            if let local = mountedShareMatchingPathSegment(for: row, smbMounts: smbMounts, verify: verify) {
                return .mountedFile(local)
            }
            return row.openTarget
        default:
            return row.openTarget
        }
    }

    /// 飞牛设备路径不对应挂载目录；仅按结果提供的共享名和相对路径定位。
    ///
    /// - Parameter allowShareNameOnly: 允许「只按共享名认」。飞牛传 true：
    ///   它没有账号证据（授权码登录，配置里账号恒为空），网页出口又只是站点首页
    ///   （浏览器没会话时就是登录页）—— 不放宽等于打开链完全不可用。
    ///   群晖 / OpenList 传 false（**默认**），它们的退路还能用，不值得冒
    ///   「打开另一台设备上同名文件」的风险。
    public static func localMountedTarget(for row: SearchResult, locator: NASLocator,
                                          smbMounts: [SMBMountCandidate],
                                          allowShareNameOnly: Bool = false,
                                          verify: Bool = true) -> URL? {
        guard case .smbLocation(let smb) = row.openTarget else { return nil }
        let parts = smb.path.split(separator: "/").map(String.init)
        guard parts.count >= 2 else { return nil }
        let share = parts[0]
        let inside = Array(parts.dropFirst())
        let mounts = SMBMountCandidate.matching(host: locator.host, shares: [share],
                                                preferredUser: locator.preferredSMBUser,
                                                allowShareNameOnly: allowShareNameOnly,
                                                in: smbMounts)
        for mount in mounts {
            if let local = localFile(segments: inside, mountRoot: mount.mountRoot, verify: verify) {
                return local
            }
        }
        return nil
    }

    /// 飞牛的**第二条路**：设备没给出覆盖这条路径的共享时，用「本机挂载的共享名
    /// 出现在结果路径里」来认。
    ///
    /// 为什么需要（2026-10-29 真机第三次报障）：这台 NAS 上实际有 **14 个 SMB 共享**
    /// （`smbutil view` 实测：Tools / 备份 / 共享文档 / Photos / docker …），而
    /// 闪寻账号的 `file.share.list` 只回了 **1 条**，且那条路径覆盖不到
    /// `/vol1/1000/共享文档/示例发票.pdf` —— 共享表是按账号可见性过滤的。
    /// 于是 `smbShareFor` 返回 null、结果行只能带网页地址，双击开到登录页；
    /// 而文件就躺在 `/Volumes/共享文档/示例发票.pdf`，就在用户眼前。
    ///
    /// 判据（都要满足，一条都不猜）：
    /// * 结果路径里有一段与本机某个 SMB 挂载的**共享名完全相同**；
    /// * 这个共享名在本机**只挂了一个**挂载点（同名挂两处就不认，宁可不打开）；
    /// * 拼出来的本地路径**确实存在**（`verify: true` 时；`verify: false` 是超时兜底，
    ///   此时文件存在性由打开动作自己确认）。
    ///
    /// 取**最靠右**的那一段：`/vol1/1000/共享文档/共享文档/x` 里右边那个才是共享根。
    ///
    /// 只给 fnOS 用：群晖 / OpenList 的路径坐标本身就是共享名（第一段），
    /// 走不到这里；它们的网页出口也还能用，不需要这条更宽的判据。
    static func mountedShareMatchingPathSegment(for row: SearchResult,
                                                smbMounts: [SMBMountCandidate],
                                                verify: Bool = true) -> URL? {
        let segments = row.path.split(separator: "/").map(String.init)
        guard segments.count >= 2 else { return nil }
        for index in stride(from: segments.count - 1, through: 1, by: -1) {
            let name = segments[index]
            let mounts = smbMounts.filter { $0.shareName == name }
            // 一个都没挂：继续找更浅的那一段；挂了两个：这条名字不能用（同名挂两处 = 分不清）。
            guard mounts.count == 1 else { continue }
            let mountRoot = mounts[0].mountRoot
            let inside = Array(segments[(index + 1)...])
            if inside.isEmpty {
                // 结果行本身就是这个共享根（文件夹）。
                if verify, !FileManager.default.fileExists(atPath: mountRoot.path) { continue }
                return mountRoot
            }
            if let local = localFile(segments: inside, mountRoot: mountRoot, verify: verify) {
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
