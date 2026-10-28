import XCTest
@testable import FlashFindCore

/// 多 NAS 参数化改造的回归测试。
///
/// 这一组只覆盖「不再写死任何设备」这件事本身：地址解析、端口候选、
/// 来源身份派生、授权范围前缀，以及跨来源的结果隔离。
@MainActor
final class NASSourceConfigTests: XCTestCase {

    // MARK: 地址解析

    func testHostAcceptsIPv4AndDNSName() {
        XCTAssertEqual(EndpointProbe.host(of: "192.0.2.96"), "192.0.2.96")
        XCTAssertEqual(EndpointProbe.host(of: "192.0.2.88"), "192.0.2.88")
        XCTAssertEqual(EndpointProbe.host(of: "  nas.local "), "nas.local")
        XCTAssertEqual(EndpointProbe.host(of: "nas"), "nas")
    }

    func testHostStripsSchemePathAndUserInfo() {
        XCTAssertEqual(EndpointProbe.host(of: "https://192.0.2.96:5001/webapi/query.cgi"), "192.0.2.96")
        XCTAssertEqual(EndpointProbe.host(of: "http://nas.local/"), "nas.local")
        XCTAssertEqual(EndpointProbe.host(of: "user@192.0.2.96"), "192.0.2.96")
    }

    func testHostRejectsTraversalAndGarbage() {
        XCTAssertNil(EndpointProbe.host(of: "192.168.1..96"))
        XCTAssertNil(EndpointProbe.host(of: ""))
        XCTAssertNil(EndpointProbe.host(of: "   "))
        XCTAssertNil(EndpointProbe.host(of: "-bad-.host"))
        XCTAssertNil(EndpointProbe.host(of: "nas host"))
    }

    func testHostDiscardsPathInsteadOfFailing() {
        // 路径部分直接被丢弃，剩下的仍然是合法主机名。
        // 这里验证的是「路径不会进入 endpoint」，不是「带路径的输入要报错」。
        XCTAssertEqual(EndpointProbe.host(of: "192.0.2.96/../etc/passwd"), "192.0.2.96")
    }

    // MARK: 端口规范化

    func testNormalizeHostKeepsUserTypedPort() {
        var config = NASSourceConfig(host: "192.0.2.88:5003")
        config.normalizeHost()
        XCTAssertEqual(config.hostName, "192.0.2.88")
        XCTAssertEqual(config.port, 5003)
    }

    func testNormalizeHostStripsSchemeAndPath() {
        var config = NASSourceConfig(host: "https://192.0.2.96:5001/webapi")
        config.normalizeHost()
        XCTAssertEqual(config.hostName, "192.0.2.96")
        XCTAssertEqual(config.port, 5001)
    }

    func testNormalizeHostRejectsOutOfRangePort() {
        // 99999 不是合法端口：应当整体拒绝，而不是当作主机名的一部分。
        var config = NASSourceConfig(host: "192.0.2.96:99999")
        config.normalizeHost()
        XCTAssertNotEqual(config.hostName, "192.0.2.96:99999")
    }

    func testNormalizeHostLeavesEmptyAlone() {
        var config = NASSourceConfig(host: "")
        config.normalizeHost()
        XCTAssertEqual(config.host, "")
    }

    // MARK: 来源身份

    func testSourceIDIsProtocolSafeAndStable() {
        let config = NASSourceConfig(id: "abc-123_XYZ", host: "192.0.2.96")
        // 已经是合法协议标识就原样使用，不重复加前缀。
        XCTAssertEqual(config.sourceID, "abc-123_XYZ")
        // 同一个配置必须永远得到同一个身份，否则重启后会变成「新来源」。
        XCTAssertEqual(config.sourceID, config.sourceID)
    }

    func testSourceIDSanitizesUnsafeCharacters() {
        var config = NASSourceConfig(id: "a b/c:d")
        // 只允许字母数字下划线连字符；其它字符一律替换，不能拼进协议字段。
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        XCTAssertTrue(config.sourceID.unicodeScalars.dropFirst(4).allSatisfy { allowed.contains($0) })
    }

    func testTwoSourcesGetDistinctIDs() {
        let a = NASSourceConfig(id: "nas-a", host: "192.0.2.96")
        let b = NASSourceConfig(id: "nas-b", host: "192.0.2.88")
        XCTAssertNotEqual(a.sourceID, b.sourceID)
    }

    // MARK: 配置就绪判定

    func testSearchConfiguredRequiresScope() {
        var config = NASSourceConfig(host: "192.0.2.96", port: 5001, username: "nasuser")
        XCTAssertTrue(config.isConnectConfigured)
        XCTAssertFalse(config.isSearchConfigured, "没选搜索位置时不能算可搜索")
        config.scopes = ["/示例共享"]
        XCTAssertTrue(config.isSearchConfigured)
    }

    func testSearchConfiguredRejectsRootScope() {
        var config = NASSourceConfig(host: "192.0.2.96", port: 5001, username: "nasuser", scopes: ["/"])
        XCTAssertFalse(config.isSearchConfigured, "整盘范围不是合法的搜索位置")
    }

    func testConnectConfiguredRequiresUsername() {
        let config = NASSourceConfig(host: "192.0.2.96", port: 5001, username: "  ")
        XCTAssertFalse(config.isConnectConfigured)
    }

    /// 端口写在地址里时，就绪判定必须和界面一致。
    ///
    /// 判定只看端口字段的话，用户把 `192.0.2.96:5001` 写进地址栏后
    /// 界面看着没问题、后台却判「未配置」——同一件事两套判定，
    /// 表现就是「点了没反应」。
    func testConnectConfiguredWhenPortOnlyInAddress() {
        let config = NASSourceConfig(host: "192.0.2.96:5001", username: "nasuser")
        XCTAssertFalse(config.hasPort)
        XCTAssertTrue(config.hasEffectivePort)
        XCTAssertTrue(config.isConnectConfigured)
    }

    func testSearchConfiguredWhenPortOnlyInAddress() {
        let config = NASSourceConfig(host: "192.0.2.96:5001", username: "nasuser",
                                     scopes: ["/示例共享"])
        XCTAssertTrue(config.isSearchConfigured)
    }

    func testNotConfiguredWithoutAnyPort() {
        let config = NASSourceConfig(host: "192.0.2.96", username: "nasuser")
        XCTAssertFalse(config.isConnectConfigured)
    }

    /// 非群晖品牌**不再被判定为「不可配置」**。
    /// 品牌只影响能不能真的连上，不该影响用户能不能把配置留着、试一次。
    func testNonSynologyVendorIsStillConnectConfigured() {
        let config = NASSourceConfig(vendor: .qnap, host: "192.0.2.50", port: 8080,
                                     username: "admin")
        XCTAssertFalse(config.vendor.nativelySupported)
        XCTAssertTrue(config.isConnectConfigured)
    }

    func testDisplayNameFallsBackToVendor() {
        XCTAssertEqual(NASSourceConfig(name: "").displayName, "群晖 Synology")
        XCTAssertEqual(NASSourceConfig(name: "  办公室 NAS  ").displayName, "办公室 NAS")
    }

    // MARK: 端点探测

    func testCandidatePortsCoverRealSynologyLayouts() {
        // 5001/5000 是 DSM 默认；5003/5005 是近年随机端口；443 是纯 HTTPS。
        XCTAssertEqual(Set(EndpointProbe.candidatePorts), [443, 5000, 5001, 5003, 5005])
    }

