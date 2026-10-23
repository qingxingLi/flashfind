import Foundation

/// 判权那一刻冻结下来的**执行句柄**：这一次请求要用哪个 provider、投给哪个调度器。
///
/// ## 为什么句柄必须和 id / 名字一起冻结（§15 #23，Phase 6.3b-1）
///
/// 6.3b-0 的 `AuthorizedSourceSnapshot` 只冻结了 id 与名字，于是执行侧要真正搜一次，
/// 还得拿 id 回去问「这个来源现在用哪个 provider」——**那就是第二次读注册表**：
///
/// ```text
/// T0  PermissionPolicy 判权：来源 A 存在且已授权，放行
/// T1  用户在设置里删掉 A，又新建了一个 A′（同名、同 id 前缀、不同设备）
/// T2  Executor 按 id 再查一次 provider → 拿到 A′，按「A」去搜
/// ```
///
/// 结果不是「这次请求失败」，而是**这次请求搜了一个它从未被授权的设备**。
/// 把 provider 引用在 T0 就装进快照之后，这条路在类型上不存在：执行侧手里
/// 只有句柄，没有注册表。
///
/// ## 为什么连调度器一起装
///
/// 同一来源的「只有一个活跃查询」这条约束住在 `SearchScheduler` 的队列里。
/// 如果执行侧自己另造一个调度器，MCP 与 GUI 就会各排一条队、同时压到同一台
/// NAS 上——正是 P3 修掉的那个故障。所以句柄里的 provider 与 scheduler
/// **必须来自同一次读数**，一起冻结。
///
/// ## 为什么是 `@unchecked Sendable`
///
/// 它只被当作值来保存与传递（`AuthoritySource` 是 `Sendable` 结构体）。
/// 真正解除引用（`.provider` / `.scheduler`）的两个 accessor 都是 `@MainActor`：
/// provider 与调度器都是主线程隔离的对象，跨线程调用在类型上写不出来。
public final class SourceExecutionHandle: @unchecked Sendable {

    /// ★ 存储层刻意用 `private` + `@MainActor` accessor 包起来：
    /// 这样「在后台线程上直接拿 provider 去搜」不会被写成一行看似无害的代码。
    private let providerRef: any SearchProvider
    private let schedulerRef: SearchScheduler

    public init(provider: any SearchProvider, scheduler: SearchScheduler) {
        self.providerRef = provider
        self.schedulerRef = scheduler
    }

    /// 这次请求被授权的那个 provider **对象**（不是按 id 现查的结果）。
    @MainActor public var provider: any SearchProvider { providerRef }

    /// 与 `provider` 同一次读数得到的调度器。
    @MainActor public var scheduler: SearchScheduler { schedulerRef }

    /// 诊断用：来源 id。
    ///
    /// 只在 `@MainActor` 上取，避免有人拿它去「顺便查一下注册表里还有没有」。
    @MainActor public var sourceID: String { providerRef.source.id }

    // MARK: - 按路径直查（Phase 6.4b-1）

    /// 问一次「这个路径此刻的元数据」。
    ///
    /// ★ 与 `provider` 同一个对象、同一次读数：直查不重新读注册表，
    /// 所以 6.3b 已经在搜索上关掉的 TOCTOU 不会在 `get_metadata` 上复活
    /// （§15 #23）。本类型的入参里没有注册表，那件事在类型上写不出来。
    ///
    /// ★ 能力探测用 `as?` 而不是给 `SearchProvider` 加一条协议要求：
    /// 要求每个 provider 都会直查，会让「应用程序」来源也得编一个
    /// 「一个 app 有多少字节」的实现。缺口**如实报**（`.unsupported` →
    /// `internal_error`）比假实现诚实（§15 #31）。
    @MainActor
    public func metadata(canonicalRelativePath: String) async -> MetadataOutcome {
        guard let provider = providerRef as? (any PathMetadataProviding) else {
            return .unsupported
        }
        return await provider.metadata(canonicalRelativePath: canonicalRelativePath)
    }
}
