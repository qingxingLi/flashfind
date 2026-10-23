import Foundation

// MARK: - 权威端接口

/// 把 Agent 的**原话**交给权威端（方案 §5.2.2 / §14.3.5）。
///
/// 权威端是「真正能读索引、读文件、连 NAS、读设置」的那一头：1.1.2 里它在 App 进程内，
/// 通过 Unix Socket 通信（§1.3）。这一层**不认识 socket**，只认识
/// 「工具名 + 原始参数」与一段文本结果。
///
/// ## 为什么只交原始参数，不交 `AuthorityRequest`
///
/// v0.17 的 `execute(_ request: AuthorityRequest)` 交出去的是**已经过校验与授权**的请求。
/// 那条路已被撤回：socket 只校验同 UID，**任何同 UID 进程都能连**（另一个闪寻、脚本、
/// 编辑器插件……），所以「Helper 已经解析并授权过」在 App 眼里没有任何可信度加成。
/// App 无论如何都要从原始参数重新解析 —— 那 Helper 侧再解析一次就只是第二份参数语义，
/// 迟早会漂。见 §5.2.2 的 P1–P4。
///
/// ★ 因此这里**不出现** `ToolCall` / `AuthorizationScope` / `PermissionFacts`：
/// 它们是 App 内部的概念，跨进程只传 `{tool, arguments}`。
///
/// ★ 为什么接口放在 `FlashFindCore` 而不是可执行文件里：
/// ① 可执行文件不可测（`FlashFindMCP` 是 executableTarget，testTarget 依赖不了它）；
/// ② 红证只能覆盖 `FlashFindCore`（§8.5）。把接口写在可执行文件里，
///    「handler 有没有正确地把请求交出来」就永远测不到。
public protocol AuthorityLink: Sendable {
    /// 交出一次调用。实现**不得**做任何权限判断或参数语义判断——它只是搬运。
    ///
    /// - Parameters:
    ///   - tool: Agent 说的工具名。**不要在这里查 `ToolCatalog`**：
    ///     未知工具必须由 App 回 `unknown_tool`，否则同一个判断就有两处实现。
    ///   - arguments: Agent 给的原始参数，含我们不认识的类型（`.unsupported`）。
    ///     不许在这里 trim、钳位、补默认值或丢键——`source_ids: null` 被丢掉
    ///     就等于把搜索范围放大（§4.3.1）。
    ///   - context: History 用的**非安全**标签。App 端只用于 History 关联与诊断，
    ///     不得参与权限判定（§7a，结构测试守着）。
    func call(tool: String, arguments: ToolArguments, context: HistoryContext?) async -> ToolOutcome
}

/// 一次执行的结果。
///
/// 只区分「成功 / 失败」，**不在这里定结果的 JSON schema**：那是接上真实执行端
/// 才有的东西（§4.4）。先定 schema 等于让执行端照着猜的东西实现。
public enum ToolOutcome: Equatable, Sendable {

    /// 成功。`json` 是结果正文，原样变成 `tools/call` 的文本内容。
    case success(json: String)

    /// 失败。`code` 必须取 §4.2 的固定错误码（英文闭集），`message` 直接进 Agent 上下文。
    ///
    /// ★ `code` 是 `String` 而不是枚举，是因为 §4.2 的码表已经在
    /// `ToolRoutingError.code` 与 `PermissionDenial` 两处以字符串形态存在。
    /// 再造一个枚举就是第三份副本；这一层的职责只是**转发**执行端给的码。
    case failure(code: String, message: String)
}
