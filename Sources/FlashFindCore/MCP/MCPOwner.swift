import Foundation

/// wire 请求 → `SearchOwner` 的**唯一映射**（方案 §4.7）。
///
/// ## 规则
///
/// ```text
/// 每一个 Authority wire request id  →  一个 MCP SearchOwner
/// SearchOwner.mcp(sessionID: authorityRequest.id)
/// ```
///
/// ## 为什么是请求 id，不是客户端自报的名字
///
/// `SearchScheduler` 的取消是按 owner 隔离的（跨 owner 永不取消）。要让它成立，
/// 必须先能回答「这条 socket 报文属于哪个 owner」。三个候选：
///
/// | 候选 | 为什么不选 |
/// | --- | --- |
/// | `clientInfo.name` | 客户端自报，可以随便写；两个 Agent 都自称 "claude" 就撞在一起 |
/// | pid | Helper 重启就变；同一个 Agent 换个连接就换了 owner，`cancelAll` 收不回来 |
/// | **wire request id** | 由 `UnixSocketAuthorityLink` 每条请求现生成，天然唯一 |
///
/// ★ 它**不是**身份，也不是安全边界。socket 只校验同 UID，任何同 UID 进程都能连；
/// 这个 id 只决定「谁的搜索会被谁取消」。谁能搜哪里由 `PermissionPolicy` 判。
///
/// ## 为什么 `locate_many` 因此天然正确
///
/// 一次 `locate_many` 是**一条** wire 请求，展开出的 N 条子查询共用同一个 id
/// → 同一个 owner；配合 `SearchScheduler.submit(supersedePrevious: false)`
/// （`.mcp` 的默认值），它们排队而不会互相取代，所以「5 条只剩 1 条」不会发生。
///
/// ## 为什么要夹住长度和字符集
///
/// `id` 来自报文，长度与内容都不受我们控制（最多到 `AuthorityLimits.maxRequestBytes`）。
/// 它会成为调度器的 `Dictionary` 键、也会进 `SearchOwner.label` 这种诊断输出——
/// 一个 4 MB 的 id 或一个带 `\n` 的 id 都能把日志与内存搞坏。
/// 不可用的 id 走摘要形态（`h:` + **完整** SHA-256 的 64 位 hex）。
///
/// ★ 措辞（Phase 6.3b-0 复审纠正）：摘要**不是**「一一对应的保证」。
/// 128 bit 截断与 256 bit 全文都一样存在理论碰撞，只是概率量级不同；把
/// 「两个不同输入永不撞」写成契约就是承诺了一件实现做不到的事。准确的契约是：
///
/// > 合法 id 原样使用；不可信 id 使用**完整的 SHA-256** 派生的稳定、
/// > 抗碰撞 session id。
///
/// 取完整 64 位而不是截断，代价是内部 id 长 32 个字符（不进 Agent 上下文、
/// 不上网、只在本进程的字典键与诊断日志里），换来的是不必为「128 bit 够不够」
/// 留一段永久性的解释。
public enum MCPOwner {

    /// 原样保留的 sessionID 字节上限。够放 UUID（36）与常见的前缀式 id。
    public static let maxSessionIDBytes = 64

    /// 摘要形态的前缀。`h:` 让诊断时一眼看出「这条不是原样 id」。
    static let digestPrefix = "h:"

    /// 摘要取多少个 hex 字符：SHA-256 全文，不截断。
    static let digestCharacters = 64

    /// 摘要形态的字节数（`h:` + 64）。**它比 `maxSessionIDBytes` 长**，
    /// 因为它不再是「用户给的 id」而是我们自己定长的派生串。
    public static var maxDigestSessionIDBytes: Int { digestPrefix.count + digestCharacters }

    /// 唯一入口。
    public static func owner(requestID: String) -> SearchOwner {
        .mcp(sessionID: sessionID(for: requestID))
    }

    /// 原样保留或退化成摘要。**同一个 id 永远得到同一个结果**（纯函数，不读外部状态）。
    static func sessionID(for requestID: String) -> String {
        if isUsable(requestID) { return requestID }
        return digestPrefix + DigestHex.prefix(Data(requestID.utf8), characters: digestCharacters)
    }

    /// 可原样用作 sessionID：1…64 字节的可打印 ASCII（排除空格与 `/`）。
    ///
    /// 排除 `/` 与空格的唯一理由是**诊断**：`mcp:<id>` 会被写进日志与 `lastRejectedCancel`，
    /// 含分隔符的 id 会让那句日志没法读。它们不影响正确性。
    static func isUsable(_ requestID: String) -> Bool {
        guard (1...maxSessionIDBytes).contains(requestID.utf8.count) else { return false }
        return requestID.utf8.allSatisfy { byte in
            byte > 0x20 && byte < 0x7F && byte != UInt8(ascii: "/")
        }
    }
}
