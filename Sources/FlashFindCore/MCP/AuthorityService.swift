import Foundation

/// 权威端收到的一条**业务**请求（`ping` 不走这里，见 `AuthorityListener`）。
///
/// 跨进程后只剩三件事：报文 id、操作名、以及 Agent 给的原始参数。
///
/// ★ 这里**没有** `sourceIDs`（v0.18）：授权范围不是 Helper 能给的，
/// 它只能由 App 的 `PermissionPolicy` 在每次请求时现算（§5.2.2）。
///
/// ★ `id` 是**请求 id**，不是身份（v0.20 / §4.7）。它唯一被用到的语义是
/// 「这次请求对应哪个搜索 owner」，由 `owner` 一处算出来。
public struct AuthorityJob: Equatable, Sendable {

    public let id: String
    public let op: AuthorityWire.Operation
    public let arguments: [String: AuthorityWire.Value]
    /// History 的非安全标签（§7a / §6.4）。由助手进程随报文带上，App 侧
    /// **只**用于 History 关联与诊断——`PermissionPolicy` 与 `AuthorizationScope`
    /// 都拿不到它（结构测试机器执行）。
    public let history: HistoryContext?

    public init(id: String,
                op: AuthorityWire.Operation,
                arguments: [String: AuthorityWire.Value],
                history: HistoryContext? = nil) {
        self.id = id
        self.op = op
        self.arguments = arguments
        self.history = history
    }

    /// 本次请求的搜索发起方。**计算属性，不是字段**：存一份就等于允许
    /// 「id 与 owner 不一致」，而它们本来就是同一个事实（`MCPOwnerTests` 守着）。
    public var owner: SearchOwner { MCPOwner.owner(requestID: id) }
}

/// 权威端的业务实现。
///
/// 1.1.2 里真正的实现是 `RoutingAuthorityService`（App 进程内：现读设置 → 判定 → 执行）。
public protocol AuthorityServing: Sendable {
    func handle(_ job: AuthorityJob) async -> ToolOutcome
}

/// 传输层测试用的空业务实现：**所有业务请求都失败**，但说的是实话。
///
/// 它只服务 `AuthoritySocketTests`（那些用例关心的是权限位、stale、上限、超时，
/// 不关心业务）。App 里装的是 `RoutingAuthorityService`。
///
/// 为什么不留一个「先返回空结果」的临时实现：空结果（`ok: true` + 零条）的语义是
/// 「闪寻搜过了，没有这个文件」。而「这条路径还没接上」是另一件事。两者在 Agent
/// 眼里完全不同：前者会让它下结论，后者会让它告诉用户去更新。
public struct NotImplementedAuthorityService: AuthorityServing {

    public static let code = "internal_error"
    public static let message = "This search operation is not available in this build of FlashFind yet."

    public init() {}

    public func handle(_ job: AuthorityJob) async -> ToolOutcome {
        .failure(code: Self.code, message: Self.message)
    }
}
