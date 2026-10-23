import XCTest
@testable import FlashFindCore

/// 会记账的内存偏好：除了像 `InMemoryClientPreferences` 一样存值，还数写了几次。
///
/// 「一次性持久化」这件事只能靠写入次数证明：写入内容最终一样，
/// 分两次写也会得到同样的终态，只有次数能区分「一次写完」和「先关再清」。
private final class CountingClientPreferences: ClientPreferences {
    private var values: [String: Any] = [:]
    private(set) var writeCount = 0

    func object(forKey key: String) -> Any? { values[key] }

    func set(_ value: Any?, forKey key: String) {
        writeCount += 1
        values[key] = value
    }

    func resetWrites() { writeCount = 0 }
}

/// Phase 4 验收：权限判定（方案 §5.1 / §5.2 / §4.2.1 / §4.3.1）。
///
/// 这批用例**先于实现写出**，锁的是三条最容易写错的语义：
///
/// 1. **总开关关着时，任何参数组合都只能得到 `mcp_disabled`。** 这条要按组合遍历，
///    不能只测一个「典型」输入——漏掉的那一组正是以后被写成「显式点名就放行」的地方。
/// 2. **`requested == nil` 等于 allowlist，不等于「全部来源」。** 这两者在「存在未授权
///    来源」时结果完全不同，而写错时没有任何报错，只是悄悄把私人 NAS 搜了。
/// 3. **拒绝信息里不得出现来源名/来源 id。** 来源名本身就是信息（`私人 NAS`
///    `财务归档`），一旦进 Agent 上下文就撤不回来；连「这个 id 存不存在」都不能让人
///    试出来，所以「未授权」与「不存在」必须给出**同一个** code 与 message。
///
/// 另一半是设置页骨架的可测部分（`AIAccessSettings` / `AIAccessStore`）：
/// 默认 OFF、首次开启不预勾任何来源、开启后零来源不许保存。
final class PermissionPolicyTests: XCTestCase {

    // 全是编造的 id 与名字：测试不许出现真实设备名。
    private let mac = "local_mac"
    private let work = "src_nas_work"
    private let home = "src_nas_home"
    /// 一直存在、但从未被授权的来源。
    private let finance = "src_nas_finance"

    private var existingAll: Set<String> { [mac, work, home, finance] }

    // MARK: - 1. 总开关

    /// 总开关关着 → 一律 `mcp_disabled`，**不因为显式点名而放行**。
    func testMasterSwitchOffDeniesEveryCombination() {
        let allowlists: [Set<String>] = [[], [mac], [mac, work], [mac, work, home, finance]]
        let requests: [[String]?] = [nil, [], [mac], [finance], [mac, finance]]

        for allowed in allowlists {
            for requested in requests {
                let decision = PermissionPolicy.decision(mcpEnabled: false,
                                                         allowedSources: allowed,
                                                         requested: requested,
                                                         existing: existingAll)
                guard case .deny(let code, _) = decision else {
                    return XCTFail("总开关关着却放行了：allowed=\(allowed.sorted()) requested=\(String(describing: requested))")
                }
                XCTAssertEqual(code, .mcpDisabled,
                               "allowed=\(allowed.sorted()) requested=\(String(describing: requested))")
            }
        }
    }

