import Combine
import FlashFindCore

/// 「允许 AI 使用闪寻」的设置页状态（方案 §5.1，Phase 4 骨架）。
///
/// 与 `AppearanceController` 同一套做法：判定与规则都在 Core（`AIAccessSettings` /
/// `PermissionPolicy`，可测），这里只负责三件事——草稿、落盘、给界面一个可以绑定的对象。
///
/// ## 为什么有「草稿」与「已保存」两份
///
/// 规则是「开启后至少选一个来源才能保存」。既然有「不能保存」的状态，就必须允许
/// 用户改到一半退出来；只有一份状态的话，「拨开开关但还没选来源」会立刻变成
/// 已生效的设置，而生效后的表现是 `mcp_disabled`——用户会以为功能坏了。
///
/// ★ **权限判定读的是 `saved`，不是 `draft`。** 草稿是界面上的临时态，
/// 让草稿参与判定等于「改了一半还没点保存，AI 的权限就已经变了」。
@MainActor
final class AIAccessController: ObservableObject {

    /// 已保存（也就是对 AI 生效）的设置。
    @Published private(set) var saved: AIAccessSettings = .initial
    /// 界面正在编辑的草稿。
    @Published private(set) var draft: AIAccessSettings = .initial
    /// 最近一次操作的结果（保存失败、预览态拒绝修改等）。成功时清空。
    @Published private(set) var message: String?

    private let preferences: any ClientPreferences
    private let isPreview: Bool
    private let fixtureMode: Bool

    init(preferences: any ClientPreferences, isPreview: Bool, fixtureMode: Bool) {
        self.preferences = preferences
        self.isPreview = isPreview
        self.fixtureMode = fixtureMode
    }

    /// 有未保存的改动。
    var isDirty: Bool { draft != saved }

    /// 「保存」是否可以点。两个条件缺一不可：
    /// 规则允许（开着时至少一个来源），并且确实改了东西。
    var canSave: Bool { draft.canSave && isDirty }

    // MARK: - 装配

    func load() {
        saved = AIAccessStore.load(from: preferences)
        draft = saved
        message = nil
    }

    // MARK: - 编辑

    func setEnabled(_ value: Bool) {
        draft = draft.settingEnabled(value)
        message = nil
    }

    func setSource(_ id: String, allowed: Bool) {
        draft = draft.settingSource(id, allowed: allowed)
        message = nil
    }

    func discard() {
        draft = saved
        message = nil
    }

    // MARK: - 落盘

    /// 保存草稿。
    ///
    /// - Parameter existing: **现在还存在**的来源 id。落盘前先剔掉已被删除的来源，
    ///   否则授权里会留下搜不到的 id，`list_sources` 会把它报给 Agent。
    func save(existing: Set<String>) {
        guard !isPreview || fixtureMode else {
            message = "UI 预览不修改真实设置"
            return
        }
        let pruned = draft.pruned(against: existing)
        guard pruned.canSave else {
            // 交给 Core 拒绝，而不是在这里重写一遍规则：规则只有一份。
            message = "开启 AI 访问时至少要选择一个来源"
            return
        }
        guard AIAccessStore.save(pruned, to: preferences) else {
            message = "设置没有保存成功"
            return
        }
        saved = pruned
        draft = pruned
        message = nil
    }

    /// 删掉一台 NAS 之后调用：同步清掉已保存授权里残留的 id。
    ///
    /// 不需要用户再去点一次保存——来源已经不在了，留着那条授权只会让
    /// `list_sources` 报一个永远搜不到的来源。
    ///
    /// ★ **删掉最后一个已授权来源时开关自动关闭**（`AIAccessSettings.pruned` 守的
    /// 不变量），并且 `enabled` 与 `sources` 在**同一次** `save` 里落盘。
    /// 分两次写会出现中间态：先写 `enabled=false` 再写 `sources=[]`，中间那一瞬
    /// 磁盘上是「关着但还勾着已删来源」——不致命，但没有理由留下它。
    func forgetSources(notExisting existing: Set<String>) {
        let prunedSaved = saved.pruned(against: existing)
        guard prunedSaved != saved else { return }
        AIAccessStore.save(prunedSaved, to: preferences)
        saved = prunedSaved
        draft = draft.pruned(against: existing)
    }

    // MARK: - 判定

    /// 用**已保存**的设置判定一次请求。留给后面的 AuthorityLink 调用。
    func decision(requested: [String]?, existing: Set<String>) -> PermissionDecision {
        saved.decision(requested: requested, existing: existing)
    }
}
