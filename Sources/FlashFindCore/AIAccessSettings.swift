import Foundation

/// AI 访问设置（设置页骨架的可测部分）：总开关 + 来源白名单。
///
/// 判定本身在 `PermissionPolicy`（纯函数）；这里只管「设置页上那几件事」：
/// 默认值、开关与勾选的联动、什么时候允许保存、删掉的来源怎么清理。
///
/// ## 三条固定规则（方案 §5.1）
///
/// 1. **默认 OFF，且不预勾任何来源。** 「我的 Mac」的授权范围比任何单台 NAS 都大
///    （整盘、含个人文件），把它设成默认等于替用户做了最大范围的授权。
/// 2. **打开总开关不自动勾选任何东西。** 首次开启必须由用户自己选。
/// 3. **开着的时候至少要有一个来源才能保存。** 关掉不需要选——否则用户会卡在
///    「开着且不能保存」，连关都关不掉。
///
/// ## 为什么整块是值类型
///
/// 设置页的编辑是「改一改、可能取消」的过程。用值类型表达，草稿与已保存状态天然
/// 是两份，不需要额外写一份「还原」逻辑；顺带整块可比较，UI 才好判断有没有未保存的改动。
public struct AIAccessSettings: Equatable, Sendable {

    public let isEnabled: Bool
    public let allowedSources: Set<String>

    /// 全新安装的取值：关着，什么都不勾。
    public static let initial = AIAccessSettings(isEnabled: false, allowedSources: [])

    public init(isEnabled: Bool = false, allowedSources: Set<String> = []) {
        self.isEnabled = isEnabled
        self.allowedSources = allowedSources
    }

    /// 「保存」按钮是否可以点。
    ///
    /// ★ 这是**界面提示**，不是约束本身。真正的约束在 `AIAccessStore.save`
    /// （拒绝落盘）与 `PermissionPolicy`（开着但没授权时一律 `mcp_disabled`）。
    /// 只靠置灰按钮是不行的：按钮状态是一个可以被改坏、也可以被绕过的 UI 事实。
    public var canSave: Bool { !isEnabled || !allowedSources.isEmpty }

    // MARK: - 编辑

    /// 拨动总开关。**不清空已勾选、也不预勾任何来源**——
    /// 用户关掉再打开，之前选过的还在，这是可预期的。
    public func settingEnabled(_ value: Bool) -> AIAccessSettings {
        AIAccessSettings(isEnabled: value, allowedSources: allowedSources)
    }

    public func settingSource(_ id: String, allowed: Bool) -> AIAccessSettings {
        var next = allowedSources
        if allowed { next.insert(id) } else { next.remove(id) }
        return AIAccessSettings(isEnabled: isEnabled, allowedSources: next)
    }

    /// 剔除已经不存在的来源（用户删了一台 NAS，授权里还留着它的 id）。
    ///
    /// 不清理的后果不是「多搜一个」，而是 `list_sources` 里出现一个永远搜不到的来源，
    /// 然后 `locate` 每次都对它报 `source_unavailable`。
    ///
    /// ## 剔空即关闭（状态不变量）
    ///
    /// 这个函数同时守住一条不变量：**开着就必须至少有一个还存在的授权来源**。
    /// 原因不是洁癖，而是「开着但零来源」在界面上无法解释——
    ///
    ///     AI 访问：[开]
    ///     允许的来源：（一个都没有）
    ///
    /// 用户看到的是一台开着的开关，MCP 每个请求都得到 `mcp_disabled`。到底是没开、
    /// 还是开坏了？没人说得清。所以删掉最后一个已授权来源时，开关跟着关掉，
    /// 让界面上的开关始终等于实际能力（与 `AIAccessStore.load` 对损坏态的读取修复同一条规则：
    /// 那边是「读出来像坏的」，这里是「别让它坏下去」）。
    ///
    /// ★ 只在**来源消失**时自动关闭。用户在设置页取消勾选最后一个来源不在此列：
    /// 那是编辑中的草稿，`canSave == false` 会挡住保存，由用户自己决定是再选一个还是关开关。
    public func pruned(against existing: Set<String>) -> AIAccessSettings {
        let remaining = allowedSources.intersection(existing)
        return AIAccessSettings(isEnabled: isEnabled && !remaining.isEmpty,
                                allowedSources: remaining)
    }

    // MARK: - 判定

    /// 用当前设置做一次判定。只是把四个入参摆好，判定逻辑仍在 `PermissionPolicy`。
    ///
    /// 留这个入口是为了让调用方**不可能**把参数摆错（尤其 `existing` 与
    /// `allowedSources` 互换——两者都是 `Set<String>`，换错了编译器一声不响）。
    public func decision(requested: [String]?, existing: Set<String>) -> PermissionDecision {
        PermissionPolicy.decision(mcpEnabled: isEnabled,
                                  allowedSources: allowedSources,
                                  requested: requested,
                                  existing: existing)
    }
}

/// `AIAccessSettings` 的存取。
///
/// ★ **不缓存。** `load` 每次都读一遍偏好：撤销授权要「下一次请求就生效」，
/// 任何一层留一份内存副本都会让这句话变成「重启后生效」。
public enum AIAccessStore {

    /// 偏好键。沿用 `ff2.` 前缀。
    public static let enabledKey = "ff2.aiAccess.enabled.v1"
    public static let sourcesKey = "ff2.aiAccess.sources.v1"

    public static func load(from preferences: any ClientPreferences) -> AIAccessSettings {
        let enabled = preferences.object(forKey: enabledKey) as? Bool ?? false
        let sources = Set(preferences.stringArray(forKey: sourcesKey) ?? [])
        let settings = AIAccessSettings(isEnabled: enabled, allowedSources: sources)
        // 存下来的状态自相矛盾（开着却零来源）时按「关」处理：宁可少放行。
        // 这种状态只可能来自手改偏好或旧版本写坏，不能让它变成「开着但搜不到任何东西」。
        return settings.canSave ? settings : .initial
    }

    /// 落盘。返回是否真的写进去了——`canSave == false` 时拒绝，
    /// 避免界面上的临时状态被持久化成「开着但零来源」。
    @discardableResult
    public static func save(_ settings: AIAccessSettings, to preferences: any ClientPreferences) -> Bool {
        guard settings.canSave else { return false }
        preferences.set(settings.isEnabled, forKey: enabledKey)
        preferences.set(settings.allowedSources.sorted(), forKey: sourcesKey)
        return true
    }
}