    /// 总开关开着、但一个来源都没勾 → 也是 `mcp_disabled`（§4.3.1「一个都没勾选」）。
    ///
    /// ★ 不能返回 `allow([])`：那会让 Agent 得到「0 条结果」并告诉用户「没找到」，
    /// 而真实原因是没授权 —— 空结果与失败必须可区分（§4.2.1）。
    func testEnabledWithEmptyAllowlistIsMcpDisabled() {
        for requested in [nil, [mac], [finance]] as [[String]?] {
            let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                     allowedSources: [],
                                                     requested: requested,
                                                     existing: existingAll)
            guard case .deny(let code, _) = decision else {
                return XCTFail("allowlist 为空却放行了：requested=\(String(describing: requested))")
            }
            XCTAssertEqual(code, .mcpDisabled)
        }
    }

    /// allowlist 里的来源全被删了 → 同样 `mcp_disabled`，不是 `allow([])`。
    func testAllAllowlistedSourcesDeletedIsMcpDisabled() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [home],
                                                 requested: nil,
                                                 existing: [mac, work])
        guard case .deny(let code, _) = decision else { return XCTFail("已无可用来源却放行了") }
        XCTAssertEqual(code, .mcpDisabled)
    }

    // MARK: - 2. `requested == nil` 的语义

    /// `nil` = 只搜 allowlist ∩ 现存来源。**绝不是「全部来源」。**
    func testMissingRequestSearchesAllowlistNotEverything() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac],
                                                 requested: nil,
                                                 existing: existingAll)
        guard case .allow(let sources, let warnings) = decision else {
            return XCTFail("allowlist 非空却拒绝了：\(decision)")
        }
        XCTAssertEqual(Set(sources), [mac])
        // 这三个都存在，只是没授权 —— 一个都不许出现。
        XCTAssertFalse(sources.contains(work))
        XCTAssertFalse(sources.contains(home))
        XCTAssertFalse(sources.contains(finance))
        XCTAssertTrue(warnings.isEmpty, "没点名任何来源，就不该产生任何 warning（warnings 也不许列举未授权来源）")
    }

    /// allowlist 里已经不存在的来源要从结果里消失（用户删了 NAS，授权还留着）。
    func testDeletedAllowlistedSourceIsNotReturned() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac, home],
                                                 requested: nil,
                                                 existing: [mac, work])
        guard case .allow(let sources, _) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(Set(sources), [mac])
        XCTAssertFalse(sources.contains(home), "已删除的来源不许出现在结果里")
    }

    // MARK: - 3. 显式点名

    func testExplicitRequestOfAuthorizedSourcesIsAllowed() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac, work],
                                                 requested: [work, mac],
                                                 existing: existingAll)
        guard case .allow(let sources, let warnings) = decision else { return XCTFail("\(decision)") }
        XCTAssertEqual(Set(sources), [mac, work])
        XCTAssertTrue(warnings.isEmpty)
    }

    /// 点名里混了一条未授权的 → **不整体拒绝**，降级为该来源的 warning（§4.2.1）。
    ///
    /// warning 里的 id 是 Agent 自己传进来的，回显它不泄露任何东西。
    func testExplicitRequestMixingDeniedSourceDegradesToWarning() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac],
                                                 requested: [mac, finance],
                                                 existing: existingAll)
        guard case .allow(let sources, let warnings) = decision else {
            return XCTFail("有一条合法来源就应当放行并按 §4.2.1 降级：\(decision)")
        }
        XCTAssertEqual(Set(sources), [mac])
        XCTAssertEqual(warnings, ["source_denied:\(finance)"])
    }

    /// 点名的全部不可用 → `source_denied`，不是空结果。
    func testExplicitRequestEntirelyDeniedIsSourceDenied() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac, work],
                                                 requested: [finance],
                                                 existing: existingAll)
        guard case .deny(let code, let message) = decision else { return XCTFail("应当拒绝：\(decision)") }
        XCTAssertEqual(code, .sourceDenied)
        XCTAssertFalse(message.contains(finance), "拒绝信息里不许出现来源 id")
        // 也不许把**其它**未授权的来源抖出来。
        for id in [mac, work, home, finance] {
            XCTAssertFalse(message.contains(id), "拒绝信息里出现了来源 id：\(id)")
        }
    }

    /// 「未授权」与「根本不存在」必须给出同一个 code 与 message。
    ///
    /// 否则 Agent 只要挨个试 id、看返回哪个码，就能把用户有哪些 NAS 枚举出来
    /// —— 这正是 §4.3.1 要挡的那类泄露。
    func testDenyMessageDoesNotDistinguishUnknownFromUnauthorized() {
        func decision(for id: String) -> PermissionDecision {
            PermissionPolicy.decision(mcpEnabled: true, allowedSources: [mac],
                                      requested: [id], existing: existingAll)
        }
        guard case .deny(let codeA, let messageA) = decision(for: finance),
              case .deny(let codeB, let messageB) = decision(for: "src_does_not_exist") else {
            return XCTFail("两种情况都应当拒绝")
        }
        XCTAssertEqual(codeA, codeB)
        XCTAssertEqual(messageA, messageB, "code 与文案都必须一致，否则可以据此枚举 source_id")
    }

    /// 点名一个「已授权但已被删除」的来源 → 同样按不可用处理。
    ///
    /// ★ 构造上必须让 allowlist 里**还有一个可用来源**（这里留 `mac`）。
    /// 否则可用集为空，会先命中「一个可用来源都没有」那条分支拿到 `mcp_disabled`——
    /// 那是一种不同的状态（用户该去重新选来源），不是本条要验的「不可区分」。
    func testExplicitlyRequestingDeletedSourceIsDeniedLikeUnauthorized() {
        let deleted = PermissionPolicy.decision(mcpEnabled: true, allowedSources: [mac, home],
                                                requested: [home], existing: [mac])
        let unauthorized = PermissionPolicy.decision(mcpEnabled: true, allowedSources: [mac],
                                                     requested: [finance], existing: existingAll)
        guard case .deny(let codeA, let msgA) = deleted,
              case .deny(let codeB, let msgB) = unauthorized else {
            return XCTFail("两种情况都应当拒绝")
        }
        XCTAssertEqual(codeA, .sourceDenied)
        XCTAssertEqual(codeA, codeB)
        XCTAssertEqual(msgA, msgB)
    }

    /// 空数组**不等于**没传。传 `[]` 是调用方写错了，必须 fail closed，
    /// 不能静默退化成「搜 allowlist」——那会让一次参数错误变成一次范围更大的搜索。
    func testEmptyRequestedArrayFailsClosed() {
        let decision = PermissionPolicy.decision(mcpEnabled: true,
                                                 allowedSources: [mac, work],
                                                 requested: [],
                                                 existing: existingAll)
        guard case .deny(let code, _) = decision else {
            return XCTFail("requested 为空数组却当成了「没传」：\(decision)")
        }
        XCTAssertEqual(code, .sourceDenied)
    }

    // MARK: - 4. 归一化与不变量

    /// 重复与顺序不影响结果：去重、排序，保证同一组输入永远得到同一个 decision。
    func testDuplicatesAndOrderAreNormalized() {
        let a = PermissionPolicy.decision(mcpEnabled: true, allowedSources: [mac, work],
                                          requested: [work, mac, work], existing: existingAll)
        let b = PermissionPolicy.decision(mcpEnabled: true, allowedSources: [mac, work],
                                          requested: [mac, work], existing: existingAll)
        XCTAssertEqual(a, b)
        guard case .allow(let sources, _) = a else { return XCTFail("\(a)") }
        XCTAssertEqual(sources, [mac, work], "去重后按 id 排序")
    }

    /// 不变量：任何 allow 的结果都必须是 `allowlist ∩ 现存来源` 的子集，
    /// 且 warnings 只回显 Agent 自己点过的 id。
    ///
    /// 用固定种子的伪随机扫一遍，比手写几组输入更容易撞到边界组合。
    func testAllowResultIsAlwaysSubsetOfAllowlistAndExisting() {
        let pool = [mac, work, home, finance, "src_ghost"]
        var seed: UInt64 = 0x5DEE_CE66_D
        func next() -> UInt64 {
            seed = seed &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return seed
        }
        func subset() -> Set<String> {
            var out = Set<String>()
            for id in pool where next() % 3 == 0 { out.insert(id) }
            return out
        }

        for _ in 0..<300 {
            let allowed = subset()
            let existing = subset()
            var requested: [String]? = nil
            if next() % 2 == 0 {
                requested = (0..<Int(next() % 4)).map { _ in pool[Int(next() % UInt64(pool.count))] }
            }
            let decision = PermissionPolicy.decision(mcpEnabled: true, allowedSources: allowed,
                                                     requested: requested, existing: existing)
            XCTAssertEqual(decision,
                           PermissionPolicy.decision(mcpEnabled: true, allowedSources: allowed,
                                                     requested: requested, existing: existing),
                           "同样的输入必须得到同样的结果")
            switch decision {
            case .allow(let sources, let warnings):
                let usable = allowed.intersection(existing)
                XCTAssertFalse(sources.isEmpty, "放行却没有任何来源：allowed=\(allowed) existing=\(existing)")
                XCTAssertTrue(Set(sources).isSubset(of: usable),
                              "放行了不该放行的来源：\(sources) usable=\(usable.sorted())")
                for warning in warnings {
                    let parts = warning.split(separator: ":", maxSplits: 1).map(String.init)
                    XCTAssertEqual(parts.count, 2)
                    XCTAssertEqual(parts[0], "source_denied")
                    XCTAssertEqual(requested?.contains(parts[1]), true,
                                   "warning 里出现了 Agent 没点过的来源：\(warning)")
                }
            case .deny(let code, let message):
                XCTAssertTrue(code == .mcpDisabled || code == .sourceDenied)
                for id in pool { XCTAssertFalse(message.contains(id)) }
            }
        }
    }

    // MARK: - 5. 撤销立即生效（不允许缓存）

    /// 撤销授权后，**下一次**判定就要变。Policy 是纯函数，缓存只可能出现在调用方，
    /// 所以这条用例盯的是「每次都用当前事实重算」这个习惯本身。
    func testRevocationAppliesToTheVeryNextDecision() {
        var settings = AIAccessSettings(isEnabled: true, allowedSources: [mac, work])
        guard case .allow(let before, _) = settings.decision(requested: nil, existing: existingAll) else {
            return XCTFail("初始应当放行")
        }
        XCTAssertEqual(Set(before), [mac, work])

        settings = settings.settingSource(work, allowed: false)
        guard case .allow(let after, _) = settings.decision(requested: nil, existing: existingAll) else {
            return XCTFail("还剩一个来源，应当放行")
        }
        XCTAssertEqual(Set(after), [mac])
        XCTAssertFalse(after.contains(work), "撤销后立刻不得再出现")
    }

    // MARK: - 6. 设置页骨架（可测部分）

    func testDefaultsAreOffAndNothingIsPreselected() {
        let initial = AIAccessSettings.initial
        XCTAssertFalse(initial.isEnabled, "总开关默认 OFF")
        XCTAssertTrue(initial.allowedSources.isEmpty, "首次不得预勾任何来源")

        let preferences = InMemoryClientPreferences()
        let loaded = AIAccessStore.load(from: preferences)
        XCTAssertEqual(loaded, initial, "没存过 = 默认值，不是别的什么")
    }

    /// 打开总开关**不自动勾选**任何来源。首次开启时用户必须自己选。
    func testTurningOnPreselectsNothing() {
        let on = AIAccessSettings.initial.settingEnabled(true)
        XCTAssertTrue(on.isEnabled)
        XCTAssertTrue(on.allowedSources.isEmpty)
        XCTAssertFalse(on.canSave, "开着但一个都没勾 → 保存按钮必须不可点")
    }

    /// 关掉总开关不需要选来源，否则用户会卡在「开着且不能保存」。
    func testDisabledStateIsAlwaysSavable() {
        XCTAssertTrue(AIAccessSettings.initial.canSave)
        XCTAssertTrue(AIAccessSettings(isEnabled: false, allowedSources: []).canSave)
    }

    func testSelectingOneSourceMakesItSavable() {
        let settings = AIAccessSettings.initial.settingEnabled(true).settingSource(mac, allowed: true)
        XCTAssertTrue(settings.canSave)
    }

    func testDeselectingLastSourceBlocksSaving() {
        var settings = AIAccessSettings.initial.settingEnabled(true).settingSource(mac, allowed: true)
        XCTAssertTrue(settings.canSave)
        settings = settings.settingSource(mac, allowed: false)
        XCTAssertFalse(settings.canSave, "取消最后一个来源后就不该还能保存")
    }

    /// 存储层自己也要拒绝「开着但零来源」。只靠按钮置灰是不够的：
    /// 按钮状态是一个可以被绕过（或改坏）的 UI 事实，不能当成约束。
    func testStoreRefusesToPersistEnabledWithNoSources() {
        let preferences = InMemoryClientPreferences()
        let bad = AIAccessSettings(isEnabled: true, allowedSources: [])
        XCTAssertFalse(AIAccessStore.save(bad, to: preferences))
        XCTAssertEqual(AIAccessStore.load(from: preferences), .initial, "拒绝保存时不许留下半截状态")
    }

    func testStoreRoundTrips() {
        let preferences = InMemoryClientPreferences()
        let settings = AIAccessSettings(isEnabled: true, allowedSources: [mac, work])
        XCTAssertTrue(AIAccessStore.save(settings, to: preferences))
        XCTAssertEqual(AIAccessStore.load(from: preferences), settings)
    }

    /// 存下来的状态自相矛盾（开着却零来源）→ 读出来按「关」处理。
    ///
    /// 这种状态只可能来自手改偏好文件或旧版本写坏。照原样读出来的表现是
    /// 「开关是开着的，但 AI 什么也搜不到」，而且用户看不出为什么——
    /// 宁可降级成关，让界面上的开关诚实地显示「没开」。
    func testCorruptStoredStateLoadsAsDisabled() {
        let preferences = InMemoryClientPreferences(values: [
            AIAccessStore.enabledKey: true,
            AIAccessStore.sourcesKey: [String](),
        ])
        XCTAssertEqual(AIAccessStore.load(from: preferences), .initial)
    }

    /// 用户删掉一台 NAS 之后，授权里残留的 id 要剔除；**剔空就自动关闭**。
    ///
    /// 不允许的结果是「开着但零来源」：界面显示 [开]，MCP 每个请求都 `mcp_disabled`，
    /// 用户看不出到底哪一步不对。来源都没了，开关诚实地跟着关。
    func testPruneDropsSourcesThatNoLongerExist() {
        let settings = AIAccessSettings(isEnabled: true, allowedSources: [mac, home])
        let pruned = settings.pruned(against: [mac, work])
        XCTAssertEqual(pruned.allowedSources, [mac])
        XCTAssertTrue(pruned.isEnabled, "还剩一个授权来源，开关不受影响")

        let emptied = AIAccessSettings(isEnabled: true, allowedSources: [home]).pruned(against: [mac])
        XCTAssertTrue(emptied.allowedSources.isEmpty)
        XCTAssertFalse(emptied.isEnabled, "最后一个授权来源被删 → 自动关闭，不许留「开着但零来源」")
        XCTAssertEqual(emptied, .initial, "剔空之后应回到全新安装的取值")
    }

    /// **状态不变量**：删除最后一个已授权来源 → 自动关闭 → 一次性持久化。
    ///
    /// 这是 Phase 4 最后一处补齐。读写两侧要能对上：
    /// * 写入侧：`pruned` 剔空即关闭，`enabled` 与 `sources` 在同一次 `save` 里落盘；
    /// * 读取侧：`load` 对「开着却零来源」的损坏态按关读出（另一条用例守着）。
    /// 只补一侧，另一侧就会在重启/手改偏好之后把矛盾状态放回来。
    func testDeletingLastAuthorizedSourceTurnsAIOffAndPersistsOnce() {
        let preferences = CountingClientPreferences()
        let authorized = AIAccessSettings(isEnabled: true, allowedSources: [mac])
        XCTAssertTrue(AIAccessStore.save(authorized, to: preferences))

        // 用户删掉了唯一授权的那台来源。
        let afterDeletion = authorized.pruned(against: [home])
        XCTAssertFalse(afterDeletion.isEnabled)
        XCTAssertTrue(afterDeletion.allowedSources.isEmpty)

        preferences.resetWrites()
        XCTAssertTrue(AIAccessStore.save(afterDeletion, to: preferences),
                      "关闭态必须可保存——否则矛盾状态会一直留在磁盘上")
        XCTAssertEqual(preferences.writeCount, 2,
                       "enabled 与 sources 必须同一次写完：分开写会留下「关着但还勾着已删来源」的中间态")
        XCTAssertEqual(preferences.object(forKey: AIAccessStore.enabledKey) as? Bool, false,
                       "磁盘上的 enabled 必须是 false")
        XCTAssertEqual(AIAccessStore.load(from: preferences).isEnabled, false,
                       "重启后读出来也必须是关")
        XCTAssertEqual(afterDeletion.decision(requested: nil, existing: [home]),
                       .deny(code: .mcpDisabled, message: PermissionPolicy.switchOffMessage),
                       "自动关闭之后，判定必须回到 mcp_disabled，而不是 source_denied")
    }

    /// 反例守卫：只想「清空来源」而不关开关的写法，在 Core 层根本走不通。
    ///
    /// 这条不是重复上一条——上一条走 `pruned`（正常运行路径），这条直接构造坏值，
    /// 确认存储层仍然拒绝它。两条路都堵住，才能说这个状态不可达。
    func testEnabledWithZeroSourcesCannotReachDiskByAnyRoute() {
        let preferences = CountingClientPreferences()
        XCTAssertFalse(AIAccessStore.save(AIAccessSettings(isEnabled: true, allowedSources: []),
                                          to: preferences))
        XCTAssertEqual(preferences.writeCount, 0, "被拒绝的保存不许写任何键")
        XCTAssertNil(preferences.object(forKey: AIAccessStore.enabledKey))
    }
}