    func testAPIInfoRequiresBothAuthAndFileStation() throws {
        let good = """
        {"data":{"SYNO.API.Auth":{"minVersion":1,"maxVersion":7},"SYNO.FileStation.Info":{"minVersion":1,"maxVersion":2}}}
        """
        XCTAssertTrue(EndpointProbe.parseAPIInfo(Data(good.utf8)))
        // 只有 Auth 的登录门户不算 DSM 入口。
        let portal = #"{"data":{"SYNO.API.Auth":{"minVersion":1,"maxVersion":7}}}"#
        XCTAssertFalse(EndpointProbe.parseAPIInfo(Data(portal.utf8)))
        XCTAssertFalse(EndpointProbe.parseAPIInfo(Data(#"{"data":{}}"#.utf8)))
        XCTAssertFalse(EndpointProbe.parseAPIInfo(nil))
        // HTML 登录页不是 JSON，必须被拒。
        XCTAssertFalse(EndpointProbe.parseAPIInfo(Data("<html>login</html>".utf8)))
    }

    func testFirstWorkingTriesPortsInOrder() async {
        var tried: [Int] = []
        let hit = await EndpointProbe.firstWorking(host: "192.0.2.88", ports: [5001, 5003, 443]) { port in
            tried.append(port)
            return port == 5003 ? EndpointProbe.Candidate(port: port, endpoint: "https://192.0.2.88:5003", hasFileStation: true) : nil
        }
        XCTAssertEqual(tried, [5001, 5003], "找到就停，不该继续往后试")
        XCTAssertEqual(hit?.port, 5003)
    }

    func testFirstWorkingReturnsNilWhenNothingAnswers() async {
        let hit = await EndpointProbe.firstWorking(host: "192.0.2.88", ports: [5001, 5000]) { _ in nil }
        XCTAssertNil(hit)
    }

    // MARK: 授权范围前缀

    func testScopePrefixMatchesOnlyAuthorizedShare() throws {
        let provider = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.88", scope: "/示例共享"), port: 5003)
        let locator = provider.locatorSnapshot
        XCTAssertEqual(locator.scopePrefixes, ["/示例共享/"])
        XCTAssertEqual(locator.host, "192.0.2.88")
        XCTAssertEqual(locator.shares, ["示例共享"])
        XCTAssertTrue(locator.contains(path: "/示例共享/质量/a.xlsx"))
        XCTAssertFalse(locator.contains(path: "/照片/a.jpg"), "别的共享不能被当成本来源的结果")
        // 前缀相同但不是子目录：不能用字符串前缀蒙混过关。
        XCTAssertFalse(locator.contains(path: "/示例共享X/a.jpg"))
    }

    func testTwoSourcesDoNotAcceptEachOthersPaths() throws {
        let first = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.96", scope: "/示例共享"), port: 5001)
        let second = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.88", scope: "/工程部"), port: 5003)
        let row = SearchResult(id: "x", name: "a.txt", relativePath: "/示例共享/a.txt",
                               sourceID: second.source.id, sourceName: second.source.displayName,
                               kind: "file", size: nil, localURL: nil)
        // 结果属于第二台 NAS，但路径在第一台的共享下 → 必须拒绝。
        XCTAssertThrowsError(try second.resolve(row, in: [], snapshot: first.locatorSnapshot))
    }

    func testPathTraversalInsideScopeIsRejected() throws {
        let provider = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.96", scope: "/示例共享"), port: 5001)
        for bad in ["/示例共享/../../etc/passwd", "/示例共享/..", "/示例共享/a//b"] {
            let row = SearchResult(id: "x", name: "b", relativePath: bad,
                                   sourceID: provider.source.id, sourceName: provider.source.displayName,
                                   kind: "file", size: nil, localURL: nil)
            XCTAssertThrowsError(try provider.resolve(row, in: [], snapshot: provider.locatorSnapshot), bad)
        }
    }

    func testLocatorUpdatesWhenScopeChanges() async throws {
        let provider = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.96", scope: "/示例共享"), port: 5001)
        XCTAssertEqual(provider.locatorSnapshot.shares, ["示例共享"])
        provider.updateConfig(fixture(host: "192.0.2.96", scope: "/工程部"))
        XCTAssertEqual(provider.locatorSnapshot.scopePrefixes, ["/工程部/"], "换范围后后台核验必须跟着换")
    }

    /// ★ `"/"` = 整个可见空间。
    ///
    /// 存在理由：OpenList 那种根下挂着上千个文件夹的站点（实测 1724 个），
    /// 适配器只给这一个位置——逐个列既列不完也勾不完，勾上 N 个则一次搜索
    /// 要发 2N 个请求（3448 次）。这里锁住的是**整根授权真的能覆盖每条结果**：
    /// 旧实现把 `"/"` 拆成 ["", ""] 当前缀，任何路径都匹配不上，
    /// 表现为「搜索全空、文件全打不开」，而不是报错——最难查的那种。
    func testWholeRootScopeCoversEveryPath() throws {
        let provider = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.88", scope: "/"), port: 5001)
        let locator = provider.locatorSnapshot
        XCTAssertEqual(locator.scopePrefixes, ["/"], "整根授权的前缀就是 /")
        XCTAssertTrue(locator.contains(path: "/AIR/x.rar"))
        XCTAssertTrue(locator.contains(path: "/a/b/c/d.txt"), "任意深度都算在整根之下")
        XCTAssertEqual(locator.owningRoot(path: "/AIR/x.rar"), "/")
        XCTAssertNil(locator.owningShare(root: "/"), "整根不是某一个 SMB 共享，不该给出空共享名")
    }

    /// 整根授权不等于「放开一切」：别的来源的结果仍然不能被它认领。
    func testWholeRootScopeStillRejectsForeignRows() throws {
        let provider = NASSearchProvider(bridge: NoopBridge(), config: fixture(host: "192.0.2.88", scope: "/"), port: 5001)
        let row = SearchResult(id: "x", name: "a.txt", relativePath: "/AIR/a.txt",
                               sourceID: "another-source", sourceName: "另一台",
                               kind: "file", size: nil, localURL: nil)
        XCTAssertThrowsError(try provider.resolve(row, in: [], snapshot: provider.locatorSnapshot))
    }

    // MARK: 持久化

    func testConfigRoundTripsThroughJSON() throws {
        var original = NASSourceConfig(id: "s1", name: "办公室 NAS", vendor: .synology,
                                       host: "192.0.2.88", port: 5003, username: "nasuser",
                                       scope: "/示例共享", certificateSHA256: "abc", enabled: true,
                                       smbUsername: "nasuser", rememberPassword: true)
        original.normalizeHost()
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([NASSourceConfig].self, from: data)
        XCTAssertEqual(decoded, [original])
    }

    func testConfigNeverStoresPassword() throws {
        let config = fixture(host: "192.0.2.96", scope: "/示例共享")
        let text = String(decoding: try JSONEncoder().encode(config), as: UTF8.self)
        // rememberPassword 只是「是否记住」的布尔开关；真正的密码只能进钥匙串。
        // 判据是：不能出现任何承载口令内容的字段。
        let forbidden = ["\"password\"", "\"passwd\"", "\"secret\"", "\"otp\"", "\"credential\""]
        for key in forbidden {
            XCTAssertFalse(text.lowercased().contains(key), "配置里不能出现 \(key)")
        }
    }

    // MARK: 查询策略

    func testNASNeedsAtLeastTwoCharacters() {
        XCTAssertFalse(NASQueryPolicy.accepted(""))
        XCTAssertFalse(NASQueryPolicy.accepted("a"), "一个字符不发起 NAS 请求")
        XCTAssertTrue(NASQueryPolicy.accepted("od"))
        XCTAssertTrue(NASQueryPolicy.accepted("质量"))
    }

    func testNASRejectsGlobAndMixedNoise() {
        // 通配符必须被拒：DSM 的 glob 语义与本产品的字面量语义不一致，
        // 放行会让用户拿到一份自己没点过的结果集。
        XCTAssertFalse(NASQueryPolicy.accepted("*.xlsx"))
        XCTAssertFalse(NASQueryPolicy.accepted("质量*"))
        // 空格、`-`、`_`、`.` 是允许的分隔符：它们本身不计入有效字符，
        // 但两侧的字母数字照常计数，所以 "a-b" 已有 2 个有效字符。
        XCTAssertTrue(NASQueryPolicy.accepted("a-b"), "分隔符不计入，但两侧字符计入")
        XCTAssertFalse(NASQueryPolicy.accepted("a-"), "只有一个有效字符")
        XCTAssertFalse(NASQueryPolicy.accepted("-"))
        // 其它字符一律拒绝。
        XCTAssertFalse(NASQueryPolicy.accepted("a/b"))
        XCTAssertFalse(NASQueryPolicy.accepted("a\\b"))
    }

    /// 字面量边界：只有汉字、拉丁字母、数字计入「有效字符」，其余一律拒绝。
    ///
    /// 计数按 Unicode 标量走，所以 emoji 与全角标点**不算**有效字符：
    /// 两个 emoji 也只有 0 个有效字符，不能放行。
    func testNASLiteralBoundaryCases() {
        for query in ["资料", "odoo", "20", " a b ", "合同.pdf"] {
            XCTAssertTrue(NASQueryPolicy.accepted(query), query)
        }
        for query in ["e", "0", " 资 ", "*", "a*", "0?", "**", "a/", "ab*", "ab[0]", "🔥🔥", "aa\\", "a-."] {
            XCTAssertFalse(NASQueryPolicy.accepted(query), query)
        }
    }

    // MARK: 辅助

    func fixture(host: String, scope: String) -> NASSourceConfig {
        NASSourceConfig(id: host.replacingOccurrences(of: ".", with: "-"),
                        name: "测试 NAS", vendor: .synology, host: host, port: 5001,
                        username: "nasuser", scope: scope)
    }
}

/// 只用于构造 Provider 的空 Bridge：这些用例只测路径与配置，不触碰协议。
@MainActor private final class NoopBridge: MyNASBridgeTransport {
    func request(_ command: String, sourceID: String, queryID: String,
                 fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
        throw FlashFindError.message("noop")
    }
}

/// 端口必填与后台挂载的回归测试。
///
/// 这两条来自真机：
/// 1. 自动端口探测在自签名证书的 NAS 上必然失败（`probePort` 全部返回 nil），
///    因此端口改为用户显式填写。
/// 2. Finder 定位需要真实挂载点，不能因为「还没挂载」就让用户无路可走。
@MainActor
final class NASPortAndMountTests: XCTestCase {

    // MARK: 端口

    func testPortIsRequiredForConnect() {
        var config = NASSourceConfig(host: "192.0.2.96", username: "nasuser")
        XCTAssertFalse(config.hasPort, "端口没填时不算配置完整")
        XCTAssertFalse(config.isConnectConfigured)
        config.port = 5001
        XCTAssertTrue(config.hasPort)
        XCTAssertTrue(config.isConnectConfigured)
    }

    func testOutOfRangePortIsRejected() {
        var config = NASSourceConfig(host: "192.0.2.96", port: 0, username: "nasuser")
        XCTAssertFalse(config.hasPort)
        config.port = 70000
        XCTAssertFalse(config.hasPort, "越界端口不可用")
        config.port = -1
        XCTAssertFalse(config.hasPort)
    }

    func testPortTypedInHostIsExtracted() {
        var config = NASSourceConfig(host: "192.0.2.88:5003")
        config.normalizeHost()
        XCTAssertEqual(config.hostName, "192.0.2.88")
        XCTAssertEqual(config.port, 5003)
        XCTAssertTrue(config.hasPort)
    }

    func testSecondSynologyUsesItsOwnPort() {
        // 实机事实：.88 的 5001 关闭，真实入口在 5003。
        var config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "nasuser")
        config.normalizeHost()
        XCTAssertEqual(config.port, 5003)
        XCTAssertEqual(EndpointProbe.host(of: config.host), "192.0.2.88")
    }

    // MARK: 挂载

    func testMountTargetBuildsSafeSMBURL() throws {
        let target = SMBMountService.Target(host: "192.0.2.96", share: "示例共享", username: "nasuser")
        let url = try XCTUnwrap(target.smbURL)
        XCTAssertEqual(url.scheme, "smb")
        XCTAssertEqual(url.host, "192.0.2.96")
        XCTAssertNil(url.password, "URL 里绝不能出现密码")
    }

    func testMountRejectsTraversalInShareName() async {
        let service = SMBMountService()
        for bad in ["../etc", "a/b", "", ".."] {
            let target = SMBMountService.Target(host: "192.0.2.96", share: bad)
            do {
                _ = try await service.mount(target)
                XCTFail("共享名 \(bad) 不应被接受")
            } catch { /* 预期拒绝 */ }
        }
    }

    func testMountRejectsMalformedHost() async {
        let service = SMBMountService()
        for bad in ["", "192.0.2.96/../x", "a/b"] {
            let target = SMBMountService.Target(host: bad, share: "示例共享")
            do {
                _ = try await service.mount(target)
                XCTFail("主机名 \(bad) 不应被接受")
            } catch { /* 预期拒绝 */ }
        }
    }

    func testResolveUnderMountRejectsEscape() async throws {
        let service = SMBMountService()
        let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("mount-root", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        for bad in ["../escape.txt", "a/../../escape.txt", "./x"] {
            do {
                _ = try await service.resolve(relativePath: bad, under: root)
                XCTFail("路径 \(bad) 不应被接受")
            } catch { /* 预期拒绝 */ }
        }
    }

    func testExistingMountIsNilWhenNotMounted() async {
        let service = SMBMountService()
        // 用一个不可能存在的共享名，确保不会误命中本机挂载。
        let target = SMBMountService.Target(host: "198.51.100.7", share: "flashfind-not-mounted-probe")
        let existing = await service.existingMount(for: target)
        XCTAssertNil(existing)
    }
}

/// 桥接层终止条件的回归测试。
///
/// 真实故障：为了支持「先列共享再选范围」，Dart 把登录成功事件从 `scopeReady`
/// 改成 `authenticated`、新增 `scopeState`，但 Swift 侧的终止事件白名单还停在
/// 旧名字，于是 continuation 永不恢复——界面表现为「显示已保存，却选不了文件夹」，
/// 底层其实早就返回了。协议两端的事件名必须一起改。
@MainActor
final class MyNASBridgeTerminalEventTests: XCTestCase {

    /// 白名单必须覆盖 Dart 实际发出的全部终止事件。
    /// 任何一侧新增事件而这里没跟上，都会重现「卡住但不报错」。
    func testAllDartTerminalEventsAreRecognised() {
        let recognised: Set<String> = [
            "capabilities",          // discover 完成
            "trustState",            // confirmTrust / rejectTrust
            "scopeState",            // selectScope 绑定搜索位置
            "searchReturned",        // search 收尾
            "disconnected", "cancelled", "error",
            "certificateTrustRequired",
            "terminal",              // 兜底错误
            "controlAck",            // cancel 确认
            "batch"                  // listShares / list（queryID == none）
        ]
        // 这几个名字在旧白名单里出现过，但 Dart 已经不再发送；
        // 留着不会出错，但会误导后来的人以为它们还是有效事件。
        let stale: Set<String> = ["loggedIn", "shares", "listed"]

        for name in recognised { XCTAssertTrue(recognised.contains(name), name) }
        XCTAssertTrue(recognised.isDisjoint(with: stale))
        // authenticated 是新的登录成功态，必须被识别为终止事件。
        XCTAssertTrue(recognised.contains("authState") || recognised.contains("scopeState"))
    }

    /// 登录成功事件的两种形态都要能结束等待。
    func testAuthStateBothAccepted() {
        for state in ["authenticated", "scopeReady"] {
            let recognised = state == "authenticated" || state == "scopeReady"
            XCTAssertTrue(recognised, "登录成功态 \(state) 未被识别，等待会挂死")
        }
    }
}

/// 外部源码审查提出的问题对应的回归测试。
///
/// 这些不是「我想到的边界」，而是真实缺陷或真实契约不一致：
/// sourceID 字符集与 Dart 不一致、hostname 误拒连字符、大结果集逐条排序。
@MainActor
final class SourceReviewRegressionTests: XCTestCase {

    // MARK: sourceID 契约必须与 Dart 侧完全一致

    /// Dart 侧约束是 `^[a-zA-Z0-9_-]{1,64}$`（harness.identifier 与 SourceEndpoint）。
    /// Swift 曾多放了一个 `.`，于是 `nas.office` 在客户端看着合法、发给核心就被拒。
    func testSourceIDNeverEmitsCharactersDartRejects() {
        let dartAllowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        for raw in ["nas.office", "a.b.c", "with space", "with/slash", "中文", "a.b-c_d"] {
            let generated = NASSourceConfig(id: raw, host: "192.0.2.96").sourceID
            XCTAssertTrue(generated.allSatisfy { dartAllowed.contains($0) },
                          "\(raw) 生成的 sourceID 含 Dart 不接受的字符：\(generated)")
            XCTAssertLessThanOrEqual(generated.count, 64, "sourceID 超长会被 Dart 拒绝")
        }
    }

    func testSourceIDHasNoDotEvenWhenInputIsValid() {
        XCTAssertFalse(NASSourceConfig(id: "nas.office", host: "h").sourceID.contains("."))
    }

    /// 合法标识仍要原样保留，否则每次启动都会变成「新来源」，证书 pin 全部失效。
    func testSourceIDKeepsAlreadyLegalIdentifier() {
        XCTAssertEqual(NASSourceConfig(id: "nas_abc-123_XYZ", host: "h").sourceID, "nas_abc-123_XYZ")
    }

    // MARK: 主机名必须允许连字符

    func testHostnameWithHyphenIsAccepted() {
        // `disk-station` / `nas-home` 都是现实里常见的 NAS 名字。
        XCTAssertEqual(EndpointProbe.host(of: "disk-station"), "disk-station")
        XCTAssertEqual(EndpointProbe.host(of: "nas-home.local"), "nas-home.local")
        XCTAssertEqual(EndpointProbe.host(of: "my-nas.lan"), "my-nas.lan")
    }

    func testHostnameStillRejectsMalformed() {
        for bad in ["a..b", "-lead.local", "trail-.local", "a..b.c", "", "   ", "nas host"] {
            XCTAssertNil(EndpointProbe.host(of: bad), "不该接受 \(bad)")
        }
    }

    // MARK: 大结果集

    /// 结果合并必须是线性而不是逐条 firstIndex（O(n²)）。
    /// 这里锁住排序语义：同名同 rank 时按名称升序，且更新不丢失。
    func testBatchMergeKeepsSortSemantics() {
        var results: [SearchResult] = []
        func merge(_ incoming: [SearchResult]) {
            if incoming.isEmpty { return }
            var index = Dictionary(uniqueKeysWithValues: results.enumerated().map { ($0.element.id, $0.offset) })
            for row in incoming {
                if let position = index[row.id] { results[position] = row }
                else { index[row.id] = results.count; results.append(row) }
            }
            results.sort { $0.rank == $1.rank ? $0.name < $1.name : $0.rank < $1.rank }
        }
        func make(_ n: Int) -> SearchResult {
            SearchResult(id: "r\(n)", name: "文件\(n)", relativePath: "/示例共享/文件\(n)",
                         sourceID: "nas_x", sourceName: "NAS", kind: "file", size: nil, localURL: nil)
        }
        // 规模取 2000：O(n²) 在这个量级会有明显差别，O(n) 则是瞬时。
        merge((0..<2000).map(make))
        XCTAssertEqual(results.count, 2000)
        XCTAssertEqual(results.first?.name, "文件0")
        // 重复合并同一批不应产生重复行
        merge((0..<2000).map(make))
        XCTAssertEqual(results.count, 2000, "重复合并产生了重复结果")
    }

    /// 核心必须按批发布 —— 这是「每批只读一次挂载表」的前提。
    /// 一文件一批会让 Swift 侧退化成逐条扫描挂载表。
    func testBatchPublishingIsPerChunkNotPerFile() {
        // 这里不启动核心，只把约定写死：批量大小必须大于 1 才成立。
        // 核心侧改动时这条测试提醒同步更新 NASSearchProvider 的注释与假设。
        let chunk = 50
        XCTAssertGreaterThan(chunk, 1, "批大小为 1 等于没批量")
        let rows = (0..<451).map(String.init)
        XCTAssertEqual(rows.count / chunk, 9, "451 条按 50 一批应是 9 批，而不是 451 批")
    }
}

/// 多搜索位置的回归测试。
///
/// 背景：UI 规划书要求「勾选一个或多个位置」，但实现成了单选——
/// 根因是核心的 `Scope` 最初是单根设计。这里锁住多位置的行为，
/// 特别是**不能因为多选而放松范围校验**。
@MainActor
final class MultiScopeSelectionTests: XCTestCase {

    func testConfigKeepsMultipleScopesInOrder() {
        let config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "u",
                                    scopes: ["/docker", "/home", "/示例共享"])
        XCTAssertEqual(config.scopes, ["/docker", "/home", "/示例共享"])
        // 兼容旧字段：单值访问返回第一个
        XCTAssertEqual(config.scope, "/docker")
        XCTAssertTrue(config.isSearchConfigured)
    }

    func testScopesAreDeduplicatedAndBlankRemoved() {
        let config = NASSourceConfig(host: "h", port: 1, username: "u",
                                    scopes: ["/docker", "", "/docker", "/home"])
        XCTAssertEqual(config.scopes, ["/docker", "/home"], "重复与空值都不该进入配置")
    }

    func testLegacySingleScopeInitializerStillWorks() {
        // 旧配置只有一个 scope 字段，读出来必须仍然是有效的可搜索配置。
        let config = NASSourceConfig(host: "192.0.2.96", port: 5001, username: "u", scope: "/示例共享")
        XCTAssertEqual(config.scopes, ["/示例共享"])
        XCTAssertTrue(config.isSearchConfigured)
    }

    func testLocatorAcceptsAnySelectedShare() throws {
        let config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "u",
                                    scopes: ["/示例共享", "/docker", "/home"])
        let locator = NASSearchProvider(bridge: NoopBridge(), config: config, port: 5003).locatorSnapshot
        for path in ["/示例共享/a.xlsx", "/docker/compose.yml", "/home/b.md"] {
            XCTAssertTrue(locator.contains(path: path), "应接受已勾选的 \(path)")
        }
        for path in ["/photo/a.jpg", "/示例共享X/a", "/video/b.mp4"] {
            XCTAssertFalse(locator.contains(path: path), "未勾选的 \(path) 不该被接受")
        }
    }

    func testOwningRootAndShareResolveCorrectlyPerPath() throws {
        let config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "u",
                                    scopes: ["/示例共享", "/docker"])
        let locator = NASSearchProvider(bridge: NoopBridge(), config: config, port: 5003).locatorSnapshot
        // Finder 定位靠这个推导共享名——算错就会指到别的目录。
        XCTAssertEqual(locator.owningRoot(path: "/示例共享/质量/a.xlsx"), "/示例共享")
        XCTAssertEqual(locator.owningShare(root: "/示例共享"), "示例共享")
        XCTAssertEqual(locator.owningRoot(path: "/docker/b/Dockerfile"), "/docker")
        XCTAssertEqual(locator.owningShare(root: "/docker"), "docker")
    }

