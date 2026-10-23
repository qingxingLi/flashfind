import Foundation

/// 权限页能列出的一条来源（id + 展示名 + 可选的执行句柄）。
///
/// ★ 身份与名字只有这两个事实：勾选状态在 `AIAccessSettings.allowedSources` 里，
/// 在线状态在 provider 里。这里复制任何一份都会变成第二处说法（§5.1）。
///
/// ★ 名字**只允许**从这里流向返回体，而且必须经过 `AuthorizationScope` 过滤：
/// 未授权来源的名字一旦出现在响应里，就等于告诉 Agent「用户还有这些来源」（§4.3.1）。
///
/// ## `execution` 为什么也在这里（Phase 6.3b-1）
///
/// 它是「这个来源此刻用哪个 provider」的唯一答案，并且**必须与 id / 名字来自同一次读数**。
/// 装在这一条上而不是另开一张表，是为了让「一次读数产出一条来源」成为类型上的事实：
/// 分开两张表就会出现「id 来自读数 A、provider 来自读数 B」的窗口（§15 #23）。
/// 列表类工具（`list_sources`）不需要它，所以是可选的。
public struct AuthoritySource: Equatable, Sendable {

    public let id: String
    public let name: String
    /// 执行句柄。`nil` = 这个 id 现在没有可用的 provider（已断开 / 尚未构建）。
    public let execution: SourceExecutionHandle?

    public init(id: String, name: String, execution: SourceExecutionHandle? = nil) {
        self.id = id
        self.name = name
        self.execution = execution
    }

    /// ★ 相等性**不含**执行句柄：它是引用，而「两条来源是不是同一条」只由 id 与名字决定。
    /// 把引用塞进 `==` 会让「同一份设置两次读数」永远不相等，测试与断言全部失真。
    public static func == (lhs: AuthoritySource, rhs: AuthoritySource) -> Bool {
        lhs.id == rhs.id && lhs.name == rhs.name
    }
}

/// App 侧的权威端实现：**每个请求现读设置 → 判定 → 执行**（方案 §5.2.2 / §14.3.5）。
///
/// ## 它是唯一产生 `AuthorizationScope` 的地方
///
/// ```text
/// 报文（未受信）{tool, args}
///   ↓
/// ToolRouter.route   参数语义：类型 / 必填 / 枚举 / limit / file_id
///   ↓
/// PermissionPolicy   唯一权限判定点（读的是**当前**设置，不是报文里说的）
///   ↓
/// AuthorizationScope 只能由放行的判定构造
///   ↓
/// 执行（6.2 只有 list_sources）
/// ```
///
/// ## 两个「现读」闭包
///
/// `settings` 与 `sources` 都在**每次 `handle` 里**调用一次，**绝不缓存**：
///
/// * 缓存快照会让「撤销授权下一次请求生效」变成「重启后生效」（§5.2 明令禁止）；
/// * 缓存也没法做对——设置是用户在另一个窗口里改的，没有任何通知能保证我们收到。
///
/// 两个闭包都是 `async`：真实实现在 App 里要跳 `MainActor` 读 `AppModel`。
public struct RoutingAuthorityService: AuthorityServing, Sendable {

    /// 读**当前**的 AI 访问设置。真实实现：`AIAccessStore.load(from: model.preferences)`。
    public typealias SettingsReader = @Sendable () async -> AIAccessSettings
    /// 读**当前**存在的来源（id + 名字）。真实实现：`AppModel.aiAccessCandidates`。
    public typealias SourcesReader = @Sendable () async -> [AuthoritySource]
    /// 一次判定的入口。默认就是 `ToolRouter.route`，可注入**只为**让
    /// 「每请求恰好路由一次」变成可断言的（`testRoutingHappensExactlyOncePerRequest`）。
    public typealias Router = @Sendable (String, ToolArguments, PermissionFacts) -> ToolRoutingResult

    private let settings: SettingsReader
    private let sources: SourcesReader
    private let route: Router
    /// 执行预算与时钟。默认 8 秒 / 系统时钟；测试注入固定时钟（排序要可复现）。
    private let timing: LocateExecutor.Timing
    /// `file_id` 的反查表（6.4b-1）。搜索写、 `get_metadata` 读，共用这一张。
    private let referenceStore: FileReferenceStore?
    /// History 的落盘库（Phase 7b）。与上面那张**不是同一个库**。
    private let historyStore: HistoryStore?

