import Foundation

/// 「已连接」与「设备此刻在线」是两件事——这里把后者做成有证据的判定。
///
/// ## 2026-11-08 报障（用户原话）
///
/// 「当前没有连接 oec 的 IP 地址 10.20.30.96，但是闪寻还判定已连接，
///   应该没有实际检测当前设备是否在线。」
///
/// `NASSearchProvider.ready` 只表示「上一次登录 + 选搜索范围成功了」，是个内存里的
/// 粘性标志：登录成功后，除非用户断开、搜索报鉴权失败、或本地核心子进程重启，
/// 否则它永远是 true。设备掉线而 App 不搜索时，设置页、菜单栏、侧边栏就一直写
/// 「已连接」。产品侧此前也没有独立的探活（`ConnectionDiagnostics.swift` 的注释直说
/// 「不假装探针」）。
///
/// ## ★★ 为什么绝不能用「TCP 能不能连上」当证据（本机实测）
///
/// 报障这台机器上，`10.20.30.96` 的路由走代理隧道 `utun8`（网关 `198.18.0.1`），
/// 域名也被解析成 fake-ip。此时：
///
/// - `ping` 100% 丢包；
/// - `nc -z` 探 5001 / 5000 / 445 / 443 / 80 **全部秒开**——代理先把 TCP 接了；
/// - 但发真实 HTTP 请求，HTTPS 5001 / HTTP 5000 / 域名**全部超时、零响应**。
///
/// 也就是说，裸 `connect()` 成功在这里是**假证据**：拿它判在线，这个 bug 会原样保留。
/// 唯一可靠的轻量判据是**完成一次应用层往返**（TLS 握手 + 收到 HTTP 响应行）。
/// 因此执行器必须走 `URLSession` 的 `data(for:)`，且允许自签证书——否则
/// 「设备在线但证书不受信」会被 TLS 失败误判成离线，是硬规则「缺证据 ≠ 反证据」的
/// 反面（把「不知道」当成了「不是」）。
///
/// ## ★ 探活失败只改显示，不动会话
///
/// 一次超时不等于这台 NAS 被删了。这里**从不**把 `ready` 清掉、不注销、不删凭据；
/// 设备回来之后下一次探活拿到响应就自动恢复显示。反过来也一样：探测结果是
/// `.unknown`（没探过 / 代理错误页 / 本机断网）时不许降级成「离线」——
/// 退路是死路时「保守」等于功能不可用。
public enum DeviceReachability {

    /// 一次探活拿到的证据。
    public enum Evidence: String, Sendable, Equatable {
        /// 完成了一次应用层往返：设备回了 HTTP 响应行（200/401/404 都算）。
        case responded
        /// 明确的设备侧失败：连不上、TLS 握手失败、请求超时。
        case unreachable
        /// 还不能下结论：没探过、被取消、5xx 代理错误页、本机网络不可用。
        case unknown
    }

    /// 界面该显示哪一种连接结论。
    public enum Display: String, Sendable, Equatable {
        /// 会话就绪，且没有反证 ⇒ 沿用原有的「已连接」。
        case connected
        /// 会话还在，但设备明确没有回应。
        case deviceOffline
        /// 本来就没连上（交给 `NASSourceRowModel` 的既有分支处理）。
        case notConnected
    }

    /// 列表行在「设备不可达」时的文案。单一出处，别在视图里再拼一遍。
    public static let offlineDetail = "设备不可达"

    /// 诊断摘要里「连接」一行在离线时的取值。
    public static let offlineDiagnostic = "设备不可达"

    /// 两次探活之间的最短间隔（秒）。按需触发入口可能会在很短时间内连着来几次。
    public static let probeCooldown: TimeInterval = 20

    /// ★ 唯一的展示判据。
    ///
    /// - `.unknown` Keep 原样：**没证据不是反证据**。设置页 / 搜索窗唤起会立刻发起
    ///   一次探测，所以「还没探过」不会长期停留在界面上。
    /// - `.unreachable` 才把「已连接」撤掉，且只撤显示。
    public static func display(ready: Bool, evidence: Evidence) -> Display {
        guard ready else { return .notConnected }
        if evidence == .unreachable { return .deviceOffline }
        return .connected
    }

    /// 把一次 URLSession 的结果翻译成证据。
    ///
    /// - Parameters:
    ///   - statusCode: 收到的 HTTP 状态码；`nil` 表示根本没拿到响应行。
    ///   - transportErrorCode: `URLError.Code.rawValue`；`nil` 表示传输层没报错。
    ///
    /// ★ 5xx 一律 `.unknown`：代理拦下来回的错误页也是 502/503，把它当
    ///   `.responded` 会重演「假在线」，当 `.unreachable` 又会冤枉好设备。
    /// ★ 本机自己没网（`notConnectedToInternet` / `networkConnectionLost`）也归
    ///   `.unknown`：那是本机的问题，不是这台设备的反证。
    public static func evidence(statusCode: Int?, transportErrorCode: Int?) -> Evidence {
        if let code = transportErrorCode {
            switch code {
            case -1009, -1005: return .unknown      // 本机无网 / 连接中途断
            case -999: return .unknown              // 主动取消
            default: return .unreachable            // 超时 / 连不上 / TLS 失败…
            }
        }
        guard let status = statusCode else { return .unknown }
        if (500...599).contains(status) { return .unknown }
        if (100...499).contains(status) { return .responded }
        return .unknown
    }

    /// 该不该现在发一次探活。
    ///
    /// 只对「已就绪、已启用、配置完整」的来源探；`ready == false` 的来源本来就没写
    /// 「已连接」，没必要为它打网络。冷却窗口内的重复入口直接跳过。
    public static func shouldProbe(ready: Bool,
                                   enabled: Bool,
                                   isConnectConfigured: Bool,
                                   lastProbeAt: Date?,
                                   now: Date,
                                   cooldown: TimeInterval = probeCooldown) -> Bool {
        guard ready, enabled, isConnectConfigured else { return false }
        guard let last = lastProbeAt else { return true }
        return now.timeIntervalSince(last) >= cooldown
    }

    /// 探活请求的目标 URL。
    ///
    /// 群晖用不需要登录的 `SYNO.API.Info`（`EndpointProbe.parseAPIInfo` 用的同一个公开
    /// 接口）；其它品牌请求配置的根路径——只要设备回了 HTTP 响应行就算在线，
    /// 401 / 404 都算，因为那恰恰证明服务在监听。
    ///
    /// ★ 刻意**不带任何凭据、不带查询词**：探活只是看设备在不在，不该在诊断日志里
    ///   留下可搜索的内容，也不该触发一次真搜索。
    public static func probeURL(scheme: String, host: String, port: Int,
                                basePath: String, isSynology: Bool) -> URL? {
        guard !host.isEmpty, port > 0 else { return nil }
        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = port
        if isSynology {
            components.path = "/webapi/query.cgi"
            components.queryItems = [
                URLQueryItem(name: "api", value: "SYNO.API.Info"),
                URLQueryItem(name: "version", value: "1"),
                URLQueryItem(name: "method", value: "query"),
                URLQueryItem(name: "query", value: "SYNO.API.Auth")
            ]
        } else {
            let path = basePath.trimmingCharacters(in: .whitespacesAndNewlines)
            components.path = path.isEmpty ? "/" : path
        }
        return components.url
    }
}