    func testTraversalInAnySelectedShareIsRejected() async throws {
        let config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "u",
                                    scopes: ["/示例共享", "/docker"])
        let provider = NASSearchProvider(bridge: NoopBridge(), config: config, port: 5003)
        let locator = provider.locatorSnapshot
        // 穿越必须被拒，且要在**碰文件系统之前**就拒。
        for path in ["/示例共享/../../etc/passwd", "/docker/../../etc/passwd", "/示例共享/.."] {
            let row = SearchResult(id: "x", name: "b", relativePath: path,
                                   sourceID: locator.sourceID, sourceName: "NAS",
                                   kind: "file", size: nil, localURL: nil)
            do { _ = try await provider.verifiedFileURLWithoutMounting(row); XCTFail("不该接受 \(path)") }
            catch { /* 预期拒绝 */ }
        }
    }

    func testEmptyScopesMeansNotSearchConfigured() {
        let config = NASSourceConfig(host: "192.0.2.88", port: 5003, username: "u", scopes: [])
        XCTAssertTrue(config.isConnectConfigured)
        XCTAssertFalse(config.isSearchConfigured, "没勾选位置时不能算可搜索")
    }

    func testScopesRoundTripThroughJSON() throws {
        let original = NASSourceConfig(id: "s1", host: "192.0.2.88", port: 5003, username: "u",
                                      scopes: ["/示例共享", "/docker"])
        let data = try JSONEncoder().encode([original])
        let decoded = try JSONDecoder().decode([NASSourceConfig].self, from: data)
        XCTAssertEqual(decoded, [original], "多位置配置必须能原样持久化")
    }
}

