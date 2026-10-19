import XCTest
@testable import FlashFindCore

/// 端口解析、连接按钮可用性、凭据身份边界。
///
/// 这三件事共用一个前提：**端口可以写在地址里**（`192.168.1.96:5001`）。
/// 早期三处判定（列表状态、保存、连接）各自只看端口字段，于是用户把端口
/// 写进地址栏时界面看着没问题、后台却判「未配置」——同一件事两套判定，
/// 正是「点了没反应」的温床。这里把「有效端口」这一套判定钉住。
@MainActor
final class NASPortResolutionTests: XCTestCase {

    // MARK: - 地址里带端口

    /// 用户把 `192.168.1.96:5001` 整串写进地址栏、端口框留空。
    func testAddressWithPortStillYieldsEffectivePort() {
        let config = NASSourceConfig(host: "192.168.1.96:5001", username: "nasuser")
        XCTAssertEqual(config.hostName, "192.168.1.96")
        // 端口字段确实还是空的——这就是按钮会变灰的原因。
        XCTAssertFalse(config.hasPort)
        // 但有效端口取得到，连接判定应该用它。
        XCTAssertEqual(config.effectivePort, 5001)
        XCTAssertTrue(config.hasEffectivePort)
    }

    /// 完整 URL 写法。
    func testHTTPSURLWithPort() {
        let config = NASSourceConfig(host: "https://192.168.1.96:5001", username: "u")
        XCTAssertEqual(config.hostName, "192.168.1.96")
        XCTAssertEqual(config.effectivePort, 5001)
    }

    /// 两种写法同时存在时，显式端口字段优先。
    func testExplicitPortFieldWins() {
        let config = NASSourceConfig(host: "192.168.1.88:5001", port: 5003, username: "u")
        XCTAssertEqual(config.effectivePort, 5003)
    }

    /// `normalizeHost` 会把地址里的端口搬进端口字段，让界面与流程一致。
    func testNormalizeHostMovesPortIntoField() {
        var config = NASSourceConfig(host: "192.168.1.96:5001")
        config.normalizeHost()
        XCTAssertEqual(config.host, "192.168.1.96")
        XCTAssertEqual(config.port, 5001)
    }

    /// 地址里没有合法端口时不能瞎猜。
    func testPortFromHostRejectsJunk() {
        XCTAssertNil(NASSourceConfig.portFromHost("nas.local"))
        XCTAssertNil(NASSourceConfig.portFromHost("192.168.1.96:"))
        XCTAssertNil(NASSourceConfig.portFromHost("192.168.1.96:abc"))
        XCTAssertNil(NASSourceConfig.portFromHost("192.168.1.96:70000"))
        XCTAssertNil(NASSourceConfig.portFromHost("192.168.1.96:0"))
        XCTAssertEqual(NASSourceConfig.portFromHost("disk-station.local:5001"), 5001)
    }

    // MARK: - 端口输入要能实时生效

    /// 逐位输入时每一步都能解析出来——按钮状态因此可以实时跟随，
    /// 不需要先点别处让输入框失焦。
    func testPortFieldParsesWhileTyping() {
        XCTAssertEqual(PortField.parse("5"), 5)
        XCTAssertEqual(PortField.parse("50"), 50)
        XCTAssertEqual(PortField.parse("500"), 500)
        XCTAssertEqual(PortField.parse("5001"), 5001)
    }

    func testPortFieldIgnoresNonDigitsAndRejectsOutOfRange() {
        XCTAssertEqual(PortField.parse("5a0"), 50)
        XCTAssertNil(PortField.parse("abc"))
        XCTAssertNil(PortField.parse(""))
        XCTAssertNil(PortField.parse("0"))
        XCTAssertNil(PortField.parse("70000"))
    }

    func testPortFieldTextRoundTrip() {
        XCTAssertEqual(PortField.text(for: 5001), "5001")
        XCTAssertEqual(PortField.text(for: 0), "")
        XCTAssertEqual(PortField.text(for: 70000), "")
    }

    // MARK: - 连接按钮的可用性

    /// 端口只写在地址里时按钮也要亮。
    func testConnectEnabledWhenPortOnlyInAddress() {
        let config = NASSourceConfig(host: "192.168.1.96:5001", username: "nasuser")
        // 用有效端口判定 → 可连接。
        XCTAssertTrue(ConnectButtonState.canConnect(busy: false, host: config.hostName,
                                                    hasPort: config.hasEffectivePort,
                                                    username: config.username,
                                                    hasTypedPassword: true,
                                                    hasStoredPassword: false))
        // 只看端口字段 → 灰。这正是要避免的那套判定，留作对照。
        XCTAssertFalse(ConnectButtonState.canConnect(busy: false, host: config.hostName,
                                                     hasPort: config.hasPort,
                                                     username: config.username,
                                                     hasTypedPassword: true,
                                                     hasStoredPassword: false))
    }

    /// 忙碌时必须拒绝再次发起，否则「双击」会起两条 discover→login 流程。
    func testBusyBlocksConnect() {
        XCTAssertFalse(ConnectButtonState.canConnect(busy: true, host: "192.168.1.96",
                                                     hasPort: true, username: "u",
                                                     hasTypedPassword: true, hasStoredPassword: false))
    }

    func testDisabledReasonExplainsMissingPort() {
        let reason = ConnectButtonState.disabledReason(busy: false, host: "192.168.1.96",
                                                       hasPort: false, username: "u",
                                                       hasTypedPassword: true, hasStoredPassword: false)
        XCTAssertNotNil(reason)
        // 提示要告诉用户「端口也可以写进地址」，否则他会以为程序不认他的输入。
        XCTAssertTrue(reason?.contains(":5001") == true)
    }

    // MARK: - 改地址或账号后不能用旧凭据

    func testEndpointDiffersWhenHostChanges() {
        let original = NASSourceConfig(host: "192.168.1.96", port: 5001, username: "nasuser")
        let edited = NASSourceConfig(host: "192.168.1.88", port: 5001, username: "nasuser")
        XCTAssertFalse(original.hasSameEndpoint(as: edited))
    }

    func testEndpointDiffersWhenUsernameChanges() {
        let original = NASSourceConfig(host: "192.168.1.96", port: 5001, username: "nasuser")
        let edited = NASSourceConfig(host: "192.168.1.96", port: 5001, username: "admin")
        XCTAssertFalse(original.hasSameEndpoint(as: edited))
    }

    func testEndpointSameWhenNothingRelevantChanged() {
        let original = NASSourceConfig(host: "192.168.1.96", port: 5001, username: "nasuser")
        let renamed = NASSourceConfig(name: "客厅 NAS", host: "192.168.1.96", port: 5001,
                                      username: "nasuser")
        XCTAssertTrue(original.hasSameEndpoint(as: renamed))
    }

    /// 端口变化**不算**身份变化。
    ///
    /// 同一个设备、同一个账号，换个端口（5001 → 5003）密码并不会变。
    /// 若把端口也算进身份，用户每次调端口都要重敲一遍密码，纯属添堵。
    func testPortChangeDoesNotInvalidateCredential() {
        let original = NASSourceConfig(host: "192.168.1.96", port: 5001, username: "nasuser")
        let edited = NASSourceConfig(host: "192.168.1.96", port: 5003, username: "nasuser")
        XCTAssertTrue(original.hasSameEndpoint(as: edited))
    }
}
