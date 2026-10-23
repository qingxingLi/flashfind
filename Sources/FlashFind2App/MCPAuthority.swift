import Foundation
import FlashFindCore

/// 主 App 侧的权威端监听（Phase 6.1 起监听，6.2 起真正判权限，6.3b-1 起真搜索）。
///
/// 这里只有「什么时候起来、什么时候停，以及从哪儿读事实」。业务实现在
/// `RoutingAuthorityService`：每个请求现读设置与来源 → `ToolRouter` → `PermissionPolicy`
/// → 执行（`list_sources` 与 `locate`）。
///
/// ## 为什么 AI 关着也照样监听
///
/// 一个很自然的想法是「设置里关了 AI 就别开 socket」。但那样助手拿到的是
/// `flashfind_app_unavailable`——文案是「闪寻没在运行，去打开它」，
/// 而真实情况是「你关了这个功能」。Agent 会把用户引到错误的动作上。
///
/// 正确做法是**监听一直在、判定在服务里**：关了 AI 就回 `mcp_disabled`，
/// 用户看到的是「去设置里打开」。
///
/// ## 两个闭包都不缓存
///
/// `settings` / `sources` 每次请求现读（`AIAccessStore.load` + `AppModel.aiAccessCandidates`）。
/// 缓存一份快照就等于「撤销授权要重启才生效」，违反 §5.2 的「权限每次请求实时重算」。
///
/// ## 抢不到 socket 时怎么办
///
/// 第二份闪寻（比如测试构建和正式构建同时跑）启动时 `start()` 会判成
/// `ownedByAnotherInstance`：本实例**不删**对方的 socket、也不绑定，
/// GUI 其它功能照常。抢的结果是两个都活着但都不可达（§1.3.3.1）。
@MainActor
final class MCPAuthorityController {

    private var listener: AuthorityListener?
    /// History 的每日修剪闸门。**必须是实例而非临时对象**：24 小时的去重状态
    /// 存在它身上，每次临时 new 一个会让「每日一次」退化成「每次启动一次」。
    private var maintenance: HistoryMaintenance?
    private var maintenanceTimer: Timer?

    /// 最近一次启动结果。启动失败只写 stderr，不弹窗：这不是用户能修的事，
    /// 而且正常安装下几乎不会发生。
    private(set) var lastStart: AuthorityListener.StartResult?

    /// 权威端 socket 的位置。
    ///
    /// ★ 开发构建允许用 `FF_AUTHORITY_SOCKET` 指到临时路径。助手端
    ///   （`Sources/FlashFindMCP/main.swift`）读的是**同一个变量名、同一个语义**：
    ///   跨进程 E2E 既不能和用户正开着的那份闪寻抢标准路径，也不该把 socket
    ///   留在用户的 `~/Library` 下。**发布构建里这段被编译掉**，产品只绑标准路径。
    static var socketPath: String {
        #if DEBUG
        if let override = ProcessInfo.processInfo.environment["FF_AUTHORITY_SOCKET"],
           !override.isEmpty {
            return override
        }
        #endif
        return AuthoritySocketPath.standard()
    }

    /// `file_id` 的反查表。**整个权威端共用一张**（Phase 6.4b-1）。
    ///
    /// ★ 只建一次、建在 `~/Library/Application Support/FlashFind2/`：
    /// 三个 Tool 都往里写，它是共享写点，每次请求建一个会让 WAL 的
    /// `-wal` / `-shm` 反复重建；跟着缓存目录走则会在预览里换根，
    /// 于是「预览搜出来的 id，正式 App 查不到」。
    ///
    /// ★ 与 `ai-history.sqlite` 分开：用户点「清空 AI 历史」不该顺手
    /// 把 Agent 手里已有 id 的解析能力清掉（§15.3）。
    private static var sharedReferenceStore: FileReferenceStore?