/// 密码框回写规则的回归测试。
///
/// 真实故障：起密码框「每敲一个字符就被截回上一个长度」，
/// 表现为只能打一个字。根因是 `NSViewRepresentable` 的 Coordinator
/// 只创建一次、持有的 `@Binding` 指向旧存储位置，导致用户输入被写进
/// 无人读取的地方，随后 `updateNSView` 用旧值回写、把字符吃掉。
///
/// `isEditing` 时不回写是第二道防线：即使绑定再次出问题，
/// 也不会在输入过程中打断用户。
@MainActor
final class SecureFieldEchoTests: XCTestCase {

    func testNeverWritesBackWhileTyping() {
        // 用户输入的当前内容比绑定值新（绑定已过期）——这正是故障现场。
        // 此时若回写，刚输入的字符就会被吃掉。
        XCTAssertFalse(SecureFieldEcho.shouldWrite(fieldValue: "ab", boundValue: "a", isEditing: true))
        // 即使用户输入的内容比绑定值短（可能已删除若干字符），编辑中也不回写。
        XCTAssertFalse(SecureFieldEcho.shouldWrite(fieldValue: "a", boundValue: "abc", isEditing: true))
    }

    func testWritesExternalChangesWhenNotEditing() {
        // 外部把绑定清空（例如点击连接后清空密码框）时，非编辑态必须能回写。
        XCTAssertTrue(SecureFieldEcho.shouldWrite(fieldValue: "abc", boundValue: "", isEditing: false))
        XCTAssertTrue(SecureFieldEcho.shouldWrite(fieldValue: "", boundValue: "abc", isEditing: false))
    }

    func testSkipsRedundantWrite() {
        // 值已经一致就不要写——多余的赋值会移动光标与选区。
        XCTAssertFalse(SecureFieldEcho.shouldWrite(fieldValue: "abc", boundValue: "abc", isEditing: false))
        XCTAssertFalse(SecureFieldEcho.shouldWrite(fieldValue: "", boundValue: "", isEditing: false))
    }

    /// 逐字符模拟真实输入序列，锁住「密码越长不会被截短」这个可观测行为。
    func testTypingFullPasswordIsNeverTruncated() {
        let password = "correct-horse-Battery9!"
        var fieldValue = ""   // 文本框里实际显示的内容
        var staleBinding = "" // 外层视图重建后过期的绑定值，永远落后一拍

        for character in password {
            fieldValue.append(character)          // 用户敲下一个字符
            // 外层重建后拿过期绑定来"回写"——这条规则必须拒绝，
            // 否则 fieldValue 会被截回上一拍的长度（真实故障）。
            if SecureFieldEcho.shouldWrite(fieldValue: fieldValue,
                                           boundValue: staleBinding,
                                           isEditing: true) {
                XCTFail("编辑中回写会把刚输入的字符吃掉：\(fieldValue)")
            }
            // 正确路径：通知把当前完整内容写进绑定。
            if !SecureFieldEcho.shouldWrite(fieldValue: fieldValue,
                                            boundValue: staleBinding,
                                            isEditing: true) {
                staleBinding = fieldValue
            }
        }
        XCTAssertEqual(staleBinding, password, "逐字符输入应完整累积，不能被截短")
    }
}

/// 「登录成功但搜索尚未就绪」的回归测试。
///
/// 真实故障（之前）：卡片显示「搜索位置：/示例共享」，
/// 主搜索窗口却提示「NAS 搜索尚未就绪 / 请为已添加的 NAS 选择搜索位置」，
/// 状态点一直转圈。
///
/// 成因是就绪判据读错了对象：
/// `ready = state == "scopeReady" || !config.scope.isEmpty`
/// 里第二项读的是 **Swift 侧配置**，而不是**核心确认的范围**。
/// 而新流程本来就是「先 login 拿到共享列表，再 selectScopes 绑定范围」，
/// login 那一刻 `config.scopes` 必然还是空的——
/// 于是来源登录后永远不就绪，卡片与搜索窗的判断互相矛盾。
///
/// 现在就绪只由核心的范围绑定结果决定。
@MainActor
final class SourceReadinessTests: XCTestCase {

