import Foundation

/// 一次搜索的位置限定：只允许在某个来源的这些根里找。
///
/// ★ 它最终会变成「**下发给设备的搜索根变小**」：
/// 群晖走 `Search.start(folder_path[])`，OpenList 走「每个根各发一次
/// `/api/fs/search`」——少一个根就少一次设备侧扫描。检索时间因此真的下降，
/// 而不是界面层做个过滤。
public struct SearchRootLimit: Hashable, Sendable {
    /// 来源 ID（与 `SearchSource.id` 同域）。
    public let sourceID: String
    /// 该来源下**已授权**的根的子集。
    ///
    /// ★ 必须是已授权根的子集。客户端传来的根只是「用户想搜哪儿」，
    /// 交集为空说明它超出了授权范围 —— 那就拒绝，绝不放行。
    public let roots: [String]

    public init(sourceID: String, roots: [String]) {
        self.sourceID = sourceID
        self.roots = roots
    }
}

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

    /// 本次搜索的位置限定。`nil` = 不限定位置（按来源自己的全部已授权根搜）。
    public let rootLimit: SearchRootLimit?

    /// - Parameters:
    ///   - localSourceID: 本机来源的 ID（`SearchSource.local.id`）。
    ///   - appSourceID: 应用搜索来源的 ID（`SearchSource.apps.id`）。
    ///   - includeLocal: 作用域包含本机（界面上的「全部」「本机」）。
    ///   - includeApps: 本次是否也搜已安装应用。应用属于本机一侧，调用方应在
    ///     `includeLocal` 为真时才传 true；「NAS」作用域下传 false。
    ///   - includeNAS: 作用域包含 NAS，且**总开关**是开的。
    ///   - nasCandidates: 每个 NAS 来源的 (sourceID, 已就绪, 已启用)。
    ///     只有 `ready` 与 `enabled` 同时为真才请求——未登录的来源发过去只会失败。
    ///   - target: 位置限定。`.unrestricted` = 不额外限定（只受上面的开关约束）。
    ///     `.local` = 只搜本机一侧。`.sourceRoot` = 只搜那一个来源、那一个根。
    ///   - authorizedRoots: 每个来源**已授权**的搜索根（来源 ID → 根列表）。
    ///     位置限定必须落在这些根之内；不在这之内 ⇒ 该来源不请求。
    public init(localSourceID: String,
                appSourceID: String,
                includeLocal: Bool,
                includeApps: Bool,
                includeNAS: Bool,
                nasCandidates: [(sourceID: String, ready: Bool, enabled: Bool)],
                target: SearchTarget = .unrestricted,
                authorizedRoots: [String: [String]] = [:]) {
        var ids = Set<String>()
        var limit: SearchRootLimit?

        switch target {
        case .unrestricted:
            if includeLocal { ids.insert(localSourceID) }
            if includeApps { ids.insert(appSourceID) }
            if includeNAS {
                for candidate in nasCandidates where candidate.ready && candidate.enabled {
                    ids.insert(candidate.sourceID)
                }
            }
        case .local:
            // 位置限定到本机：总开关与本机开关照旧生效，只是 NAS 一律不参与。
            if includeLocal {
                ids.insert(localSourceID)
                if includeApps { ids.insert(appSourceID) }
            }
        case .sourceRoot(let sourceID, let root):
            // 位置限定到某个来源的某个根：只有那一个来源、那一个根参与。
            // 总开关与逐来源开关仍然有效 —— 限定位置不能绕过它们。
            guard includeNAS else { break }
            guard let candidate = nasCandidates.first(where: { $0.sourceID == sourceID }),
                  candidate.ready, candidate.enabled else { break }
            // ★ 根必须已在授权范围之内。不在 ⇒ 这个来源不请求：
            // 宁可什么都不搜，也不能搜一个没授权的目录。
            let granted = authorizedRoots[sourceID] ?? []
            guard granted.contains(root) else { break }
            ids.insert(sourceID)
            limit = SearchRootLimit(sourceID: sourceID, roots: [root])
        }

        sourceIDs = ids
        rootLimit = limit
    }

    /// 没有任何来源可请求 ⇒ 不该进入「正在搜索」态。
    public var isEmpty: Bool { sourceIDs.isEmpty }
}
