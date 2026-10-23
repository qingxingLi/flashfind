import Foundation

/// History 的写入端：**唯一的降级点**（方案 §6.6）。
///
/// ## ★ 为什么是它来吞错误
///
/// ```text
/// FileReferenceStore 写失败 → Tool Call 必须失败
/// HistoryStore       写失败 → Tool Call 照常成功，只丢一条事件
/// ```
///
/// 两条相反的规则若散落在调用点，迟早有人写成同一副样子。所以降级只写在这一处：
/// 调用方**拿不到** `throws`，也就没法把历史故障传回给 Agent。
///
/// ## ★ 它只写「真正交出去的那些」
///
/// 是否记 `located` 由**调用方**决定（只有进窗口的才算），本类型不做判断；
/// 这里只保证：写了就写，写失败就记一条诊断然后继续。
///
/// ## ★ 它不碰 SQLite
///
/// 它把 `AccessEvent` 交给 `HistoryStore`，自己不做任何 `sqlite3_*` 调用。
/// 这不只是洁癖：结构测试断言「`HistoryStore.swift` 是唯一接触 SQLite 的文件
/// 且无需额外加锁」，本类跟 store 放在同一个文件里时，那条断言会被这里的
/// `NSLock` 误伤。分开两个文件后，「谁碰数据库」就成了可机器检查的事实。
public final class HistorySink: @unchecked Sendable {

    /// 这次调用来自哪个会话（不可信标签）。
    public let context: HistoryContext

    /// 最近一次写入失败的描述。**只是诊断**，不影响任何对外结果。
    ///
    /// ★ 只留最后一条：历史写入失败可以是高频的（磁盘满），攒一堆描述
    ///   会把真正的故障日志淹掉。
    public private(set) var lastFailure: String?

    private let lock = NSLock()
    private let store: HistoryStore?

    public init(store: HistoryStore?, context: HistoryContext) {
        self.store = store
        self.context = context
    }

    /// 记一批 `located`。**永不抛**。
    ///
    /// ★ 一个事务：一批要么都进、要么都不进。批内部分成功会让 `recent`
    ///   的先后顺序依赖「那次写盘恰好走到哪一行」。
    public func located(_ events: [AccessEvent]) {
        guard let store, !events.isEmpty else { return }
        do {
            try store.recordLocatedAll(events)
        } catch {
            note(error)
        }
    }

    /// 记一条 `metadata`。**永不抛**。
    ///
    /// ★ 不去重：Phase 8 的 `metadata-access` 要用**次数**算 `1-exp(-n/5)`，
    ///   这里去重会让信号永远停在 n=1。
    public func metadata(_ event: AccessEvent) {
        guard let store else { return }
        do {
            try store.recordMetadata(event)
        } catch {
            note(error)
        }
    }

    private func note(_ error: Error) {
        let text = String(describing: error)
        lock.withLock { lastFailure = text }
    }
}

/// 每日修剪的闸门（方案 §6.5）。
///
/// ```text
/// 启动时   → 跑一次
/// 每日一次 → 跑一次
/// 请求路径 → 绝不跑
/// ```
///
/// ★ 为什么不能放进请求路径：一次 `locate` 要的是秒级返回，而修剪可能扫
///   一张 20 000 行的表。把维护塞进热路径，会让「历史越久、搜索越慢」，
///   而且慢的方式是**每台机器都不一样**，很难查。
///
/// ★ 它自己不扫表，只决定「该不该跑」；真正删行的是 `HistoryStore.prune`。
public final class HistoryMaintenance: @unchecked Sendable {

    /// 一天的长度（秒）。
    public static let dayLength: TimeInterval = 86_400

    private let lock = NSLock()
    private var lastRun: TimeInterval?
    private let store: HistoryStore?

    public init(store: HistoryStore?) {
        self.store = store
    }

    /// 到新的一天就修剪一次；**同一天重复调用是空操作**。
    ///
    /// ★ 返回值只说明「这次有没有真的跑」，**不**说明跑得成不成功——
    ///   修剪失败不冒泡，与 §6.6 是同一条纪律：历史故障不许影响搜索。
    @discardableResult
    public func runIfNeeded(now: Date = Date()) -> Bool {
        let stamp = now.timeIntervalSince1970

        lock.lock()
        if let previous = lastRun, stamp - previous < Self.dayLength {
            lock.unlock()
            return false
        }
        lastRun = stamp
        lock.unlock()

        // ★ 锁外执行：修剪可能扫 20 000 行，不该占着这把锁。
        _ = try? store?.prune(now: now)
        return true
    }
}
