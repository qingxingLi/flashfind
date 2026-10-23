import Foundation

/// 一次请求里**判权与执行共用的那份来源**（方案 §15 #23，Phase 6.3b-0 落成；
/// 6.3b-1 起连执行句柄一起冻结）。
///
/// ## 它解决的问题
///
/// 如果执行侧自己再去读一遍注册表，就会出现这样一个窗口：
///
/// ```text
/// T0  PermissionPolicy 判权：来源 A 存在，放行
/// T1  用户在设置里删掉 A、新建了 A'（未授权，或者干脆是别的设备）
/// T2  Executor 重新读注册表 → 拿到 A'，按「A」去搜
/// ```
///
/// 结果不是「这次请求失败」，而是**这次请求获得了它在 T0 没有的权限**。
/// 所以判权用的那份来源必须一路带到执行，中途不再读第二次。
///
/// ## 为什么是「快照」而不是「再查一次注册表」
///
/// 快照是**不可变**的：`ids` 一旦建好，就没有任何方法能让它变长。
/// 执行侧只拿得到 `ids` 与 `execution(for:)` 给出的句柄，拿不到注册表，
/// 所以「顺手读一下全局来源」在类型上就写不出来。
///
/// ★ 它**不是**第二份权限判定：能进 `ids` 的只有 `AuthorizationScope` 里已有的 id
/// （`PermissionPolicy` 已经做过「勾选 ∩ 存在 ∩ Agent 点名」）。这里只做过滤与排序，
/// 不做任何放行判断——`contains` 只回答「这次请求的范围里有没有它」。
///
/// ## 名字与句柄的处理
///
/// 名字与执行句柄都只从**这一份**注册表里取，且只给已授权的来源。
/// 取不到名字的 id 仍然可以执行（搜索不需要名字），但不会出现在 `list_sources` —
/// 宁可在列表里少一条，也不要在这里现编一个名字（§4.3.1）。
/// 取不到句柄的 id 仍然进 `ids`（它确实被授权了），执行时会如实报 `source_unavailable` ——
/// 那是「现在搜不了」，不是「没授权」。
public struct AuthorizedSourceSnapshot: Equatable, Sendable {

    /// 本次请求可以碰的来源 id，**升序、无重复、非空**。
    public let ids: [String]
    /// 部分失败的说明，来自 `AuthorizationScope`（`source_denied:<id>`，不含名字）。
    public let warnings: [String]

    /// 只有已授权来源的名字。键一定在 `ids` 里（构造时过滤过）。
    private let names: [String: String]

    /// 只有已授权来源的执行句柄。键一定在 `ids` 里（同上）。
    private let handles: [String: SourceExecutionHandle]

    public init(scope: AuthorizationScope, registry: [AuthoritySource]) {
        // 注册表里可能重复（别处已经坏了），也可能顺序任意——这里收敛成
        // 「去重 + 升序」。排序是本类型的性质，不依赖调用方给什么顺序。
        var byID: [String: AuthoritySource] = [:]
        for source in registry where byID[source.id] == nil {
            byID[source.id] = source
        }

        // ★ id 只来自 `scope.sourceIDs`——它已经是「勾选 ∩ 存在 ∩ Agent 点名」的交集。
        // 注册表在这里**只提供名字与句柄**，不提供「还能搜哪些来源」。这个方向不能反：
        // 反过来就成了「注册表里有什么就搜什么」，判权结果被注册表盖掉。
        var seen = Set<String>()
        var kept: [String] = []
        for id in scope.sourceIDs where seen.insert(id).inserted {
            kept.append(id)
        }
        kept.sort()

        self.ids = kept
        self.warnings = scope.warnings
        self.names = kept.reduce(into: [:]) { result, id in
            if let name = byID[id]?.name { result[id] = name }
        }
        self.handles = kept.reduce(into: [:]) { result, id in
            if let handle = byID[id]?.execution { result[id] = handle }
        }
    }

    public var count: Int { ids.count }
    public var isEmpty: Bool { ids.isEmpty }

    /// ★ 相等性只看「这次请求被允许的范围」：id、名字、warnings。
    /// 执行句柄是引用，不参与比较——否则同一份设置两次读数永远不相等。
    /// `testTheSnapshotHasNoWayToGrow` 与 `testOnlyAuthorizedSourcesAreInTheSnapshot`
    /// 断言的都是这三样，句柄换没换不该影响它们。
    public static func == (lhs: AuthorizedSourceSnapshot, rhs: AuthorizedSourceSnapshot) -> Bool {
        lhs.ids == rhs.ids && lhs.warnings == rhs.warnings && lhs.names == rhs.names
    }

    /// 这次请求的范围里有没有它。
    ///
    /// ★ 只回答「在不在本次授权快照里」，**不回答**「这台机器上有没有这个来源」。
    /// 后者是注册表的事，执行侧不该知道。
    public func contains(_ id: String) -> Bool { ids.contains(id) }

    /// 执行句柄。**只对本次授权范围内的 id 回答**——未授权的 id 一律 `nil`，
    /// 哪怕调用方手里有那张注册表。
    ///
    /// ★ 这是执行侧唯一能拿到 provider 的入口。它返回的是 T0 那一刻的那个对象，
    /// 不是「按 id 现查」的结果。
    public func execution(for id: String) -> SourceExecutionHandle? { handles[id] }

    /// `list_sources` 用：**能配上名字的**授权来源，按 id 升序。
    ///
    /// 循环顺序跟随 `ids`（已排序），所以输出顺序与注册表顺序无关。
    /// 这里**不带句柄**：列表是描述，不是执行。
    public var namedSources: [AuthoritySource] {
        ids.compactMap { id in names[id].map { AuthoritySource(id: id, name: $0) } }
    }
}
