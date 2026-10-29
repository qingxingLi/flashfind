import Foundation

/// 搜索浮窗仅在时间窗内恢复仍然有效的查询和结果。
public enum SearchSessionMemory {
    /// 保留时长 30 秒。够覆盖一次「关掉—复制—回来」，又不至于跨天还挂着旧结果。
    public static let windowSeconds: TimeInterval = 30

    /// 距离隐藏是否仍在保留期内。
    public static func isWithinMemoryWindow(hiddenAt: Date?, now: Date = Date()) -> Bool {
        guard let hiddenAt else { return false }
        let elapsed = now.timeIntervalSince(hiddenAt)
        // 负数表示系统时间被回拨（少见但可能发生），一律当作仍在窗口内，
        // 免得用户莫名其妙丢掉正在看的结果。
        return elapsed <= windowSeconds
    }

    /// 来源、搜索范围等设置变更后不能恢复旧结果。
    public static func shouldRestore(hiddenAt: Date?, hasQuery: Bool, resultsAreValid: Bool,
                                     now: Date = Date()) -> Bool {
        guard isWithinMemoryWindow(hiddenAt: hiddenAt, now: now) else { return false }
        guard hasQuery else { return false }
        // 结果已过期时不能恢复：宁可让用户重搜一次，也不能显示不对应的结果。
        return resultsAreValid
    }
}
