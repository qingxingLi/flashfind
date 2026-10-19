import XCTest
@testable import FlashFindCore

/// 版本号展示契约。
///
/// 设置页「通用」和「关于」面板都要显示版本，格式化收在 `AppVersion.displayText`。
/// 这里锁两件事：
/// ① **界面只写短版本**（`1.0.1`），构建号绝不拼进来——它是内部序号，同一个
///    版本号会为修 bug 重打若干次，露在界面上只是一串对不上东西的数字；
/// ② 缺值与空白的降级规则——真机上 Info.plist 永远齐全，只有源码直接跑
///    （裸二进制没有 Info.plist）或打包脚本漏填时才走到，那时候界面最容易
///    出现空白行。
final class AppVersionTests: XCTestCase {

    /// 正式版形态：只有短版本，没有括号和构建号。
    func testShowsShortVersionAlone() {
        XCTAssertEqual(AppVersion.displayText(short: "1.0.1"), "1.0.1")
    }

    /// 两端空白要剪掉——Info.plist 里多敲一个空格不该显示成「 1.0.1 」。
    func testTrimsSurroundingWhitespace() {
        XCTAssertEqual(AppVersion.displayText(short: " 1.0.1 "), "1.0.1")
        XCTAssertEqual(AppVersion.displayText(short: "\n1.0.1\t"), "1.0.1")
    }

    /// 什么都没有时给一个明确的占位，而不是空白行。
    func testShowsPlaceholderWhenNothingIsKnown() {
        XCTAssertEqual(AppVersion.displayText(short: nil), "—")
        XCTAssertEqual(AppVersion.displayText(short: ""), "—")
        XCTAssertEqual(AppVersion.displayText(short: "   "), "—")
    }
}
