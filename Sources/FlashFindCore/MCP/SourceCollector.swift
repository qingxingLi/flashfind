import Foundation

/// 收集单来源事件；用锁保证终态与超时只有一个结果生效。
final class SourceCollector: @unchecked Sendable {

    struct Snapshot: Sendable {
        let rows: [SearchResult]
        let state: ProviderSearchState
        let resultsIncomplete: Bool
        /// 预算到期，provider 还没给终态。
        let timedOut: Bool
    }

    private let lock = NSLock()
    private var rows: [SearchResult] = []
    private var resultsIncomplete = false
    private var outcome: Snapshot?
    private var waiter: CheckedContinuation<Snapshot, Never>?
    private var timer: Task<Void, Never>?

    /// 收到一条事件。终态第一条生效，之后的全部忽略（provider 违约多发也不会双计）。
    func record(_ event: ProviderEvent) {
        var resume: CheckedContinuation<Snapshot, Never>?
        var finished: Snapshot?
        lock.lock()
        if outcome == nil {
            rows.append(contentsOf: event.results)
            resultsIncomplete = resultsIncomplete || event.resultsIncomplete
            if event.isTerminal {
                let snapshot = Snapshot(rows: rows,
                                        state: event.state,
                                        resultsIncomplete: resultsIncomplete,
                                        timedOut: false)
                outcome = snapshot
                finished = snapshot
                resume = waiter
                waiter = nil
                timer?.cancel()
                timer = nil
            }
        }
        lock.unlock()

        guard let finished else { return }
        resume?.resume(returning: finished)
    }

    /// 等到终态，或预算到期。
    func wait(budget: TimeInterval) async -> Snapshot {
        await withCheckedContinuation { continuation in
            lock.lock()
            if let outcome {
                lock.unlock()
                continuation.resume(returning: outcome)
                return
            }
            waiter = continuation
            lock.unlock()

            let task = Task { [weak self] in
                try? await Task.sleep(for: .seconds(budget))
                guard !Task.isCancelled else { return }
                self?.expire()
            }

            lock.lock()
            if outcome == nil { timer = task } else { task.cancel() }
            lock.unlock()
        }
    }

    private func expire() {
        var resume: CheckedContinuation<Snapshot, Never>?
        var finished: Snapshot?
        lock.lock()
        if outcome == nil {
            let snapshot = Snapshot(rows: rows,
                                    state: .searching,
                                    resultsIncomplete: true,
                                    timedOut: true)
            outcome = snapshot
            finished = snapshot
            resume = waiter
            waiter = nil
        }
        lock.unlock()
        guard let finished else { return }
        resume?.resume(returning: finished)
    }
}
