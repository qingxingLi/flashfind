import Foundation

/// 「选择搜索位置」列表上那两个批量入口（全选 / 取消全选）的判定。
///
/// 为什么放在 Core：这类「什么算已经全选」「按钮该不该可点」的判断，
/// 写在 App 层就等于没测（`FlashFind2App` 是 executableTarget，测试依赖不上）。
/// 界面的职责只剩把结果画出来 —— **不许自己再算一遍集合**。
///
/// 三个概念的边界在这里划死：
/// - 「可用位置」= 这台机器此刻看得到的共享目录（`draftAvailableShares`）；
/// - 「已选」= 草稿里准备提交的那份集合（`draftSource.scopes`），**可能含有界面
///   上已经看不到的旧位置**（共享被删、账号权限变了）——所以两者不能互相代替；
/// - 「全选」= 可用位置全部在已选里，**空集不算全选**（一个位置都没有时那两颗按钮
///   本来也不显示）。
public enum ScopeBulkSelection {

    /// 去重 + 排序。所有要交给底层的集合都先过这一道：
    /// 底层按顺序比较，重复项会让「已选 N 个」数错。
    public static func normalized(_ shares: [String]) -> [String] {
        var seen = Set<String>()
        return shares.filter { seen.insert($0).inserted }.sorted()
    }

    /// 值不值得提供「全选 / 取消全选」：只有一个位置时这两下没有意义。
    public static func isOffered(available: [String]) -> Bool {
        normalized(available).count > 1
    }

    /// 可用位置是不是已经全在已选里（空集不算）。
    public static func isAllSelected(available: [String], selected: [String]) -> Bool {
        let all = normalized(available)
        guard !all.isEmpty else { return false }
        let chosen = Set(selected)
        return all.allSatisfy { chosen.contains($0) }
    }

    /// 「全选」此刻能不能点：已经全选完就没得选。
    public static func canSelectAll(available: [String], selected: [String]) -> Bool {
        isOffered(available: available) && !isAllSelected(available: available, selected: selected)
    }

    /// 「取消全选」此刻能不能点：一个可用位置都没勾时没得取消。
    ///
    /// 只看「可用位置里有没有被勾的」——草稿里残留的旧位置（界面上看不见）
    /// 不该让这颗按钮亮起来，用户按了会发现「本来就没勾啊」。
    public static func canClearAll(available: [String], selected: [String]) -> Bool {
        let chosen = Set(selected)
        return normalized(available).contains { chosen.contains($0) }
    }

    /// 全选之后的集合。
    public static func selectAll(available: [String]) -> [String] {
        normalized(available)
    }

    /// 取消全选之后的集合：一个都不勾。
    ///
    /// 刻意返回空集而不是「只摘掉可用位置」：草稿里可能残留界面看不见的旧位置，
    /// 留着它们会让「已选 N 个目录」和界面上零个勾对不上 —— 那正是这类面板
    /// 最容易变成「勾了也不生效」的地方。
    public static func clearAll() -> [String] { [] }
}
