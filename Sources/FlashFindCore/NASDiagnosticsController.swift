import Foundation

/// NAS 诊断的落盘（P2-01 拆分出的第一块：完全自包含，不碰任何 UI 状态）。
///
/// 为什么要单独抽出来：诊断写入的规则很容易在「顺手改一改」里被破坏——
/// 比如记下查询词、文件名或凭据，或者把「正常结束」也写进去，
/// 让这份排查时最先看的文件被噪音淹没。收在一个类型里，
/// 规则就只有一处，也才能被测试锁住。
///
/// 记什么、不记什么：
/// - **不记**查询词 / 文件名 / 凭据 / 完整路径。
/// - 记「挂在哪个 API / 方法上」、设备错误码、`cleanupState`——
///   这些是定位的第一把钥匙，且不含内容。
public final class NASDiagnosticsController {
    /// 常驻诊断目录（`nas-search-events.jsonl` 的所在目录）。
    /// 由外部注入：目录取决于连接管理器的状态目录，这里不该自己去找。
    public var stateDirectory: (() -> URL?)?
    /// 验收用的旁录目录。与常驻诊断刻意分开：
    /// 验收产物跟随 app 包，常驻诊断跟随用户数据。
    public var acceptanceDirectory: (() -> URL?)?
    public private(set) var eventSequence = 0
    /// 哪些协议事件值得进常驻诊断。
    ///
    /// **必须保持这个白名单**：核心在连接、登录、选范围时会发一大堆正常事件
    /// （`capabilities` / `authState` / `scopeState` …）。把它们记下来，
    /// 每次启动就往这份文件里塞十几条与故障长得一样的行 —— 而这份文件
    /// 正是排查搜索问题时最先看的东西。
    /// （重构时漏掉过这道闸，实测启动一次多写 5 条噪音。）
    public var acceptedEvents: Set<String> = ["batch", "sourceState", "terminal", "searchReturned", "controlAck"]
    private let sessionID = UUID().uuidString
    private let now: () -> Date
    private let uptime: () -> TimeInterval

    public init(now: @escaping () -> Date = Date.init,
                uptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.now = now
        self.uptime = uptime
    }

    /// 一次搜索事件。只记录状态与计数，不含任何文件内容。
    public func recordProviderEvent(_ event: ProviderEvent) {
        eventSequence += 1
        let row: [String: Any] = ["sequence": eventSequence, "monotonicSeconds": uptime(),
                                  "queryID": event.queryID.uuidString, "sourceID": event.sourceID,
                                  "state": event.state.rawValue, "batchCount": event.results.count,
                                  "isTerminal": event.isTerminal,
                                  "resultsIncomplete": event.resultsIncomplete,
                                  "isMetadataUpdate": event.isMetadataUpdate,
                                  "reportedTotal": event.reportedTotal as Any? ?? NSNull(),
                                  "cleanupState": event.cleanupState as Any? ?? NSNull()]
        appendAcceptance(row, file: "provider-events")
    }

    /// 核心协议事件。
    public func recordProtocolEvent(_ m: [String: Any]) {
        guard let event = m["event"] as? String,
              ["batch", "sourceState", "terminal", "searchReturned", "controlAck"].contains(event) else { return }
        var row: [String: Any] = ["monotonicSeconds": uptime(), "event": event,
                                  "batchCount": (m["files"] as? [Any])?.count ?? 0]
        for key in ["sourceID", "queryID", "resultState", "cleanupState", "reportedTotal",
                    "publishedCount", "isComplete", "state"] {
            if let value = m[key] { row[key] = value }
        }
        appendAcceptance(row, file: "protocol-summary")
    }