    /// History 库。**与上面的映射表不是同一个文件**（§15.3）。
    ///
    /// ★ 同样只建一次：每次请求开一次会让 WAL 反复重建。
    private static var sharedHistoryStore: HistoryStore?

    func start(model: AppModel) {
        guard listener == nil else { return }

        if Self.sharedReferenceStore == nil {
            Self.sharedReferenceStore = Self.makeReferenceStore()
        }
        if Self.sharedHistoryStore == nil {
            Self.sharedHistoryStore = Self.makeHistoryStore()
        }
        // ★ 启动时先修剪一次（方案 §6.5 的两个时机之一），然后挂一个每小时的
        //   tick 去接「每日一次」。
        //
        // ★ 为什么是每小时 tick + 24 小时闸门，而不是直接挂一个 24 小时的 Timer：
        //   Timer 在机器睡眠期间不推进，醒来后会补发一次——于是「每日修剪」
        //   会随睡眠时长漂移（睡 10 小时就变成 34 小时一次）。每小时一跳，
        //   由 `runIfNeeded` 自己守 24 小时闸门，睡醒后一小时内就会补上。
        //   ★ tick 里只有一次读时间 + 比较，**与 MCP 请求完全无关**——
        //     修剪绝不能出现在请求热路径上。
        let maintenance = HistoryMaintenance(store: Self.sharedHistoryStore)
        maintenance.runIfNeeded()
        self.maintenance = maintenance
        // ★ 闭包里捕获的是 `maintenance` 自己（`@unchecked Sendable`），不是 `self`：
        //   捕获 `self` 会把这个 Timer 变成「App 一退出就白跑」，还会踩到
        //   MainActor 隔离的编译告警。
        maintenanceTimer = Timer.scheduledTimer(withTimeInterval: 3_600,
                                                repeats: true) { _ in
            maintenance.runIfNeeded()
        }
        let service = Self.service(model: model)
        let candidate = AuthorityListener(path: Self.socketPath, service: service)
        let result = candidate.start()
        lastStart = result

        switch result {
        case .listening:
            listener = candidate
        case .ownedByAnotherInstance:
            // 另一份闪寻已经在服务。日志由 listener 自己写（§1.3.3.1 的固定措辞）。
            listener = nil
        case .failed(let reason):
            AuthorityListener.stderrLog("could not start the IPC listener: \(reason)")
            listener = nil
        }
    }

    /// 打开 `file_id` 的反查表。
    ///
    /// ★ 打不开时**照实说**（返回 nil）：这是一次装配失败，不该让搜索链路
    /// 悄悄退化成「照样返回 id，但那些 id 以后查不出来」（§4.11.4）。
    private static func makeReferenceStore() -> FileReferenceStore? {
        do {
            return try FileReferenceStore(url: FileReferenceStorePath.standard())
        } catch {
            AuthorityListener.stderrLog("could not open the file reference store: \(error)")
            return nil
        }
    }

    /// 打开 History 库。
    ///
    /// ★ 打不开时**照实说**，但**不让 MCP 起不来**：History 是旁路能力，
    ///   它坏掉只该让 `recent` 说「不可用」，不该让 `locate` 也跟着挂
    ///   （§6.6 的同一条纪律：历史故障不许影响搜索）。
    private static func makeHistoryStore() -> HistoryStore? {
        do {
            return try HistoryStore(url: HistoryStorePath.standard())
        } catch {
            AuthorityListener.stderrLog("could not open the history store: \(error)")
            return nil
        }
    }

