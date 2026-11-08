import Foundation
import FlashFindCore

/// 按需探测「这台 NAS 此刻在不在线」。
///
/// ## 为什么必须是一次真实的 HTTP 往返（2026-11-08 现场）
///
/// 用户报障时，来源配的是 `10.20.30.96:5001`。本机路由把这段私网流量交给代理
/// 隧道（`utun8`，网关 `198.18.0.1`），域名也解析成 fake-ip。实测：
///
/// | 判据 | 结果 |
/// | --- | --- |
/// | `ping` | 100% 丢包 |
/// | 裸 TCP `connect` 到 5001/5000/445/443 | **全部秒开** |
/// | 真实 HTTP 请求（HTTPS 5001 / HTTP 5000 / 域名） | **全部超时、零响应** |
///
/// 所以 `SMBReachability` / `smbPortReachable` 那种 socket 探活在这里会**假通过**，
/// 拿它判在线等于没修。唯一可靠的轻量证据是「TLS 握手完成 + 收到 HTTP 响应行」，
/// `URLSession.data(for:)` 恰好同时满足这两条。
///
/// ## ★ 自签证书必须放行
///
/// 群晖这类设备常年用自签证书，项目自己也有证书固定记录（`source-trust.json`）。
/// 若这里走默认校验，设备明明在线却会在 TLS 阶段失败，被误判成离线——那是硬规则
/// 「缺证据 ≠ 反证据」的反面。探活请求**不带任何凭据、不取业务数据**，
/// 所以接受 serverTrust 只为完成握手，不改变任何搜索/登录链路的证书策略。
///
/// ## ★ 探活失败只改显示，不动会话
///
/// 本文件从不写 `ready`、不注销、不删凭据、不拆核心会话。一次超时不代表这台
/// 来源被删了；设备回来后下一次探活拿到响应，`DeviceReachability.display` 会自动
/// 把「已连接」放回去。
@MainActor
final class DevicePresenceProbe {
    static let shared = DevicePresenceProbe()

    /// 每个来源上次探活时间，配合 Core 的冷却判据避免重复打网络。
    private var lastProbeAt: [String: Date] = [:]

    private let requestTimeout: TimeInterval = 3

    private init() {}

    /// 这一次入口要不要真的发请求。
    func shouldProbe(config: NASSourceConfig, ready: Bool, now: Date = Date()) -> Bool {
        DeviceReachability.shouldProbe(ready: ready,
                                       enabled: config.enabled,
                                       isConnectConfigured: config.isConnectConfigured,
                                       lastProbeAt: lastProbeAt[config.id],
                                       now: now)
    }

    /// 发一次轻量请求，把传输结果翻译成 Core 的证据枚举。
    ///
    /// 群晖打不需要登录的 `SYNO.API.Info`；其它品牌打配置根路径。
    /// 只要设备回了 HTTP 响应行（200/401/404 都算）就证明服务在监听。
    func probe(config: NASSourceConfig) async -> DeviceReachability.Evidence {
        guard let url = DeviceReachability.probeURL(
            scheme: config.usesPlainHTTP ? "http" : "https",
            host: config.hostName,
            port: config.effectivePort,
            basePath: config.effectiveBasePath,
            isSynology: config.vendor == .synology) else { return .unknown }
        lastProbeAt[config.id] = Date()

        let delegate = ServerTrustDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = requestTimeout
        configuration.timeoutIntervalForResource = requestTimeout + 1
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }

        var request = URLRequest(url: url)
        request.timeoutInterval = requestTimeout
        request.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        request.httpMethod = "GET"

        do {
            let (_, response) = try await session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode
            return DeviceReachability.evidence(statusCode: status, transportErrorCode: nil)
        } catch {
            let code = (error as? URLError)?.code.rawValue
            return DeviceReachability.evidence(statusCode: nil, transportErrorCode: code)
        }
    }

    /// 只用于探活的证书处理：接受 serverTrust 完成握手，不做业务校验。
    private final class ServerTrustDelegate: NSObject, URLSessionDelegate {
        func urlSession(_ session: URLSession,
                        didReceive challenge: URLAuthenticationChallenge,
                        completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) {
            guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
                  let serverTrust = challenge.protectionSpace.serverTrust else {
                completionHandler(.performDefaultHandling, nil)
                return
            }
            completionHandler(.useCredential, URLCredential(trust: serverTrust))
        }
    }
}
