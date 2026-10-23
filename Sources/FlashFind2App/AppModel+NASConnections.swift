import AppKit
import SwiftUI
import Combine
import FlashFindCore

// ─────────────────────────────────────────────────────────────────────────────
// AppModel 的「NAS 连接生命周期」分区（Stage 3A）。
//
// 这一块 577 行原来是跟在 `// MARK: - 全局快捷键转发` 后面的——标注和内容对不上，
// 顺着读很容易以为快捷键有 580 行。搬出来之后 MARK 各归各位。
//
// 代价要写清楚：跨文件 extension 看不到主文件的 `private`，所以这一块用到的
// 49 个共享状态/工具方法已在主文件改为 internal。它们本来就被全文件多处引用
// （`runtimes`、`preferences`、`queryID`、`displayed*` ……），标 private 只是
// 文件级封装，拆开后必须放开。同一模块内 internal 已是最小可见范围，对外 API 未变。
//
// 行为一行未改，界面与调用点仍是 `model.xxx`，一行不动。
// ─────────────────────────────────────────────────────────────────────────────

extension AppModel {
    func persist(_ profiles: [NASConnectionProfile]) throws {
        let data = try JSONEncoder().encode(profiles)
        preferences.set(data, forKey: profilesKey)
    }
    func initialize(_ profile: NASConnectionProfile) {
        let runtime = NASRuntime(); runtimes[profile.id] = runtime
        runtime.blocked = preferences.bool(forKey: "ff2.permissionPending." + profile.cacheProfile)
        connectionStates[profile.id] = NASConnectionState()
        if fixtureMode {
            setState(profile.id, profile.isConfigured ? .idle : .unconfigured, profile.isConfigured ? "UI 样例：尚未连接，没有缓存" : "尚未配置 HTTPS 索引地址和账号")
            return
        }
        guard profile.isConfigured else {
            setState(profile.id, .unconfigured, "尚未配置 HTTPS 索引地址和账号；不能同步或搜索")
            return
        }
        do {
            runtime.coordinator = try SyncCoordinator(directory: AccountProfile.directory(root: cacheRoot, address: profile.address, username: profile.username))
            let epoch = runtime.epoch
            Task {
                let cached = await runtime.coordinator?.sources() ?? []
                let available = (try? await runtime.coordinator?.searchableSourceIDs()) ?? []
                guard runtime.epoch == epoch else { return }
                connectionStates[profile.id]?.sources = cached
                connectionStates[profile.id]?.cachedSourceIDs = available
                connectionStates[profile.id]?.message = runtime.blocked ? "权限同步未完成，缓存暂时隔离，请重新连接验证" : (available.isEmpty ? "尚未连接；没有可搜索缓存" : "尚未连接；已有离线缓存，请选择搜索来源")
                if runtime.blocked {
                    connectionStates[profile.id]?.phase = .error
                    connectionStates[profile.id]?.failureKind = .permissionVerification
                }
                updateCompatibility(); changedQuery()
            }
        } catch {
            runtime.blocked = true
            setState(profile.id, .error, "缓存无法初始化：\(error.localizedDescription)。保存配置或重新连接可重试。")
            connectionStates[profile.id]?.failureKind = .unknown
        }
    }
    @discardableResult
    func addConnection() -> Bool {
        guard !AppEnvironment.isPreview || fixtureMode else { status = "UI 预览不能保存真实 NAS 配置"; return false }
        guard !configurationBlocked else { status = "原 NAS 配置无法读取，已保留；请先恢复配置后再添加"; return false }
        let profile = NASConnectionProfile(name: "NAS \(nasConnections.count + 1)")
        do {
            try persist(nasConnections + [profile]); nasConnections.append(profile)
            initialize(profile); selectConnection(profile.id)
            status = "已添加 \(profile.name)；请填写 HTTPS 索引地址和账号后保存"
            return true
        } catch { status = "添加 NAS 失败：" + error.localizedDescription; return false }
    }
    func selectConnection(_ id: String) {
        guard let profile = nasConnections.first(where: { $0.id == id }) else { return }
        selectedConnectionID = id; connectionName = profile.name; address = profile.address; username = profile.username
        pin = profile.certificateSHA256; rememberPassword = profile.rememberPassword
        loadingPassword = true; password = runtimes[id]?.password ?? ""; loadingPassword = false
        passwordDraftIdentity = profile.cacheProfile; updateCompatibility()
        localSources.restoreImportedShare(for: id)
    }
    @discardableResult
    func saveConnection() -> Bool {
        guard (!AppEnvironment.isPreview || fixtureMode), let id = selectedConnectionID,
              let index = nasConnections.firstIndex(where: { $0.id == id }) else { return false }
        guard runtimes[id]?.task == nil else { status = "此 NAS 正在连接或同步，请先断开再保存配置"; return false }
        do {
            guard let url = URL(string: address.trimmingCharacters(in: .whitespacesAndNewlines)), url.scheme == "https",
                  url.host != nil, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
                throw FlashFindError.message("请输入不含密码、查询或片段的 HTTPS 地址")
            }
            let canonical = url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            let old = nasConnections[index]
            var updated = old; updated.name = connectionName.trimmingCharacters(in: .whitespacesAndNewlines)
            if updated.name.isEmpty { updated.name = url.host ?? "NAS" }
            updated.address = canonical; updated.username = username.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !updated.username.isEmpty else { throw FlashFindError.message("请填写索引服务账号；不能把空白账号配置标为已就绪") }
            updated.rememberPassword = rememberPassword
            let changedAccount = old.cacheProfile != updated.cacheProfile
            let changedServer = old.address.trimmingCharacters(in: CharacterSet(charactersIn: "/")) != canonical
            guard !nasConnections.contains(where: { $0.id != id && $0.cacheProfile == updated.cacheProfile }) else {
                throw FlashFindError.message("此服务器与账号已保存，请选择现有连接；不同账号可分别添加")
            }
            let accountChangedWithoutNewPassword = changedAccount && passwordDraftIdentity != updated.cacheProfile
            // Only unchanged servers may carry an existing trust decision.
            updated.certificateSHA256 = changedServer ? "" : old.certificateSHA256
            if changedAccount { updated.selectedSourceIDs = []; updated.bindings = [:]; updated.legacyCredentialAccount = nil }
            var profiles = nasConnections; profiles[index] = updated
            try persist(profiles)
            nasConnections = profiles
            if changedAccount {
                stop(id); initialize(updated)
                // A typed password is accepted only as an explicit new-account draft;
                // never inherit the runtime credential from the previous account.
                if accountChangedWithoutNewPassword { password = "" }
            }
            address = canonical; pin = updated.certificateSHA256
            invalidate(); updateCompatibility(); changedQuery()
            status = "已保存 \(updated.name)；\(connectionStates[id]?.hasCache == true ? "已有缓存" : "尚未连接并同步")"
            return true
        } catch { status = error.localizedDescription; return false }
    }
    func updateProfile(_ id: String, _ change: (inout NASConnectionProfile) -> Void) -> Bool {
        guard let index = nasConnections.firstIndex(where: { $0.id == id }) else { return false }
        var profiles = nasConnections; change(&profiles[index])
        do { try persist(profiles); nasConnections = profiles; return true }
        catch { status = error.localizedDescription; return false }
    }
    func stop(_ id: String) {
        guard let runtime = runtimes[id] else { return }
        runtime.epoch = UUID(); runtime.task?.cancel(); runtime.poll?.cancel()
        runtime.task = nil; runtime.poll = nil; runtime.connection = nil; runtime.password = ""
        storedCredentialRequests.remove(id)
        fixtureConnectedIDs.remove(id)
    }
    func removeConnection(_ id: String) {
        guard (!AppEnvironment.isPreview || fixtureMode), !configurationBlocked,
              let profile = nasConnections.first(where: { $0.id == id }) else { return }
        do {
            let key = "ff2.multiNAS.archived.v1"
            var archive: [NASConnectionProfile] = []
            if let data = preferences.data(forKey: key) { archive = try JSONDecoder().decode([NASConnectionProfile].self, from: data) }
            archive.append(profile)
            preferences.set(try JSONEncoder().encode(archive), forKey: key)
            let remaining = nasConnections.filter { $0.id != id }
            try persist(remaining)
            stop(id); runtimes.removeValue(forKey: id); connectionStates.removeValue(forKey: id)
            nasConnections = remaining
            if selectedConnectionID == id {
                selectedConnectionID = nil; connectionName = ""; address = ""; username = ""; password = ""; pin = ""
                sources = []; bindings = [:]; selectedSourceIDs = []; rememberPassword = false
                if let first = remaining.first { selectConnection(first.id) }
            }
            updateCompatibility(); invalidate(); changedQuery()
            status = "已移除连接配置；离线缓存、本机凭据及配置归档保留"
        } catch { status = error.localizedDescription }
    }
    func disconnectConnection(_ id: String) {
        guard !AppEnvironment.isPreview || fixtureMode else { return }
        stop(id); if selectedConnectionID == id { password = "" }
        setState(id, .disconnected, "已断开；" + cacheDescription(id))
        invalidate(); changedQuery()
    }
    func setConnectionEnabled(_ id: String, enabled value: Bool) {
        if value && !connectionCanParticipate(id) { status = nasSearchAvailabilityMessage; updateCompatibility(); return }
        guard (!AppEnvironment.isPreview || fixtureMode), updateProfile(id, { $0.enabled = value }) else { return }
        if !value { stop(id); setState(id, .disconnected, "已停用；不参与搜索") }
        updateCompatibility()
        invalidate(); changedQuery()
    }
    func setSyncPaused(_ id: String, paused: Bool) {
        guard connectionCanPause(id) else { status = "此 NAS 尚未连接，暂无同步任务可暂停"; return }
        guard (!AppEnvironment.isPreview || fixtureMode), updateProfile(id, { $0.syncPaused = paused }) else { return }
        let credential = runtimes[id]?.password ?? "", connection = runtimes[id]?.connection
        let wasFixtureConnected = fixtureConnectedIDs.contains(id)
        stop(id); runtimes[id]?.password = credential; runtimes[id]?.connection = connection
        if wasFixtureConnected { fixtureConnectedIDs.insert(id) }
        setState(id, paused ? .paused : .disconnected, paused ? "同步已暂停；" + cacheDescription(id) : "同步已恢复，请连接以开始同步")
        invalidate(); changedQuery()
        if !paused, enabled { restartPolling(id); refreshConnection(id) }
    }
    func setState(_ id: String, _ phase: NASConnectionPhase, _ message: String) {
        if connectionStates[id] == nil { connectionStates[id] = NASConnectionState() }
        connectionStates[id]?.phase = phase; connectionStates[id]?.message = message
        if phase != .error && phase != .offline { connectionStates[id]?.failureKind = nil }
        updateCompatibility()
    }
    func updateCompatibility() {
        for profile in nasConnections {
            guard var state = connectionStates[profile.id] else { continue }
            state.hasCache = !state.cachedSourceIDs.isEmpty && runtimes[profile.id]?.blocked != true
            state.canSearch = profile.isConfigured && profile.enabled && state.hasCache && !state.cachedSourceIDs.intersection(profile.selectedSourceIDs).isEmpty
            state.canSync = profile.isConfigured && !profile.syncPaused && !profile.selectedSourceIDs.isEmpty && (runtimes[profile.id]?.connection != nil || fixtureConnectedIDs.contains(profile.id)) && runtimes[profile.id]?.task == nil
            connectionStates[profile.id] = state
        }
        connecting = connectionStates.values.contains { $0.phase == .connecting }
        syncing = connectionStates.values.contains { $0.phase == .syncing }
        if let id = selectedConnectionID, let profile = nasConnections.first(where: { $0.id == id }) {
            sources = connectionStates[id]?.sources ?? []; bindings = profile.bindings
            selectedSourceIDs = profile.selectedSourceIDs
        }
    }
    func connectionGuidance(_ id: String) -> NASConnectionGuidance {
        guard let profile = nasConnections.first(where: { $0.id == id }), let state = connectionStates[id] else {
            return NASConnectionGuidance(title: "尚未添加", detail: "先添加 NAS 的 HTTPS 索引服务", action: .configure, actionTitle: "添加 NAS")
        }
        guard profile.isConfigured else { return NASConnectionGuidance(title: "待配置", detail: "填写 HTTPS 索引服务地址和账号后保存；SMB 地址不用于索引登录", action: .configure, actionTitle: "填写连接信息") }
        if state.phase == .connecting { return NASConnectionGuidance(title: "连接中", detail: "正在验证此服务器与账号，请稍候") }
        if state.phase == .syncing { return NASConnectionGuidance(title: "同步中", detail: state.message) }
        if let failure = state.failureKind {
            let title = state.canSearch && enabled ? "连接失败 · 可用离线缓存" : "连接失败"
            switch failure {
            case .credentials: return NASConnectionGuidance(title: title, detail: "在此 NAS 的连接设置重新输入账号密码，再连接；SMB 会话不会提供索引令牌", action: .configure, actionTitle: "检查账号与密码")
            case .setup: return NASConnectionGuidance(title: title, detail: "先在此 NAS 的闪寻管理页面完成初始化，再连接", action: .configure, actionTitle: "检查服务初始化")
            case .certificate: return NASConnectionGuidance(title: title, detail: "核对服务器地址和证书；证书变化不能自动信任，不要把它当作密码错误", action: .configure, actionTitle: "核对地址与证书")
            case .authorization: return NASConnectionGuidance(title: title, detail: "当前账号缺少来源权限，请检查此 NAS 的授权；不会自动扩大共享权限", action: .configure, actionTitle: "检查账号授权")
            case .rateLimited: return NASConnectionGuidance(title: title, detail: "登录尝试过多，请稍后再连接；不要连续重试", action: .configure, actionTitle: "检查登录信息")
            case .resync, .permissionVerification:
                return NASConnectionGuidance(title: title, detail: failure == .resync ? "索引或权限已更新，请重新同步当前来源" : "NAS 文件权限尚未验证，请检查 SMB 服务后重新连接；隔离缓存不会参与搜索", action: connectionCanSync(id) ? .sync : .connect, actionTitle: connectionCanSync(id) ? "重新同步" : "重新连接验证")
            case .network: return NASConnectionGuidance(title: title, detail: "检查网络与此 NAS 的 HTTPS 索引服务是否运行，再连接；不会自动部署或重启 NAS", action: .connect, actionTitle: "重试连接")
            case .unknown: return NASConnectionGuidance(title: title, detail: state.message, action: .configure, actionTitle: "检查连接设置")
            }
        }
        if profile.syncPaused { return NASConnectionGuidance(title: state.canSearch && enabled ? "同步已暂停 · 可搜索" : "同步已暂停", detail: state.hasCache ? "已有缓存保留；恢复后只同步此连接" : "暂无可搜索缓存", action: .resumeSync, actionTitle: "恢复同步") }
        if state.canSearch && enabled {
            let connected = runtimes[id]?.connection != nil || fixtureConnectedIDs.contains(id)
            return NASConnectionGuidance(title: "可搜索", detail: connected ? "已连接；所选来源已有可读缓存" : "当前未连接；使用已验证的离线缓存", action: connected ? .none : .connect, actionTitle: connected ? "" : "重新连接")
        }
        if connectionCanParticipate(id) { return NASConnectionGuidance(title: "缓存已就绪", detail: "开启参与搜索后即可查询所选来源", action: .enableSearch, actionTitle: "启用搜索") }
        let connected = runtimes[id]?.connection != nil || fixtureConnectedIDs.contains(id)
        if connected && profile.selectedSourceIDs.isEmpty { return NASConnectionGuidance(title: "已连接", detail: "选择有权限的搜索来源并同步，完成后才可搜索", action: .selectSources, actionTitle: "选择搜索目录") }
        if connected { return NASConnectionGuidance(title: "已连接 · 等待同步", detail: "所选来源尚无可读缓存", action: .sync, actionTitle: "同步所选目录") }
        return NASConnectionGuidance(title: "待连接", detail: "配置已保存；连接索引服务后选择目录，不等于已可搜索", action: .connect, actionTitle: "连接并验证")
    }
    func runConnectionNextAction(_ id: String) {
        switch connectionGuidance(id).action {
        case .connect:
            if selectedConnectionID == id && (address != nasConnections.first(where: { $0.id == id })?.address || username != nasConnections.first(where: { $0.id == id })?.username) {
                status = "连接信息尚未保存，请先保存配置再连接"; return
            }
            connectConnection(id)
        case .sync: refreshConnection(id)
        case .enableSearch:
            guard connectionCanParticipate(id) else { status = nasSearchAvailabilityMessage; return }
            enabled = true; preferences.set(true, forKey: "ff2.multiNAS.enabled"); setConnectionEnabled(id, enabled: true)
        case .resumeSync: setSyncPaused(id, paused: false)
        case .configure, .selectSources: status = connectionGuidance(id).detail
        case .none: break
        }
    }
    func recordConnectionFailure(_ id: String, _ error: Error) {
        let kind: NASFailureKind
        if let http = error as? HTTPFailure {
            switch http.status {
            case 401: kind = .credentials
            case 403: kind = .authorization
            case 409: kind = .resync
            case 429: kind = .rateLimited
            case 503: kind = http.code == "setup_required" ? .setup : .permissionVerification
            default: kind = .unknown
            }
        } else if let url = error as? URLError {
            switch url.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate, .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid, .cancelled: kind = .certificate
            default: kind = .network
            }
        } else { kind = error.localizedDescription.contains("请输入此 NAS") ? .credentials : .unknown }
        connectionStates[id]?.failureKind = kind
    }
    func invalidate() {
        providerCoordinator?.cancel()
        contextRevision &+= 1; resultsAreCurrent = false; displayedRevision = nil
        searchTask?.cancel(); spotlight?.cancel(); queryID = UUID()
        results = []; selected = nil; searching = false
    }
    func changedQuery() {
        // 一开始输入就把首次使用的键位提示收起——它只在「还没动手」时有用。
        dismissSearchHints()
        searchTask?.cancel(); spotlight?.cancel(); let id = UUID(); queryID = id
        resultsAreCurrent = false; displayedRevision = nil; searchFailure = nil; searchWarnings = []
        // 打开失败的提示条讲的是「刚才点的那一条结果」。查询一换（或清空）
        // 那条结果就不在列表里了，留着它会对着空列表继续喊「无法打开文件」。
        openFailure = nil
        let text = query, revision = contextRevision, searchScope = scope
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { results = []; selected = nil; searching = false; return }
        if AppEnvironment.isPreview {
            results = AppEnvironment.fixtures(for: query); selected = results.first?.id
            let active = fixtureMode ? nasConnections.filter { connectionStates[$0.id]?.canSearch == true } : nasConnections
            if fixtureMode && active.isEmpty && (scope == .nas || !localEnabled) {
                results = []; selected = nil; searchWarnings = [nasSearchAvailabilityMessage]
            } else if !active.isEmpty {
                for i in results.indices {
                    results[i].connectionID = active[i % active.count].id; results[i].connectionName = active[i % active.count].name
                    if fixtureMode { results[i].sourceID = "fixture-source" }
                }
            }
            if !fixtureMode && !nasConnections.isEmpty {
                searchWarnings = ["备份 NAS：UI 样例 · 离线缓存"]
            }
            publishCurrent(text, searchScope, revision); searching = false
            if query == "error" { searchFailure = "NAS 暂时不可用，请检查网络连接。" }
            return
        }
        ensureProviderCoordinator();providerCoordinator?.cancel()
        results=[];selected=nil
        // 本机范围只有一处出处（MCP 执行侧也要套，见 `AppModel+AIAccess`）。
        applyLocalScopeToProvider()
        for provider in nativeProviders.values { provider.queryBudgetMs = max(1, min(120, nativeSearchTimeoutSeconds)) * 1000 }
        // 请求哪些来源完全由当前配置决定：不再写死任何设备标识。
        // ★ 判定搬到 Core 的 `SearchRequestPlan`：这台机器到底有没有请求 NAS，
        // 原来只能在界面上点出来，现在可以直接断言（R01 的验证面）。
        //
        // 应用搜索跟着「本机」作用域走（`includeApps` 与 `includeLocal` 同源），
        // 但**不受「指定文件夹」限制**：那种模式刻意不扫全盘，而应用不在用户的
        // 数据文件夹里，本就不该被那条限制挡住——否则用户设了文件夹就搜不到 app，
        // 而这个功能在他看来是坏的。
        let includeLocalSide = localEnabled && scope != .nas
        let requested = SearchRequestPlan(
            localSourceID: SearchSource.local.id,
            appSourceID: SearchSource.apps.id,
            includeLocal: includeLocalSide,
            includeApps: includeLocalSide,
            includeNAS: enabled && scope != .local,
            nasCandidates: nativeProviders.map { id, provider in
                (sourceID: id,
                 ready: provider.ready,
                 enabled: nasSources.first(where: { $0.id == id })?.enabled == true)
            }).sourceIDs
        // ★ 「还在搜吗」的判据搬到 Core 的 `SearchCompletionTracker`。
        // 原来是一行内联的 `!requested.isSubset(of: terminal)`：断开一台正在搜的 NAS
        // 之后，如果那个来源永远不发终态，这条判据就永远为真 —— 结果行都出来了，
        // 状态栏却一直显示「正在搜索」。搬到 Core 之后这条判据才可能被断言。
        var completion = SearchCompletionTracker(requested: requested)
        searchTask=Task {
            // 本地立即出结果；NAS 走 Coordinator 的 600ms 防抖，
            // 避免用户输入过程中产生多次无谓的远端请求。
            // 依据： 间隔对照实验，四档间隔均为 100%，
            // debounce 不是为规避设备退化，而是节流请求数。
            guard queryID==id,contextRevision==revision else { return }
            searching = !requested.isEmpty
            // ★ queryID 由这里生成并一路传到底（P1-01）：
            // 不传的话 Coordinator 会另造一个，于是界面与协调层各持一个 ID，
            // 取消、旧结果迟到、并发返回时根本对不上谁是谁。
            providerCoordinator?.searchDebounced(text,sources:requested,queryID:id) { [weak self] event in
                guard let self,self.queryID==id,self.contextRevision==revision else { return }
                self.recordProviderEvent(event)
                // 批量合并。逐条 firstIndex + 逐条 append/排序是 O(n²)：
                // 结果上千条时，单是排序就能吃掉主线程几百毫秒，界面明显卡顿。
                // 现在按「已有索引 → 追加新项 → 一次排序」处理，O(n)。
                if !event.results.isEmpty {
                    var index = Dictionary(uniqueKeysWithValues: self.results.enumerated()
                        .map { ($0.element.id, $0.offset) })
                    var appended = false
                    for row in event.results {
                        if let position = index[row.id] { self.results[position] = row }
                        else {
                            index[row.id] = self.results.count
                            self.results.append(row); appended = true
                        }
                    }
                    self.results.sort { $0.rank == $1.rank ? $0.name < $1.name : $0.rank < $1.rank }
                    _ = appended
                }
                if !self.results.contains(where:{$0.id==self.selected}) { self.selected=self.results.first?.id }
                completion.note(event)
                if let message=event.message,!self.searchWarnings.contains(message) { self.searchWarnings.append(message) }
                self.searching = completion.isSearching
                // A source error never hides successful results from another source.
                self.searchFailure=nil
                self.publishCurrent(text,searchScope,revision)
            }
        }
    }
    func publishCurrent(_ text: String, _ searchScope: SearchScope, _ revision: UInt64) {
        displayedQuery = text; displayedScope = searchScope; displayedRevision = revision; resultsAreCurrent = true
    }
    func moveResultSelection(_ delta: Int) {
        guard canUseDisplayedResults, !results.isEmpty else { return }
        let current = results.firstIndex(where: { $0.id == selected }) ?? (delta > 0 ? -1 : results.count)
        selected = results[max(0, min(results.count - 1, current + delta))].id
    }
    /// 连上 NAS 之后把总开关打开（R01）。
    ///
    /// 只在这种前提下动手：总开关当前是关的，**且**用户从来没有显式设置过它。
    /// 用户主动关掉的场景（例如只想搜本机）必须原样保留，不能反过来替他打开。
    func ensureNASSearchEnabled() {
        guard !enabled, !masterSwitchIsExplicit, (!AppEnvironment.isPreview || fixtureMode) else { return }
        enabled = true
        masterSwitchIsExplicit = true
        preferences.set(true, forKey: NASMasterSwitch.storageKey)
        invalidate()
        changedQuery()
    }

    func toggleNetwork() {
        guard !AppEnvironment.isPreview || fixtureMode else { return }
        // 用户动过开关，从这一刻起它就是显式的，不再允许自动改写。
        masterSwitchIsExplicit = true
        preferences.set(enabled, forKey: NASMasterSwitch.storageKey)
        if enabled && !hasSelectedNASSource { status = nasSearchAvailabilityMessage }
        if !enabled { for id in runtimes.keys { stop(id); setState(id, .disconnected, "网络索引已停用；保留缓存") } }
        invalidate(); changedQuery()
    }
    func connect() {
        guard !AppEnvironment.isPreview || fixtureMode else { return }
        if selectedConnectionID == nil {
            let draft = (connectionName, address, username, password, rememberPassword)
            addConnection()
            (connectionName, address, username, password, rememberPassword) = draft
        }
        guard saveConnection(), let id = selectedConnectionID else { return }
        connectConnection(id)
    }
    func connectConnection(_ id: String, interactive: Bool = true) {
        if fixtureMode { connectFixture(id); return }
        guard !AppEnvironment.isPreview, let profile = nasConnections.first(where: { $0.id == id }), profile.isConfigured, !profile.syncPaused,
              let runtime = runtimes[id], runtime.task == nil else { return }
        if runtime.coordinator == nil { initialize(profile) }
        guard let current = runtimes[id] else { return }
        let credential = interactive && selectedConnectionID == id && passwordDraftIdentity == profile.cacheProfile && draftIdentity == profile.cacheProfile ? password : current.password
        let epoch = current.epoch
        setState(id, .connecting, "正在连接")
        current.task = Task {
            defer { if current.epoch == epoch { current.task = nil; updateCompatibility() } }
            do {
                var secret = credential
                if secret.isEmpty && profile.rememberPassword && credentialAccessAllowed && storedCredentialRequests.remove(id) != nil {
                    secret = await Task.detached {
                        SecureStorage.read(account: profile.credentialAccount,
                                            identity: profile.credentialIdentity,
                                            allowInteraction: interactive)
                            ?? profile.legacyCredentialAccount.flatMap { SecureStorage.read(account: $0, allowInteraction: interactive) }
                    }.value ?? ""
                }
                try Task.checkCancellation(); guard current.epoch == epoch else { return }
                guard !secret.isEmpty else { throw FlashFindError.message("请输入此 NAS 账号密码") }
                guard let url = URL(string: profile.address) else { throw FlashFindError.message("无效服务器地址") }
                var trust = profile.certificateSHA256
                if trust.isEmpty {
                    guard interactive else { throw FlashFindError.message("请在设置中连接并确认此服务器证书") }
                    let fingerprint = try await ServerConnection(settings: ServerSettings(address: url, username: profile.username, certificateSHA256: "")).probeCertificate()
                    try Task.checkCancellation(); guard current.epoch == epoch else { return }
                    let alert = NSAlert(); alert.messageText = "信任 \(profile.name) 的索引服务器？"
                    alert.informativeText = "\(profile.address)\nSHA256: \(fingerprint)"
                    alert.addButton(withTitle: "信任并连接"); alert.addButton(withTitle: "取消")
                    guard alert.runModal() == .alertFirstButtonReturn else { setState(id, .disconnected, "已取消证书信任；保留离线缓存"); return }
                    trust = fingerprint
                    guard updateProfile(id, { $0.certificateSHA256 = fingerprint }) else { return }
                    if selectedConnectionID == id { pin = fingerprint }
                }
                let connection = try ServerConnection(settings: ServerSettings(address: url, username: profile.username, certificateSHA256: trust))
                try await connection.login(password: secret)
                try Task.checkCancellation(); guard current.epoch == epoch else { return }
                current.password = secret; current.connection = connection
                restartPolling(id)
                enabled = true; preferences.set(true, forKey: "ff2.multiNAS.enabled")
                try await synchronize(id, runtime: current, epoch: epoch)
                 if profile.rememberPassword && credentialAccessAllowed {
                     let saved = secret
                     try await Task.detached {
                         try SecureStorage.save(saved, account: profile.credentialAccount,
                                                identity: profile.credentialIdentity,
                                                reason: "连接成功后保存（旧连接管理）")
                     }.value
                 }
                 // 登录已经成功 —— 此刻密码要么刚写进新键、要么本来就在新键里，
                 // 于是 1.0 旧键（`<地址>|<账号>`）下那份副本就成了纯冗余：
                 // 它不含来源 ID，删来源 / 关「记住密码」都点不到它，
                 // 只能在这里趁「新的一份确定可用」时定点清掉。
                 // 不看 rememberPassword：关掉记住意味着本机不该留密码，
                 // 旧键那一份更要删。
                 if let legacy = profile.legacyCredentialAccount, credentialAccessAllowed {
                     CredentialStore.removeLegacyItem(legacy,
                                                      migratedTo: profile.credentialAccount,
                                                      reason: "旧键规则的副本已由新键接管")
                 }
                guard current.epoch == epoch else { return }; restartPolling(id)
            } catch {
                guard current.epoch == epoch else { return }
                current.connection = nil
                current.failures += 1
                blockPermissionFailure(id, error: error, epoch: epoch)
                setState(id, current.blocked ? .error : .offline, error.localizedDescription + (current.blocked ? "；权限同步未完成，此 NAS 缓存暂时隔离" : "；" + cacheDescription(id)))
                recordConnectionFailure(id, error)
                status = profile.name + "：" + error.localizedDescription
                await reloadSources(id, current, epoch); changedQuery()
            }
        }
    }
    func refresh() {
        guard (!AppEnvironment.isPreview || fixtureMode), enabled else { return }
        for profile in nasConnections where profile.enabled && !profile.syncPaused { refreshConnection(profile.id) }
    }
    func refreshConnection(_ id: String) {
        if fixtureMode { syncFixture(id); return }
        guard !AppEnvironment.isPreview, enabled, let profile = nasConnections.first(where: { $0.id == id }), profile.isConfigured, !profile.syncPaused,
              let runtime = runtimes[id], runtime.task == nil else { return }
        guard runtime.connection != nil else { status = "请先连接 \(profile.name) 的 HTTPS 索引服务；SMB 挂载不会提供索引会话"; return }
        guard !profile.selectedSourceIDs.isEmpty else { status = "请先选择此 NAS 的搜索来源再同步"; return }
        let epoch = runtime.epoch
        runtime.task = Task {
            defer { if runtime.epoch == epoch { runtime.task = nil; updateCompatibility() } }
            do { try await synchronize(id, runtime: runtime, epoch: epoch) }
            catch {
                guard runtime.epoch == epoch else { return }
                runtime.failures += 1
                blockPermissionFailure(id, error: error, epoch: epoch)
                if let http = error as? HTTPFailure, http.status == 401 { runtime.connection = nil }
                setState(id, runtime.blocked ? .error : .offline, error.localizedDescription + (runtime.blocked ? "；权限同步未完成，此 NAS 缓存暂时隔离" : "；" + cacheDescription(id)))
                recordConnectionFailure(id, error)
                await reloadSources(id, runtime, epoch); changedQuery()
            }
        }
    }
    func reloadSources(_ id: String, _ runtime: NASRuntime, _ epoch: UUID) async {
        let items = await runtime.coordinator?.sources() ?? []
        let available = (try? await runtime.coordinator?.searchableSourceIDs()) ?? []
        guard runtime.epoch == epoch else { return }
        connectionStates[id]?.sources = items; connectionStates[id]?.cachedSourceIDs = available; updateCompatibility()
    }
    func synchronize(_ id: String, runtime: NASRuntime, epoch: UUID) async throws {
        guard let profile = nasConnections.first(where: { $0.id == id }), let coordinator = runtime.coordinator,
              let connection = runtime.connection, let url = URL(string: profile.address) else { throw FlashFindError.message("缓存或连接不可用，请重新连接") }
        setState(id, .syncing, "正在同步")
        _ = try await coordinator.sync(settings: ServerSettings(address: url, username: profile.username, certificateSHA256: profile.certificateSHA256),
             password: runtime.password, selectedSourceIDs: profile.selectedSourceIDs, authenticatedConnection: connection,
             permissionsChanged: { [weak self] in await self?.permissionsChanged(id, epoch: epoch) })
        try Task.checkCancellation(); guard runtime.epoch == epoch else { return }
        runtime.blocked = false
        preferences.set(false, forKey: "ff2.permissionPending." + profile.cacheProfile)
        runtime.failures = 0
        await reloadSources(id, runtime, epoch)
        connectionStates[id]?.lastSync = Date()
        setState(id, .online, (profile.selectedSourceIDs.isEmpty ? "已连接；请选择来源并同步，" + cacheDescription(id) : "已完成所选来源同步 ") + (profile.selectedSourceIDs.isEmpty ? "" : Date().formatted(date: .omitted, time: .shortened)))
        changedQuery()
    }
    func permissionsChanged(_ id: String, epoch: UUID) {
        guard let runtime = runtimes[id], runtime.epoch == epoch else { return }
        runtime.permissionRevision &+= 1
        if let profile = nasConnections.first(where: { $0.id == id }) {
            preferences.set(true, forKey: "ff2.permissionPending." + profile.cacheProfile)
        }
        // Block search until this sync finishes: an old database must not be
        // republished while the coordinator is awaiting the replacement snapshot.
        runtime.blocked = true; invalidate(); changedQuery()
    }
    func blockPermissionFailure(_ id: String, error: Error, epoch: UUID) {
        guard let http = error as? HTTPFailure,
              http.status == 403 || http.status == 409 || (http.status == 503 && http.code == "permission_verification_failed") else { return }
        permissionsChanged(id, epoch: epoch)
    }
    func cacheDescription(_ id: String) -> String {
        connectionStates[id]?.hasCache == true ? "已有离线缓存" : "尚无可搜索缓存"
    }
    func fixtureSource(_ profile: NASConnectionProfile) -> Source? {
        var endpoint = URLComponents(); endpoint.scheme = "smb"; endpoint.host = URL(string: profile.address)?.host ?? "nas.example"; endpoint.path = "/Team"
        let object: [String: Any] = ["source_id": "fixture-source", "name": "UI 样例共享", "generation": "fixture", "smb_endpoint": endpoint.url?.absoluteString ?? "smb://nas.example/Team",
            "share_relative_root": "", "index_state": "ready", "min_valid_cursor": "0", "max_change_id": "0", "snapshot_id": "fixture", "snapshot_change_id": "0"]
        return (try? JSONSerialization.data(withJSONObject: object)).flatMap { try? JSONDecoder().decode(Source.self, from: $0) }
    }
    func connectFixture(_ id: String) {
        guard let profile = nasConnections.first(where: { $0.id == id }), profile.isConfigured,
              let runtime = runtimes[id], runtime.task == nil else { status = "请先填写并保存 HTTPS 地址和账号"; return }
        let epoch = runtime.epoch
        setState(id, .connecting, "UI 样例：正在连接，不发送网络请求")
        runtime.task = Task {
            defer { if runtime.epoch == epoch { runtime.task = nil; updateCompatibility() } }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard runtime.epoch == epoch else { return }
            if profile.username == "invalid" || profile.address.contains("offline.example") {
                setState(id, .error, "UI 样例：登录失败或服务离线，没有缓存")
                connectionStates[id]?.failureKind = profile.username == "invalid" ? .credentials : .network
                return
            }
            fixtureConnectedIDs.insert(id)
            connectionStates[id]?.sources = fixtureSource(profile).map { [$0] } ?? []
            setState(id, .online, "UI 样例：已连接，请选择来源并同步；尚无缓存")
            status = "UI 样例：连接完成，未访问 NAS"; changedQuery()
        }
    }
    func syncFixture(_ id: String) {
        guard fixtureConnectedIDs.contains(id), let profile = nasConnections.first(where: { $0.id == id }), !profile.selectedSourceIDs.isEmpty,
              let runtime = runtimes[id], runtime.task == nil else { status = "UI 样例：请先连接并选择来源"; return }
        let epoch = runtime.epoch
        setState(id, .syncing, "UI 样例：正在同步，没有写入真实缓存")
        runtime.task = Task {
            defer { if runtime.epoch == epoch { runtime.task = nil; updateCompatibility() } }
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard runtime.epoch == epoch else { return }
            connectionStates[id]?.cachedSourceIDs = profile.selectedSourceIDs
            connectionStates[id]?.lastSync = Date()
            setState(id, .online, "UI 样例：所选来源已有完整样例缓存，可明确启用搜索")
            status = "UI 样例：同步完成，非真实 NAS 功能验收"; changedQuery()
        }
    }
    func connectUsingStoredCredential() {
        guard credentialAccessAllowed, let id = selectedConnectionID,
              let profile = nasConnections.first(where: { $0.id == id }), profile.isConfigured,
              profile.rememberPassword, runtimes[id]?.task == nil, draftIdentity == profile.cacheProfile else {
            status = "请先保存匹配服务器与账号，并明确启用记住密码选项"; return
        }
        storedCredentialRequests.insert(id)
        connectConnection(id)
    }
    func restartPolling(_ id: String) {
        guard let runtime = runtimes[id] else { return }
        runtime.poll?.cancel(); let epoch = runtime.epoch
        runtime.poll = Task {
            while !Task.isCancelled && runtime.epoch == epoch {
                let delay = min(900, (ProcessInfo.processInfo.isLowPowerModeEnabled ? 300 : 60) * (1 << min(runtime.failures, 4)))
                do { try await Task.sleep(nanoseconds: UInt64(delay) * 1_000_000_000) } catch { return }
                guard enabled, let profile = nasConnections.first(where: { $0.id == id }), profile.enabled, !profile.syncPaused else { return }
                refreshConnection(id)
            }
        }
    }
}
