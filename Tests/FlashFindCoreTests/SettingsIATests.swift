import XCTest
@testable import FlashFindCore

/// 设置界面的信息架构与「来源行」判定（UI 简化）。
///
/// 这一批断言锁的是**新设计**里最容易在后续改动中被悄悄改回去的几条：
/// 页面数、页面集合、来源行什么时候给按钮，以及实验性来源开关的默认值。
/// 判定全在 Core，所以能被直接断言——App 层是 executableTarget，测试目标 import 不到。
final class SettingsIATests: XCTestCase {

    // MARK: - 页面集合

    /// ★ 一级导航最多四页。页数本身就是复杂度：七页意味着用户要在七个地方找一件小事。
    ///
    /// 第二次收敛：「搜索来源」并入「搜索」——它们回答的是同一个
    /// 问题（搜哪些地方），分成两页只会让用户在「调整搜索」和「管理 NAS」
    /// 之间来回跳。
    ///
    /// 第三次（1.1.2 Phase 9-lite，2026-10-22）：三页变四页，新增独立的「AI」页。
    /// **这不是回退**——AI 是 1.1.2 唯一的新增主功能，原先挂在「高级」里
    /// （§14.3.1 记过这条冲突），而「高级」只该放诊断与实验性开关。
    /// 四页仍是上限：再拆（比如把「允许的位置」单列一页）就会让
    /// 「为什么搜不到」又要在两页之间对照。
    func testSettingsPaneHasAtMostFourPages() {
        XCTAssertLessThanOrEqual(SettingsPane.allCases.count, 4,
                                 "设置的一级导航必须压到四页以内")
        XCTAssertEqual(SettingsPane.allCases.map(\.rawValue), ["通用", "搜索", "AI", "高级"])
    }

    /// ★ AI 是独立页，而且排在「高级」**前面**。
    ///
    /// 顺序不是审美：排在最后会让它看起来像「又一个高级设置」，
    /// 而它是这一版的主功能。前半句防「AI 又没了」，后半句防
    /// 「AI 还在，但被挪到高级后面，跟诊断混在一起」。
    func testAIIsItsOwnPaneAndSitsBeforeAdvanced() {
        let titles = SettingsPane.allCases.map(\.rawValue)
        guard let ai = titles.firstIndex(of: "AI"),
              let advanced = titles.firstIndex(of: "高级") else {
            return XCTFail("「AI」与「高级」都该是一级页，实际：\(titles)")
        }
        XCTAssertLessThan(ai, advanced, "AI 页要排在「高级」前面：正式功能不该排在诊断之后")
    }

    /// ★ 「搜索来源」不再是独立页面。
    ///
    /// 它并入「搜索」之后，**来源列表与「添加搜索来源」入口就住在搜索页里**。
    /// 这条钉住合并的结果，免得以后有人又把它拆出去。
    func testSourcesAreNotItsOwnPaneAnymore() {
        let titles = Set(SettingsPane.allCases.map(\.rawValue))
        XCTAssertFalse(titles.contains("搜索来源"),
                       "来源列表已并入「搜索」页，不该再有独立一级页")
    }

    /// 权限 / 外观不再是独立页面；「关于」走独立面板。
    ///
    /// 这三项若回到一级导航，就说明页面简化被回退了。
    func testSettingsPaneExcludesPermissionAppearanceAndAbout() {
        let titles = Set(SettingsPane.allCases.map(\.rawValue))
        for removed in ["权限", "外观", "关于"] {
            XCTAssertFalse(titles.contains(removed),
                           "「\(removed)」不该再是一级页面：权限/外观已并入通用，关于走独立面板")
        }
    }

    // MARK: - 来源行：正常不给按钮

    private func source(scopes: [String] = ["/示例共享文件夹", "/项目资料"],
                        host: String = "192.0.2.96", username: String = "nasuser",
                        enabled: Bool = true) -> NASSourceConfig {
        NASSourceConfig(name: "公司 NAS", vendor: .synology,
                        host: host, port: 5001, username: username, scopes: scopes, enabled: enabled)
    }

    /// ★ 正常连接的来源**一个按钮都不给**。
    ///
    /// 这一行上若挂着「参与搜索 / 重新连接 / 管理… / 断开」，正常也照挂，
    /// 于是设置页看着像 NAS 管理器。这条钉住「正常 = 无操作」。
    func testReadySourceRowHasNoActionButton() {
        let row = NASSourceRowModel.make(config: source(), status: NASSourceStatus(), ready: true)
        XCTAssertNil(row.action, "正常连接的来源不该出现按钮")
        XCTAssertEqual(row.detail, "群晖 · 已连接")
        XCTAssertEqual(row.locations, "示例共享文件夹、项目资料")
        XCTAssertEqual(row.health, .ready)
        XCTAssertTrue(row.enabled)
    }

