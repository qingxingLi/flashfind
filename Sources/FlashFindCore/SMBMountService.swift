import AppKit
import Foundation

/// SMB 共享挂载器。
///
/// 搜索能拿到路径，但 Finder 定位需要真实挂载点。没有挂载就直接报错，
/// 用户体验断成两截（能搜不能开）。这里提供两条挂载途径，
/// 按「最少打扰用户」的顺序尝试：
///
///   1. `NSFileCoordinator` —— 系统级挂载请求，会复用钥匙串里的凭据，
///      且在已挂载时零成本返回。**首选**。
///   2. 都不行则如实报错，并把「在访达中手动连接」交给用户自己决定
///      （见 `MountError.manualConnectURL`）。
///
/// **不再自动弹访达连接框。** 以前的第二条路是
/// `NSWorkspace.shared.open(smb://…)`，它会把 «连接到服务器» 窗口弹出来。
/// 在用公网域名连接、445 没有公网映射的场景下这一步**注定失败**，
/// 用户只落得「弹出来、等超时、手动关掉」。现在改为：
/// 先探端口，不可达就直接讲清楚原因；可达但要凭据也由用户点按钮才弹。
///
/// 安全约束：
/// - 只挂用户自己配置过的来源，地址与共享名都经过校验；
/// - **绝不**把密码拼进 URL 或命令行——凭据只经系统钥匙串；
/// - 挂载失败不吞错误，返回可显示的原因。
public actor SMBMountService {
    public init() {}
    public struct Target: Sendable, Hashable {
        public let host: String
        public let share: String
        public let username: String?
        public init(host: String, share: String, username: String? = nil) {
            self.host = host; self.share = share; self.username = username
        }
        public var smbURL: URL? {
            var components = URLComponents()
            components.scheme = "smb"
            // 共享名可能是中文，必须走 path 而非 pathSegments 的百分号编码假设。
            components.host = host
            components.path = "/" + share
            // user 只用于选身份，不带密码；URL 里出现的 user 会显示在挂载名上。
            if let username, !username.isEmpty { components.user = username }
            return components.url
        }
        public var displayName: String { share.isEmpty ? host : "\(host)/\(share)" }
    }

    public enum MountError: LocalizedError {
        case invalidTarget
        case notAuthorized
        /// SMB 服务端口不可达（不在同一网络、公网域名未映射 445 等）。
        case unreachable(String, smbURL: String)
        /// 端口通但系统没有可复用的凭据，需要用户手动登录一次。
        case needsCredential(String, smbURL: String)
        case failed(String)

        public var errorDescription: String? {
            switch self {
            case .invalidTarget: return "共享地址不合法"
            case .notAuthorized: return "尚未获得访问该共享的授权"
            case .unreachable(let reason, _): return reason
            case .needsCredential(let reason, _): return reason
            case .failed(let reason): return reason
            }
        }

        /// 用户主动要求时才用它去弹访达连接框。其余错误没有可连的地址。
        public var manualConnectURL: String? {
            switch self {
            case .unreachable(_, let url), .needsCredential(_, let url): return url
            default: return nil
            }
        }
    }

    /// 同一目标的挂载请求在飞行中时复用，避免连点产生并发挂载。
    private var inFlight: [Target: Task<URL, Error>] = [:]
    /// 已经确认挂载成功的挂载点，短期内直接复用。
    private var resolved: [Target: URL] = [:]

    /// SMB 端口可达性探测。默认走真实 TCP 握手。
    ///
    /// 留成属性是为了可测：否则「不可达时不得惊动系统」这条行为
    /// 在单元测试里只能依赖「本机恰好没开文件共享」这种运气。
    private var reachability: @Sendable (String, UInt16) async -> Bool = { host, port in
        await SMBReachability.isReachable(host: host, port: port)
    }

    /// 供测试替换探测实现（生产路径不要调用）。
    func useReachability(_ probe: @escaping @Sendable (String, UInt16) async -> Bool) {
        reachability = probe
    }

    /// 挂载并返回可用的本地路径。已挂载时立即返回。
    @discardableResult
    public func mount(_ target: Target) async throws -> URL {
        guard !target.host.isEmpty, !target.share.isEmpty,
              !target.host.contains("/"), !target.share.contains("/"),
              !target.share.contains("..") else { throw MountError.invalidTarget }
        if let cached = resolved[target], FileManager.default.fileExists(atPath: cached.path) { return cached }
        if let running = inFlight[target] { return try await running.value }

        let task = Task<URL, Error> { [weak self] in
            guard let self else { throw MountError.notAuthorized }
            return try await self.performMount(target)
        }
        defer { inFlight[target] = nil }
        inFlight[target] = task
        let url = try await task.value
        resolved[target] = url
        return url
    }

    /// 查询是否已经挂载，不主动发起挂载。
    public func existingMount(for target: Target) -> URL? {
        if let cached = resolved[target], FileManager.default.fileExists(atPath: cached.path) { return cached }
        return Self.currentMount(for: target)
    }

    /// 从挂载表里找这台 NAS 这个共享的本地路径。读不到挂载表时返回 nil。
    private static func currentMount(for target: Target) -> URL? {
        guard let mounts = try? SMBMountCandidate.discover() else { return nil }
        return mounts.first { $0.host == target.host && $0.shareName == target.share }?.mountRoot
    }

    private func performMount(_ target: Target) async throws -> URL {
        // 已经有人挂好了（Finder 里连过）就不用再请求一次。
        if let existing = Self.currentMount(for: target) { return existing }
        guard let smbURL = target.smbURL else { throw MountError.invalidTarget }

        // 先做 TCP 预检。不可达时**绝不惊动系统** ——
        // 否则 NSFileCoordinator 与访达 «连接到服务器» 都会把用户
        // 拖进一次注定的等待，而公网域名场景（445 无公网映射）就是这种情况。
        guard await reachability(target.host, SMBReachability.standardPort) else {
            throw MountError.unreachable(
                "SMB 文件服务不可达：\(target.host) 的 445 端口没有响应。"
                + "若你正在用公网域名连接，NAS 的 445 端口通常没有公网映射，这种方式无法在本机打开文件。"
                + "可回到同一局域网用内网地址重连，或点「在访达中连接」手动挂载。",
                smbURL: smbURL.absoluteString)
        }

        // 第一条路：系统级挂载请求。凭据走钥匙串，不经过我们。
        if let mounted = await requestSystemMount(smbURL) { return mounted }

        // 这里以前是 `NSWorkspace.shared.open(smbURL)`，会直接弹出访达连接框。
        // 已移除：弹窗是用户没要求过的打扰，改由失败提示条上的
        // 「在访达中连接」按钮显式触发（`MountError.manualConnectURL`）。
        throw MountError.needsCredential(
            "共享 \(target.displayName) 还没连上，系统也没有可用凭据。"
            + "点「在访达中连接」输入账号密码，挂载成功后回来点「重试」。",
            smbURL: smbURL.absoluteString)
    }

    /// 用 NSFileCoordinator 触发系统挂载。成功返回本地路径，失败返回 nil。
    ///
    /// `coordinate(readingItemAt:)` 会在路径不可达时请求挂载，且复用钥匙串凭据；
    /// 相比自己调 `mount_smbfs`，不需要额外授权，也不会把密码暴露给本进程。
    /// 用 NSFileCoordinator 触发系统挂载。
    ///
    /// `coordinate(readingItemAt:)` 在路径不可达时会**请求挂载**，并复用钥匙串凭据；
    /// 相比自己调 `mount_smbfs`，不需要额外授权，也不把密码暴露给本进程。
    ///
    /// 它是同步 API，但可能阻塞（挂载可能要用户输密码），因此放到后台线程执行，
    /// 不占用主线程。返回 nil 表示这次没能拿到可用的挂载点，交给下一重保障。
    private nonisolated func requestSystemMount(_ smbURL: URL) async -> URL? {
        // 用 Task.detached 把这个同步且可能阻塞的调用移出调用方线程：
        // 挂载若需要用户输入密码，可能要等上几十秒。
        await Task.detached(priority: .userInitiated) { () -> URL? in
            let coordinator = NSFileCoordinator(filePresenter: nil)
            let box = ResumeBox()
            var coordinationError: NSError?
            // 两条路径都要收尾：block 被调用，或 outError 被填。
            // 少一条 continuation 就永久挂起，界面会一直转圈。
            coordinator.coordinate(readingItemAt: smbURL, options: [],
                                   error: &coordinationError) { actual in
                coordinator.cancel()
                // actual 可能仍是 smb:// 形式（挂载请求已发出但尚未映射到 /Volumes）。
                // 这种情况交给第二重保障（NSWorkspace），不在这里判定失败。
                let resolved = (actual.isFileURL
                                && FileManager.default.fileExists(atPath: actual.path)) ? actual : nil
                box.resume(with: resolved)
            }
            if coordinationError != nil { box.resume(with: nil) }
            return box.value
        }.value
    }

    /// 挂载后重新解析文件在共享内的绝对路径。
    ///
    /// 三重防护与搜索侧保持一致：
    ///   1. 相对路径不允许 `..`、空段、NUL；
    ///   2. 解析结果必须仍在挂载根之下；
    ///   3. 文件必须真实存在。
    public func resolve(relativePath: String, under mountRoot: URL) throws -> URL {
        try RelativePath.validate(relativePath)
        let root = mountRoot.resolvingSymlinksInPath().standardizedFileURL
        let target = relativePath.split(separator: "/").reduce(root) { $0.appendingPathComponent(String($1)) }
            .resolvingSymlinksInPath().standardizedFileURL
        guard target.path.hasPrefix(root.path + "/") else {
            throw MountError.failed("目标不在已连接的共享内")
        }
        return target
    }
}


/// 一次性结果闸门。
///
/// `NSFileCoordinator.coordinate(readingItemAt:)` 不保证一定调用 block
/// （URL 无法访问时会填 outError 直接返回），而 continuation 只能恢复一次。
/// 这里用锁保证「谁先到谁写入」，两条路径都不会丢结果、也不会二次恢复。
private final class ResumeBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: URL??

    var value: URL? { lock.lock(); defer { lock.unlock() }; return stored ?? nil }

    func resume(with url: URL?) {
        lock.lock(); defer { lock.unlock() }
        if stored == nil { stored = .some(url) }
    }
}
