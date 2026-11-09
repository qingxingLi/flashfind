import AppKit
import CoreGraphics
import QuartzCore

/// ★★ 1.1.68 / 1.1.69 诊断包专用：把拖动期间每一帧记成带高精度时间戳的行，松手时一次落盘。
///
/// ## 为什么必须有它（2026-11-08 复盘）
/// 1.1.67 的 6 条 `DraggingUnityTests` 全是**结构守卫**——只查源码里有没有某个调用，
/// 在「拖起来还是卡」这个 bug 存在时它们照样全绿。结构守卫只能防回退，不能当验收。
/// 1.1.68 真机帧日志给出的硬证据是：拖搜索框时两类 `DID_MOVE` 严格成对（整体移动成立），
/// 但另有两段 `FIELD_DID_MOVE=0 / RESULTS_DID_MOVE=27、26`（结果窗被单独拖走）。
///
/// ★ 1.1.69 的验收判据（用户：「只有固定以后才能拖动，否则就是整体移动」）：
///   ① 拖结果窗：出现 `RESULTS_MOUSE_DOWN`，**不出现** `RESULTS_DID_MOVE`；
///   ② 拖搜索框：`FIELD_DID_MOVE` 与 `RESULTS_DID_MOVE` 成对、`D` 恒定；
///   ③ 钉住后的快照窗：仍可拖到任意位置（点验观感，日志不覆盖）。
/// 只用 AppKit 原点记账；要 WindowServer 真实屏幕坐标再显式开 `FF2_DRAG_TRACE_CG=1`。
///
/// ★ 不套 `#if DEBUG`：本地试用包是 `--release` 构建，DEBUG 段会被整段编译掉。
/// 正式发布前删除本文件与所有调用点，或把 `enabled` 默认改成 false。
///
/// 落盘位置：`~/Library/Logs/FlashFind2/drag-trace.log`（追加）。
/// 关掉：`FF2_DRAG_TRACE=0` 启动时传入；诊断包默认开。
@MainActor
enum DragFrameTrace {

    static let enabled: Bool = ProcessInfo.processInfo.environment["FF2_DRAG_TRACE"] != "0"
    /// ★ CGWindowListCopyWindowInfo 是跨进程调用，拖动中采样本身可能制造掉帧。
    /// 默认只记 AppKit 侧高精度时间戳；确实要 WindowServer 真实屏幕坐标时再显式打开。
    private static let sampleCG: Bool = ProcessInfo.processInfo.environment["FF2_DRAG_TRACE_CG"] == "1"

    private static var lines: [String] = []
    private static var epoch: CFTimeInterval?
    private static var moveCount = 0

    private static let logURL: URL = {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/FlashFind2", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("drag-trace.log")
    }()

    /// 记一行。`F` / `R` 是 AppKit 侧两窗原点，`D = R - F` 是相对偏移；
    /// `D` 恒定才说明两块作为一个整体在走。
    static func record(_ event: String,
                       field: CGPoint? = nil,
                       results: CGPoint? = nil,
                       note: String = "") {
        guard enabled else { return }
        let now = CACurrentMediaTime()
        if epoch == nil { epoch = now }
        let ms = (now - (epoch ?? now)) * 1000
        var line = String(format: "%.3f %@", ms, event)
        if let f = field { line += String(format: " F=%.1f,%.1f", f.x, f.y) }
        if let r = results { line += String(format: " R=%.1f,%.1f", r.x, r.y) }
        if let f = field, let r = results {
            line += String(format: " D=%.1f,%.1f", r.x - f.x, r.y - f.y)
        }
        if !note.isEmpty { line += " " + note }
        if lines.isEmpty {
            lines.append("# 1.1.69 | t_ms EVENT | F/R=AppKit原点 D=R-F | CG=WindowServer真实屏幕位置")
        }
        lines.append(line)
        if event.hasPrefix("FIELD_DID_MOVE") { moveCount += 1 }
    }

    /// WindowServer 真正画在屏幕上的位置 —— AppKit 的 `frame` 只是 App 侧记账值，
    /// 光看它会把「记账对上了、屏幕上还差一帧」漏掉。每 5 帧采一次，避免采样拖慢拖动。
    static func sampleWindowServer(fieldNumber: Int, resultsNumber: Int) {
        guard enabled, sampleCG, moveCount > 0, moveCount % 10 == 0 else { return }
        guard let f = screenOrigin(windowNumber: fieldNumber),
              let r = screenOrigin(windowNumber: resultsNumber) else { return }
        lines.append(String(format: "CG F=%.1f,%.1f R=%.1f,%.1f D=%.1f,%.1f",
                            f.x, f.y, r.x, r.y, r.x - f.x, r.y - f.y))
    }

    private static func screenOrigin(windowNumber: Int) -> CGPoint? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow],
                                                   CGWindowID(windowNumber)) as? [[String: Any]],
              let entry = list.first,
              let bounds = entry[kCGWindowBounds as String] as? [String: Any] else { return nil }
        func number(_ key: String) -> Double? {
            guard let v = bounds[key] else { return nil }
            if let n = v as? NSNumber { return n.doubleValue }
            return v as? Double
        }
        guard let x = number("X"), let y = number("Y") else { return nil }
        return CGPoint(x: x, y: y)
    }

    /// 松手时一次写盘：拖动期间只拼字符串，不做磁盘 I/O，避免日志本身造成掉帧。
    static func flush() {
        guard enabled, !lines.isEmpty else { return }
        let text = lines.joined(separator: "\n") + "\n---\n"
        lines.removeAll()
        guard let data = text.data(using: .utf8) else { return }
        if FileManager.default.fileExists(atPath: logURL.path),
           let handle = try? FileHandle(forWritingTo: logURL) {
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: data)
            try? handle.close()
        } else {
            try? data.write(to: logURL)
        }
    }
}
