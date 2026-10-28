import XCTest
@testable import FlashFindCore

/// 设备时间戳解析：结果必须与旧的 `ISO8601DateFormatter` 实现逐条一致。
///
/// 换解析器是为了性能（见 `DeviceTimestamp` 里的对照表），但**行为不能变**：
/// 「能不能认出这个时间」会直接决定结果行有没有时间、`recent` 能不能排出来。
/// 所以这里拿旧实现当对照标准，一个样本一个样本比。
final class DeviceTimestampTests: XCTestCase {

    private let legacyFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let legacyPlain = ISO8601DateFormatter()

    private func legacyParse(_ raw: String) -> Date? {
        legacyFractional.date(from: raw) ?? legacyPlain.date(from: raw)
    }

    /// 设备真会发出来的几种形态（群晖带小数秒、WebDAV 不一定、Z 与偏移都出现过）。
    private let deviceShapes = [
        "2026-10-27T09:12:33.000+08:00",
        "2026-10-27T01:12:33.000Z",
        "2026-10-27T01:12:33Z",
        "2026-10-27T01:12:33+0000",
        "2026-10-27T01:12:33.5Z"
    ]

    func testAgreesWithLegacyFormatterOnDeviceShapes() {
        for raw in deviceShapes {
            guard let legacy = legacyParse(raw) else {
                XCTFail("对照组自己不认这个形态：\(raw)")
                continue
            }
            guard let parsed = DeviceTimestamp.parse(raw) else {
                XCTFail("新实现漏掉了这个形态：\(raw)")
                continue
            }
            XCTAssertEqual(parsed.timeIntervalSince1970, legacy.timeIntervalSince1970, accuracy: 0.001,
                           "同一时刻必须解出同一个值：\(raw)")
        }
    }

    /// 认不出来的仍然是 nil —— **不许**退回 `.distantPast` / 1970 冒充「有值」。
    func testRejectsWhatLegacyRejects() {
        let junk = ["", "  ", "not-a-date", "2026-10-27", "2026-10-27 01:12:33", "2026-13-45T99:99:99Z"]
        for raw in junk {
            XCTAssertNil(legacyParse(raw), "对照组意外认了这个：\(raw)")
            XCTAssertNil(DeviceTimestamp.parse(raw), "非法时间戳必须返回 nil：\(raw)")
        }
    }

    /// 小数秒不再被截到毫秒 —— 这个方向只会更准，误差仍在 1 ms 以内。
    func testKeepsSubMillisecondPrecision() throws {
        let raw = "2026-10-27T01:12:33.123456Z"
        let parsed = try XCTUnwrap(DeviceTimestamp.parse(raw))
        let legacy = try XCTUnwrap(legacyParse(raw))
        XCTAssertGreaterThanOrEqual(parsed.timeIntervalSince1970, legacy.timeIntervalSince1970)
        XCTAssertLessThan(parsed.timeIntervalSince1970 - legacy.timeIntervalSince1970, 0.001)
        XCTAssertEqual(parsed.timeIntervalSince1970.truncatingRemainder(dividingBy: 1), 0.123456, accuracy: 0.000001)
    }

    /// 大结果集下**不许**退回到「一行一个 formatter」。
    ///
    /// 这条是性能回归闸：现在是 ~2 ms / 2000 行，逐行新建 formatter 是 ~260 ms。
    /// 阈值取 100 ms（现状的 50 倍余量，慢机器上也过）——真退化成一个量级以上必然红。
    func testParsingThousandsOfRowsStaysCheap() {
        let samples = (0..<2000).map { "2026-10-27T09:12:\(String(format: "%02d", $0 % 60)).000+08:00" }
        let start = Date()
        var parsed = 0
        for raw in samples where DeviceTimestamp.parse(raw) != nil { parsed += 1 }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertEqual(parsed, samples.count, "样本必须全部解析成功，否则这条计时没有意义")
        XCTAssertLessThan(elapsed, 0.1, "2000 行解析用了 \(Int(elapsed * 1000)) ms，疑似又回到了逐行新建 formatter 的写法")
    }
}
