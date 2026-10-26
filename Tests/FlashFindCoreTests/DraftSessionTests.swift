import XCTest
@testable import FlashFindCore

/// 草稿会话的所有权语义（用户报障：「已登录后修改搜索位置点击不了」）。
///
/// 这一组锁两件事，正是那个 bug 的两半：
///  ① **借来的活会话也能改搜索位置** —— 之前判定用「有没有本次新连的会话」，
///     编辑已连接的来源永远进不来，界面写着「已连接，可以搜索了」却点不动；
///  ② **离开草稿时不误断开借来的会话** —— 那是连接管理器手里用户正在用的连接，
///     取消一次编辑把它断开，就是「点一下取消，来源掉线」。
///
/// 每条断言都必须能在对应缺陷存在时变红，见报告里的变异记录。
@MainActor
final class DraftSessionTests: XCTestCase {

    /// 记录发到核心的每条命令，并允许指定 `selectScope` 的应答。
    private final class RecordingBridge: MyNASBridgeTransport {
        var commands: [(name: String, fields: [String: Any])] = []
        /// `selectScope` 回什么状态。默认 `scopeReady`（成功）。
        var selectScopeState = "scopeReady"

        /// 让 `selectScope` 卡在闸门上，直到 `releaseGate()`。
        ///
        /// ★ 这个闸门是**复现竞态的必需品**：没有它，「响应晚一步回来」
        /// 这种时序在测试里根本造不出来，只能测到「改完了再取消」那条不痛的路径。
        /// 同时只允许一个请求卡在闸门上（本文件不会出现两个）。
        var holdSelectScope = false
        private var selectScopeGate: CheckedContinuation<Void, Never>?

        /// 放行卡住的那次 `selectScope`。
        func releaseGate() {
            let pending = selectScopeGate
            selectScopeGate = nil
            pending?.resume()
        }

        func request(_ command: String, sourceID: String, queryID: String,
                     fields: [String: Any], event: (([String: Any]) -> Void)?) async throws -> [String: Any] {
            commands.append((command, fields))
            switch command {
            case "discover": return ["event": "capabilities"]
            case "login": return ["event": "authState", "state": "scopeReady", "isManager": false]
            case "selectScope":
                if holdSelectScope {
                    await withCheckedContinuation { selectScopeGate = $0 }
                }
                return ["event": "scopeState", "state": selectScopeState,
                                        "scopes": fields["scopes"] ?? []]
            case "disconnect": return ["event": "sourceState", "state": "disconnected"]
            default: return [:]
            }
        }

        var disconnectCount: Int { commands.filter { $0.name == "disconnect" }.count }
        var selectScopeCalls: [[String: Any]] {
            commands.filter { $0.name == "selectScope" }.map(\.fields)
        }
    }

    private func connectedProvider(_ bridge: RecordingBridge,
                                   scopes: [String] = ["/A0002"]) async throws -> NASSearchProvider {
        let config = NASSourceConfig(vendor: .openlist, host: "openlist.example.invalid",
                                     port: 443, username: "tester", scopes: scopes)
        let provider = NASSearchProvider(bridge: bridge, config: config, port: 443)
        try await provider.login(account: "tester", password: "p")
        _ = try await provider.selectScopes(scopes)
        XCTAssertTrue(provider.ready, "前置：这台来源应当已就绪")
        return provider
    }

    // MARK: - ① 借来的会话能不能改搜索位置

