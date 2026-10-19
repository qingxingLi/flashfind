import Foundation

public enum SpotlightIndexState: String, Sendable { case available, disabled, unavailable }
public struct SpotlightAvailability: Sendable {
    public let state: SpotlightIndexState
    public let message: String

    /// 设置页要不要为这件事占一行。
    ///
    /// 索引正常时返回 `nil`：**正常态不说话**。
    /// 把「索引已启用」那句也摆进设置页，
    /// 每一台正常 Mac 的设置页上都会挂着一行永远不变的灰字。
    /// `message` 保持不变——搜索失败时它仍要当错误原因用（见 `SpotlightProvider`）。
    public var attentionMessage: String? {
        state == .available ? nil : message
    }
    public static func parse(_ output: String, exitCode: Int32) -> SpotlightAvailability {
        let text = output.lowercased()
        if text.contains("spotlight server is disabled") || text.contains("indexing disabled") {
            return SpotlightAvailability(state: .disabled, message: "系统 Spotlight 索引已关闭。请在本机设置选择“已选文件夹”模式并添加具体文件夹；不会自动开启系统索引。")
        }
        if exitCode == 0 && text.contains("indexing enabled") {
            return SpotlightAvailability(state: .available, message: "Spotlight 索引已启用；查询结果仍取决于系统已收录的目录")
        }
        return SpotlightAvailability(state: .unavailable, message: "无法确认此卷的 Spotlight 索引状态，请选择“已选文件夹”模式或检查系统索引设置")
    }
    public static func inspect(volumePath: String = "/") async -> SpotlightAvailability {
        await Task.detached {
            let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/mdutil")
            process.arguments = ["-s", volumePath]
            var environment = ProcessInfo.processInfo.environment; environment["LC_ALL"] = "C"; process.environment = environment
            let pipe = Pipe(); process.standardOutput = pipe; process.standardError = pipe
            do {
                try process.run()
                let deadline = ProcessInfo.processInfo.systemUptime + 2
                while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                if process.isRunning {
                    process.terminate()
                    return SpotlightAvailability(state: .unavailable, message: "Spotlight 状态检测超时，请选择“已选文件夹”模式")
                }
                let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
                return parse(output, exitCode: process.terminationStatus)
            } catch {
                if process.isRunning { process.terminate() }
                return SpotlightAvailability(state: .unavailable, message: "无法读取系统索引状态：" + error.localizedDescription)
            }
        }.value
    }
}
