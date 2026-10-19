import XCTest
@testable import FlashFindCore

/// 打开 / 定位失败的文案。
///
/// 放在 Core 才能测：App 层是 executableTarget，测试依赖不进去，
/// 而「用户看到什么」恰恰最该被锁住——界面上一个技术名词，
/// 用户既不知道发生了什么、也不知道下一步该做什么。
final class OpenFailureTextTests: XCTestCase {

    // MARK: - 挂载类错误

    func testMountUnreachableKeepsItsOwnReason() {
        // 不可达的原因里带着具体到端口的判断，比任何按类型猜出来的话都准。
        let error = SMBMountService.MountError.unreachable(
            "无法访问 192.168.1.96 的 445 端口（可能不在同一网络）",
            smbURL: "smb://192.168.1.96/示例共享")
        let text = OpenFailureText.describe(error)
        XCTAssertTrue(text.contains("445"), "应保留端口这个关键线索，实际：\(text)")
    }

    func testMountErrorExposesManualConnectURL() {
        let reachable = SMBMountService.MountError.needsCredential("需要登录", smbURL: "smb://h/s")
        XCTAssertEqual(OpenFailureText.manualConnectURL(reachable), "smb://h/s")
        // 地址不合法时没有可连的目标，就不该给用户一个点了也没用的按钮。
        XCTAssertNil(OpenFailureText.manualConnectURL(SMBMountService.MountError.invalidTarget))
    }

    // MARK: - 闪寻自己的错误

    func testFlashFindMessageIsUsedVerbatim() {
        let error = FlashFindError.message("尚未连接共享 示例共享。请先在 Finder 里连接。")
        XCTAssertEqual(OpenFailureText.describe(error),
                       "尚未连接共享 示例共享。请先在 Finder 里连接。")
    }

    // MARK: - 核心错误

    /// ★ 这条是搬进 Core 的理由。
    ///
    /// `FlashFindError.coreFailure.errorDescription` 返回的是 **kind**
    /// （Models.swift 里刻意如此，因为既有代码靠 `localizedDescription` 做字符串判断）。
    /// 旧实现只处理了 `.message`，coreFailure 会落到 `localizedDescription`
    /// ⇒ 用户看到 "AuthenticationFailed" 这种技术名词。
    func testCoreFailureIsNotShownAsRawKind() {
        let error = FlashFindError.coreFailure(kind: "AuthenticationFailed", reason: nil, apiCode: nil)
        let text = OpenFailureText.describe(error)
        // 注意：kind 允许以「（错误类型 …）」的形式跟在中文主句后面——
        // 那是立的纪律（用户报障时靠它定位），打开链路同样要带。
        // 这里禁止的是「主句缺失、只剩一个技术名词」。
        XCTAssertNotEqual(text, "AuthenticationFailed", "主句缺失，只剩 kind")
        XCTAssertTrue(text.hasPrefix("账号或密码被设备拒绝"),
                      "应以中文主句开头，实际：\(text)")
        XCTAssertTrue(text.contains("（错误类型 AuthenticationFailed）"),
                      "排查用的类型后缀要保留，实际：\(text)")
    }

    func testCoreFailurePrefersCoreReason() {
        // 核心写好的原因比按 kind 查表更贴近现场（可能带设备原文）。
        let error = FlashFindError.coreFailure(kind: "TLSRejected",
                                               reason: "TLS 握手失败：证书已过期",
                                               apiCode: nil)
        XCTAssertEqual(OpenFailureText.describe(error), "TLS 握手失败：证书已过期")
    }

    /// 打开失败与搜索失败必须是同一套中文——同一个 kind 在两条链路上
    /// 说出两种话，是自相矛盾的界面。
    func testOpenAndSearchFailuresShareTheSameWording() {
        for kind in ["SessionExpired", "PermissionDenied", "RateLimited", "NetworkFailure"] {
            let openText = OpenFailureText.describe(
                FlashFindError.coreFailure(kind: kind, reason: nil, apiCode: nil))
            let searchText = NASSearchFailureText.describe(kind: kind, apiCode: nil)
            XCTAssertEqual(openText, searchText, "kind=\(kind) 两条链路文案不一致")
        }
    }

    func testCoreFailureStillCarriesApiCode() {
        // 设备错误码是最有排查价值的单个字段。
        let error = FlashFindError.coreFailure(kind: "ApiError", reason: nil, apiCode: 119)
        XCTAssertTrue(OpenFailureText.describe(error).contains("119"),
                      "应带出设备错误码，实际：\(OpenFailureText.describe(error))")
    }

    // MARK: - 兜底

    func testUnknownErrorFallsBackToLocalizedDescription() {
        struct Weird: LocalizedError { var errorDescription: String? { "某种系统错误" } }
        XCTAssertEqual(OpenFailureText.describe(Weird()), "某种系统错误")
    }

    /// 提示条上「消息 + 按钮」两件事一次算完，避免调用方漏掉 smbURL——
    /// 漏了就没有可点的出路，用户只能看着提示发呆。
    func testBannerReturnsBothParts() {
        let error = SMBMountService.MountError.unreachable("端口不通", smbURL: "smb://h/s")
        let banner = OpenFailureText.banner(error)
        XCTAssertEqual(banner.message, "端口不通")
        XCTAssertEqual(banner.smbURL, "smb://h/s")

        let plain = OpenFailureText.banner(FlashFindError.message("文件已删除"))
        XCTAssertEqual(plain.message, "文件已删除")
        XCTAssertNil(plain.smbURL)
    }
}
