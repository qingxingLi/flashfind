import Foundation

/// History 用的**非安全**标签：`session_id` + `agent_id`（方案 §6.4 / Phase 7a）。
///
/// ## 它为什么存在
///
/// History 需要「谁在什么时候看过哪个文件」这个维度，而冻结报文里只有
/// `{v, id, op, args}`——里面没有任何能标识「哪一次助手进程」的东西。
///
/// 所以在 wire 上多带一层，且与 `args` **同级**：
///
/// ```json
/// { "v": 1, "id": "…", "op": "locate", "args": { "query": "…" },
///   "context": { "session_id": "…", "agent_id": "claude-code/1.0.31" } }
/// ```
///
/// ## ★ 为什么不能拿 Authority request id 顶替 `session_id`
///
/// ```text
/// request id  →  每次调用的所有者（§4.7，MCPOwner 用它算 SearchOwner）
/// session id  →  Helper 进程的生命周期
/// ```
///
/// 两者语义不同，而且差别正是 `located` 去重成立的前提：同一个 session 里的
/// 5 次 `locate` = 5 个 request id + 1 个 session id。若用 request id 当
/// session id，去重会退化成「每条都算首见」，§6.2.2 那条规则当场失效。
///
/// ## ★ 这两个值在 App 端一律按**不可信标签**处理
///
/// ```text
/// 允许：History 关联 / located 去重 / 客户端诊断
/// 禁止：PermissionPolicy / AuthorizationScope / 来源选择
///      Keychain / NAS 权限 / 一切安全判断
/// ```
///
/// 线上这条报文由**任何同 UID 进程**都能发（socket 只校验同 UID，§5.2.2），
/// 所以这两个值一定可以被伪造。设计上的要求是：
///
/// > 伪造的最坏后果只能是「History 标签不准」，**绝不能扩大权限**。
///
/// 这条不是靠注释守的，有两条机器执行的边界：
///
/// * **结构**：`PermissionPolicy.swift` / `ToolRouter.swift` /
///   `AuthorizedSourceSnapshot.swift` 三个文件里都不许出现 `HistoryContext`；
/// * **行为**：换掉 `session_id` / `agent_id`（含伪造、超长、带换行），
///   路由与判定结果必须逐字相同。
///
/// ## ★ 为什么标签要有长度上限
///
/// 它们是不可信输入，而且会写进 sqlite 与诊断行。不设上限等于让任何同 UID
/// 进程往用户磁盘里塞任意长的字符串。解码时就裁掉，且不因畸形标签报错——
/// 报错会让一个无关进程有能力把 MCP 搜索打挂。
public struct HistoryContext: Equatable, Sendable {

    /// 单个标签允许的最大长度。
    public static let maxLabelLength = 256

    /// 客户端标识取不到时的前缀。
    ///
    /// ★ 写成 `unknown` 而不是空串：空串在诊断里看不出「没取到」还是「取到了空」，
    /// 而这两件事的排查方向完全不同。
    public static let unknownAgent = "unknown"

    /// Helper 进程生命周期标识。进程内稳定，重启后变化。
    public let sessionID: String
    /// 发起这次会话的 MCP 客户端标识，形如 `claude-code/1.0.31`。
    public let agentID: String

    public init(sessionID: String, agentID: String) {
        self.sessionID = sessionID
        self.agentID = agentID
    }

    /// 裁到边界内。
    ///
    /// ★ **不抛错**：标签不可信，「不合预期」是常态而不是故障。
    public var clamped: HistoryContext {
        HistoryContext(sessionID: Self.normalize(sessionID),
                       agentID: Self.normalize(agentID))
    }

    /// `name/version`；取不到时 `unknown/<启动 epoch 秒>`。
    ///
    /// ★ 为什么带上启动时间：两个都没报名字的客户端因此不会共享同一个
    /// `agent_id`，诊断时能把「两个未知客户端」与「一个客户端」分开。
    static func agentLabel(name: String?, version: String?, launchedAt: Date) -> String {
        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let cleanVersion = version?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !cleanName.isEmpty else {
            return "\(Self.unknownAgent)/\(Int(launchedAt.timeIntervalSince1970))"
        }
        return cleanVersion.isEmpty ? cleanName : "\(cleanName)/\(cleanVersion)"
    }

    /// 去控制字符 → 压平连续空白 → 截断 → 空则 `unknown`。
    ///
    /// ★ 为什么不抛错、不丢标签：标签不可信，「不合预期」是常态而不是故障。
    ///   若畸形就报错，任何同 UID 进程都能用一条畸形标签把 MCP 搜索打挂（§5.2.2）。
    static func normalize(_ raw: String) -> String {
        var flattened = ""
        for scalar in raw.unicodeScalars {
            // 换行与 NUL 会破坏 jsonl 诊断行的结构；其余控制字符也只可能是噪声。
            flattened.append(CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar))
        }
        // 连续空白压成一个：标签是要给人看的，缩进式的空跑没有意义。
        let words = flattened.split(whereSeparator: { $0 == " " || $0.isNewline })
        return words.isEmpty ? Self.unknownAgent : String(words.joined(separator: " ").prefix(maxLabelLength))
    }
}

/// Helper 进程级的身份源：**构造时定下 session，进程内不再变化**。
///
/// ## 为什么 session 要在这个对象里，而不是每次调用现造
///
/// `session_id` 的定义就是「Helper 进程的生命周期」。如果每次调用现造一个 UUID，
/// 它就退化成第二个 request id，§6.2.2 的 `located` 去重立刻失效——
/// 而且这种失效**只在真机上出现一次**：单测里一次调用 = 一个 session，
/// 怎么造都对。
///
/// ## ★ 它是不可信标签的**唯一**产地
///
/// `agent_id` 只在 `noteClient` 里写，来源是 MCP `initialize` 的 clientInfo。
/// 客户端可以随便报名字，所以这个字段**只**用于 History 关联与诊断，
/// 不得参与任何判定（边界由结构测试守着）。
public final class HistoryContextSource: @unchecked Sendable {

    private let lock = NSLock()
    private let launchedAt: Date
    private var agentName: String?
    private var agentVersion: String?

    /// 这次 Helper 进程的 session。**公开只读**：它的稳定性本身就是契约。
    public let sessionID: String

    public init(sessionID: String = UUID().uuidString, launchedAt: Date = Date()) {
        self.sessionID = sessionID
        self.launchedAt = launchedAt
    }

    /// MCP `initialize` 到达时记一次客户端标识。
    ///
    /// ★ 这个方法**不影响任何判定**：它只改 History 的标签。
    public func noteClient(name: String?, version: String?) {
        lock.withLock {
            agentName = name
            agentVersion = version
        }
    }

    /// 当前标签。每次调用都现算——客户端可能在 initialize 之后才被记下来。
    public func current() -> HistoryContext {
        let (name, version) = lock.withLock { (agentName, agentVersion) }
        return HistoryContext(sessionID: sessionID,
                              agentID: HistoryContext.agentLabel(name: name,
                                                                 version: version,
                                                                 launchedAt: launchedAt))
            .clamped
    }
}

// MARK: - Codable

extension HistoryContext: Codable {

    private enum CodingKeys: String, CodingKey {
        case sessionID = "session_id"
        case agentID = "agent_id"
    }
}