    /// 默认路由。
    ///
    /// ★ 写成闭包而不是直接写 `ToolRouter.route`：静态方法值本身不是 `@Sendable`，
    /// 直接当默认实参会得到一条「converting non-sendable function value」的警告
    /// （编译能过，但真警告会被这条噪声淹掉）。函数体不捕获任何东西，闭包是 Sendable。
    public static let defaultRoute: Router = { tool, arguments, facts in
        ToolRouter.route(tool: tool, arguments: arguments, permission: facts)
    }

    public init(settings: @escaping SettingsReader,
                sources: @escaping SourcesReader,
                route: @escaping Router = RoutingAuthorityService.defaultRoute,
                timing: LocateExecutor.Timing = LocateExecutor.Timing(),
                referenceStore: FileReferenceStore? = nil,
                historyStore: HistoryStore? = nil) {
        self.settings = settings
        self.sources = sources
        self.route = route
        self.timing = timing
        self.referenceStore = referenceStore
        self.historyStore = historyStore
    }

    // MARK: - AuthorityServing

    public func handle(_ job: AuthorityJob) async -> ToolOutcome {
        // ★ 一次请求各读一次。**不要**把这两次读提到 init，也不要跨请求复用。
        let currentSettings = await settings()
        let currentSources = await sources()

        let facts = PermissionFacts(mcpEnabled: currentSettings.isEnabled,
                                    allowedSources: currentSettings.allowedSources,
                                    existing: Set(currentSources.map(\.id)))

        // 报文里的 `source_ids`（如果有）在这里仍然只是「Agent 想搜这些」：
        // Router 会把它当 `requested` 交给 PermissionPolicy 审。
        switch route(job.op.rawValue, AuthorityWire.toolArguments(from: job.arguments), facts) {
        case .failed(let error):
            return .failure(code: error.code, message: error.message)

        case .routed(let request):
            // ★ 判权与执行共用**同一份**来源（§15 #23）：快照由 `request.scope`
            // 与刚刚那次 `sources()` 的读数一起构造，执行侧拿不到注册表。
            // 6.3b-1 起这份读数里还带着执行句柄（provider + 调度器）。
            let snapshot = AuthorizedSourceSnapshot(scope: request.scope, registry: currentSources)
            // ★ History 的写入端在这一刻配好：库是 App 级的，标签是**这一次报文**带来的。
            //   标签为 nil（老客户端 / 直接写 socket 的进程）时**不写**，而不是造一个假的
            //   session ——「不知道是谁」要如实说（§7a）。
            let history = historyStore.flatMap { store in
                job.history.map { HistorySink(store: store, context: $0) }
            }
            return await execute(request, snapshot: snapshot, owner: job.owner, history: history)
        }
    }

    // MARK: - 执行