    /// 关掉的来源不搜索、不删除、也不给按钮。
    func testDisabledSourceRowHasNoActionButKeepsLocations() {
        let row = NASSourceRowModel.make(config: source(enabled: false), status: NASSourceStatus(), ready: false)
        XCTAssertNil(row.action, "用户主动关闭的来源不给操作按钮")
        XCTAssertEqual(row.detail, "已关闭")
        XCTAssertFalse(row.enabled)
        // 位置仍然显示：关掉不等于忘了配过什么。
        XCTAssertEqual(row.locations, "示例共享文件夹、项目资料")
    }

    // MARK: - 来源行：异常才给按钮，而且只给一个

    private func status(health: NASSourceHealth, action: NASSourceRequiredAction?, message: String = "",
                        needsOTP: Bool = false) -> NASSourceStatus {
        var s = NASSourceStatus()
        s.health = health; s.requiredAction = action; s.message = message
        s.needsOTP = needsOTP
        return s
    }

    /// 连不上 → [重试]。
    func testOfflineSourceRowOffersRetry() {
        let row = NASSourceRowModel.make(config: source(), status: status(health: .offline, action: .retry), ready: false)
        XCTAssertEqual(row.action, .retry)
        XCTAssertEqual(row.detail, "无法连接")
        XCTAssertEqual(row.action?.buttonTitle, "重试")
    }

    /// 本机没有密码 → [登录]。
    func testNeedsLoginSourceRowOffersLogin() {
        let long = ReconnectEntryState.missingStoredReason
        let row = NASSourceRowModel.make(config: source(),
                                        status: status(health: .needsAttention, action: .login, message: long),
                                        ready: false)
        XCTAssertEqual(row.action, .login)
        XCTAssertEqual(row.detail, "需要重新登录")
        XCTAssertEqual(row.action?.buttonTitle, "登录")
    }

    /// 设备要动态码 → 仍然只给 [登录]，但**说法必须变**。
    ///
    /// 真机（2026-10-23）：第二台 NAS 开了两步验证，自动连接必然失败，
    /// 而列表照旧写着「需要重新登录」——用户于是以为密码又没存住，
    /// 每次都把密码重输一遍。实际密码好好躺在钥匙串里，缺的只是那 6 位码。
    func testOTPRequiredSourceRowSaysItNeedsACodeNotALogin() {
        let row = NASSourceRowModel.make(config: source(),
                                        status: status(health: .needsAttention, action: .login,
                                                       message: "设备要求动态码", needsOTP: true),
                                        ready: false)
        XCTAssertEqual(row.action, .login, "按钮还是「登录」：点它才会弹动态码输入框")
        XCTAssertEqual(row.detail, "需要输入动态码",
                       "要动态码时不能说「需要重新登录」——那句话在说密码没了")
    }

    /// 配置不完整 / 需要选位置 / 证书要确认 → [继续设置]。
    func testIncompleteConfigurationOffersContinueSetup() {
        let notConfigured = NASSourceRowModel.make(
            config: source(host: "", username: ""), status: NASSourceStatus(), ready: false)
        XCTAssertEqual(notConfigured.action, .continueSetup)
        XCTAssertEqual(notConfigured.detail, "需要填写地址与账号")

        let noScopes = NASSourceRowModel.make(
            config: source(scopes: []), status: NASSourceStatus(), ready: true)
        XCTAssertEqual(noScopes.action, .continueSetup)
        XCTAssertEqual(noScopes.detail, "需要选择搜索位置")

        let cert = NASSourceRowModel.make(
            config: source(), status: status(health: .needsAttention, action: .continueSetup), ready: false)
        XCTAssertEqual(cert.action, .continueSetup)
        XCTAssertEqual(cert.action?.buttonTitle, "继续设置")
    }

    /// ★ 列表行上只放**短**状态语，完整原因留给详情页。
    ///
    /// 把 `status.message` 整句（可能是「读取共享目录失败：连接被拒绝…」）
    /// 直接铺在行上，一行被撑得又高又乱，还挤掉了搜索位置。
    func testRowDetailStaysShortAndNeverDumpsTheRawMessage() {
        let long = "读取共享目录失败：" + String(repeating: "很长的原因", count: 8)
        let row = NASSourceRowModel.make(
            config: source(),
            status: status(health: .needsAttention, action: .continueSetup, message: long),
            ready: false)
        XCTAssertNotEqual(row.detail, long, "列表行不该直接显示完整的原因文本")
        XCTAssertLessThanOrEqual(row.detail.count, 12, "行上的状态语必须短：\(row.detail)")
    }

