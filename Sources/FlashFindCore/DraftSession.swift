import Foundation

/// 向导草稿里那个「可以改搜索位置、可以提交」的登录会话，以及**它归谁所有**。
///
/// ## 为什么这是个类型，而不是一个 `NASSearchProvider?` 加一个 `Bool`
///
/// 所有权只有一个后果，但那个后果很重：**离开草稿时要不要断开它**。
/// 之前这件事没有名字：`pendingProvider` 只是一个可选引用，五条离开路径
/// （取消 / 返回 / 切换来源 / 断开 / 提交）都按「它是我建的」来处理，
/// 于是编辑一个**已经连上**的来源时，手里拿到的其实是连接管理器持有的活会话——
/// 无条件断开，等于用户点一下「取消」就把正在用的来源注销掉。
///
/// 把它写成带 case 的值，好处是「谁建的」与「怎么收」在同一个地方定义，
/// 调用方没法只挑一半（只赋值不断言所有权）。
public enum DraftSession {
    /// 草稿里没有可操作的会话：还没连上，或者已经提交/释放。
    case none
    /// 本次向导新建的登录会话（`connectDraft` 走完 discover → login → selectScopes）。
    /// 离开草稿时必须由向导断开，否则核心里会留着一份没人认领的会话。
    case wizard(NASSearchProvider)
    /// 借用连接管理器里**已经在运行**的会话（编辑一个已连接的来源）。
    /// 离开草稿时只放引用，**不许断开**——那是用户正在使用的连接。
    case borrowed(NASSearchProvider)

    /// 会话实例（`none` 时为 nil）。
    public var provider: NASSearchProvider? {
        switch self {
        case .none: return nil
        case .wizard(let provider), .borrowed(let provider): return provider
        }
    }

    /// 能不能改搜索位置。
    ///
    /// `borrowed` 必须为 true —— 这正是用户报的那个 bug：编辑已连接的来源时，
    /// 会话在跑、界面显示「已连接，可以搜索了」，勾选却因为「没有 pending provider」
    /// 被一句「请先完成连接」挡回去。会话存在就是存在，不因为它是借来的而消失。
    public var canEditScopes: Bool {
        switch self {
        case .none: return false
        case .wizard, .borrowed: return true
        }
    }

    /// 离开草稿时，是否**由向导**断开这个会话。
    ///
    /// 只有自己建的那个才归自己收；借来的不收，也不许顺手收。
    public var disconnectsOnTeardown: Bool {
        if case .wizard = self { return true }
        return false
    }

    /// 是否是借来的活会话（提交时不必再 install，它已经在管理器里了）。
    public var isBorrowed: Bool {
        if case .borrowed = self { return true }
        return false
    }

    /// 提交前的「落定 + 绑定」：等上一轮收尾与本轮勾选都有结果，再确认范围一致。
    ///
    /// ★ 为什么必须有这一步（Codex 实测的缺陷现场）：
    ///   之前 `commitDraft` 是**先落盘**、`setSourceStatus` 显示旧范围、
    ///   `changedQuery` 按旧范围发起搜索，最后才 `Task { _ = try? await
    ///   provider.selectScopes(target) }`。那个 Task 在结论已经既定之后才跑，
    ///   且 `false` 与 `throw` 全被丢掉 ⇒ 绑定失败时 persisted 是新范围、
    ///   核心仍是旧范围、状态栏一句提示都没有。
    ///   **新增一个 fallback 并没有关掉「配置与实际不一致」，只是把它推迟到
    ///   网络往返之后，并在失败时变成静默不一致。**
    ///
    /// 所以这里把顺序倒过来：**先拿到绑定的结果，再由调用方决定要不要保存。**
    ///
    /// - Parameter scopes: 草稿里用户选的位置。
    /// - Returns: 需要给用户看的失败说明（且**必须**导致不保存）；`nil` 表示
    ///   「无需绑定」或「核心已确认绑定」，调用方可以继续落盘。
    @MainActor
    public func bindScopesForCommit(_ scopes: [String]) async -> String? {
        guard let provider else { return nil }
        // ★ 顺序是「先等上一轮的收尾，再收本轮的勾选」。
        //   反过来等的话，本轮刚发下去的绑定会被上一轮那次回滚盖掉。
        await provider.drainTeardown()
        await provider.drainScopeMutations()
        // 没选位置不是这里的事：那是保存前的校验（`commitDraft` 会挡）。
        guard !scopes.isEmpty else { return nil }
        guard Set(scopes) != Set(provider.config.scopes) else { return nil }
        do {
            guard try await provider.selectScopes(scopes) else {
                return "所选位置没有通过共享准入校验，配置没有保存。请重新勾选搜索位置后再保存。"
            }
            return nil
        } catch {
            return "所选位置没能生效，配置没有保存：" + OpenFailureText.describe(error)
        }
    }

