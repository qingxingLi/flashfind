import XCTest
import Darwin
@testable import FlashFindCore

/// 锁定实机反馈：**点开 NAS 文件会弹出访达的 SMB 连接框**。
///
/// 场景是「用公网域名连的群晖」：DSM 的 Web 入口有公网映射，
/// 但 SMB 的 445 一般没有，本机也不在 NAS 所在局域网 ——
/// 于是系统那条 `NSWorkspace.open(smb://…)` 必然失败，
/// 用户只落得「框弹出来 → 等超时 → 手动关掉」。
///
/// 期望语义：闪寻自己**不弹**任何系统连接框；
/// 不可达 / 缺凭据时直接给出原因，并把可选的 smb:// 地址交给用户决定。
final class SMBReachabilityTests: XCTestCase {

    // MARK: - 真实 TCP 探测

    /// 有人监听 → 可达。
    func testReachablePortIsDetected() async throws {
        let listener = try LoopbackListener()
        defer { listener.close() }
        let reachable = await SMBReachability.isReachable(host: "127.0.0.1", port: listener.port,
                                                          timeout: 1.0)
        XCTAssertTrue(reachable, "本地已监听的端口必须判定为可达")
    }

    /// 无人监听 → 不可达（用回环上的拒绝连接，无需触碰外网）。
    func testClosedPortIsNotReachable() async throws {
        let listener = try LoopbackListener()
        let port = listener.port
        listener.close()   // 拿到端口后立刻释放，此刻必定无人监听
        let reachable = await SMBReachability.isReachable(host: "127.0.0.1", port: port, timeout: 1.0)
        XCTAssertFalse(reachable)
    }

    /// 解析不到的主机名不能抛异常，只能返回 false。
    func testUnresolvableHostReturnsFalse() async {
        let reachable = await SMBReachability.isReachable(host: "no-such-host.invalid", timeout: 1.0)
        XCTAssertFalse(reachable)
    }

    /// 空主机名直接 false，不建连。
    func testEmptyHostIsRejected() async {
        let reachable = await SMBReachability.isReachable(host: "   ", timeout: 0.2)
        XCTAssertFalse(reachable)
    }

    /// 超时必须生效：不可路由地址不能把调用方挂住。
    /// 这条是「用户不会看到转圈几十秒」的硬约束。
    func testProbeHonoursTimeout() async {
        let start = Date()
        _ = await SMBReachability.isReachable(host: "10.255.255.1", port: 445, timeout: 0.5)
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 2.0, "超时 0.5 秒的探测不应耗时 \(elapsed) 秒")
    }

    // MARK: - 挂载失败语义

    /// 端口不可达时，抛出的必须是 `unreachable`，且带上可手动连接的地址。
    /// 关键点是它**不**走系统弹框路径。
    func testUnreachableTargetFailsWithoutPromptingFinder() async throws {
        let service = SMBMountService()
        await service.useReachability { _, _ in false }   // 确定性地「连不上」
        let target = SMBMountService.Target(host: "nas.example.com", share: "示例共享", username: "u")
        do {
            _ = try await service.mount(target)
            XCTFail("不可达时不应返回挂载点")
        } catch let error as SMBMountService.MountError {
            let url = try XCTUnwrap(error.manualConnectURL)
            XCTAssertTrue(url.hasPrefix("smb://"), "要带一个可手动挂载的地址：\(url)")
            XCTAssertTrue(url.contains("nas.example.com"), "地址要指向这台 NAS：\(url)")
            XCTAssertTrue(url.contains("%E7%A4%BA%E4%BE%8B%E5%85%B1%E4%BA%AB") || url.contains("示例共享"),
                          "共享名要带上：\(url)")
            let message = try XCTUnwrap(error.errorDescription)
            XCTAssertTrue(message.contains("445"), "要说清是端口不可达，而不是笼统的失败：\(message)")
            XCTAssertTrue(message.contains("在访达中连接"), "要给出下一步：\(message)")
        }
    }

    /// 只有「不可达 / 需凭据」这两种错误才提供手动连接入口。
    /// 别的错误弹连接框没有意义（地址都不合法）。
    func testManualConnectURLOnlyForActionableErrors() {
        XCTAssertNil(SMBMountService.MountError.invalidTarget.manualConnectURL)
        XCTAssertNil(SMBMountService.MountError.notAuthorized.manualConnectURL)
        XCTAssertNil(SMBMountService.MountError.failed("随便什么原因").manualConnectURL)
        XCTAssertEqual(SMBMountService.MountError.unreachable("原因", smbURL: "smb://h/s").manualConnectURL,
                       "smb://h/s")
        XCTAssertEqual(SMBMountService.MountError.needsCredential("原因", smbURL: "smb://h/s").manualConnectURL,
                       "smb://h/s")
    }

    /// 错误文案就是给用户看的文案，不能再出现英文技术词。
    func testErrorDescriptionsAreUserFacingChinese() throws {
        let cases: [SMBMountService.MountError] = [
            .invalidTarget, .notAuthorized,
            .unreachable("SMB 文件服务不可达：nas 的 445 端口没有响应。", smbURL: "smb://h/s"),
            .needsCredential("点「在访达中连接」输入账号密码。", smbURL: "smb://h/s"),
            .failed("无法挂载共享")
        ]
        for item in cases {
            let text = try XCTUnwrap(item.errorDescription)
            XCTAssertFalse(text.isEmpty)
            XCTAssertFalse(text.lowercased().contains("error"), "不该把技术错误码甩给用户：\(text)")
        }
    }

    /// 目标地址里不出现密码字段——凭据只走系统钥匙串。
    func testTargetURLNeverCarriesPassword() throws {
        let target = SMBMountService.Target(host: "nas.example.com", share: "示例共享", username: "u")
        let url = try XCTUnwrap(target.smbURL?.absoluteString)
        let afterScheme = url.replacingOccurrences(of: "smb://", with: "")
        XCTAssertFalse(afterScheme.contains(":"), "user:password@host 形态会泄漏密码：\(url)")
        XCTAssertTrue(afterScheme.contains("u@nas.example.com") || afterScheme.hasPrefix("nas.example.com/"))
    }
}

/// 回环上的临时 TCP 监听器。只为拿到一个「肯定有人监听」的端口。
private final class LoopbackListener {
    let fd: Int32
    let port: UInt16

    init() throws {
        let handle = socket(AF_INET, SOCK_STREAM, 0)
        guard handle >= 0 else { throw ListenerError.socket }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0                       // 让内核挑一个空闲端口
        address.sin_addr.s_addr = inet_addr("127.0.0.1")

        var reuse: Int32 = 1
        setsockopt(handle, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(handle, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(handle, 4) == 0 else { Darwin.close(handle); throw ListenerError.bind }

        var actual = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &actual) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(handle, $0, &length) }
        }
        guard named == 0 else { Darwin.close(handle); throw ListenerError.bind }
        self.fd = handle
        self.port = UInt16(bigEndian: actual.sin_port)
    }

    func close() { Darwin.close(fd) }

    enum ListenerError: Error { case socket, bind }
}
