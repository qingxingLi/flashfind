import XCTest
@testable import FlashFindCore

/// 外观选择（浅色 / 深色 / 跟随系统）的取值判定。
///
/// 这条判定放在 Core：App 层是 executableTarget，测试目标 import 不到，
/// 而「默认跟随系统、认不出的值退回跟随系统」是用户每次启动都会遇到的路径。
final class AppearanceChoiceTests: XCTestCase {

    /// ★ 默认**跟随系统**：没设过就是跟随，不许替用户决定浅色或深色。
    func testDefaultIsFollowSystem() {
        XCTAssertEqual(AppearanceChoice.resolve(stored: nil), .system)
        XCTAssertEqual(AppearanceChoice.resolve(stored: ""), .system)
    }

    /// 认得的值原样恢复。
    func testStoredValuesRoundTrip() {
        for choice in AppearanceChoice.allCases {
            XCTAssertEqual(AppearanceChoice.resolve(stored: choice.rawValue), choice,
                           "\(choice.rawValue) 应该能原样读回")
        }
    }

    /// 认不出的值（含旧版写坏的）退回跟随系统，而不是浅色——
    /// 退回任何一个具体外观都是替用户做决定。
    func testUnknownValueFallsBackToSystem() {
        XCTAssertEqual(AppearanceChoice.resolve(stored: "light-mode"), .system)
        XCTAssertEqual(AppearanceChoice.resolve(stored: "1"), .system)
        XCTAssertEqual(AppearanceChoice.resolve(stored: "深色"), .system)
    }

    /// 三个选项的标题与 rawValue 都不重复，否则设置页里会出现两个一样的项。
    func testChoicesAreDistinct() {
        XCTAssertEqual(AppearanceChoice.allCases.count, 3)
        XCTAssertEqual(Set(AppearanceChoice.allCases.map(\.rawValue)).count, 3)
        XCTAssertEqual(Set(AppearanceChoice.allCases.map(\.title)).count, 3)
    }

    /// 偏好 key 用统一的 `ff2.` 前缀，且不为空。
    func testStorageKeyIsNamespaced() {
        XCTAssertTrue(AppearanceChoice.storageKey.hasPrefix("ff2."))
        XCTAssertFalse(AppearanceChoice.storageKey.isEmpty)
    }
}