    /// 交还会话：该断开的断开，借来的只放引用，并**把范围回滚到已保存的配置**。
    ///
    /// 回滚这一步不能省。编辑期间每点一下勾选，都是直接对活会话调用
    /// `selectScopes` —— 范围当场就变了。用户点「取消」若只放引用不还范围，
    /// 结果就是「界面退回去了，搜索还在用新范围」：配置说一套、实际跑另一套。
    ///
    /// - Parameter persistedScopes: 已保存配置里的范围（`nasSources` 里那份）。
    /// - Parameter ticket: 调用方**同步**认领的归属票号（`beginTeardown()` 的返回值）。
    ///   不传则由这里现取——那只在「取消与收尾之间没有别的编辑插进来」时成立；
    ///   真实调用链（按钮同步返回、收尾 Task 稍后才跑）必须传。
    /// - Note: 必须 `@MainActor`：`NASSearchProvider` 是主 actor 隔离的，
    ///   读它的 `config`（判断范围有没有被改过）不能从别的 actor 直接摸。
    @MainActor
    public func release(persistedScopes: [String], ticket: Int? = nil) async -> String? {
        switch self {
        case .none:
            return nil
        case .wizard(let provider):
            // ★ 先等本轮在途的改范围请求落定再断开：那条应答回来时会
            //   解 `sessionClosed` 闸门并抬 `ready` —— 断开之后才回来的话，
            //   等于把刚断开的来源又复活成「已连接」。
            await provider.drainScopeMutations()
            await provider.disconnect()
            return nil
        case .borrowed(let provider):
            // ★ 顺序是「先收束在途请求，再判断要不要回滚」，并且**先认领归属**。
            //
            // `config.scopes` 要等核心应答回来才变；请求还在飞的时候它**仍然
            // 等于已保存值**，此刻判断「没改过」就立刻 return —— 等应答落地，
            // 范围变成用户刚勾的那份，而回滚已经跳过了：
            // 界面退回去了，搜索却还在用新范围（用户点的「取消」等于没生效）。
            let owned = ticket ?? provider.beginScopeTeardown()
            await provider.drainScopeMutations()
            // ★ 等待期间若有人发起了**新的**改范围请求（用户取消了这一轮、
            //   又开了下一轮并保存），范围已经不属于这次收尾了：
            //   再按上一轮的已保存值回滚，就是拿旧草稿的结论盖掉刚才那次保存。
            //   序号核对管不到这条 —— 旧收尾是在更晚的时刻**新发**一次回滚，
            //   不是一条旧应答迟到。
            guard !provider.hasScopeMutationNewer(than: owned) else { return nil }
            let current = Set(provider.config.scopes)
            guard current != Set(persistedScopes) else { return nil }
            do {
                guard try await provider.selectScopes(persistedScopes) else {
                    return "编辑已取消，但搜索位置没能恢复（核心没有确认），请对这台来源重新连接一次。"
                }
                return nil
            } catch {
                return "编辑已取消，但搜索位置没能恢复，请对这台来源重新连接一次。"
            }
        }
    }
}