/// 判定层必须是**纯函数**：不读偏好、不碰文件系统、不认识 Keychain、不认识 MCP。
///
/// 这条用源码扫描守住，而不是靠注释约定——`PermissionPolicy` 一旦为了「省点参数」
/// 自己去读当前设置，撤销授权就不会在下次请求时生效，而且 App 与 Helper 会各自
/// 看到不同的事实。判定要能被单测覆盖，前提就是它只依赖入参。
final class PermissionPolicyPurityTests: XCTestCase {

    private func coreSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/\(name)"),
                          encoding: .utf8)
    }

    /// 去掉 `//` 与 `///` 注释——注释里出现「UserDefaults」正是在说明「不读它」。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> String in
                guard let range = line.range(of: "//") else { return String(line) }
                return String(line[line.startIndex..<range.lowerBound])
            }
            .joined(separator: "\n")
    }

    func testPolicyKnowsNothingAboutStorageOrMCP() throws {
        let code = codeOnly(try coreSource("PermissionPolicy.swift"))
        let forbidden = ["UserDefaults", "ClientPreferences", "FileManager", "Keychain",
                         "SecretStore", "import AppKit", "MCP", "URLSession", "NASSourceConfig"]
        for token in forbidden {
            XCTAssertFalse(code.contains(token), "PermissionPolicy 不许碰 \(token)——它只能依赖入参")
        }
        XCTAssertTrue(code.contains("enum PermissionPolicy"), "判定入口还在不在？")
        XCTAssertTrue(code.contains("static func decision"), "签名被改了？")
    }

    /// 反向断言：上面那条 `codeOnly` 真能把注释删掉（否则它可能一直是空串，断言就假绿了）。
    func testCodeOnlyActuallyStripsComments() throws {
        let code = codeOnly(try coreSource("PermissionPolicy.swift"))
        XCTAssertGreaterThan(code.count, 200, "剥离注释后不该只剩这么点内容")
        XCTAssertTrue(code.contains("mcp_disabled") || code.contains("mcpDisabled"))
    }
}