    /// ★ 这条就是用户报的那个 bug：编辑已连接的来源时勾选必须可用。
    ///
    /// 变异：把 `canEditScopes` 改回只有 `.wizard` 为真（等价于原来的
    /// `pendingProvider != nil`），本条立刻红。
    func testBorrowedSessionAllowsScopeEditing() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge)
        let session = DraftSession.borrowed(provider)
        XCTAssertTrue(session.canEditScopes,
                      "编辑已连接的来源时，借来的活会话必须能改搜索位置")
        XCTAssertNotNil(session.provider)
    }

    func testEmptySessionCannotEditScopes() {
        XCTAssertFalse(DraftSession.none.canEditScopes, "还没连上就不该能勾选")
        XCTAssertNil(DraftSession.none.provider)
    }

    /// 新建的会话同样能改（回归：别把原来能用的那条路弄坏）。
    func testWizardSessionAllowsScopeEditing() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge)
        XCTAssertTrue(DraftSession.wizard(provider).canEditScopes)
    }

    // MARK: - ② 离开草稿时的收尾

    /// ★ 借来的会话**不许**在取消/返回时被断开。
    ///
    /// 变异：让 `release` 对所有 case 都 `disconnect`（等价于原来无条件断开），红。
    func testReleasingBorrowedSessionNeverDisconnectsIt() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge)
        let session = DraftSession.borrowed(provider)

        let note = await session.release(persistedScopes: ["/A0002"])

        XCTAssertNil(note, "范围没变过，收尾应当干净")
        XCTAssertEqual(bridge.disconnectCount, 0,
                       "借来的会话是用户正在用的连接，取消编辑绝不能把它断开")
        XCTAssertTrue(provider.ready, "断开后 ready 会翻成 false —— 用户会看到来源掉线")
    }

    /// 反向：本次新建的会话必须由向导断开，否则核心里留下没人认领的会话。
    ///
    /// 变异：`disconnectsOnTeardown` 恒为 false（漏了断开），红。
    func testReleasingWizardSessionDisconnectsIt() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge)
        let session = DraftSession.wizard(provider)

        let note = await session.release(persistedScopes: [])

        XCTAssertNil(note)
        XCTAssertEqual(bridge.disconnectCount, 1, "自己建的会话离开时必须断开")
        XCTAssertFalse(provider.ready)
    }

    /// ★ 编辑期间改过范围、最后点「取消」—— 必须把范围滚回已保存的那份。
    ///
    /// 不回滚的后果不是「界面不一致」这么轻：界面退回去了，
    /// 底层会话却还在用新范围搜索，配置说一套、实际跑另一套。
    ///
    /// 变异：`release` 里去掉 rollback 分支，红。
    func testReleasingBorrowedSessionRestoresSavedScopes() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        // 模拟编辑时用户又勾了一个目录（每点一下都直接改活会话）。
        _ = try await provider.selectScopes(["/A0002", "/A0123"])
        XCTAssertEqual(provider.config.scopes, ["/A0002", "/A0123"], "前置：活会话范围已改")

        let note = await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"])

        XCTAssertNil(note, "回滚应当成功")
        XCTAssertEqual(provider.config.scopes, ["/A0002"],
                       "取消编辑后，活会话必须回到已保存的范围")
        XCTAssertEqual(bridge.selectScopeCalls.last?["scopes"] as? [String], ["/A0002"],
                       "回滚必须真的发到核心，不能只改本地字段")
        XCTAssertEqual(bridge.disconnectCount, 0, "回滚不等于断开")
    }

    /// 范围没变就别多发一条命令（免得取消一次也去动核心）。
    func testReleasingUnchangedBorrowedSessionTouchesNothing() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        let before = bridge.commands.count

        let note = await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"])

        XCTAssertNil(note)
        XCTAssertEqual(bridge.commands.count, before, "范围没变就不该再打扰核心")
    }

    /// 回滚失败要如实说，不能假装成功 —— 否则用户以为搜索范围退回去了。
    ///
    /// 变异：`release` 不看 `selectScopes` 的返回值，红。
    func testReleasingBorrowedSessionReportsWhenRestoreIsRejected() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        _ = try await provider.selectScopes(["/A0002", "/A0123"])
        bridge.selectScopeState = "scopeDenied"

        let note = await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"])

        let message = try XCTUnwrap(note, "核心没确认回滚时必须给出说明")
        XCTAssertTrue(message.contains("重新连接"), "要给用户一个明确的下一步，实际：\(message)")
    }

    // MARK: - ③ 在途的改范围请求必须先收束

    /// 轮询等一个条件成立（闸门的时序在测试里只能这么等）。
    ///
    /// ★ 按**时间**等，不按次数等：固定次数的循环在慢机器上会假红。
    private func waitUntil(_ condition: @MainActor () -> Bool, timeout: TimeInterval = 5) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition(), Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
    }

    /// ★ 点「取消」时改范围的请求**还在飞** —— 必须等它落定，再判断要不要回滚。
    ///
    /// 旧实现在这里看到「`config.scopes` == 已保存值」就立刻 return：
    /// 那时响应还没回来，范围看起来没变过。等它落地，范围变成用户刚勾的那份，
    /// 而回滚已经被跳过 —— 用户点了取消，实际生效的却是新范围。
    ///
    /// 变异：去掉 `release` 里的 `drainScopeMutations()`，本条立刻红
    /// （`config.scopes` 停在 ["/A0002", "/A0123"]）。
    func testCancelWhileScopeChangeInFlightStillRestoresSavedScopes() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        bridge.holdSelectScope = true

        let edit = Task { try await provider.selectScopes(["/A0002", "/A0123"]) }
        await waitUntil { provider.hasScopeMutationInFlight }
        XCTAssertTrue(provider.hasScopeMutationInFlight, "前置：确有在途的改范围请求")
        XCTAssertEqual(provider.config.scopes, ["/A0002"], "前置：响应还没回来，范围仍显示旧值")

        let release = Task { await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"]) }
        // ★ 先证明「取消真的挂上去等了」，再放行请求。
        //
        // 不校验这一步的话，闸门可能在 `release` 还没进 drain 就被放掉 ——
        // 那条用例其实测的是「改完了再取消」（旧缺陷本来就绿的那条路径），
        // 于是它锁不住任何东西。
        await waitUntil { provider.scopeMutationWaiterCount > 0 }
        XCTAssertEqual(provider.scopeMutationWaiterCount, 1,
                       "取消必须真的等在在途请求上，而不是扫一眼就走")
        bridge.holdSelectScope = false
        bridge.releaseGate()
        _ = try await edit.value
        let note = await release.value

        XCTAssertNil(note, "回滚应当成功")
        XCTAssertEqual(provider.config.scopes, ["/A0002"],
                       "取消编辑后，活会话必须回到已保存的范围（在途请求也要算进去）")
        XCTAssertEqual(bridge.selectScopeCalls.last?["scopes"] as? [String], ["/A0002"],
                       "回滚必须真的发到核心")
        XCTAssertEqual(bridge.disconnectCount, 0, "回滚仍然不等于断开")
    }

    /// ★ 迟到的回滚不许盖掉**之后**发起的那次保存。
    ///
    /// 顺序反过来的后果是：用户取消编辑后又保存了一份新范围，
    /// 而旧回滚的应答晚到一步 —— 配置停在已保存的旧值上，界面却显示「已保存」。
    ///
    /// 变异：去掉 `selectScopes` 里的序号核对，本条立刻红
    /// （`config.scopes` 会停在 ["/A0002"]）。
    func testStaleRollbackDoesNotOverrideLaterSave() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        _ = try await provider.selectScopes(["/A0002", "/A0123"])

        bridge.holdSelectScope = true
        let rollback = Task { await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"]) }
        // 等回滚真的发到核心（此刻它被闸门卡着，还没落地）。
        await waitUntil { (bridge.selectScopeCalls.last?["scopes"] as? [String]) == ["/A0002"] }

        // 用户在回滚还在飞的时候保存了一份新范围 —— 后发起的才算数。
        bridge.holdSelectScope = false
        _ = try await provider.selectScopes(["/B0007"])
        bridge.releaseGate()
        let note = await rollback.value

        XCTAssertNil(note)
        XCTAssertEqual(provider.config.scopes, ["/B0007"],
                       "迟到的回滚不许覆盖之后发起的那次保存")
    }

    /// ★ 旧收尾**还在等**的时候，下一轮编辑已经保存了新范围 —— 归属归新的那次。
    ///
    /// 与上面那条的区别：上一条是「回滚已发出、新保存后到」，靠应答序号就够；
    /// 这一条是「旧取消还挂着，新保存先完成，旧请求随后才落地」。
    /// 此时旧收尾醒来看到的范围是 `/B0007`（新保存的那份），
    /// 它若照「当前 != 已保存值就回滚」办事，就会**在更晚的时刻新发一次回滚**，
    /// 把刚才那次保存整个盖掉 —— 序号核对管不到这种「新发的旧结论」。
    ///
    /// 变异：去掉 `release` 里的 `beginScopeTeardown/hasScopeMutationNewer` 归属判断，
    /// 本条立刻红（`config.scopes` 会被拽回 ["/A0002"]，核心最后收到的也是它）。
    func testTeardownGivesUpWhenANewerSaveLandsWhileItIsWaiting() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        bridge.holdSelectScope = true
        let edit = Task { try await provider.selectScopes(["/A0123"]) }
        await waitUntil { provider.hasScopeMutationInFlight }
        XCTAssertTrue(provider.hasScopeMutationInFlight, "前置：旧编辑的改范围请求还在飞")

        let cancel = Task { await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"]) }
        await waitUntil { provider.scopeMutationWaiterCount > 0 }
        XCTAssertEqual(provider.scopeMutationWaiterCount, 1, "前置：取消已挂在旧请求上等待")

        // 下一轮编辑不卡闸，直接保存成功 —— 它才是此刻的结论。
        bridge.holdSelectScope = false
        _ = try await provider.selectScopes(["/B0007"])
        bridge.releaseGate()
        _ = try await edit.value
        let note = await cancel.value

        XCTAssertNil(note, "旧收尾让位给新的保存，不该报失败")
        XCTAssertEqual(provider.config.scopes, ["/B0007"],
                       "旧取消不许把范围拽回上一轮的已保存值")
        XCTAssertEqual(bridge.selectScopeCalls.last?["scopes"] as? [String], ["/B0007"],
                       "核心收到的最后一次范围必须是新保存的那份（配置与核心要一致）")
        XCTAssertEqual(bridge.disconnectCount, 0, "借用会话仍然不许被取消编辑断开")
    }

    // MARK: - ④ 收尾边界：取消与「下一草稿」之间必须有先后

    /// ★ 回滚还在飞的时候重新打开同一台来源 —— 不许复制一份即将失效的快照。
    ///
    /// 原缺陷（Codex 第三轮给出）：持久化 `/saved`，旧草稿已把活会话改成 `/draft`；
    /// 取消触发 `rollback(/saved)` 且应答挂着（此刻 `config` 仍是 `/draft`）；
    /// 立刻重新进编辑 ⇒ 把 `/draft` 复制进新草稿；回滚落地后 provider/核心 = `/saved`，
    /// 而新草稿还是 `/draft`；一个都不改直接保存 ⇒ 配置 `/draft`、实际 `/saved`。
    ///
    /// 这条用**真实的 `DraftSession.release` + 真实的 provider**，只把「下一草稿
    /// 借这台会话」这一步按 `editSource` 的真实顺序（先 `drainTeardown()` 再复制）走。
    ///
    /// 变异：`editSource` 不等 `drainTeardown()` 就复制（或 `drainTeardown` 直接 return），
    /// 本条立刻红（adopted 会变成 ["/A0002", "/A0123"]）。
    func testNextDraftAdoptsScopesOnlyAfterPendingTeardownSettles() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        // 编辑期间勾了一个新位置：活会话当场变成 /draft。
        _ = try await provider.selectScopes(["/A0002", "/A0123"])
        XCTAssertEqual(provider.config.scopes, ["/A0002", "/A0123"], "前置：旧草稿已改范围")

        // 取消：同步认领归属，收尾 Task 随后才跑（与 controller 的真实顺序一致）。
        let ticket = provider.beginTeardown()
        XCTAssertTrue(provider.hasPendingTeardown, "同步认领后这台来源上必须看得见未落定的收尾")
        bridge.holdSelectScope = true
        let cancel = Task {
            defer { provider.endTeardown() }
            return await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"], ticket: ticket)
        }
        // 等回滚真的发到核心（此刻被闸门卡着，还没落地）。
        await waitUntil { (bridge.selectScopeCalls.last?["scopes"] as? [String]) == ["/A0002"] }
        XCTAssertTrue(provider.hasPendingTeardown, "收尾还没落定，下一草稿不许看成可用")
        // 反证：此刻若照旧直接复制，拿到的正是那份马上失效的快照。
        XCTAssertEqual(provider.config.scopes, ["/A0002", "/A0123"],
                       "（反证）不等收尾就复制 = 复制一份即将被回滚掉的范围")

        // 下一草稿借这台会话：与 `editSource` 同一套原语、同一个顺序
        //（先 `drainTeardown()` 再复制）。放行闸门放在**外面**，
        // 这样「到底等没等」才有区别——自己先放行再等，等于什么都没测。
        let opener = Task { @MainActor in
            await provider.drainTeardown()
            return provider.config.scopes
        }
        await waitUntil { provider.hasTeardownWaiters }
        XCTAssertTrue(provider.hasTeardownWaiters,
                      "下一草稿必须真的挂在收尾上等它落定，而不是扫一眼就走")
        bridge.holdSelectScope = false
        bridge.releaseGate()
        let adopted = await opener.value
        let note = await cancel.value

        XCTAssertNil(note, "回滚应当成功")
        XCTAssertEqual(adopted, ["/A0002"],
                       "新草稿复制进来的必须是回滚**之后**的范围，不是即将失效的那份")
        XCTAssertEqual(provider.config.scopes, ["/A0002"], "配置与活会话要一致")
        XCTAssertEqual(bridge.selectScopeCalls.last?["scopes"] as? [String], ["/A0002"],
                       "核心最后收到的范围也要一致")
        XCTAssertEqual(bridge.disconnectCount, 0, "借用会话仍然不许被断开")
        XCTAssertFalse(provider.hasPendingTeardown, "收尾落定后必须摘掉这面旗")
    }

    /// ★ 「取消」是同步的，收尾 Task 可能还没开始 —— 票号不能等到那时才取。
    ///
    /// 原实现在 `release` 内部才取票号：用户取消后立刻勾一个新位置（序号被推过去），
    /// 晚出发的旧收尾取到的是**最新**序号 ⇒ 它反而成了归属者，
    /// 于是拿上一轮的已保存值盖掉用户刚勾的位置。
    ///
    /// 变异：`release` 忽略传入的 ticket、改在内部现取，本条立刻红
    /// （`config.scopes` 会被拽回 ["/A0002"]）。
    func testTeardownClaimedBeforeItsTaskStartsIsNotOverriddenByLaterEdit() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        _ = try await provider.selectScopes(["/A0002", "/A0123"])

        // 同步认领（此刻收尾 Task 还没被调度）。
        let ticket = provider.beginTeardown()
        // 用户取消后立刻重新编辑并保存了一份新范围。
        _ = try await provider.selectScopes(["/B0007"])
        // 收尾 Task 这时候才跑起来。
        let note = await DraftSession.borrowed(provider).release(persistedScopes: ["/A0002"], ticket: ticket)
        provider.endTeardown()

        XCTAssertNil(note, "归属已经转移，旧收尾让位，不该报失败")
        XCTAssertEqual(provider.config.scopes, ["/B0007"],
                       "晚出发的旧收尾不许拿上一轮的已保存值盖掉新的编辑")
        XCTAssertEqual(bridge.selectScopeCalls.last?["scopes"] as? [String], ["/B0007"],
                       "核心最后收到的必须是新的那一份")
    }

    /// ★ 收尾不许再自造一条比核心命令更短的时限去「盲目放行」。
    ///
    /// 有过一个 5 秒兜底：到点直接 resume 等待者，既不使在途请求失效、
    /// 也不保证核心回滚 ⇒ 响应第 6 秒回来时，取消照样失效，而界面报成功。
    /// 那是把同一个缺陷往后挪，不是收尾。这里锁死「不许再长回来」。
    ///
    /// 变异：给 `drainScopeMutations` 加回 timeout + `Task.sleep` 兜底，本条立刻红。
    func testDrainHasNoBlindTimeoutEscapeHatch() throws {
        let path = String(describing: #filePath)
            .replacingOccurrences(of: "Tests/FlashFindCoreTests/DraftSessionTests.swift",
                                  with: "Sources/FlashFindCore/NASSearchProvider.swift")
        let source = try String(contentsOfFile: path, encoding: .utf8)
        let body = try XCTUnwrap(
            braceBlock(after: "public func drainScopeMutations", in: source),
            "找不到 drainScopeMutations 的实现")
        XCTAssertFalse(body.contains("Task.sleep"),
                       "收尾不许自造定时放行：那只是把「慢响应」这条真实路径继续当缺陷留着")
        XCTAssertFalse(body.contains("timeout"),
                       "收尾不许带自己的时限，只能等核心命令真正落定")
        XCTAssertTrue(body.contains("withCheckedContinuation"),
                      "必须挂在在途请求上等它真正落定")
    }

    // MARK: - ④ 提交：绑定必须有结果，才轮到落盘

    /// ★ 核心确认之后才允许落盘。
    func testBindForCommitConfirmsScopesBeforeSave() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        let session = DraftSession.borrowed(provider)

        let note = await session.bindScopesForCommit(["/A0002", "/B0007"])

        XCTAssertNil(note, "核心确认之后才允许落盘")
        XCTAssertEqual(Set(provider.config.scopes), ["/A0002", "/B0007"],
                       "绑定成功必须真的生效——否则「已保存」又是空的")
    }

    /// ★ 绑定被核心拒绝时**必须**有话说，不许吞掉。
    ///
    /// 吞掉的后果就是 Codex 实测的那份证据：persisted=/new、live=/old、
    /// 状态栏一句提示都没有，用户以为保存成功了。
    func testBindForCommitRejectionIsReportedNotSwallowed() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        bridge.selectScopeState = "scopeDenied"
        let session = DraftSession.borrowed(provider)

        let message = await session.bindScopesForCommit(["/A0002", "/B0007"])

        let note = try XCTUnwrap(message, "绑定被拒必须给出说明：吞掉就是「已保存但搜不到」")
        XCTAssertTrue(note.contains("没有保存"),
                      "要明确告诉用户这份配置**没有**存下去，实际：\(note)")
        XCTAssertEqual(provider.config.scopes, ["/A0002"],
                       "被拒时核心仍是旧范围 —— 调用方据此不落盘")
    }

    /// 范围本来就一致时不打扰核心（避免提交时多发一次无意义的往返）。
    func testBindForCommitSkipsWhenAlreadyAligned() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        let before = bridge.selectScopeCalls.count
        let session = DraftSession.borrowed(provider)

        let note = await session.bindScopesForCommit(["/A0002"])

        XCTAssertNil(note)
        XCTAssertEqual(bridge.selectScopeCalls.count, before, "一致时不必再发一次绑定")
    }

    /// ★ 上一轮「取消」的收尾还没落定时，提交必须排在它后面。
    ///
    /// 反过来等的话，本轮刚发下去的绑定会被上一轮那次回滚盖掉：
    /// 界面显示保存成功，核心却停在旧范围。
    func testBindForCommitWaitsForPendingTeardown() async throws {
        let bridge = RecordingBridge()
        let provider = try await connectedProvider(bridge, scopes: ["/A0002"])
        _ = provider.beginTeardown()
        let session = DraftSession.borrowed(provider)

        let bind = Task { await session.bindScopesForCommit(["/B0007"]) }
        await waitUntil { provider.hasTeardownWaiters }
        XCTAssertTrue(provider.hasTeardownWaiters,
                      "上一轮收尾没落定之前，提交不许抢先发绑定")
        provider.endTeardown()

        let result = await bind.value
        XCTAssertNil(result, "收尾落定之后绑定应当成功")
        XCTAssertEqual(provider.config.scopes, ["/B0007"],
                       "收尾落定之后，这一轮提交的范围才是最终值")
    }

    /// 小工具：切出一段源码的花括号块（**必须括号配平**）。
    ///
    /// 只取第一个 `}` 是不够的：实现里 `guard ... else { return }` 自带一对，
    /// 那样切出来的块会以 `return` 结尾，断言就变成恒真/恒假的假证据。
    private func braceBlock(after marker: String, in text: String) -> String? {
        guard let range = text.range(of: marker),
              let start = text[range.upperBound...].firstIndex(of: "{") else { return nil }
        var depth = 0
        var index = start
        while index < text.endIndex {
            if text[index] == "{" { depth += 1 }
            else if text[index] == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }
}