    /// 装配权威端业务实现。
    ///
    /// ★ 两个闭包都跳 `MainActor` 读 `AppModel`：设置与来源都是界面状态，
    /// 从 socket 的连接线程直接读会踩到未同步的 `@Published`。
    /// ★ 弱捕获：监听可能比某个临时 `AppModel` 活得久（预览 / 测试构造的实例），
    /// 模型没了就按「关着 + 零来源」回答——那是 fail closed，不是放行。
    ///
    /// ★ 6.3b-1 起来源里还带**执行句柄**（provider + 调度器），而且与名单来自
    /// 同一次 `MainActor.run`：判权与执行拿到的是同一刻的对象（§15 #23）。
    /// 没有 provider 的来源照样列出来（它确实存在、也可能被授权），只是执行时
    /// 如实报 `source_unavailable` —— 那是「现在搜不了」，不是「没授权」。
    ///
    /// ★ 6.4b-1 起带上 `file_id` 的反查表：搜索写、`get_metadata` 读，共用一张。
    static func service(model: AppModel) -> RoutingAuthorityService {
        RoutingAuthorityService(
            settings: { [weak model] in
                guard let model else { return .initial }
                return await MainActor.run { AIAccessStore.load(from: model.preferences) }
            },
            sources: { [weak model] in
                guard let model else { return [] }
                return await MainActor.run {
                    // 一次读数：名单、provider、调度器同刻取。
                    let providers = model.aiAccessProviders
                    let scheduler = model.aiAccessScheduler()
                    // ★ 用 `aiAccessUsableCandidates` 而不是 `aiAccessCandidates`：
                    //   「不搜索这台 Mac」是全局关闭，压过 AI 授权（§15 #26）。
                    //   授权的**保存**不在这里做——那条授权仍然留在设置里，
                    //   开关一打开就自动恢复（latent authorization）。
                    return model.aiAccessUsableCandidates.map { candidate in
                        var handle: SourceExecutionHandle?
                        if let provider = providers[candidate.id], let scheduler {
                            handle = SourceExecutionHandle(provider: provider, scheduler: scheduler)
                        }
                        return AuthoritySource(id: candidate.id, name: candidate.name, execution: handle)
                    }
                }
            },
            // ★ 三个搜索 Tool 的写者、`get_metadata` 的读者，是同一张表：
            // 分成两张就会出现「locate 发了 id、get_metadata 查不到」。
            referenceStore: Self.sharedReferenceStore,
            // ★ History 是**另一张库**：它可以被用户清空，映射表不能（§15.3）。
            historyStore: Self.sharedHistoryStore)
    }

    func stop() {
        listener?.stop()
        listener = nil
        maintenanceTimer?.invalidate()
        maintenanceTimer = nil
        maintenance = nil
    }

    // MARK: - 设置页要读的两件事（Phase 9-lite）

    /// 助手那一段的事实：把启动那一刻的 `StartResult` 翻成一句话。
    ///
    /// ★ 只读、不重试。启动失败要重启 App 才会再试一次——设置页里放一个
    /// 「重新启动监听」按钮看着有用，实际会把「socket 被另一份闪寻占着」
    /// 变成用户可以反复点的事。
    var helperStatus: MCPHelperStatus { MCPHelperStatus(start: lastStart) }

    /// 历史里现有多少条。`nil` = 历史库不可用（没建起来或打不开）。
    ///
    /// ★ 与「0 条」严格区分：0 条是正常空库，`nil` 是故障。
    func historyEventCount() -> Int? {
        guard let store = Self.sharedHistoryStore else { return nil }
        return try? store.count()
    }

    /// 清空全部访问记录。
    ///
    /// ★ **只清 `ai-history.sqlite`。** 映射表（`ai-file-reference.sqlite`）一个字节都不碰：
    ///   清掉它会让 Agent 手里已有的 `file_id` 全部失效——用户点的是「清空历史」，
    ///   不是一个「让 AI 手上的文件编号全部作废」的按钮（§15.3）。
    func clearHistory() -> AIHistoryClearOutcome {
        guard let store = Self.sharedHistoryStore else { return .unavailable }
        do {
            let before = try store.count()
            try store.clear()
            return .cleared(before)
        } catch {
            // 失败照实记，并且**不**把界面说成「已清空」。
            AuthorityListener.stderrLog("could not clear the history store: \(error)")
            return .failed
        }
    }
}
