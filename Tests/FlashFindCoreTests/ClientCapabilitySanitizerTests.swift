import Foundation
import Logging
import MCP
import XCTest
@testable import FlashFindCore

/// Phase 11-lite：客户端 `capabilities.experimental` 的兼容清洗。
///
/// 这组用例守的不是「我们的实现细节」，而是**一条现实中的互操作事实**：
/// swift-sdk 把 `experimental` 定成 `[String: String]?`，而真实客户端会发对象值。
/// 所以最要紧的两条是：
///
///   · `testCodexInitializeFailsWithoutTheSanitizer` —— 证明缺陷真的存在（没它就绿，说明 SDK 变了）
///   · `testCodexInitializeDecodesAfterSanitizing`    —— 证明修法真的管用（用 SDK 自己的解码器验）
///
/// 两条一起才有意义：只留后者，SDK 哪天自己修好了，用例仍然全绿而清洗层已经多余却没人知道；
/// 只留前者，则是「证明有病、没证明治好」。
final class ClientCapabilitySanitizerTests: XCTestCase {

    /// Codex 0.163.0-alpha.11 实际发出的报文（shim 逐字节抓包所得，2026-10-22）。
    private static let codexInitialize = Data(#"""
    {"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"codex/auth-change":{}},"elicitation":{"form":{},"url":{}}},"clientInfo":{"name":"codex-mcp-client","title":"Codex","version":"0.163.0-alpha.11"}}}
    """#.utf8)

    private func params(_ data: Data) throws -> Initialize.Parameters {
        let frame = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let raw = try XCTUnwrap(frame["params"])
        let encoded = try JSONSerialization.data(withJSONObject: raw)
        return try JSONDecoder().decode(Initialize.Parameters.self, from: encoded)
    }

    // MARK: - 缺陷本身

    /// 不清洗就解不开——这是「为什么要有这一层」的证据。
    func testCodexInitializeFailsWithoutTheSanitizer() throws {
        XCTAssertThrowsError(try params(Self.codexInitialize)) { error in
            XCTAssertTrue(error is DecodingError,
                          "期望解码失败（experimental 的值是对象，SDK 期待字符串），实际：\(error)")
        }
    }

    /// 清洗之后必须能被 SDK 自己的解码器解开，且**其它字段一个都没变**。
    func testCodexInitializeDecodesAfterSanitizing() throws {
        let sanitized = ClientCapabilitySanitizer.sanitize(Self.codexInitialize)
        let decoded = try params(sanitized)

        XCTAssertEqual(decoded.protocolVersion, "2025-06-18")
        XCTAssertEqual(decoded.clientInfo.name, "codex-mcp-client")
        XCTAssertEqual(decoded.clientInfo.version, "0.163.0-alpha.11")
        // 唯一的对象值条目被丢掉，于是整键消失（不是留一个空对象）。
        XCTAssertNil(decoded.capabilities.experimental,
                     "experimental 里只有对象值，应当整键删除")
        // 同一个 capabilities 里的 elicitation 必须原样保留——只碰一个字段。
        XCTAssertNotNil(decoded.capabilities.elicitation,
                        "elicitation 被顺手删掉了：清洗范围溢出了")
    }

    // MARK: - 不该动的时候一个字节都不动

    func testMessageThatIsNotInitializeIsReturnedByteIdentical() {
        let raw = Data(#"{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"locate","arguments":{"query":"x"}}}"#.utf8)
        XCTAssertEqual(ClientCapabilitySanitizer.sanitize(raw), raw)
    }

    func testStringValuedExperimentalIsLeftByteIdentical() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{"experimental":{"a":"b"}},"clientInfo":{"name":"n","version":"1"}}}"#.utf8)
        XCTAssertEqual(ClientCapabilitySanitizer.sanitize(raw), raw,
                       "合规客户端的字节不该被重编码")
    }

    func testMissingCapabilitiesIsReturnedByteIdentical() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","clientInfo":{"name":"n","version":"1"}}}"#.utf8)
        XCTAssertEqual(ClientCapabilitySanitizer.sanitize(raw), raw)
    }

    func testMissingExperimentalIsReturnedByteIdentical() {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"roots":{"listChanged":true}}}}"#.utf8)
        XCTAssertEqual(ClientCapabilitySanitizer.sanitize(raw), raw)
    }

    func testMalformedJSONIsReturnedByteIdentical() {
        let raw = Data("not json at all\n".utf8)
        XCTAssertEqual(ClientCapabilitySanitizer.sanitize(raw), raw,
                       "畸形报文原样交给 SDK 去报错，清洗层不猜")
    }

    // MARK: - 混合与畸形形态

    func testMixedExperimentalKeepsStringEntriesOnly() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"experimental":{"keep":"v","drop":{"x":1},"num":3}}}}"#.utf8)
        let decoded = try params(ClientCapabilitySanitizer.sanitize(raw))
        let kept = try XCTUnwrap(decoded.capabilities.experimental)
        XCTAssertEqual(kept, ["keep": "v"], "非字符串值必须被丢掉，字符串条目必须留住")
    }

    /// `experimental` 是字符串 / 数组 / null —— 任何一种都不是 `[String: String]`，
    /// 留着同样会解码失败，所以整键删。
    func testNonObjectExperimentalIsDroppedEntirely() throws {
        for shape in [#""experimental":"x""#, #""experimental":[1,2]"#, #""experimental":null"#] {
            let raw = Data((#"{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"# + shape + #"}}}"#).utf8)
            let decoded = try params(ClientCapabilitySanitizer.sanitize(raw))
            XCTAssertNil(decoded.capabilities.experimental, "\(shape) 应当被整键删除")
        }
    }

    /// 传输层按行分帧：清洗后原来带换行还得带换行。
    func testTrailingNewlineIsPreserved() {
        let withoutNewline = ClientCapabilitySanitizer.sanitize(Self.codexInitialize)
        let withNewline = ClientCapabilitySanitizer.sanitize(Self.codexInitialize + Data([0x0A]))
        XCTAssertNotEqual(withoutNewline.last, 0x0A)
        XCTAssertEqual(withNewline.last, 0x0A)
    }

    // MARK: - 传输层包装真的接上了

    /// 只测纯函数是不够的：`main.swift` 里那一行忘了换成 `SanitizingTransport`，
    /// 上面九条照样全绿，而 Codex 依旧连不上。这条从 `receive()` 出口验。
    func testSanitizingTransportRewritesIncomingInitialize() async throws {
        let inner = StubTransport(chunks: [Self.codexInitialize])
        let transport = SanitizingTransport(wrapping: inner)
        var received: [Data] = []
        for try await chunk in await transport.receive() {
            received.append(chunk)
        }
        XCTAssertEqual(received.count, 1)
        XCTAssertNoThrow(try params(try XCTUnwrap(received.first)),
                         "receive() 出口没洗，说明包装层没接上")
        let outbound = await inner.sentData
        XCTAssertEqual(outbound, [], "入站清洗不该改动出站字节")
    }

    /// 出站原样转发。
    func testSanitizingTransportForwardsOutboundVerbatim() async throws {
        let inner = StubTransport(chunks: [])
        let transport = SanitizingTransport(wrapping: inner)
        let payload = Data(#"{"jsonrpc":"2.0","id":1,"result":{"protocolVersion":"2025-06-18"}}"#.utf8)
        try await transport.send(payload)
        let outbound = await inner.sentData
        XCTAssertEqual(outbound, [payload])
    }
}

/// 内存里的假传输：按顺序吐固定几块，并记下 `send` 收到的字节。
private actor StubTransport: Transport {
    nonisolated let logger = Logger(label: "flashfind.tests.transport")
    private let chunks: [Data]
    private(set) var sentData: [Data] = []

    init(chunks: [Data]) {
        self.chunks = chunks
    }

    func connect() async throws {}
    func disconnect() async {}

    func send(_ data: Data) async throws {
        sentData.append(data)
    }

    func receive() -> AsyncThrowingStream<Data, Swift.Error> {
        let chunks = self.chunks
        return AsyncThrowingStream { continuation in
            for chunk in chunks { continuation.yield(chunk) }
            continuation.finish()
        }
    }
}