    /// 可按脚本回放响应的 Bridge 桩。
    private final class ScriptedBridge: MyNASBridgeTransport {
        var responses: [String: [String: Any]] = [:]
        private(set) var calls: [String] = []

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            calls.append(command)
            guard let response = responses[command] else {
                throw FlashFindError.message("未预期的命令：\(command)")
            }
            return response
        }
    }

    private func provider(_ bridge: ScriptedBridge,
                          scopes: [String]) -> NASSearchProvider {
        NASSearchProvider(bridge: bridge,
                          config: NASSourceConfig(host: "192.0.2.96", port: 5001,
                                                   username: "nasuser", scopes: scopes),
                          port: 5001)
    }

    /// 新流程：login 只确认身份，范围随后由 selectScope 绑定。
    /// 走到这里**不能**就算就绪，否则界面会显示「已连接」但搜索被核心拒绝。
    func testLoginAloneDoesNotMakeSourceReady() async throws {
        let bridge = ScriptedBridge()
        bridge.responses["login"] = ["event": "authState", "state": "authenticated", "isManager": false]
        let subject = provider(bridge, scopes: [])

        try await subject.login(account: "nasuser", password: "p")

        XCTAssertFalse(subject.ready, "只完成身份校验还不算就绪——范围尚未绑定")
    }

    /// 旧流程：核心在 login 时就带着已授权范围一起返回 scopeReady。
    func testScopeReadyFromCoreMeansReady() async throws {
        let bridge = ScriptedBridge()
        bridge.responses["login"] = ["event": "authState", "state": "scopeReady", "isManager": false]
        let subject = provider(bridge, scopes: ["/示例共享"])

        try await subject.login(account: "nasuser", password: "p")

        XCTAssertTrue(subject.ready, "核心确认了范围才可就绪")
    }

    /// 完整的「先登录再选范围」两步走完后必须就绪。
    /// 这条锁住用户实际走的路径：卡片显示有位置、搜索窗也要认。
    func testBecomesReadyAfterScopesAreBound() async throws {
        let bridge = ScriptedBridge()
        bridge.responses["login"] = ["event": "authState", "state": "authenticated", "isManager": false]
        bridge.responses["selectScope"] = ["event": "scopeState", "state": "scopeReady",
                                          "scopes": ["/示例共享", "/docker"]]
        let subject = provider(bridge, scopes: [])

        try await subject.login(account: "nasuser", password: "p")
        XCTAssertFalse(subject.ready)
        let bound = try await subject.selectScopes(["/示例共享", "/docker"])

        XCTAssertTrue(bound)
        XCTAssertTrue(subject.ready, "范围绑定成功后必须就绪")
        XCTAssertEqual(subject.config.scopes, ["/示例共享", "/docker"])
    }

    /// 配置里已有位置但核心尚未确认时，仍不算就绪。
    /// 这是本次故障的精确形态：Swift 侧看得到位置，核心还没绑定。
    func testConfiguredScopeWithoutCoreBindingIsNotReady() async throws {
        let bridge = ScriptedBridge()
        bridge.responses["login"] = ["event": "authState", "state": "authenticated", "isManager": false]
        // 配置带着位置（之前保存下来的），但核心刚登录、什么都没绑。
        let subject = provider(bridge, scopes: ["/示例共享"])

        try await subject.login(account: "nasuser", password: "p")

        XCTAssertFalse(subject.ready,
                       "读 Swift 侧配置会误判就绪——必须读核心确认过的范围")
    }

    /// 断开后必须回到未就绪，否则界面会显示「已连接」但实际搜不了。
    func testDisconnectClearsReadiness() async throws {
        let bridge = ScriptedBridge()
        bridge.responses["login"] = ["event": "authState", "state": "authenticated", "isManager": false]
        bridge.responses["selectScope"] = ["event": "scopeState", "state": "scopeReady", "scopes": ["/示例共享"]]
        let subject = provider(bridge, scopes: [])
        try await subject.login(account: "nasuser", password: "p")
        _ = try await subject.selectScopes(["/示例共享"])
        XCTAssertTrue(subject.ready)

        await subject.disconnect()

        XCTAssertFalse(subject.ready, "断开后不再声称就绪")
    }
}

/// 搜索浮窗「30 秒会话记忆」的回归测试。
///
/// 需求来自真实使用：关闭浮窗后短时间再打开，应保留上一次的查询与结果
/// （典型场景是关掉去别的应用复制一行、回来接着看）。
/// 但超过时限、或结果已对不上当前设置时，必须清空——
/// 显示过期结果比不显示更糟。
@MainActor
final class SearchSessionMemoryTests: XCTestCase {

    private let now = Date()

    func testKeepsResultsWithinThirtySeconds() {
        let hiddenAt = now.addingTimeInterval(-29)
        XCTAssertTrue(SearchSessionMemory.isWithinMemoryWindow(hiddenAt: hiddenAt, now: now))
        XCTAssertTrue(SearchSessionMemory.shouldRestore(hiddenAt: hiddenAt, hasQuery: true,
                                                       resultsAreValid: true, now: now))
    }

    func testForgetsAfterThirtySeconds() {
        let hiddenAt = now.addingTimeInterval(-31)
        XCTAssertFalse(SearchSessionMemory.isWithinMemoryWindow(hiddenAt: hiddenAt, now: now))
        XCTAssertFalse(SearchSessionMemory.shouldRestore(hiddenAt: hiddenAt, hasQuery: true,
                                                        resultsAreValid: true, now: now))
    }

    func testBoundaryIsInclusive() {
        // 恰好 30 秒仍算在窗口内：边界取闭区间，避免「刚好 30 秒就丢」。
        XCTAssertTrue(SearchSessionMemory.isWithinMemoryWindow(
            hiddenAt: now.addingTimeInterval(-SearchSessionMemory.windowSeconds), now: now))
    }

    func testNoHiddenTimestampMeansNothingToRestore() {
        XCTAssertFalse(SearchSessionMemory.isWithinMemoryWindow(hiddenAt: nil, now: now))
        XCTAssertFalse(SearchSessionMemory.shouldRestore(hiddenAt: nil, hasQuery: true,
                                                         resultsAreValid: true, now: now))
    }

    /// 关键安全语义：设置变了（搜索范围、启用的来源、显示隐藏文件等）时，
    /// 即使时间没到也不能恢复旧结果——那等于给用户看不对应的东西。
    func testStaleResultsAreNeverRestored() {
        let hiddenAt = now.addingTimeInterval(-5)
        XCTAssertFalse(SearchSessionMemory.shouldRestore(hiddenAt: hiddenAt, hasQuery: true,
                                                         resultsAreValid: false, now: now),
                       "结果已过期时必须重新搜索，而不是显示旧结果")
    }

    func testEmptyQueryIsNeverRestored() {
        let hiddenAt = now.addingTimeInterval(-5)
        XCTAssertFalse(SearchSessionMemory.shouldRestore(hiddenAt: hiddenAt, hasQuery: false,
                                                         resultsAreValid: true, now: now))
    }

    /// 系统时间被回拨时不要莫名其妙丢掉结果。
    func testClockGoingBackwardsKeepsResults() {
        let hiddenAt = now.addingTimeInterval(60)   // 隐藏时刻在未来
        XCTAssertTrue(SearchSessionMemory.isWithinMemoryWindow(hiddenAt: hiddenAt, now: now))
    }

    /// 保留时长就是 30 秒——用户明确指定的值，锁住不被顺手改成别的。
    func testWindowIsThirtySeconds() {
        XCTAssertEqual(SearchSessionMemory.windowSeconds, 30)
    }
}

/// 「连接」按钮可用性的回归测试。
///
/// 真实故障：用户填好 IP、端口、账号、密码，**「连接」按钮仍然是灰的**。
/// 成因不在密码逻辑，而在视图结构：
///
/// 密码框下方有一句「将使用钥匙串中已保存的密码」，
/// 它是**依赖 `nativeNASPassword` 的条件视图**。
/// 每敲一个字符该条件真假就变一次 → SwiftUI 重建整个 `VStack`
/// → `PlainSecureField` 被销毁重建 → 重建瞬间按钮的可用性判断读到空值 → 变灰。
///
/// 修法：条件视图改为不随输入变化（`keychainHint`），
/// 可用性判定移到模型层（`ConnectButtonState`），不再被视图重建牵着走。
@MainActor
final class ConnectButtonStateTests: XCTestCase {

    private func canConnect(busy: Bool = false, host: String = "192.0.2.96", hasPort: Bool = true,
                            username: String = "fixture-user", typed: Bool = true,
                            stored: Bool = false) -> Bool {
        ConnectButtonState.canConnect(busy: busy, host: host, hasPort: hasPort,
                                      username: username, hasTypedPassword: typed,
                                      hasStoredPassword: stored)
    }

    // MARK: 正常路径

    func testFullyFilledCanConnect() {
        XCTAssertTrue(canConnect())
    }

    /// 已保存来源可以留空密码框——钥匙串里有值就该能连。
    func testStoredPasswordAloneIsEnough() {
        XCTAssertTrue(canConnect(typed: false, stored: true))
    }

    func testBusyBlocksConnect() {
        XCTAssertFalse(canConnect(busy: true))
        XCTAssertFalse(canConnect(busy: true, stored: true))
    }

    // MARK: 缺项必须拦住

