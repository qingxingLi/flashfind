import XCTest

final class OnboardingFlowStructureTests: XCTestCase {
    func testNetworkOnboardingWaitsForUserInsteadOfScanningAndExpanding() throws {
        let client = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: client.appendingPathComponent("Sources/FlashFind2App/OnboardingView.swift"), encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "private struct NetworkStep: View"))
        let end = try XCTUnwrap(source.range(of: "// MARK: - 06 完成"))
        let network = String(source[start.lowerBound..<end.lowerBound])
        XCTAssertFalse(network.contains("LocalNetworkDiscovery()"), "引导不应自行开始局域网发现")
        XCTAssertFalse(network.contains("discovery.start("), "查找设备必须由添加流程里的用户操作触发")
        XCTAssertFalse(network.contains("ForEach(discovery.devices)"), "设备列表不能随发现结果撑大引导窗口")
        XCTAssertTrue(network.contains("NASWizardWindow.shared.show(model: model)"), "保留主动添加入口")
    }
}
