import Foundation

/// 一次搜索要请求哪些来源（审核 R01 的验证面）。
///
/// 原来这段判定内联在 AppModel 里，而 AppModel 属于 executableTarget、
/// 测试目标依赖不了它 —— 于是「新装机器上 NAS 到底有没有被请求」这件事
/// 只能靠人点。搬到 Core 之后可以直接断言。
///
/// ★ 这里的规则与界面上的开关一一对应：
/// 总开关关掉 ⇒ 一个 NAS 来源都不请求；逐来源关掉 ⇒ 只不请求那一个。
/// 两者都不允许被 `ready` 之外的东西悄悄放行——「连上了却搜不到」正是这么来的。
public struct SearchRequestPlan {

    /// 本次要请求的来源 ID 集合。
    public let sourceIDs: Set<String>

    /// - Parameters:
    ///   - localSourceID: 本机来源的 ID（`SearchSource.local.id`）。
    ///   - appSourceID: 应用搜索来源的 ID（`SearchSource.apps.id`）。
    ///   - includeLocal: 作用域包含本机（界面上的「全部」「本机」）。
    ///   - includeApps: 本次是否也搜已安装应用。应用属于本机一侧，调用方应在
    ///     `includeLocal` 为真时才传 true；「NAS」作用域下传 false。
    ///   - includeNAS: 作用域包含 NAS，且**总开关**是开的。
    ///   - nasCandidates: 每个 NAS 来源的 (sourceID, 已就绪, 已启用)。
    ///     只有 `ready` 与 `enabled` 同时为真才请求——未登录的来源发过去只会失败。
    public init(localSourceID: String,
                appSourceID: String,
                includeLocal: Bool,
                includeApps: Bool,
                includeNAS: Bool,
                nasCandidates: [(sourceID: String, ready: Bool, enabled: Bool)]) {
        var ids = Set<String>()
        if includeLocal { ids.insert(localSourceID) }
        if includeApps { ids.insert(appSourceID) }
        if includeNAS {
            for candidate in nasCandidates where candidate.ready && candidate.enabled {
                ids.insert(candidate.sourceID)
            }
        }
        sourceIDs = ids
    }

    /// 没有任何来源可请求 ⇒ 不该进入「正在搜索」态。
    public var isEmpty: Bool { sourceIDs.isEmpty }
}
