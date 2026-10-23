import Foundation

/// socket 报文的四条上限（方案 §1.3.4）。**数字只在这里出现一次**。
///
/// 权威端按这组值拒绝过大请求、拒发过大响应、断开读空闲连接；
/// 调用端用同一组值约束自己读回来的响应。两边各写一份数字，
/// 就会出现「一边 64 KB 一边 16 KB」——症状是偶尔一个 `locate` 报 `request too large`。
public struct AuthorityLimits: Equatable, Sendable {

    /// 请求上限。
    ///
    /// 64 KB 对请求够用到奢侈（最长的是 `locate` 的 query + 几个可选参数）。
    public var maxRequestBytes: Int

    /// 响应上限。
    ///
    /// 4 MB 是**最后一道护栏**，不是预期值：`search` 50 条 × 约 200 字符 ≈ 10 KB。
    /// 真正的限额是每个 Tool 自己的 `limit`（`ToolSchema` 的 `LimitRange`）。
    public var maxResponseBytes: Int

    /// **已经收到数据之后**两块之间的停顿上限。半死进程的症状是「回到一半不吭声」。
    ///
    /// ★ build 29 起它**不再兼管首帧**。原先调用端写的是
    ///   `min(readIdleTimeout, 剩余预算)`，把「权威端还在算」误判成「半死」：
    ///   `locate` / `search` 的正常耗时是 5–8 秒，而权威端只在整次操作跑完时
    ///   才回一帧。现在首帧等满 `requestTimeout`，中途停顿才用这个数。
    ///   两处的分工见 `UnixSocket.readLine` 的参数说明。
    public var readIdleTimeout: TimeInterval

    /// 单条请求在权威端的总处理预算。超了回 `timeout`。
    public var requestTimeout: TimeInterval

    /// 启动时探测「已存在的 socket 是活的还是 stale」的预算（§1.3.3.1）。
    /// 500 ms：用户机器上出现半死进程是会发生的，但正常往返只有 0.29 ms。
    public var probeTimeout: TimeInterval

    public init(maxRequestBytes: Int = 64 * 1024,
                maxResponseBytes: Int = 4 * 1024 * 1024,
                readIdleTimeout: TimeInterval = 5,
                requestTimeout: TimeInterval = 10,
                probeTimeout: TimeInterval = 0.5) {
        self.maxRequestBytes = maxRequestBytes
        self.maxResponseBytes = maxResponseBytes
        self.readIdleTimeout = readIdleTimeout
        self.requestTimeout = requestTimeout
        self.probeTimeout = probeTimeout
    }
}
