import Foundation
import FlashFindCore

/// 权限页能列出的一条来源。
///
/// 只有 id 与名字：勾选状态在 `AIAccessSettings.allowedSources` 里，
/// 在线状态在 provider 里——**这里不复制任何一份**，免得两处说法不一致。
struct AIAccessCandidate: Identifiable, Hashable {
    let id: String
    let name: String
}

extension AppModel {

    /// 权限页列出的来源：本机 + 每台已添加的 NAS。
    ///
    /// ★ 「此 Mac」用 `SearchSource.local` 的 id 与展示名，不另起一个字符串：
    /// 权限里的 `source_id` 与搜索时用的必须是同一个，否则授权放行了一个
    /// 搜索永远不用的 id，表现就是「勾了却搜不到」。
    ///
    /// 应用搜索（`local_apps`）**不进这个列表**：1.1.2 的 Source 宇宙只含文件来源
    /// （方案 §5.1.1，2026-10-20 冻结）。它不是「一个位置」而是「一种能力」，
    /// 混进「允许的位置」会让「我授权了这个位置」变得含糊；而且应用结果没有
    /// 相对路径、没有 `file_id`，塞进 File Resolver 会让六个 Tool 的契约各多一个特例。
    var aiAccessCandidates: [AIAccessCandidate] {
        [AIAccessCandidate(id: SearchSource.local.id, name: SearchSource.local.displayName)]
            + nasSources.map { AIAccessCandidate(id: $0.sourceID, name: $0.displayName) }
    }

    /// 现在还在的来源 id。判定里用来剔掉「授权还在、来源已删」的残留。
    var aiAccessExistingSourceIDs: Set<String> {
        Set(aiAccessCandidates.map(\.id))
    }

    /// 判定与执行用的来源：**来源宇宙 ∩ 全局开关**（§15 #26，v0.27 拍板）。
    ///
    /// ## 两个开关的优先级：全局关闭压过 AI 授权
    ///
    /// 「不搜索这台 Mac」（`ff2.localEnabled`）是来源的**全局可用开关**；
    /// AI 授权是**额外权限**。权限只能收紧，不能把用户全局关掉的东西重新打开，
    /// 否则 UI 上写着「不搜索这台 Mac」，Agent 那边却还在搜——两个开关的语义直接打架。
    ///
    /// ```text
    /// localEnabled = false + 授权里有 local_mac
    ///   → list_sources 不出现 local_mac
    ///   → locate / search 不执行本机 provider
    ///   → 显式 source_ids: ["local_mac"] 得到 source_denied
    /// ```
    ///
    /// 用同一个 `source_denied`（而不是另造一个码）是 §4.3.1 的老规则：
    /// 「未授权」与「全局关掉」对 Agent 必须不可区分，否则它靠试 id 就能枚举
    /// 用户有几台设备。
    ///
    /// ## ★ 授权是 latent 的：不要拿这个集合去 prune
    ///
    /// 本机关着的时候，用户在 AI 设置里勾过的 `local_mac` **必须原样留着**。
    /// 落盘（`AIAccessController.save`）与删来源后的清理
    /// （`forgetSources`，走 `aiAccessExistingSourceIDs`）用的都是**完整宇宙**。
    /// 一旦有人把这里换成「当前可执行集合」去 `pruned`，用户关一次本机搜索
    /// 就会把那条授权**永久删掉**——UI 上只是「关了个开关」，恢复时却要重新授权。
    var aiAccessUsableCandidates: [AIAccessCandidate] {
        aiAccessCandidates.filter { candidate in
            candidate.id != SearchSource.local.id || localEnabled
        }
    }

    /// `source_id` → **此刻那个 provider 对象**（Phase 6.3b-1）。
    ///
    /// ★ 只在 `@MainActor` 上取，而且**必须与 `aiAccessCandidates` 在同一次读数里**取：
    /// 判权用的是那份名单，执行必须用同一刻的 provider，否则就会出现
    /// 「判权时是 A、执行时是 A′」（§15 #23）。
    ///
    /// ★ 键取 `provider.source.id` 而不是字典键：`nativeProviders` 的键是配置 id，
    /// 而 `source.id` 才是搜索结果里会出现的那个（两者本该相等，但这里宁可跟结果走）。
    var aiAccessProviders: [String: any SearchProvider] {
        // ★ 取执行句柄**之前**把本机范围套好（Phase 6.3b-4）：MCP 与 GUI 必须搜
        //   同一批文件。漏了这一步，从没在搜索框里搜过的用户会让 Agent 按默认的
        //   「整台 Mac」搜，而他在设置里选的是「只搜索指定文件夹」。
        applyLocalScopeToProvider()
        var map: [String: any SearchProvider] = [localProvider.source.id: localProvider]
        for provider in nativeProviders.values {
            map[provider.source.id] = provider
        }
        return map
    }

