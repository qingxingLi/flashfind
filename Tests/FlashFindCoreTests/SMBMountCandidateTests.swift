import XCTest
@testable import FlashFindCore

/// 已挂载共享与来源端点的匹配判定。
///
/// 这条判定原来住在 AppModel 里，而 AppModel 测不了（App 是可执行目标）。
/// 它决定的事很具体：**能不能把这条挂载直接绑到那个来源上**。
/// 判宽了会把别的共享绑上去——用户打开文件时拿到的是另一个目录里的同名文件，
/// 而且不会报错；判窄了则永远「不匹配」，用户只能手动选目录。
final class SMBMountCandidateTests: XCTestCase {

    private func candidate(host: String = "nas.example", share: String = "team") -> SMBMountCandidate {
        let parsed = SMBMountCandidate.parse(origin: "//alice@\(host)/\(share)", mountPath: "/Volumes/\(share)")
        return try! XCTUnwrap(parsed, "样例挂载记录应能解析")
    }

    func testMatchesSameHostAndShare() {
        XCTAssertTrue(candidate().matches(smbEndpoint: "smb://nas.example/team"))
    }

    /// 主机名大小写不敏感：挂载表里和索引服务返回的常常一个大写一个小写。
    func testHostComparisonIgnoresCase() {
        XCTAssertTrue(candidate(host: "NAS.Example").matches(smbEndpoint: "smb://nas.example/team"))
    }

    /// 中文共享名必须匹配得上。
    ///
    /// 群晖、飞牛上的共享名大量是中文；端点里可能是百分号编码，也可能不是，
    /// 两种写法都要落在同一个共享上。
    func testMatchesPercentEncodedChineseShareName() {
        let cn = candidate(share: "示例共享")
        XCTAssertTrue(cn.matches(smbEndpoint: "smb://nas.example/示例共享"))
        XCTAssertTrue(cn.matches(smbEndpoint: "smb://nas.example/%E7%A4%BA%E4%BE%8B%E5%85%B1%E4%BA%AB"))
    }

    /// 端点里带账号的一律不算。
    ///
    /// 「这台机器已挂载的共享」和「别人给的一条带凭据的连接串」是两回事，
    /// 后者不该被当成可绑定的挂载——它根本不在这台机器上。
    func testEndpointWithCredentialNeverMatches() {
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://alice@nas.example/team"))
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://alice:pw@nas.example/team"))
    }

    func testRejectsNonSMBScheme() {
        XCTAssertFalse(candidate().matches(smbEndpoint: "https://nas.example/team"))
        XCTAssertFalse(candidate().matches(smbEndpoint: "afp://nas.example/team"))
    }

    func testDifferentHostOrShareNeverMatches() {
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://other.example/team"))
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://nas.example/other"))
    }

    /// ★ AFP 挂载也算「已连接共享」。
    ///
    /// 真机 bug：群晖 DS124 是早年用 AFP 连的，挂载表里写的是 `afpfs`。
    /// 只认 smbfs 时这台 NAS 能搜到、点开却报「尚未连接共享」——
    /// 而同一份文件在访达里明明打得开。打开用的是挂载后的路径，与协议无关。
    func testAFPMountCountsAsConnectedShare() throws {
        let afp = try XCTUnwrap(SMBMountCandidate.candidate(origin: "//admin1@10.20.30.96/李青宇",
                                                           mountPath: "/Volumes/李青宇",
                                                           fileSystem: "afpfs"))
        XCTAssertEqual(afp.host, "10.20.30.96")
        XCTAssertEqual(afp.shareName, "李青宇")
        XCTAssertEqual(afp.username, "admin1")
        XCTAssertEqual(afp.mountRoot.path, "/Volumes/李青宇")
        XCTAssertNotNil(SMBMountCandidate.candidate(origin: "//alice@nas.example/team",
                                                    mountPath: "/Volumes/team", fileSystem: "smbfs"))
    }

    /// 别的文件系统不是 NAS 共享：本地磁盘、NFS、WebDAV 都不该被认成来源的挂载。
    func testOnlyNetworkShareFilesystemsAreAccepted() {
        for fs in ["apfs", "nfs", "webdav", ""] {
            XCTAssertNil(SMBMountCandidate.candidate(origin: "//alice@nas.example/team",
                                                     mountPath: "/Volumes/team", fileSystem: fs),
                         "不该把 \(fs.isEmpty ? "空类型" : fs) 当成已连接的共享")
        }
    }

    /// 端点**没有共享段**时不算匹配：光有主机说明不了是哪个共享。
    func testEndpointWithoutShareDoesNotMatch() {
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://nas.example"))
        XCTAssertFalse(candidate().matches(smbEndpoint: "smb://nas.example/"))
    }

    /// 记录下来的既有行为：端点指向共享**下面**的子目录时仍算同一个共享。
    /// 这不是宽判——绑定的是挂载根，子路径由 relativePath 接着走。
    func testEndpointUnderShareStillMatchesTheShare() {
        XCTAssertTrue(candidate().matches(smbEndpoint: "smb://nas.example/team/2026"))
    }

    func testMalformedEndpointDoesNotMatch() {
        XCTAssertFalse(candidate().matches(smbEndpoint: ""))
        XCTAssertFalse(candidate().matches(smbEndpoint: "不是 URL"))
    }
}
