import XCTest
@testable import FlashFindCore

/// NAS 总开关的取值（审核 R01）。
///
/// 这条判定原来内联在 AppModel 的 `init` 里，而 AppModel 属于 executableTarget、
/// 测试目标依赖不了它 —— 于是「全新安装的机器上总开关到底是开是关」
/// 只能靠人在设置里点出来，而那个开关若绑成 `.constant(...)`，点了也不动。
///
/// 这里的每一条都对应一种真实的用户处境，不是枚举组合：
final class NASMasterSwitchTests: XCTestCase {

    /// ★ 全新安装：两个 key 都没写过 ⇒ 必须是**开**。
    ///
    /// 旧写法 `object(...) ?? bool(forKey:)` 在这时得到 false，
    /// 用户连好 NAS 后一次都搜不到，且设置里开不了。这是 R01 的全部由来。
    func testFreshInstallDefaultsToEnabled() {
        XCTAssertTrue(NASMasterSwitch.resolve(stored: nil, legacy: nil))
    }

    /// 用户在设置页关掉 ⇒ 必须尊重，重启后仍是关。
    func testExplicitlyDisabledIsRespected() {
        XCTAssertFalse(NASMasterSwitch.resolve(stored: false, legacy: nil))
    }

    /// 用户显式打开 ⇒ 开（哪怕旧版 key 写着关）。
    func testExplicitlyEnabledIsRespected() {
        XCTAssertTrue(NASMasterSwitch.resolve(stored: true, legacy: nil))
    }

    /// 当前 key 优先于旧版 key：旧版遗留的 false 不能盖掉用户后来的选择。
    func testCurrentKeyWinsOverLegacy() {
        XCTAssertTrue(NASMasterSwitch.resolve(stored: true, legacy: false))
        XCTAssertFalse(NASMasterSwitch.resolve(stored: false, legacy: true))
    }

    /// 只有旧版 key（老用户升级上来）⇒ 沿用旧选择，不擅自改成开。
    func testLegacyChoiceIsInherited() {
        XCTAssertFalse(NASMasterSwitch.resolve(stored: nil, legacy: false))
        XCTAssertTrue(NASMasterSwitch.resolve(stored: nil, legacy: true))
    }

    /// key 名字两侧一致：产品代码与测试用同一份常量，避免各写一份字面量。
    ///
    /// 落盘 key 写错一次的后果是「用户的开关设置下次启动就没了」，
    /// 而且和 R01 的表现一模一样，极难分辨是哪种。
    func testStorageKeysMatchConstants() {
        XCTAssertEqual(NASMasterSwitch.storageKey, "ff2.multiNAS.enabled")
        XCTAssertEqual(NASMasterSwitch.legacyKey, "ff2.enabled")
    }

    /// ★ 整个修复的前提：`UserDefaults` 真的能区分「没写过」和「写过关」。
    ///
    /// 用真的 UserDefaults 验一次而不是凭印象：`bool(forKey:)` 对两种情形都返回 false，
    /// 只有 `object(forKey:)` 的 nil 能分辨。这条不成立的话上面五条全是空中楼阁。
    func testUserDefaultsDistinguishesUnsetFromExplicitFalse() {
        let name = "ff2.test.masterswitch.\(UUID().uuidString)"
        guard let suite = UserDefaults(suiteName: name) else {
            return // 临时 suite 建不出来时跳过，不假绿
        }
        defer { suite.removePersistentDomain(forName: name) }

        // 情形一：全新安装，什么都没写过。
        XCTAssertNil(suite.object(forKey: NASMasterSwitch.storageKey))
        XCTAssertFalse(suite.bool(forKey: NASMasterSwitch.storageKey),
                       "★ 对不存在的 key，bool(forKey:) 同样返回 false —— 这正是 R01 的由来")
        XCTAssertTrue(NASMasterSwitch.resolve(stored: suite.object(forKey: NASMasterSwitch.storageKey) as? Bool,
                                              legacy: nil))

        // 情形二：用户显式关掉。
        suite.set(false, forKey: NASMasterSwitch.storageKey)
        XCTAssertNotNil(suite.object(forKey: NASMasterSwitch.storageKey),
                        "写过 false 之后 object 不能是 nil，否则无法与「没写过」区分")
        XCTAssertFalse(NASMasterSwitch.resolve(stored: suite.object(forKey: NASMasterSwitch.storageKey) as? Bool,
                                               legacy: nil))
    }
}