    /// 把「本机搜索范围」套到那个 GUI 与 MCP **共用**的 provider 上。
    ///
    /// ★ `mode` 与 `folders` 必须一起给：从「已选文件夹」切回「整台 Mac」时，
    ///   用户挑过的文件夹仍留在 `localFolders` 里（切回去还要用）；只给 folders
    ///   会让 provider 以为还在文件夹模式，把全盘搜索也限制在那几个旧目录里。
    ///
    /// ★ 两个入口（GUI 搜索、MCP 执行）都走这一处。原来只写在 GUI 的搜索入口里，
    ///   于是「配好文件夹、但一次都没在搜索框里搜过」的用户，Agent 先来搜时
    ///   provider 还停在默认的整台 Mac —— 6.3b-4 的产品级 E2E 抓到的就是这个
    ///   （`hits=0`：临时目录没进系统索引，Spotlight 模式什么也搜不到）。
    func applyLocalScopeToProvider() {
        localProvider.folders = localFolders
        localProvider.mode = localSearchMode
    }

    /// 拿到 MCP 与 GUI **共用的那个**调度器（Phase 6.3b-1）。
    ///
    /// 顺手保证协调器已经建起来：只在 GUI 里搜过、从没打开过设置的用户，
    /// 首次 MCP 请求也不该得到「搜不了」。`ensureProviderCoordinator()` 本身幂等。
    func aiAccessScheduler() -> SearchScheduler? {
        ensureProviderCoordinator()
        return providerCoordinator?.searchScheduler
    }

    // MARK: - AI 设置页要读的两行事实（Phase 9-lite）

    /// 「MCP 助手」那一行的状态。没注入监听时如实说「未启动」。
    var mcpHelperStatus: MCPHelperStatus {
        mcpAuthority?.helperStatus ?? .notStarted
    }

    /// 「AI 历史」那一行的事实：开关取**已保存**值（不是草稿），条数取自库。
    ///
    /// ★ 读已保存而不是草稿：草稿是「改了一半还没点保存」的界面状态，
    ///   拿它去说明「现在记不记录」会骗人（`AIAccessController` 顶上那条规矩）。
    var aiHistorySummary: AIHistorySummary {
        AIHistorySummary(isRecording: aiAccess.saved.isEnabled,
                         eventCount: mcpAuthority?.historyEventCount() ?? nil)
    }

    /// 清空 AI 历史。只清历史库，映射表不动。
    func clearAIHistory() -> AIHistoryClearOutcome {
        mcpAuthority?.clearHistory() ?? .unavailable
    }

    /// AI 访问是否**已保存且已开启**——注意不是草稿。
    ///
    /// 视图里不许直接写 `aiAccess.saved`（`AIAccessSettingsSurfaceTests` 有一条守着，
    /// 因为开关一旦绑到已保存值，点了不会动）。但「接入提示词」与「历史」说的是
    /// **当下的事实**，只能读已保存值：草稿是「改了一半还没点保存」，
    /// 拿它去给出一段可复制的接入说明，用户复制过去必然连不上。
    /// 所以从这里开一个只读口子，而不是让视图自己去摸 saved。
    var isAIAccessGranted: Bool { aiAccess.saved.isEnabled }

    // MARK: - 接入提示词（Phase 9-lite 追加）

    /// 复制给 AI 客户端的那段话。
    ///
    /// ★ Helper 路径按**当前这个包的位置**推（`Bundle.main.bundleURL`），
    ///   不写死 `/Applications/闪寻.app/...`：App 改名、被拖到 `~/Applications`、
    ///   或者跑的是预览包，三种情况下路径都该自己是对的。
    ///   Core 拿不到「哪个包在跑」这件事，所以 bundle 由这里读、只把路径传进去。
    var aiIntegrationPrompt: MCPIntegrationPrompt {
        MCPIntegrationPrompt(
            helperPath: MCPIntegrationPrompt.helperPath(forAppAt: Bundle.main.bundleURL))
    }
}