/// 设置页骨架的**接线**检查（App 层进不了单测，只能看源码有没有接对）。
///
/// 这里不检查排版，只检查那几条「不接就等于功能是假的」的线：
/// 开关绑的是草稿而不是已保存值、保存时带上「现在还存在哪些来源」、
/// 启动时真的读过一次偏好。
final class AIAccessSettingsSurfaceTests: XCTestCase {

    private func appSource(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/FlashFind2App/\(name)"),
                          encoding: .utf8)
    }

    func testSettingsSectionExistsWithStableIdentifiers() throws {
        let source = try appSource("SettingsView.swift")
        XCTAssertTrue(source.contains("允许 AI 使用闪寻"))
        // 标识是以后做 UI 用例的唯一抓手：不稳定就等于没有。
        for id in ["ai-access-enabled", "ai-access-save", "ai-access-revert"] {
            XCTAssertTrue(source.contains(id), "设置页缺少 \(id)")
        }
    }

    /// 开关必须绑草稿。绑到已保存值的话，点开关不会动（或者动完立刻被覆盖）。
    func testToggleBindsToDraftNotToSavedValue() throws {
        let source = try appSource("SettingsView.swift")
        XCTAssertTrue(source.contains("model.aiAccess.draft.isEnabled"), "开关读的不是草稿")
        XCTAssertFalse(source.contains("model.aiAccess.saved"), "界面不许直接读写已保存值——那是判定用的")
    }

    /// 保存必须把「现在还存在哪些来源」一起传下去，否则已删来源的授权永远清不掉。
    func testSavePassesExistingSourceIDs() throws {
        let source = try appSource("SettingsView.swift")
        XCTAssertTrue(source.contains("model.aiAccess.save(existing:"))
    }

    /// 启动时要真的读一次偏好。
    ///
    /// 这个仓库已经踩过两次「设置界面骗人」：状态在里面，界面却绑着另一份；
    /// 或者构造了 controller 但从没 `load()`，界面上永远是默认值。
    func testControllerIsLoadedAtStartup() throws {
        let source = try appSource("AppModel.swift")
        XCTAssertTrue(source.contains("aiAccess.load()"), "AppModel 没在启动时读 AI 访问设置")
        XCTAssertTrue(source.contains("aiAccessBridge = aiAccess.objectWillChange"), "没桥接 objectWillChange，界面不会跟着刷新")
    }

    /// 删掉一台 NAS 时要顺手清掉它残留的授权。
    func testRemovingSourceForgetsItsAuthorization() throws {
        let source = try appSource("AppModel+Wizard.swift")
        XCTAssertTrue(source.contains("aiAccess.forgetSources(notExisting:"),
                      "删来源时没清授权：list_sources 会一直报一个搜不到的来源")
    }

    /// 「不搜索这台 Mac」是**全局关闭**，压过 AI 授权，但**不许删授权**（§15 #26）。
    ///
    /// 两条线必须分开走，走混了都会出事：
    ///
    /// ```text
    /// 判定 / 执行  → aiAccessUsableCandidates（关着时本机不在里面）
    /// 落盘 / 清理  → aiAccessExistingSourceIDs（完整宇宙）
    /// ```
    ///
    /// * 判定用完整宇宙 → 用户明明关了「搜索这台 Mac」，Agent 还在搜；
    /// * 清理用可用集合 → 关一次开关就把那条授权**永久删掉**，恢复时要重新授权。
    ///
    /// ★ 授权是 latent authorization：`localEnabled` 关着只是「当前不可执行」。
    func testTheLocalSwitchGatesJudgementWithoutPruningTheAuthorization() throws {
        let model = codeOnly(try appSource("AppModel+AIAccess.swift"))
        XCTAssertTrue(model.contains("var aiAccessUsableCandidates"),
                      "没有「可用候选」这个类型，判权与授权就会共用一份")
        XCTAssertTrue(model.contains("candidate.id != SearchSource.local.id || localEnabled"),
                      "过滤规则不在这个函数里——那它就不叫 usable")

        let authority = codeOnly(try appSource("MCPAuthority.swift"))
        XCTAssertTrue(authority.contains("model.aiAccessUsableCandidates.map"),
                      "App 的判权来源必须过全局开关，否则关掉的本机还在被搜")
        XCTAssertFalse(authority.contains("model.aiAccessCandidates.map"),
                       "判权不许直接用完整宇宙")

        let wizard = codeOnly(try appSource("AppModel+Wizard.swift"))
        XCTAssertTrue(wizard.contains("forgetSources(notExisting: aiAccessExistingSourceIDs)"),
                      "清理残留授权必须用完整宇宙，否则关一次本机就永久丢掉授权")

        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.aiAccess.save(existing: model.aiAccessExistingSourceIDs)"),
                      "保存时的 prune 也必须用完整宇宙")

        let controller = codeOnly(try appSource("AIAccessController.swift"))
        XCTAssertFalse(controller.contains("aiAccessUsableCandidates"),
                       "prune 路径不许碰可用集合——那是 latent authorization 的生死线")
    }

    /// ★ AI 段搬出「高级」页，并长出自己的几块（Phase 9-lite，2026-10-22）。
    ///
    /// 两处入口必然分叉：一处改文案另一处没改，用户看到的就是「设置里有两个
    /// AI 开关，说的话还不一样」。所以「高级」里必须**一个标识都不剩**，
    /// 而 AI 页里四块都得在。
    func testTheAISectionMovedOutOfTheAdvancedPane() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))

        guard let advanced = braceBlock(after: "private var advancedForm: some View", in: settings) else {
            return XCTFail("缺少 advancedForm")
        }
        for id in ["ai-access-enabled", "ai-access-save", "ai-helper-status", "ai-history-clear",
                   "ai-prompt-text", "ai-prompt-copy"] {
            XCTAssertFalse(advanced.contains(id),
                           "「高级」页里还留着 \(id)：AI 段已搬去独立页，这里不许再有一份")
        }

        guard let ai = braceBlock(after: "private var aiForm: some View", in: settings) else {
            return XCTFail("缺少 AI 页 aiForm")
        }
        for id in ["ai-access-enabled", "ai-access-save", "ai-access-revert",
                   "ai-helper-status", "ai-history-title", "ai-history-clear",
                   "ai-prompt-text", "ai-prompt-copy", "ai-prompt-other-clients",
                   "ai-prompt-save-first"] {
            XCTAssertTrue(ai.contains(id), "AI 页缺少 \(id)")
        }
        // ★ 清空必须走二次确认：这是唯一一个删数据的按钮，一次误点就没了。
        XCTAssertTrue(ai.contains("confirmingHistoryClear = true"),
                      "「清空历史」没有先弹确认——它是这个页面里唯一会删东西的按钮")
        XCTAssertTrue(ai.contains(".alert(AIHistoryText.clearTitle"),
                      "确认框不见了")
        XCTAssertTrue(settings.contains("case .ai: aiForm"),
                      "一级导航里没有 AI 页这条分支——那 aiForm 永远走不到")
    }

    /// 「接入提示词」必须挂在**已保存且已开启**这道闸后面，不是草稿。
    ///
    /// 用草稿当条件的话：用户拨开开关、还没点保存，下面就已经摆出一段可复制的话。
    /// 复制过去必然连不上——权威端那边 AI 访问还是关的，每个请求都会被拒。
    /// 这种错界面看着完全正常，只能靠这条守着。
    func testThePromptWaitsForTheSavedGrant() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let ai = braceBlock(after: "private var aiForm: some View", in: settings) else {
            return XCTFail("缺少 AI 页 aiForm")
        }
        XCTAssertTrue(ai.contains("if model.isAIAccessGranted"),
                      "提示词前面没有「已保存且已开启」这道闸")
        // 顺序也要对：闸在前、提示词在后。只查「两者都在」是查不出挂反的。
        guard let gate = ai.range(of: "if model.isAIAccessGranted"),
              let prompt = ai.range(of: "Text(integration.text)") else {
            return XCTFail("AI 页里找不到闸或提示词")
        }
        XCTAssertLessThan(gate.lowerBound, prompt.lowerBound,
                          "提示词出现在闸之前——那等于没设防")
        // 开了但还没保存，必须有一句话解释「为什么下面是空的」。
        XCTAssertTrue(ai.contains("MCPIntegrationText.saveFirst"),
                      "开了但没保存时，这一段什么都不说")
    }

    /// 复制出来的必须是**界面上那一段**，不是重新拼一遍。
    ///
    /// 重新拼一次就会出现「屏幕上一句、剪贴板里另一句」——这种分叉没有编译错误，
    /// 也没有任何现象提示，只有把两处逐字比对才能发现。
    func testCopyTakesTheTextThatIsOnScreen() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        guard let ai = braceBlock(after: "private var aiForm: some View", in: settings) else {
            return XCTFail("缺少 AI 页 aiForm")
        }
        XCTAssertTrue(ai.contains("Text(integration.text)"), "屏幕上显示的不是那一段")
        XCTAssertTrue(ai.contains("copyPrompt(integration.text)"),
                      "复制按钮没有把界面上那一段交给剪贴板")
    }

    /// 那道闸读的必须是**已保存**值。
    ///
    /// 这个只读口子存在的唯一理由，就是「视图不许直接摸 `saved`」。它自己要是读了草稿，
    /// 这道闸等于没有——而且从名字上看不出来（还叫 `isAIAccessGranted`），
    /// 只能靠这一条守着。
    func testTheGrantGateReadsTheSavedValue() throws {
        let model = codeOnly(try appSource("AppModel+AIAccess.swift"))
        XCTAssertTrue(model.contains("var isAIAccessGranted: Bool { aiAccess.saved.isEnabled }"),
                      "闸读的不是已保存值——拨开开关还没保存，AI 页就已经在发接入说明")
    }

    /// ★ 注入必须发生在启动之前。
    ///
    /// 反过来的表现很隐蔽：监听其实起来了，设置页却一直显示「未启动」——
    /// `lastStart` 是在 `start()` 里写的，先读后写只能读到 nil。
    func testTheAuthorityIsInjectedBeforeItStarts() throws {
        let app = codeOnly(try appSource("FlashFind2App.swift"))
        guard let injected = app.range(of: "model.mcpAuthority = mcpAuthority"),
              let started = app.range(of: "mcpAuthority.start(model: model)") else {
            return XCTFail("App 入口没把权威端注入模型，或没启动它")
        }
        XCTAssertLessThan(injected.lowerBound, started.lowerBound,
                          "先启动再注入：设置页会一直显示「未启动」")
    }

    /// ★ 历史那一行读的是**已保存**的总开关，条数来自历史库。
    ///
    /// 读草稿会骗人（改了一半没保存，界面已经在说「记录中」）；
    /// 估算条数更糟——`canClear` 要靠它判断，估错就给出一个点了没用的按钮。
    func testTheHistoryRowReadsTheSavedSwitchAndTheRealCount() throws {
        let settings = codeOnly(try appSource("SettingsView.swift"))
        XCTAssertTrue(settings.contains("model.aiHistorySummary"),
                      "设置页没接上历史摘要，那一行只能是死值")
        XCTAssertTrue(settings.contains("model.clearAIHistory()"),
                      "「清空历史」按钮没接上真正的清理动作")

        let model = codeOnly(try appSource("AppModel+AIAccess.swift"))
        XCTAssertTrue(model.contains("aiAccess.saved.isEnabled"),
                      "历史行必须读已保存的开关，不能读草稿")
        XCTAssertTrue(model.contains("mcpAuthority?.historyEventCount()"),
                      "条数要来自历史库，不许估算")
    }

    /// 去掉整行注释后的源码。
    ///
    /// ★ 不剥注释的话，下面那些 `contains` 会被注释里的变量名满足；
    /// 尤其 `XCTAssertFalse` 那几条，注释里提一句「不要用完整宇宙」就会永远绿。
    private func codeOnly(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 从 `marker` 之后第一个 `{` 起，按括号配平切出整块。
    ///
    /// ★ 不能用「整文件 `contains`」代替：同名标识在另一个函数里出现过，
    /// 整文件断言就永远绿（本仓库踩过两次）。这里另拷一份，不去共享别处的实现。
    private func braceBlock(after marker: String, in text: String) -> String? {
        guard let markerRange = text.range(of: marker),
              let open = text.range(of: "{", range: markerRange.upperBound..<text.endIndex) else { return nil }
        var depth = 0
        var index = open.lowerBound
        while index < text.endIndex {
            switch text[index] {
            case "{": depth += 1
            case "}":
                depth -= 1
                if depth == 0 { return String(text[open.lowerBound...index]) }
            default: break
            }
            index = text.index(after: index)
        }
        return nil
    }

    /// 忘记一个来源这条路径**只写一次盘**。
    ///
    /// 这里必须按函数切块再数：同一文件里 `save(existing:)` 也有一处 `AIAccessStore.save(`，
    /// 直接对整份源码 `contains` / 计数会把两处混在一起，看起来「接对了」其实什么都没证明。
    func testForgettingSourcesWritesExactlyOnce() throws {
        let source = try appSource("AIAccessController.swift")
        let body = try functionBody(named: "forgetSources", in: source)
        let writes = body.components(separatedBy: "AIAccessStore.save(").count - 1
        XCTAssertEqual(writes, 1, "删来源后的落盘必须一次写完（enabled 与 sources 同一次）")
        XCTAssertTrue(body.contains(".pruned(against:"),
                      "忘记来源必须先按现存来源收敛——剔空即自动关闭的不变量在 pruned 里")
    }

    /// 取某个函数体（从 `func name(` 到下一个同类缩进的 `func`）。
    ///
    /// 只服务于上面那种「数调用次数」的断言。切不出来就直接失败，
    /// 不许静默返回空串——空串会让「次数 == 0」型的断言变成假绿。
    private func functionBody(named name: String, in source: String) throws -> String {
        guard let start = source.range(of: "func \(name)(") else {
            XCTFail("源码里找不到函数 \(name)")
            return ""
        }
        let rest = source[start.upperBound...]
        let body = rest.range(of: "\n    func ").map { String(rest[..<$0.lowerBound]) } ?? String(rest)
        XCTAssertFalse(body.isEmpty, "函数 \(name) 切出来是空的，切块逻辑坏了")
        return body
    }
}
