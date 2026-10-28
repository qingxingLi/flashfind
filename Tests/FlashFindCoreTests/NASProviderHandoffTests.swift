import XCTest
@testable import FlashFindCore

/// 已登录 Provider 的**交接**（R02）。
///
/// 这类缺陷单元测试抓不到：管理器自己的 `rebuild` 在同配置下确实会复用实例，
/// 单看它是绿的。坏掉的是**跨持有者**的那一步——向导 / 静默自动连接
/// 自己建了一个实例并登录成功，却把实例写进了界面的字典，
/// 而管理器持有的是另一份字典。下一次 rebuild 就从自己那份里
/// 拿一个从未登录的实例覆盖回来。
///
/// 界面读的正好是 `providers[id]?.ready`，于是出现用户报的那一幕：
/// **核心里登录成功了，设置页显示未连接。**
///
/// 所以这里测的是完整交接顺序：建实例 → 登录 → 交给管理器 → 再 rebuild，
/// 每一步都断言拿到的还是那个实例。
@MainActor final class NASProviderHandoffTests: XCTestCase {

    /// 记录命令、按脚本回应的假传输层。不起进程、不碰网络。
    private final class HandoffBridge: MyNASBridgeTransport {
        var commands: [String] = []
        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            commands.append(command)
            switch command {
            case "selectScope": return ["state": "scopeReady"]
            default: return ["status": "ok"]
            }
        }
    }

    /// 造一个「资源目录」，让 `ensureBridge` 能找到核心可执行文件。
    private func makeResourceDirectory() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-handoff-\(UUID().uuidString)")
        let bin = root.appendingPathComponent("MyNAS/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: bin.appendingPathComponent("mynas-core").path, contents: Data("fake".utf8))
        // 放一个项目标记，状态目录就会落在临时目录里，不会去动真实的用户目录。
        FileManager.default.createFile(atPath: root.appendingPathComponent("README-目录说明.md").path, contents: Data())
        return root
    }

    private func makeManager(_ bridge: HandoffBridge) -> NASConnectionManager {
        NASConnectionManager { _, _ in bridge }
    }

    private func config(id: String, host: String = "nas.example", port: Int = 5001) -> NASSourceConfig {
        NASSourceConfig(id: id, name: host, host: host, port: port, username: "u", scopes: ["/share"])
    }

    /// 走一遍「静默自动连接」：新建实例 → 登录（这里用选范围代表登录完成）→ 交接。
    private func connectWithNewInstance(manager: NASConnectionManager,
                                        config: NASSourceConfig) async throws -> NASSearchProvider {
        guard let bridge = manager.bridge else { throw HandoffFailure.noBridge }
        let provider = NASSearchProvider(bridge: bridge, config: config, port: config.port)
        _ = try await provider.selectScopes(config.scopes)
        manager.install(provider)
        return provider
    }

    private enum HandoffFailure: Error { case noBridge }

    // MARK: - 测试

    /// 交接之后再 rebuild，拿到的必须还是那个已登录的实例。
    func testInstalledProviderSurvivesRebuild() async throws {
        let bridge = HandoffBridge()
        let manager = makeManager(bridge)
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try makeResourceDirectory()))

        let source = config(id: "AAAA")
        // 启动时的第一次 rebuild：造出一个从未登录的实例。
        manager.rebuild(configs: [source], queryBudgetMs: 60_000, mountService: nil)
        let blank = try XCTUnwrap(manager.provider(for: source.id))
        XCTAssertFalse(blank.ready, "重建出来的实例不该是已登录的")

        var published: [String: NASSearchProvider] = [:]
        manager.onProvidersChanged = { published = $0 }

        // 静默自动连接：自己建实例、登录、再交回管理器。
        let loggedIn = try await connectWithNewInstance(manager: manager, config: source)
        XCTAssertTrue(loggedIn.ready)
        XCTAssertTrue(manager.provider(for: source.id) === loggedIn,
                      "交接后管理器必须持有那个已登录的实例")
        XCTAssertTrue(published[source.id] === loggedIn,
                      "交接必须把新实例发布出去，否则界面拿到的还是旧的")

        // 任一配置变更触发的 rebuild：不许把已登录实例顶掉。
        manager.rebuild(configs: [source], queryBudgetMs: 60_000, mountService: nil)
        XCTAssertTrue(manager.provider(for: source.id) === loggedIn,
                      "R02：rebuild 之后管理器应继续持有已登录实例，换成新实例等于掉线")
        XCTAssertTrue(manager.provider(for: source.id)?.ready == true,
                      "R02：rebuild 之后 ready 被压成 false，界面就会显示未连接")
    }

    /// 交接一台，不能把另一台的已登录实例弄丢。
    func testInstallingOneSourceKeepsAnotherReady() async throws {
        let bridge = HandoffBridge()
        let manager = makeManager(bridge)
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try makeResourceDirectory()))

        let a = config(id: "AAAA", host: "a.example")
        let b = config(id: "BBBB", host: "b.example")
        manager.rebuild(configs: [a, b], queryBudgetMs: 60_000, mountService: nil)

        let first = try await connectWithNewInstance(manager: manager, config: b)
        manager.rebuild(configs: [a, b], queryBudgetMs: 60_000, mountService: nil)
        let second = try await connectWithNewInstance(manager: manager, config: a)

        XCTAssertTrue(manager.provider(for: b.id) === first, "交接 A 不该顶掉 B 的已登录实例")
        XCTAssertTrue(manager.provider(for: a.id) === second)
        XCTAssertTrue(manager.provider(for: b.id)?.ready == true)
    }

    /// 同一个 sourceID 重复交接（重连一次）：不应对同一个核心槽位发 disconnect。
    func testReinstallDoesNotDisconnectSameSource() async throws {
        let bridge = HandoffBridge()
        let manager = makeManager(bridge)
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try makeResourceDirectory()))

        let source = config(id: "AAAA")
        manager.rebuild(configs: [source], queryBudgetMs: 60_000, mountService: nil)
        _ = try await connectWithNewInstance(manager: manager, config: source)
        bridge.commands.removeAll()
        _ = try await connectWithNewInstance(manager: manager, config: source)

        XCTAssertFalse(bridge.commands.contains("disconnect"),
                       "核心按 sourceID 存会话；交接时发 disconnect 会清掉刚建好的会话")
    }

    /// 只改名字：同一条会话必须留着，且名字要立刻生效。
    ///
    /// 用户报的是「连上以后没地方改名字」，补上入口之后真正容易踩的是这一步：
    /// `rebuild` 拿整份 `config == source` 判复用，名字也在里面，于是**改个名字就被
    /// 当成换了设备** —— disconnect、换一个从未登录的实例，界面立刻显示未连接。
    /// 所以这里同时盯三件事：实例还是那个、`ready` 没掉、`provider.source` 换了新名。
    func testRenameKeepsSessionAndUpdatesDisplayName() async throws {
        let bridge = HandoffBridge()
        let manager = makeManager(bridge)
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try makeResourceDirectory()))

        let source = config(id: "AAAA")
        manager.rebuild(configs: [source], queryBudgetMs: 60_000, mountService: nil)
        let loggedIn = try await connectWithNewInstance(manager: manager, config: source)
        XCTAssertTrue(loggedIn.ready)

        var renamed = source
        renamed.name = "客厅 NAS"
        bridge.commands.removeAll()
        manager.rebuild(configs: [renamed], queryBudgetMs: 60_000, mountService: nil)

        XCTAssertTrue(manager.provider(for: source.id) === loggedIn,
                      "只改名字却换了实例：等于改个名就掉线，用户还得重新输密码")
        XCTAssertTrue(manager.provider(for: source.id)?.ready == true,
                      "改名把 ready 压掉了，设置页会显示未连接")
        XCTAssertEqual(manager.provider(for: source.id)?.config.name, "客厅 NAS",
                       "实例持有的配置没有跟着改名，重启前一直显示旧名")
        XCTAssertEqual(manager.provider(for: source.id)?.source.name, "客厅 NAS",
                       "结果行的来源徽标读 provider.source，它是构造时的快照，必须一起换")
        XCTAssertFalse(bridge.commands.contains("disconnect"),
                       "改名不许向核心发 disconnect：那会把正在用的会话清掉")
    }

    /// 配置真的变了（换主机）才允许换实例 —— 否则旧密码会被发去新地址。
    func testChangedEndpointReplacesProvider() async throws {
        let bridge = HandoffBridge()
        let manager = makeManager(bridge)
        XCTAssertTrue(manager.ensureBridge(resourceDirectory: try makeResourceDirectory()))

        let source = config(id: "AAAA")
        manager.rebuild(configs: [source], queryBudgetMs: 60_000, mountService: nil)
        let loggedIn = try await connectWithNewInstance(manager: manager, config: source)

        var moved = source
        moved.host = "other.example"
        manager.rebuild(configs: [moved], queryBudgetMs: 60_000, mountService: nil)

        XCTAssertFalse(manager.provider(for: source.id) === loggedIn,
                       "主机变了就必须换实例：沿用旧实例等于拿旧会话去连新设备")
        XCTAssertFalse(manager.provider(for: source.id)?.ready == true,
                       "新实例尚未登录，不能沿用旧的 ready")
    }
}