    /// 需要解释的现场。正常结束不记，避免噪音淹没真正的故障。
    public func recordSearchFailureTrace(_ m: [String: Any]) {
        guard let event = m["event"] as? String, acceptedEvents.contains(event) else { return }
        // 正常结束与「正在跑」都不记——只留下需要解释的现场。
        let state = (m["resultState"] as? String) ?? (m["state"] as? String) ?? ""
        if state == "completed" || state == "searching" || state == "starting" || state == "polling" {
            // ★ 结果正常但**任务没清干净**时要破例记一条。
            //
            // 「搜索成功、但 DSM 上留了一个任务」不会立刻表现为故障，
            // 但要攒够几十次才会变成「File Station 正常、闪寻搜不到」。
            // 那时候现场早就没了。所以这种「看似正常」的行反而最该留下来。
            let leaked = (m["cleanupState"] as? String) == "pending"
                || ((m["pendingAfter"] as? [String: Any])?["remaining"] as? Int ?? 0) > 0
            if !leaked { return }
        }
        // `disconnected` 同理：**成功地断开**不解释任何东西。
        //
        // 每次「连接 / 重新连接 / 确认证书」之前，产品端都会先发一条幂等清理。
        // 这条清理成功时会回一个 `sourceState: disconnected`，而它属于「正常结束」。
        // 把它记下来，每次启动就都会往这份文件里塞与真实故障长得一样的行
        // ——而这份文件正是排查搜索问题时最先看的东西。
        if state == "disconnected" { return }
        guard let base = stateDirectory?() else { return }
        let directory = base.deletingLastPathComponent().appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var row: [String: Any] = ["at": ISO8601DateFormatter().string(from: now()),
                                  "event": m["event"] as? String ?? "terminal"]
        for key in ["sourceID", "resultState", "state", "cleanupState", "reportedTotal",
                    "publishedCount", "fetchedCount", "unparsedCount", "duplicateCount", "isComplete",
                    // 旧 DSM 搜索任务的回收情况：一次泄漏看不出来，累积就是「越搜越不行」。
                    "pendingBefore", "pendingAfter"] {
            if let value = m[key] { row[key] = value }
        }
        let error = m["error"] as? [String: Any]
        if let kind = error?["kind"] { row["errorKind"] = kind }
        // 失败在**哪个 API / 方法**上是定位的第一把钥匙。
        // 只记 kind 的话，「登录挂了」和「分页挂了」在诊断里长得一样。
        if let api = error?["api"] as? String, !api.isEmpty { row["errorApi"] = api }
        if let method = error?["method"] as? String, !method.isEmpty { row["errorMethod"] = method }
        if let code = error?["apiCode"] { row["apiCode"] = code }
        if let http = error?["httpStatus"] { row["httpStatus"] = http }
        // detail 里是「第 N 行的哪个字段不对」或客户端异常类型，
        // 由核心侧保证不含文件名/路径/凭据。
        if let detail = error?["detail"] { row["errorDetail"] = detail }
        write(row, to: directory.appendingPathComponent("nas-search-events.jsonl"), rotateAbove: 512 * 1024)
    }

    /// 追加一行到常驻诊断（不记查询词 / 文件名 / 凭据）。
    public func append(_ row: [String: Any]) {
        guard let base = stateDirectory?() else { return }
        let directory = base.deletingLastPathComponent().appendingPathComponent("diagnostics")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        write(row, to: directory.appendingPathComponent("nas-search-events.jsonl"), rotateAbove: nil)
    }

    // MARK: - 落盘

    private func appendAcceptance(_ row: [String: Any], file prefix: String) {
        guard let directory = acceptanceDirectory?() else { return }
        write(row, to: directory.appendingPathComponent("\(prefix)-\(sessionID).jsonl"), rotateAbove: nil)
    }

    private func write(_ row: [String: Any], to destination: URL, rotateAbove: Int?) {
        if let rotateAbove,
           let size = try? FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? Int,
           size > rotateAbove {
            try? FileManager.default.removeItem(at: destination)
        }
        guard let line = try? JSONSerialization.data(withJSONObject: row) else { return }
        if !FileManager.default.fileExists(atPath: destination.path) {
            _ = FileManager.default.createFile(atPath: destination.path, contents: nil,
                                               attributes: [.posixPermissions: 0o600])
        }
        if let handle = try? FileHandle(forWritingTo: destination) {
            _ = try? handle.seekToEnd(); try? handle.write(contentsOf: line + Data([10])); try? handle.close()
        }
    }
}