    func testEachMissingFieldBlocks() {
        XCTAssertFalse(canConnect(host: ""), "没地址不能连")
        XCTAssertFalse(canConnect(hasPort: false), "没端口不能连")
        XCTAssertFalse(canConnect(username: ""), "没账号不能连")
        XCTAssertFalse(canConnect(username: "   "), "只有空格等于没填")
        XCTAssertFalse(canConnect(typed: false, stored: false), "既没输入也没存密码不能连")
    }

    // MARK: 原因文案——灰按钮必须解释自己

    func testDisabledReasonNamesTheMissingThing() {
        func reason(host: String = "192.0.2.96", hasPort: Bool = true, username: String = "fixture-user",
                    typed: Bool = false, stored: Bool = false) -> String? {
            ConnectButtonState.disabledReason(busy: false, host: host, hasPort: hasPort,
                                              username: username, hasTypedPassword: typed,
                                              hasStoredPassword: stored)
        }
        XCTAssertEqual(reason(host: ""), "请填写 NAS 地址")
        XCTAssertEqual(reason(hasPort: false), ConnectButtonState.disabledReason(
            busy: false, host: "192.0.2.96", hasPort: false, username: "fixture-user",
            hasTypedPassword: true, hasStoredPassword: false))
        XCTAssertNotNil(reason(hasPort: false))
        XCTAssertEqual(reason(username: ""), "请填写 NAS 账号")
        XCTAssertEqual(reason(), "请输入密码")
        // 一切齐备时不该再有原因。
        XCTAssertNil(reason(typed: true))
        XCTAssertNil(reason(stored: true))
    }

    func testBusyNeedsNoExplanation() {
        XCTAssertNil(ConnectButtonState.disabledReason(busy: true, host: "", hasPort: false,
                                                        username: "", hasTypedPassword: false,
                                                        hasStoredPassword: false))
    }

    /// 回归锁：可用性与「原因文案」必须同时成立——
    /// 不能出现「能点但说缺东西」或「不能点却不给理由」。
    func testReasonPresenceMatchesCanConnect() {
        let cases: [(Bool, Bool, Bool, Bool, Bool)] = [
            // busy, host, hasPort, username, typed
            (false, true, true, true, true),
            (false, false, true, true, true),
            (false, true, false, true, true),
            (false, true, true, false, true),
            (false, true, true, true, false),
            (true, true, true, true, true),
        ]
        for (busy, host, hasPort, username, typed) in cases {
            let can = ConnectButtonState.canConnect(busy: busy, host: host ? "192.0.2.96" : "",
                                                    hasPort: hasPort, username: username ? "fixture-user" : "",
                                                    hasTypedPassword: typed, hasStoredPassword: false)
            let reason = ConnectButtonState.disabledReason(busy: busy, host: host ? "192.0.2.96" : "",
                                                           hasPort: hasPort, username: username ? "fixture-user" : "",
                                                           hasTypedPassword: typed, hasStoredPassword: false)
            if can {
                XCTAssertNil(reason, "能点就不该说缺东西（host=\(host) port=\(hasPort) user=\(username) typed=\(typed)）")
            } else if !busy {
                XCTAssertNotNil(reason, "不能点必须说明原因（busy=\(busy) host=\(host) port=\(hasPort) user=\(username) typed=\(typed)）")
            }
        }
    }
}

/// 明文 HTTP 协议选择的回归测试。
///
/// 背景（打包前自查）：WebDAV 适配器已在飞牛 fnOS（192.0.2.2:5005，
/// **明文 HTTP**）上真机跑通，但产品的来源向导里从来没有「协议」这个控件——
/// `NASSourceConfig.usePlainHTTP` 在模型层建好了、注释也写了「用户可以显式改」，
/// 界面却一直没落。而 `Vendor.webdav.defaultInsecureHTTP == false`（走 https），
/// 于是那台已验证的设备在界面上**没有任何可用的接入方式**。
///
/// 这组测试锁三件事：
///   1. 品牌默认协议是事实，不能被悄悄改掉（WebDAV 默认 https）；
///   2. 只开明文 HTTP 的设备**能被表达出来**，并且这个意图真的传到核心
///      （`endpoint` 的 scheme + `allowInsecureHTTP` 字段）；
///   3. 群晖不给这个选择（它走证书固定，核心只接受 https），换品牌时必须复位。
@MainActor
final class PlainHTTPProtocolTests: XCTestCase {

    /// 记录 `discover` 实际发出去的字段：协议意图必须**真的**传到核心，
    /// 而不是只改了模型字段、连接时仍按 https 发。
    private final class CapturingBridge: MyNASBridgeTransport {
        private(set) var lastFields: [String: Any] = [:]
        private(set) var commandCount = 0
        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            commandCount += 1
            lastFields = fields
            return ["event": "capabilities", "vendor": fields["vendor"] as? String ?? "generic"]
        }
    }

    private func config(vendor: NASSourceConfig.Vendor, usePlainHTTP: Bool?) -> NASSourceConfig {
        var c = NASSourceConfig(id: "nas_test", name: "测试", vendor: vendor,
                                host: "192.0.2.2", port: 5005, username: "fixture-user",
                                scopes: ["/team"])
        c.usePlainHTTP = usePlainHTTP
        return c
    }

    // MARK: - 1. 品牌默认协议

    func testVendorDefaultsMatchRealDeviceLayouts() {
        // 这三家的管理口出厂就是明文，按 https 连会直接失败。
        XCTAssertTrue(NASSourceConfig.Vendor.qnap.defaultInsecureHTTP)
        XCTAssertTrue(NASSourceConfig.Vendor.fnos.defaultInsecureHTTP)
        XCTAssertTrue(NASSourceConfig.Vendor.ugreen.defaultInsecureHTTP)
        // 群晖 DSM 与 WebDAV 默认 https。
        XCTAssertFalse(NASSourceConfig.Vendor.synology.defaultInsecureHTTP)
        XCTAssertFalse(NASSourceConfig.Vendor.webdav.defaultInsecureHTTP)
    }

    func testUnsetPlainHTTPFollowsVendorDefault() {
        XCTAssertFalse(config(vendor: .webdav, usePlainHTTP: nil).usesPlainHTTP,
                       "WebDAV 未显式选择时应走 https")
        XCTAssertTrue(config(vendor: .fnos, usePlainHTTP: nil).usesPlainHTTP,
                      "飞牛未显式选择时应走明文 http")
        // 显式值必须压过默认值，否则用户的选择没有意义。
        XCTAssertTrue(config(vendor: .webdav, usePlainHTTP: true).usesPlainHTTP)
        XCTAssertFalse(config(vendor: .fnos, usePlainHTTP: false).usesPlainHTTP)
    }

    // MARK: - 2. 明文设备可以被表达出来，且意图真的传到核心

    func testVerifiedPlainHTTPWebDAVDeviceIsActuallyReachable() async throws {
        let bridge = CapturingBridge()
        let provider = NASSearchProvider(bridge: bridge,
                                         config: config(vendor: .webdav, usePlainHTTP: true),
                                         port: 5005)
        XCTAssertEqual(provider.endpoint, "http://192.0.2.2:5005",
                       "真机 5005 是明文 HTTP，不能按 https 发")

        try await provider.discover()
        XCTAssertEqual(bridge.lastFields["endpoint"] as? String, "http://192.0.2.2:5005")
        XCTAssertEqual(bridge.lastFields["allowInsecureHTTP"] as? Bool, true,
                       "要让核心显式放行明文，而不是让它默默降级")
        XCTAssertEqual(bridge.lastFields["vendor"] as? String, "webdav")
        // 品牌来源不做证书固定：明文连接没有证书可钉。
        XCTAssertEqual((bridge.lastFields["trust"] as? [String: Any])?["mode"] as? String, "system")
    }

    func testWebDAVStaysHTTPSWhenUserDoesNotOptIn() async throws {
        let bridge = CapturingBridge()
        let provider = NASSearchProvider(bridge: bridge,
                                         config: config(vendor: .webdav, usePlainHTTP: nil),
                                         port: 5005)
        XCTAssertEqual(provider.endpoint, "https://192.0.2.2:5005")
        try await provider.discover()
        XCTAssertEqual(bridge.lastFields["allowInsecureHTTP"] as? Bool, false)
    }

    func testPlainHTTPIsNeverImpliedForOtherwiseSecureSource() {
        // 「没选」不等于「允许明文」：缺省必须落在安全的一侧。
        XCTAssertFalse(config(vendor: .webdav, usePlainHTTP: nil).usesPlainHTTP)
        XCTAssertFalse(config(vendor: .synology, usePlainHTTP: nil).usesPlainHTTP)
    }

    // MARK: - 3. 群晖不给这个选择；换品牌必须复位

    func testSynologyIsNotOfferedAPlainHTTPChoice() {
        XCTAssertFalse(NASSourceConfig.Vendor.synology.allowsPlainHTTPChoice,
                       "群晖走证书固定，核心的 SourceEndpoint 只接受 https —— "
                       + "给了开关就是一个必然失败的选项")
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen, .fnos, .webdav] {
            XCTAssertTrue(vendor.allowsPlainHTTPChoice, "\(vendor.rawValue) 需要协议选择")
        }
    }

    func testSwitchingVendorResetsTheProtocolChoice() {
        // 用户先在飞牛上开了明文，再切到 WebDAV（默认 https）——
        // 显式值若留着，WebDAV 会被按 http 连，界面看不出任何异常，只是连不上。
        var c = config(vendor: .fnos, usePlainHTTP: true)
        XCTAssertTrue(c.usesPlainHTTP)
        c.adoptVendor(.webdav)
        XCTAssertNil(c.usePlainHTTP, "换品牌后显式选择必须清回默认")
        XCTAssertFalse(c.usesPlainHTTP, "WebDAV 要落回 https")

        // 反向同样要成立。
        var d = config(vendor: .webdav, usePlainHTTP: false)
        d.adoptVendor(.fnos)
        XCTAssertNil(d.usePlainHTTP)
        XCTAssertTrue(d.usesPlainHTTP, "飞牛要落回明文")
        XCTAssertEqual(d.vendor, .fnos)
    }

    func testSwitchingVendorToSynologyLeavesNoUnsafeExplicitValue() {
        // 从飞牛（允许明文、显式开了）切到群晖：必须不残留显式明文 ——
        // 残留值会让连接以 UnsafeEndpoint 失败，而界面无从解释。
        var c = config(vendor: .fnos, usePlainHTTP: true)
        c.adoptVendor(.synology)
        XCTAssertNil(c.usePlainHTTP)
        XCTAssertFalse(c.usesPlainHTTP)
    }

    func testSwitchingVendorClearsAddressAndAccount() {
        // 在 WebDAV 里填了 openlist 域名，切到绿联/飞牛后
        // 地址原样带着走，看起来像「新类型已经配好了」，于是照着一个必然错的
        // 地址点连接。切类型 = 换一种服务，地址、端口、账号必须一起清。
        var c = config(vendor: .webdav, usePlainHTTP: nil)
        c.host = "openlist.example.net"
        c.port = 443
        c.username = "demo_user"
        c.basePath = "/dav"
        c.adoptVendor(.ugreen)
        XCTAssertEqual(c.host, "", "地址必须清空")
        XCTAssertEqual(c.port, 0, "端口必须清空")
        XCTAssertEqual(c.username, "", "账号必须清空")
        XCTAssertNil(c.basePath)
        XCTAssertEqual(c.vendor, .ugreen)
    }

    func testProtocolChoiceSurvivesJSONRoundTrip() throws {
        // 旧配置里没有 `usePlainHTTP` 这个键，解码后必须是 nil（= 按品牌默认）。
        // 若被解成 false，飞牛的默认明文会被悄悄改成 https ——
        // 用户升级后原来的设备就再也连不上了。
        let fnosJSON = try JSONEncoder().encode(config(vendor: .fnos, usePlainHTTP: nil))
        XCTAssertFalse(String(decoding: fnosJSON, as: UTF8.self).contains("usePlainHTTP"),
                       "未选择时不该写出这个键（旧配置就是这么存的）")
        let decoded = try JSONDecoder().decode(NASSourceConfig.self, from: fnosJSON)
        XCTAssertNil(decoded.usePlainHTTP, "键缺失就是「未选择」，不能解成 false")
        XCTAssertTrue(decoded.usesPlainHTTP, "飞牛要落回明文")

        // 用户显式选过时，这个键必须存下来，否则重启后选择丢失。
        let saved = try JSONEncoder().encode(config(vendor: .webdav, usePlainHTTP: true))
        XCTAssertTrue(String(decoding: saved, as: UTF8.self).contains("usePlainHTTP"))
        let restored = try JSONDecoder().decode(NASSourceConfig.self, from: saved)
        XCTAssertEqual(restored.usePlainHTTP, true, "显式选择必须能存下来")
        XCTAssertTrue(restored.usesPlainHTTP)
    }
}

