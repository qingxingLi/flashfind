import XCTest
@testable import FlashFindCore

/// 版本号展示契约。
///
/// 设置页「通用」和「关于」面板都要显示版本，格式化收在 `AppVersion.displayText`。
/// 这里锁的是**缺值与相等的降级规则**——真机上 Info.plist 永远齐全，只有在
/// 源码直接跑（裸二进制没有 Info.plist）或打包脚本漏填时才走到，而那时候
/// 界面最容易出现「1.0.0（-）」「开发构建」这种半截话。
final class AppVersionTests: XCTestCase {

    /// 正式版形态：短版本 + 构建号。
    func testCombinesShortVersionAndBuild() {
        XCTAssertEqual(AppVersion.displayText(short: "1.0.0", build: "1"), "1.0.0（1）")
    }

    /// 只有短版本时不再凭空补一个构建号。
    func testFallsBackToShortVersionAlone() {
        XCTAssertEqual(AppVersion.displayText(short: "1.0.0", build: nil), "1.0.0")
        XCTAssertEqual(AppVersion.displayText(short: "1.0.0", build: ""), "1.0.0")
        XCTAssertEqual(AppVersion.displayText(short: "1.0.0", build: "   "), "1.0.0")
    }

    /// 只有构建号时同理。
    func testFallsBackToBuildAlone() {
        XCTAssertEqual(AppVersion.displayText(short: nil, build: "1"), "1")
        XCTAssertEqual(AppVersion.displayText(short: "", build: "1"), "1")
    }

    /// 两个都没有时给一个明确的占位，而不是空白行。
    func testShowsPlaceholderWhenNothingIsKnown() {
        XCTAssertEqual(AppVersion.displayText(short: nil, build: nil), "—")
        XCTAssertEqual(AppVersion.displayText(short: "", build: ""), "—")
    }

    /// 短版本与构建号相同时不重复写成「1.0.0（1.0.0）」。
    func testDoesNotRepeatIdenticalValues() {
        XCTAssertEqual(AppVersion.displayText(short: "1.0.0", build: "1.0.0"), "1.0.0")
    }

    /// 两端空白要剪掉——Info.plist 里多敲一个空格不该显示成「1.0.0（ 1 ）」。
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(AppVersion.displayText(short: " 1.0.0 ", build: " 1 "), "1.0.0（1）")
    }
}
