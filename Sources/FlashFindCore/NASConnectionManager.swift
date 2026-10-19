import Foundation

/// NAS 连接管理（P2-02）：持有核心桥接层与全部 NAS Provider，负责它们的生死。
///
/// 从 AppModel 里分出来的理由：连接的生命周期（建桥、重建、断开、核心重启后恢复）
/// 与「界面现在显示什么」是两件事。混在一起时，任何一处连接状态变化
/// 都要在两千多行里找到该改哪几个 `@Published`，漏一个就是
/// 「界面显示已连接、实际连不上」。
///
/// 这里**只管连接**，不管界面：所有外部通知走闭包，由 AppModel 决定怎么显示。
@MainActor public final class NASConnectionManager {
    public private(set) var providers: [String: NASSearchProvider] = [:]
    public private(set) var bridge: (any MyNASBridgeTransport)?
    public private(set) var stateDirectory: URL?

    /// Provider 集合变化。AppModel 用它刷新 `@Published` 与重建搜索协调器。
    public var onProvidersChanged: (([String: NASSearchProvider]) -> Void)?
    /// 桥接层的协议观测转发（诊断、版本不一致提示都挂在这上面）。
    public var observeProtocol: (([String: Any]) -> Void)?
    /// 诊断行。交给 `NASDiagnosticsController` 落盘，这里不管文件格式。
    public var onDiagnostic: (([String: Any]) -> Void)?
    /// 自动重连用的凭据来源。返回 nil ⇒ 不重试（绝不拿空密码去撞设备）。
    ///
    /// 默认从本机凭据文件读；测试可替换成任意来源。
    public var credentialProvider: ((NASSourceConfig) -> NASAutoReconnect.Credential?)?

    /// 桥接层工厂。声明成协议而不是具体类：**交接缺陷（R02）只能用假传输层测**，
    /// 真进程起不来，也就无法断言「登录后重建有没有把已登录实例顶掉」。
    private let makeBridge: @MainActor (URL, URL) -> any MyNASBridgeTransport

    /// - Parameter makeBridge: 桥接层工厂。默认造真的；测试可注入假的，
    ///   免得为了测连接管理而去真的起一个 Dart 进程。
    public init(makeBridge: @escaping @MainActor (URL, URL) -> any MyNASBridgeTransport = {
        MyNASProcessBridge(executable: $0, stateDirectory: $1)
    }) {
        self.makeBridge = makeBridge
    }

    // MARK: - 桥接层

    /// 确保桥接层已建立。重复调用不会重复起进程。
    ///
    /// - Parameter resourceDirectory: app 包内的资源目录（核心可执行文件在这里）。
    /// - Returns: 缺少资源时返回 false。
    @discardableResult
    public func ensureBridge(resourceDirectory: URL) -> Bool {
        guard bridge == nil else { return true }
        let executable = resourceDirectory.appendingPathComponent("MyNAS/bin/mynas-core")
        guard FileManager.default.fileExists(atPath: executable.path) else { return false }
        // 开发树里把可写状态放在项目根的 .build 下，便于逐轮比对证据；
        // 正式安装（找不到项目根标记）时回落 Application Support。
        //
        // 状态目录曾经拼的是一条内部工作区路径（某个历史实验目录），
        // 换台机器、换个人就指到不存在的地方，而且把内部目录名写进了产品代码。
        // .build 是构建产物目录、已被版本控制忽略，既能重建也不污染仓库。
        var parent = resourceDirectory
        while parent.path != "/" && !FileManager.default.fileExists(
            atPath: parent.appendingPathComponent("README-目录说明.md").path) {
            parent.deleteLastPathComponent()
        }
        let state = parent.path != "/"
            ? parent.appendingPathComponent(".build/mynas-state/trust")
            : FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("FlashFind2/MyNAS/trust")
        stateDirectory = state
        // 一个 Bridge 进程承载全部 NAS 来源：核心内部按 sourceID 分源，
        // 因此新增第二台 NAS 不需要再开子进程。
        let created = makeBridge(executable, state)
        created.observeProtocol = { [weak self] message in self?.observeProtocol?(message) }
        bridge = created
        return true
    }

    // MARK: - Provider 生命周期

    /// 按当前配置重建全部 Provider。**配置未变的来源保留已有登录态**——
    /// 否则改一个无关设置就会把所有 NAS 踢下线。
    public func rebuild(configs: [NASSourceConfig], queryBudgetMs: Int,
                        mountService: SMBMountService?) {
        guard let bridge else { return }
        var rebuilt: [String: NASSearchProvider] = [:]
        for source in configs where source.enabled {
            if let existing = providers[source.id], existing.config == source {
                rebuilt[source.id] = existing
            } else {
                if let previous = providers[source.id] { Task { await previous.disconnect() } }
                rebuilt[source.id] = makeProvider(bridge: bridge, config: source,
                                                  queryBudgetMs: queryBudgetMs, mountService: mountService)
            }
        }
        for (id, provider) in providers where rebuilt[id] == nil { Task { await provider.disconnect() } }
        providers = rebuilt
        onProvidersChanged?(rebuilt)
    }