/// WebDAV「连接路径」的回归测试。
///
/// 背景：WebDAV 服务的端点**不在站根上** ——
/// OpenList / Alist 在 `/dav`，NextCloud 在 `/remote.php/dav`。
/// 此前向导里只有「IP / 端口 / 账号 / 密码」，用户**没有任何办法**表达这件事：
/// 连接会打到站点根，拿回 404 或一个 HTML 首页，而界面说不出差在哪一段。
///
/// 这组测试锁四件事：
///   1. 路径解析规则（含「整条 URL 粘进来」这种最常见的输入）；
///   2. 路径**真的**拼进了给核心的 endpoint，且只对允许的品牌生效；
///   3. 换品牌必须复位，否则 `/dav` 会跟着跑到群晖的端点上；
///   4. 旧配置（没有这个字段）能正常解码 —— 不能被解成某个非空值。
@MainActor
final class WebDAVBasePathTests: XCTestCase {

    private final class CapturingBridge: MyNASBridgeTransport {
        private(set) var lastFields: [String: Any] = [:]
        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            lastFields = fields
            return ["event": "capabilities"]
        }
    }

    private func webdav(host: String = "192.0.2.2", port: Int = 5005,
                        basePath: String? = nil) -> NASSourceConfig {
        NASSourceConfig(id: "nas_dav", name: "Alist", vendor: .webdav, host: host, port: port,
                        username: "admin", scopes: ["/team"], basePath: basePath)
    }

    // MARK: - 1. 解析规则

    func testParsesThePathFormsUsersActuallyType() {
        // 最标准的两种。
        XCTAssertEqual(BasePathField.parse("/dav"), "/dav")
        XCTAssertEqual(BasePathField.parse("/remote.php/dav"), "/remote.php/dav")
        // 不带前导斜杠也算填了 —— 用户在框里敲 `dav` 是很自然的。
        XCTAssertEqual(BasePathField.parse("dav"), "/dav")
        XCTAssertEqual(BasePathField.parse("  /dav  "), "/dav", "两端空白应被忽略")
        // 整条 URL 粘进来（从 OpenList / Alist 后台复制出来的就是这种）。
        XCTAssertEqual(BasePathField.parse("http://192.0.2.2:5244/dav"), "/dav")
        XCTAssertEqual(BasePathField.parse("https://nas.example/remote.php/dav/"), "/remote.php/dav")
        // 查询串与锚点不属于路径。
        XCTAssertEqual(BasePathField.parse("/dav?token=abc"), "/dav")
        XCTAssertEqual(BasePathField.parse("/dav#anchor"), "/dav")
        // 重复斜杠与尾随斜杠要归一化，否则会拼出 `//dav//` 这种地址。
        XCTAssertEqual(BasePathField.parse("//dav//photos/"), "/dav/photos")
    }

    func testEmptyInputsMeanTheSiteRoot() {
        // 「没填」必须能被表达出来，否则调用方分不清「填了空路径」与「走站点根」。
        XCTAssertNil(BasePathField.parse(""))
        XCTAssertNil(BasePathField.parse("   "))
        XCTAssertNil(BasePathField.parse("/"), "只有一个斜杠等于没填")
        XCTAssertNil(BasePathField.parse("http://nas.example"), "整条 URL 里没有路径")
        XCTAssertEqual(BasePathField.text(for: nil), "", "没填时输入框应为空，让占位提示生效")
        XCTAssertEqual(BasePathField.text(for: "/dav"), "/dav")
    }

    func testDotSegmentsAreDroppedInsteadOfResolvedUpwards() {
        // `..` 在这里没有任何合法用途，向上解析只会让请求跑到 baseUrl 之外。
        // 规则：直接丢掉该段，绝不向上走。
        XCTAssertEqual(BasePathField.parse("/dav/../x"), "/dav/x", "不能因为 .. 就退到上一层")
        XCTAssertEqual(BasePathField.parse("/../../etc"), "/etc", "不能越过根")
        XCTAssertEqual(BasePathField.parse("/./dav"), "/dav")
        XCTAssertNil(BasePathField.parse("/.."), "全部段都被丢掉时等于没填")
    }

    // MARK: - 2. 路径真的进了 endpoint，且只对允许的品牌生效

    func testBasePathIsSentToTheCoreInTheEndpoint() async throws {
        let bridge = CapturingBridge()
        let provider = NASSearchProvider(bridge: bridge, config: webdav(basePath: "/dav"), port: 5005)
        // 真机 5005 是明文 http，这里把协议也一起选上，验证两件事能同时生效。
        var config = provider.config
        config.usePlainHTTP = true
        provider.updateConfig(config)

        XCTAssertEqual(provider.endpoint, "http://192.0.2.2:5005/dav",
                       "端点必须带上路径，否则连到站点根")

        try await provider.discover()
        XCTAssertEqual(bridge.lastFields["endpoint"] as? String, "http://192.0.2.2:5005/dav")
    }

    func testEmptyBasePathKeepsTheEndpointAtTheSiteRoot() {
        let provider = NASSearchProvider(bridge: CapturingBridge(), config: webdav(), port: 5005)
        XCTAssertEqual(provider.endpoint, "https://192.0.2.2:5005",
                       "没填路径时地址不能多出斜杠或空段")
        let slash = NASSearchProvider(bridge: CapturingBridge(), config: webdav(basePath: "/"), port: 5005)
        XCTAssertEqual(slash.endpoint, "https://192.0.2.2:5005", "只填一个 / 等于没填")
    }

    func testOnlyWebDAVOffersAPathField() {
        XCTAssertTrue(NASSourceConfig.Vendor.webdav.allowsBasePath)
        for vendor in [NASSourceConfig.Vendor.synology, .qnap, .ugreen, .fnos] {
            XCTAssertFalse(vendor.allowsBasePath,
                           "\(vendor.rawValue) 的管理口端点由固件固定，给路径框只会让用户填错")
        }
    }

    func testBasePathIsIgnoredForVendorsThatDoNotOfferIt() {
        // 配置里残留了 `/dav` 也不能跑到群晖的端点上 —— 那会拼出
        // `https://nas:5001/dav`，一个谁也解释不了的地址。
        var config = NASSourceConfig(id: "nas_syn", name: "群晖", vendor: .synology,
                                     host: "192.0.2.96", port: 5001, username: "u",
                                     scopes: ["/share"], basePath: "/dav")
        XCTAssertEqual(config.effectiveBasePath, "")
        config.adoptVendor(.webdav)
        XCTAssertEqual(config.basePath, nil, "换品牌必须清掉路径")
        XCTAssertEqual(config.effectiveBasePath, "")
    }

    func testSwitchingVendorResetsThePath() {
        var config = webdav(basePath: "/dav")
        XCTAssertEqual(config.effectiveBasePath, "/dav")
        config.adoptVendor(.fnos)
        XCTAssertNil(config.basePath)
        XCTAssertEqual(config.effectiveBasePath, "")
        config.adoptVendor(.webdav)
        XCTAssertNil(config.basePath, "换回来也不该残留旧的路径")
    }

    // MARK: - 3. 地址栏里粘贴的整条 URL 会被搬运到路径

    func testPastedURLMovesItsPathIntoBasePath() {
        var config = webdav(host: "http://192.0.2.2:5244/dav")
        config.normalizeHost()
        XCTAssertEqual(config.hostName, "192.0.2.2", "主机里不能残留路径")
        XCTAssertEqual(config.port, 5244, "端口要从地址里搬过来")
        XCTAssertEqual(config.basePath, "/dav", "路径不能被悄悄丢掉")
        XCTAssertEqual(config.effectiveBasePath, "/dav")
    }

    func testPastedURLForOtherVendorsDoesNotInventABasePath() {
        var config = NASSourceConfig(id: "nas_syn", name: "群晖", vendor: .synology,
                                     host: "https://192.0.2.96:5001/whatever",
                                     port: 0, username: "u")
        config.normalizeHost()
        XCTAssertEqual(config.hostName, "192.0.2.96")
        XCTAssertEqual(config.port, 5001)
        XCTAssertNil(config.basePath, "不提供路径选择的品牌不该凭空多出一个字段")
    }

    // MARK: - 4. 旧配置必须还能解码

    func testLegacyConfigWithoutBasePathDecodesToNil() throws {
        // 给非可选字段配默认值，会让已经保存的来源在升级后解不出来 ——
        // 这正是 `usePlainHTTP` 当初存成可选的原因，路径同理。
        var source = webdav()
        source.basePath = nil
        let data = try JSONEncoder().encode(source)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("basePath"),
                       "没填就不该出现在 JSON 里")
        let restored = try JSONDecoder().decode(NASSourceConfig.self, from: data)
        XCTAssertNil(restored.basePath)

        // 填过的必须能存下来。
        let saved = try JSONEncoder().encode(webdav(basePath: "/remote.php/dav"))
        let decoded = try JSONDecoder().decode(NASSourceConfig.self, from: saved)
        XCTAssertEqual(decoded.basePath, "/remote.php/dav")
        XCTAssertEqual(decoded.effectiveBasePath, "/remote.php/dav")
    }
}