    /// `list_sources` 是纯描述；`locate` / `locate_many` / `search` 真搜索并**落盘**；
    /// `get_metadata` 真直查；`recent` 真执行（Phase 7d）。
    ///
    /// ## ★ `recent` 为什么现在能真跑
    ///
    /// 它依赖 History，而 History 在 7b/7c 才落地。此前**不允许**返回空结果：
    /// 空结果的语义是「搜过了，没有」，而事实是「这条路径还没接上」——
    /// 两者在 Agent 眼里完全不同（§14.3，v0.27）。
    @MainActor
    private func execute(_ request: AuthorityRequest,
                         snapshot: AuthorizedSourceSnapshot,
                         owner: SearchOwner,
                         history: HistorySink?) async -> ToolOutcome {
        switch request.call {
        case .listSources:
            return Self.listSources(snapshot)

        case .locate(let query, let kind, let modifiedAfter, let limit):
            // ★ owner 由 wire 请求 id 算出来（§4.7），不是这里现造的：
            // 两个 MCP 会话必须是两个 owner，否则互相取消就回来了。
            let run = await searchExecutor().run(query: query,
                                                 kind: kind,
                                                 modifiedAfter: modifiedAfter,
                                                 application: limit,
                                                 snapshot: snapshot,
                                                 owner: owner,
                                                 history: history)
            return run.outcome

        case .locateMany(let queries, let perQueryLimit):
            // N 条子查询共用**一个 owner** 与**一张预算券**（§4.7 / §15 #28）：
            // 每条各领一份预算，最坏就是 5 × 10 s，直接突破对外契约。
            let run = await searchExecutor().runMany(queries: queries,
                                                     application: perQueryLimit,
                                                     snapshot: snapshot,
                                                     owner: owner,
                                                     history: history)
            return run.outcome

        case .search(let query, let limit):
            // 与 `locate` 共用收集/过滤/开窗，**不共用**最终排序（§15 #29）：
            // `search` 只按 lexical 档位排，不做修改时间与历史加权。
            let run = await searchExecutor().runSearch(query: query,
                                                       application: limit,
                                                       snapshot: snapshot,
                                                       owner: owner,
                                                       history: history)
            return run.outcome

        case .getMetadata(let fileID):
            // 四步链：① 权限（已由 Router 判过）→ ② 查表 ③ 本次 scope ④ 冻结句柄直查。
            // 没有映射表就无从反查——那是装配缺失，不是「文件不存在」。
            guard let store = referenceStore else {
                return .failure(code: MetadataExecutor.FailureCode.internalError.rawValue,
                                message: MetadataExecutor.FailureCode.internalError.message)
            }
            let run = await MetadataExecutor(store: store)
                .run(fileID: fileID, snapshot: snapshot, history: history, now: timing.now())
            return run.outcome

        case .recent(let withinDays, let limit):
            // ★ 判权已经在 Router/PermissionPolicy 里做完（`request.scope`）；
            //   `recent` 只是**再用一次**这份 scope，不重算、不重搜、不 stat。
            let run = RecentExecutor.run(withinDays: withinDays,
                                         application: limit,
                                         snapshot: snapshot,
                                         history: historyStore,
                                         references: referenceStore,
                                         now: timing.now())
            return run.outcome
        }
    }

    /// 三个搜索 Tool 共用同一个执行器装配——**包括映射表**。
    ///
    /// ★ 映射表只在一处接进 `LocateExecutor`：三处各自接线的话，
    /// 漏掉 `search` 那一条会表现为「search 出来的 id 问不出元数据」，
    /// 而三个 Tool 各自的用例都是绿的。
    @MainActor
    private func searchExecutor() -> LocateExecutor {
        LocateExecutor(timing: timing, referenceStore: referenceStore)
    }

    // MARK: - list_sources

    /// `{"sources":[{"source_id":"…","name":"…"}]}`，按 `source_id` 升序。
    ///
    /// * **只列授权来源**：叫得动它的是 `AuthorizedSourceSnapshot`——它建自
    ///   `AuthorizationScope`（已授权 ∩ 还存在），未授权来源连名字都进不来。
    /// * 名字取不到就整条不输出：宁可少一条，也不要在执行端现编一个名字。
    /// * **不带 `truncated` / `limit_applied`**：`list_sources` 没有 `limit` 参数，
    ///   硬塞两个恒定值会让 Agent 以为它可以要更多。这是 §4.1「所有列表类返回都带」
    ///   的唯一例外，写进了 tool description。
    ///
    /// ★ 排序**不在这里做**：唯一出处是 `AuthorizedSourceSnapshot` 的 `ids`
    /// （它自己的用例守着）。这里再排一次不是「更稳」，而是让「忘了排序」的变异
    /// 拿不到明确归属——两处都排时，删掉任意一处都不会红。
    static func listSources(_ snapshot: AuthorizedSourceSnapshot) -> ToolOutcome {

        let entries: [AuthorityWire.Value] = snapshot.namedSources.map { source in
            .object([AuthorityWire.ResponseKey.sourceID: .string(source.id),
                     AuthorityWire.ResponseKey.name: .string(source.name)])
        }

        let payload = AuthorityWire.Value.object(
            [AuthorityWire.ResponseKey.sources: .array(entries)])

        guard let json = try? AuthorityWire.jsonString(payload) else {
            // 三个字符串字段编不出来只可能是代码 bug；不能报成功（成功 = 空结果 = 「搜过了，没有」）。
            return .failure(code: UnixSocketAuthorityLink.internalCode,
                            message: "FlashFind could not describe the source list.")
        }
        return .success(json: json)
    }
}