    /// 正在连接时不打扰用户——不给按钮，等它自己走完。
    func testConnectingSourceRowHasNoButton() {
        let row = NASSourceRowModel.make(
            config: source(), status: status(health: .connecting, action: nil), ready: false)
        XCTAssertNil(row.action)
        XCTAssertEqual(row.detail, "正在连接…")
    }

    /// 没连上但也没有明确原因时，仍是「未连接 + 重试」，不会出现空按钮。
    func testPlainNotConnectedStillOffersRetry() {
        let row = NASSourceRowModel.make(
            config: source(), status: status(health: .offline, action: nil), ready: false)
        XCTAssertEqual(row.action, .retry)
        XCTAssertEqual(row.detail, "未连接")
    }

    /// 动作与按钮标题一一对应，不许出现「有事却没入口」。
    func testEveryRequiredActionHasAButtonTitle() {
        let titles = [NASSourceRequiredAction.retry, .login, .continueSetup].map(\.buttonTitle)
        XCTAssertEqual(titles, ["重试", "登录", "继续设置"])
    }

    /// 搜索位置在界面上不带前导斜杠（那是 DSM 的表示法，不是产品概念）。
    func testScopeDisplayNameStripsTheLeadingSlash() {
        XCTAssertEqual(NASSourceRowModel.scopeDisplayName("/项目资料"), "项目资料")
        XCTAssertEqual(NASSourceRowModel.scopeDisplayName("项目资料"), "项目资料")
    }

    /// 行上状态用短名，不带品牌全称里的英文。
    func testVendorShortTitleIsUsedOnTheRow() {
        XCTAssertEqual(NASSourceConfig.Vendor.synology.shortTitle, "群晖")
        XCTAssertFalse(NASSourceConfig.Vendor.synology.shortTitle.contains("Synology"),
                       "行上不该出现品牌英文全称")
    }

    // MARK: - 实验性来源开关

    /// ★ 默认**关**：开关只管「实验性」的那几个品牌。
    ///
    /// 群晖、飞牛、OpenList 是**正式开放**的三项，不归这个开关管 ——
    /// 关着的时候也应该看得见，否则用户永远找不到它们的入口。
    func testExperimentalSourcesDefaultsOffAndGatesTheVendorList() {
        XCTAssertFalse(ExperimentalSources.resolve(stored: nil), "没设过必须是关")
        XCTAssertFalse(ExperimentalSources.resolve(stored: false))
        XCTAssertTrue(ExperimentalSources.resolve(stored: true))

        XCTAssertEqual(ExperimentalSources.vendors(includingExperimental: false),
                       [.synology, .fnos, .openlist],
                       "关着的时候给正式开放的三项")
        // 打开只放出「核心里有适配器的」那一批：没接入的（smb/generic）不出现——
        // 摆出来等于请用户去试一个连不上的类型。
        //
        // 顺序 = 正式三项在前，其余按 `allCases` 声明顺序追加
        // （qnap → ugreen → webdav，与「优先级」无关）。
        // ★ 飞牛 2026-10-29 转正后**不在追加批里**：它已在基线里，
        //   `ExperimentalSources` 的 `!result.contains(vendor)` 会跳过它。
        XCTAssertEqual(ExperimentalSources.vendors(includingExperimental: true),
                       [.synology, .fnos, .openlist, .qnap, .ugreen, .webdav],
                       "打开以后给出的是核心认得的类型，不是全部枚举值")
    }

    // MARK: - 诊断汇总

    /// 诊断只报已知事实，不编造探针结果。
    func testDiagnosticsSummaryReportsFactsOnly() {
        let usable = ConnectionDiagnostics.summary(config: source(), status: NASSourceStatus(), ready: true)
        XCTAssertEqual(usable.map(\.title), ["参与搜索", "连接", "搜索位置", "搜索"])
        XCTAssertTrue(usable.allSatisfy(\.ok), "正常来源的每一行都应为 ok")

        var offline = NASSourceStatus()
        offline.health = .offline
        let broken = ConnectionDiagnostics.summary(
            config: source(scopes: []), status: offline, ready: false)
        let search = broken.first { $0.title == "搜索" }
        XCTAssertEqual(search?.value, "不可用")
        XCTAssertEqual(search?.ok, false)
        let connection = broken.first { $0.title == "连接" }
        XCTAssertEqual(connection?.value, "未连接")
    }

    /// 关掉的来源在诊断里也必须写明「已关闭」，而不是笼统说不可用。
    func testDiagnosticsFlagsDisabledSource() {
        let lines = ConnectionDiagnostics.summary(
            config: source(enabled: false), status: NASSourceStatus(), ready: false)
        XCTAssertEqual(lines.first { $0.title == "参与搜索" }?.value, "已关闭")
    }
}
