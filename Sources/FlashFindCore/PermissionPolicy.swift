import Foundation

/// 权限判定被拒的原因。取值就是对外错误码，**英文、闭集**（方案 §4.2）。
///
/// 只有两个码，是因为判定层只回答「你有权限吗」：
/// `source_unavailable`（掉线）与 `auth_required`（密码失效）是 provider 的事实，
/// 判定层看不到、也不该猜——混进来就会把「没授权」说成「连不上」。
public enum PermissionDenial: String, Equatable, Sendable {
    /// 用户在设置里关了 AI 访问，或一个来源都没授权。
    case mcpDisabled = "mcp_disabled"
    /// 点名的来源没有一个可用（含「全部来源都没授权」）。
    case sourceDenied = "source_denied"
}

/// 一次权限判定的结果。
///
/// `allow` 带 `sources` 与 `warnings` 两个字段，对应方案 §4.2.1 的「部分失败」：
/// 点名的来源里只要有一个可用，就不整体拒绝，而是把不可用的那几条降级成
/// `warnings: ["source_denied:<id>"]`。
public enum PermissionDecision: Equatable, Sendable {
    case allow(sources: [String], warnings: [String])
    case deny(code: PermissionDenial, message: String)

    /// 放行时的来源集合（拒绝时为空）。
    public var allowedSources: [String] {
        if case .allow(let sources, _) = self { return sources }
        return []
    }
}

/// 权限判定的**唯一入口**。纯函数：只依赖四个入参，不读偏好、不碰文件系统、
/// 不认识 Keychain、也不认识 MCP。
///
/// ## 为什么必须是纯函数
///
/// 判定在**每次请求**时重算（方案 §5.2）。一旦这里自己去读当前设置：
///
/// * 撤销授权不会在下次请求时生效——进程里已经有一份「算过」的结论；
/// * App 与 Helper 会各自读到不同的事实（Helper 是独立进程，凭据与设置都在 App 侧）；
/// * 单测只能靠改真实偏好文件来覆盖，跑一次就污染用户环境。
///
/// 所以「事实」由调用方给：总开关、allowlist、Agent 点名的来源、**现在还存在**的来源。
public enum PermissionPolicy {

    // MARK: - 文案
    //
    // 全部英文、全部固定：MCP 的 message 会直接进 Agent 上下文。
    // ★ 一律不拼接来源 id 或来源名——「私人 NAS」「财务归档」这类名字本身就是信息，
    // 一旦进了对话记录就撤不回来（方案 §4.3.1）。

    static let switchOffMessage = "AI access is turned off in FlashFind settings. Turn it on and choose at least one source."
    static let nothingAuthorizedMessage = "No source is currently authorized for AI access. Choose at least one source in FlashFind settings."
    static let nothingRequestedMessage = "No source was requested."
    static let nothingUsableMessage = "None of the requested sources is available for AI access."

    /// 判定一次请求能不能用哪些来源。
    ///
    /// - Parameters:
    ///   - mcpEnabled: 总开关。
    ///   - allowedSources: 用户勾选的来源 id（可能含已删除的残留）。
    ///   - requested: Agent 点名的来源。**`nil` = 只搜 allowlist，不是「全部来源」**；
    ///     `[]` 是调用方写错，按拒绝处理（fail closed）。
    ///   - existing: **现在还存在**的来源 id。★ 不是「在线」——在线与否是 provider 的事
    ///     （`source_unavailable`）。这里只回答「这个来源还在不在」，用来剔掉
    ///     用户删掉一台 NAS 之后残留的授权。
    public static func decision(mcpEnabled: Bool,
                                allowedSources: Set<String>,
                                requested: [String]?,
                                existing: Set<String>) -> PermissionDecision {
        guard mcpEnabled else { return .deny(code: .mcpDisabled, message: switchOffMessage) }

        // 可用 = 授权 ∩ 存在。两者的差集都不能出现在任何结果里：
        // 没授权的不许搜，已删除的不许返回（否则 list_sources 会给 Agent 一个搜不到的来源）。
        let usable = allowedSources.intersection(existing)
        guard !usable.isEmpty else { return .deny(code: .mcpDisabled, message: nothingAuthorizedMessage) }

        guard let requested else {
            return .allow(sources: usable.sorted(), warnings: [])
        }
        // 空数组是「点了名，但一个都没给」——不能当成「没点名」，
        // 否则一次参数错误会静默变成一次范围更大的搜索。
        guard !requested.isEmpty else { return .deny(code: .sourceDenied, message: nothingRequestedMessage) }

        var seen = Set<String>()
        var granted: [String] = []
        var warnings: [String] = []
        for id in requested where seen.insert(id).inserted {
            if usable.contains(id) {
                granted.append(id)
            } else {
                // 未授权与不存在走同一条分支、给同一个 warning：两者必须不可区分，
                // 否则 Agent 靠试 id 就能枚举出用户有哪些来源。
                warnings.append("source_denied:\(id)")
            }
        }
        guard !granted.isEmpty else { return .deny(code: .sourceDenied, message: nothingUsableMessage) }
        return .allow(sources: granted.sorted(), warnings: warnings)
    }
}