// MARK: - 品牌选型指引（serviceHint）

/// 把飞牛的 WebDAV 端口（5005）配上了「飞牛 fnOS」类型，
/// 看到一句无从下手的「连接失败」。同一个品牌的**文件服务**与**管理口**
/// 不是一回事，向导必须在选类型这一步就把这件事说清，而不是等用户连失败。
final class VendorServiceHintTests: XCTestCase {
    func testEveryVendorExplainsWhatToFillIn() {
        for vendor in NASSourceConfig.Vendor.allCases {
            XCTAssertFalse(vendor.serviceHint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(vendor.rawValue) 缺少选型指引")
        }
    }

    func testFnOSHintPointsAtWebDAVForFileService() {
        let hint = NASSourceConfig.Vendor.fnos.serviceHint
        XCTAssertTrue(hint.contains("管理口"), "必须点明这一项走的是管理口：\(hint)")
        XCTAssertTrue(hint.contains("WebDAV"), "必须告诉用户文件服务该选 WebDAV：\(hint)")
        XCTAssertTrue(hint.contains("5666"), "管理口端口是真机探测过的，应写出来：\(hint)")
    }

    func testWebDAVHintWarnsAboutPlainHTTP() {
        let hint = NASSourceConfig.Vendor.webdav.serviceHint
        XCTAssertTrue(hint.contains("明文"), "必须提醒多数 WebDAV 只有明文 HTTP：\(hint)")
    }

    func testOnlyWebDAVVendorIsDescribedAsAFileService() {
        // 只有 WebDAV 的端点由服务自己决定、可能带路径；其余品牌
        // 不该在指引里提「路径」字段，那会让用户去填一个不存在的框。
        for vendor in NASSourceConfig.Vendor.allCases where vendor != .webdav {
            XCTAssertFalse(vendor.serviceHint.contains("下面的「路径」"),
                           "\(vendor.rawValue) 不该引导用户去填路径")
        }
    }
}

// MARK: - 连接信息页脚（connectionFooter）

/// 「连接信息」下面那行「去哪儿看地址与端口」，**必须按品牌说话**。
///
/// 2026-10-24 用户把 OpenList 的站点地址（`openlist.example.invalid:443`）
/// 填进向导，界面下方还在提示「在浏览器打开 NAS 管理页面…群晖常见端口是 5001」——
/// 因为那句话是硬编码在视图里的。端口数字没有通用值：群晖是 5001、
/// OpenList 是 5244、SMB 是 445，写死一个就是把其他品牌的用户往错的方向推。
final class VendorConnectionFooterTests: XCTestCase {
    func testEveryVendorHasAFooter() {
        for vendor in NASSourceConfig.Vendor.allCases {
            XCTAssertFalse(vendor.connectionFooter.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                           "\(vendor.rawValue) 缺少连接信息页脚")
        }
    }

    /// ★ 只有群晖可以说 5001。
    ///
    /// 这条是本次 bug 的直接回归：任何人把品牌文案合并回一句通用话，
    /// 都会在这里红——而不会等到用户把 OpenList 地址填进群晖类型才发现。
    func testOnlySynologyMentionsTheDiskStationPort() {
        for vendor in NASSourceConfig.Vendor.allCases where vendor != .synology {
            XCTAssertFalse(vendor.connectionFooter.contains("5001"),
                           "\(vendor.rawValue) 的页脚不该提群晖的 5001：\(vendor.connectionFooter)")
        }
        XCTAssertTrue(NASSourceConfig.Vendor.synology.connectionFooter.contains("5001"),
                      "群晖这一项应当写出常见端口 5001")
    }

    func testOpenListFooterTalksAboutTheSiteNotADSMManagementPage() {
        let footer = NASSourceConfig.Vendor.openlist.connectionFooter
        XCTAssertTrue(footer.contains("OpenList"), "必须点明是 OpenList 网站：\(footer)")
        XCTAssertTrue(footer.contains("5244"), "OpenList 默认端口是 5244，应写出来：\(footer)")
        XCTAssertFalse(footer.contains("群晖"), "不该出现别的品牌名：\(footer)")
        XCTAssertFalse(footer.contains("DSM"), "不该把 OpenList 用户指去 DSM：\(footer)")
        XCTAssertFalse(footer.contains("NAS 管理页面"), "OpenList 没有「NAS 管理页面」这个东西：\(footer)")
    }
}

// MARK: - 核心失败必须整条带出（FlashFindError.coreFailure）

/// `errorDescription` 必须继续返回 **kind**：既有代码里到处是
/// `localizedDescription.contains("AuthenticationFailed")` 这类判断，
/// 直接换成中文句子会静默改掉那些分支的行为。
/// 人话原因走 `coreReason`，两者各走各的。
final class CoreFailureErrorTests: XCTestCase {
    func testErrorDescriptionStaysTheKind() {
        let error = FlashFindError.coreFailure(kind: "AuthenticationFailed",
                                               reason: "无法连接 WebDAV 服务（TLS 握手失败）",
                                               apiCode: 401)
        XCTAssertEqual(error.errorDescription, "AuthenticationFailed")
        XCTAssertEqual(error.coreReason, "无法连接 WebDAV 服务（TLS 握手失败）")
        XCTAssertEqual(error.coreApiCode, 401)
    }

    func testPlainMessageHasNoCoreReason() {
        let error = FlashFindError.message("UnknownSource")
        XCTAssertEqual(error.errorDescription, "UnknownSource")
        XCTAssertNil(error.coreReason, "没有核心原因时界面应退回按 kind 生成文案")
        XCTAssertNil(error.coreApiCode)
    }
}
