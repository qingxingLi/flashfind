import Foundation
import Logging
import MCP

/// 在 SDK 的传输层外面套一层，把 `initialize` 里会让 SDK 解码失败的
/// `capabilities.experimental` 洗掉（见 `ClientCapabilitySanitizer` 的文档）。
///
/// ## 为什么只能套在传输层
///
/// SDK 没有给「自定义解码」留钩子：`server.start(transport:)` 拿到报文后直接用
/// 自己的 `JSONDecoder` 解 `Initialize.Parameters`，失败就在握手阶段回 `-32603`。
/// 唯一能插手的位置是报文从 fd 0 读出来、还没进解码器的那一刻——也就是
/// `Transport.receive()` 的出口。
///
/// ## 为什么不改 SDK
///
/// 依赖是 `exact 0.12.1` + `Package.resolved` 入库，改法有三条都不合适：
/// fork（多一份要跟的代码）、打补丁（`swift package resolve` 会覆盖）、
/// 升级（上游 `main` 的声明没变，升了照样失败）。
///
/// ## 只碰入站方向
///
/// `send` 直接转发、不做任何改写：出站报文是我们自己生成的，不存在兼容问题，
/// 多一层重编码只会给「谁改了字节」留下新的疑点。
public actor SanitizingTransport: Transport {

    private let wrapped: any Transport

    /// 传输层日志。用自己的实例而不是转述 `wrapped.logger`：后者是 actor 隔离的，
    /// 在 `nonisolated` 上下文里拿不到。这个 logger 只承载传输诊断，
    /// 与 `StdioTransport` 默认那个走同一个 stderr 目的地。
    public nonisolated let logger: Logger

    public init(wrapping wrapped: any Transport,
                logger: Logger = Logger(label: "flashfind.mcp.transport")) {
        self.wrapped = wrapped
        self.logger = logger
    }

    public func connect() async throws {
        try await wrapped.connect()
    }

    public func disconnect() async {
        await wrapped.disconnect()
    }

    public func send(_ data: Data) async throws {
        try await wrapped.send(data)
    }

    public func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        AsyncThrowingStream { continuation in
            let task = Task { [wrapped] in
                do {
                    for try await chunk in await wrapped.receive() {
                        continuation.yield(ClientCapabilitySanitizer.sanitize(chunk))
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}