    private func makeProvider(bridge: any MyNASBridgeTransport, config: NASSourceConfig,
                              queryBudgetMs: Int, mountService: SMBMountService?) -> NASSearchProvider {
        let provider = NASSearchProvider(bridge: bridge, config: config, port: config.port)
        provider.queryBudgetMs = queryBudgetMs
        provider.mountService = mountService
        attachAutoReconnect(provider)
        return provider
    }

    /// 接管一个**已经登录验证过**的 Provider（R02）。
    ///
    /// 为什么必须走这里：向导与静默自动连接都会先建 Provider、再走完
    /// discover → login → selectScopes，最后把「已经连好的那个实例」交回来。
    /// 以前只写界面层的字典，而管理器持有**另一份**字典；下一次 `rebuild`
    /// 就从自己那份里拿一个**从未登录**的空白实例覆盖回去，
    /// 刚登录好的实例变成孤儿（既没被使用、也没被断开）。
    ///
    /// 表现就是用户看到的那一幕：核心里登录明明成功了，
    /// 设置页却显示「未连接」——因为界面读的是 `providers[id]?.ready`，
    /// 而那个位置的实例已经被换成了 `ready == false` 的空白实例。
    ///
    /// 现在管理器是 Provider 的**唯一持有者**：交回实例后由这里入表并发布，
    /// 绝不新建实例覆盖它。
    ///
    /// - Note: 同一个 sourceID 下不重复断开旧实例。核心按 sourceID 存会话，
    ///   新旧实例共用同一个槽位；这里再发 disconnect 会把刚建好的会话清掉。
    public func install(_ provider: NASSearchProvider) {
        providers[provider.config.id] = provider
        attachAutoReconnect(provider)
        onProvidersChanged?(providers)
    }

    public func provider(for sourceID: String) -> NASSearchProvider? { providers[sourceID] }

    /// 连接前先发一条幂等清理：核心里这个 sourceID 可能还留着
    /// 上一次连接的残骸（旧连接、失败的尝试、确认过但没走完的流程），
    /// 否则会回 `SourceExists`。
    public func resetCoreSource(_ sourceID: String) async {
        guard let bridge else { return }
        _ = try? await bridge.command("disconnect", sourceID: sourceID)
    }

    /// 断开**一台** NAS（BUG-NAS-DISCONNECT-01）。
    ///
    /// 断开的语义只作用于这一台：结束它自己的会话与活跃查询；
    /// 其它来源的连接状态、Provider 实例与在飞查询一律不碰。
    ///
    /// 三个刻意**不做**：
    ///   * 不走 `rebuild(configs:)` —— 那是「配置变化后的整体重建」，断开一台
    ///     却把它跑一遍，等于让全部来源陪着一台做一轮身份核对，而一旦某台的
    ///     配置与已存配置不等，就会被换成一个从未登录的实例（看起来就是「全断了」）；
    ///   * 不把该来源从表里摘掉 —— 断开不是移除：配置与已保存的凭据都保留，
    ///     来源仍以 `ready == false` 留在表内，用户随时可以用已保存的密码再连；
    ///   * 不发布集合变化 —— 界面与协调器持有的是**同一批 Provider 实例**，
    ///     `ready` 的变化直接可读；发布只会让上层把搜索协调器整个换掉，
    ///     把其它来源正在跑的查询一起打断。
    public func disconnectOne(_ id: String) async {
        guard let provider = providers[id] else { return }
        await provider.disconnect()
    }

    // MARK: - 自动重连（P1-03）

    /// 给 Provider 装上自动重连。
    ///
    /// 对外暴露是因为向导流程里也会手工建 Provider（探测端口、确认证书），
    /// 那些 Provider 和用户保存下来的来源走的是同一套重连逻辑，不能有第二个版本。
    ///
    /// 核心一重启，进程里的登录态就没了；没有这个钩子，用户必须手动重连一次。
    public func attachAutoReconnect(_ provider: NASSearchProvider) {
        provider.autoReconnect = { [weak self] target in await self?.autoReconnect(target) ?? false }
    }

    /// 重连一台 NAS。凭据读不到就放弃，绝不拿空密码去撞设备
    /// （会触发设备侧的防暴力破解封禁）。
    private func autoReconnect(_ provider: NASSearchProvider) async -> Bool {
        await NASAutoReconnect.recover(provider) { [weak self, weak provider] in
            guard let provider else { return nil }
            let lookup = self?.credentialProvider ?? Self.storedCredential
            return lookup(provider.config)
        } log: { [weak self, weak provider] detail in
            guard let provider else { return }
            self?.onDiagnostic?(["at": ISO8601DateFormatter().string(from: Date()),
                                  "event": "autoReconnect",
                                  "sourceID": provider.config.sourceID,
                                  "detail": detail])
        }
    }

    /// 默认凭据来源：本机凭据文件。
    ///
    /// 放在这里是刻意的——凭据只有一个出处，
    /// 「谁在读凭据」这个问题因此只需要在这一处回答。
    private static func storedCredential(_ config: NASSourceConfig) -> NASAutoReconnect.Credential? {
        // 自动重连最容易绕过 UI 的身份校验，所以这里**必须**带 identity：
        // 换了地址或端口之后，旧密码在这里就该读不出来。
        guard let password = SecureStorage.read(account: config.credentialAccount,
                                               identity: config.credentialIdentity),
              !password.isEmpty else { return nil }
        return NASAutoReconnect.Credential(account: config.username, password: password)
    }
}
