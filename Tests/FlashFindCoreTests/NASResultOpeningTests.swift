import XCTest
@testable import FlashFindCore

final class NASResultOpeningTests: XCTestCase {
    private var root: URL!
    private let origin = WebOrigin(scheme: "https", host: "files.example.com", port: 443)!
    private let locator = NASLocator(sourceID: "source", host: "files.example.com", shares: ["A0003"],
                                     scopePrefixes: ["/A0003/"], preferredSMBUser: "tester")

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("A0003"), withIntermediateDirectories: true)
        try Data().write(to: root.appendingPathComponent("A0003/报告 100% #1?.pdf"))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: root) }

    private func row(_ path: String = "/A0003/报告 100% #1?.pdf") -> SearchResult {
        var row = SearchResult(id: "r", name: (path as NSString).lastPathComponent, relativePath: path,
                               sourceID: "source", sourceName: "OpenList", kind: "file", size: nil, localURL: nil)
        var url = URLComponents(); url.scheme = "https"; url.host = "files.example.com"; url.path = path
        row.openTarget = .webURL(url.url!)
        return row
    }
    private func mount(_ endpoint: String = "https://files.example.com/dav/", at path: URL? = nil) throws -> WebDAVMountCandidate {
        try XCTUnwrap(.parse(origin: endpoint, mountPath: (path ?? root).path))
    }
    private func target(_ row: SearchResult, mounts: [WebDAVMountCandidate] = [],
                        smb: [SMBMountCandidate] = [], vendor: NASSourceConfig.Vendor = .openlist) throws -> SearchOpenTarget {
        try NASResultOpening.target(for: row, vendor: vendor, origin: origin, locator: locator,
                                    smbMounts: smb, webDAVMounts: mounts)
    }

    func testOpenListPrefersExactWebDAVMountIncludingSpecialCharacters() throws {
        let result = row()
        XCTAssertEqual(try target(result, mounts: [mount()]),
                       .mountedFile(root.appendingPathComponent(String(result.path.dropFirst())).resolvingSymlinksInPath()))
    }
    func testNoMountAndUnmountAfterSearchFallBackToWeb() throws {
        var result = row()
        result.localURL = root.appendingPathComponent("stale.pdf")
        XCTAssertEqual(try target(result), result.openTarget, "不能相信搜索时缓存的本地路径")
    }
    func testMissingLocalFileFallsBackToWeb() throws {
        let result = row("/A0003/missing.pdf")
        XCTAssertEqual(try target(result, mounts: [mount()]), result.openTarget)
    }
    func testHostPortSchemeAndDAVPathMustAllMatch() throws {
        // 主机名不在此列：它是「同一个部署的两种写法」唯一允许变化的变量，见下面两条用例。
        for endpoint in ["https://files.example.com:8443/dav/", "http://files.example.com/dav/",
                         "https://files.example.com/other/", "https://files.example.com/davX/"] {
            let result = row()
            XCTAssertEqual(try target(result, mounts: [mount(endpoint)]), result.openTarget, endpoint)
        }
    }
    /// ★ 主机名对不上不等于「没挂载」：来源填域名、Finder 里用局域网 IP 挂是常见组合。
    ///
    /// 与群晖那条同一条理由（2026-10-29 用户要求三条线统一）。OpenList 的凭据常在钥匙串里，
    /// 挂载 URL 上没有 `user@`，所以这里靠「协议 + 端口 + `/dav` 根全等 + 本机只此一个候选」
    /// 判同一性 —— 端口不同一律不认，那是另一台机器/另一个服务的可能性太高。
    func testOpenListFindsTheOnlyDAVOnAnotherHost() throws {
        let result = row()
        let only = try mount("https://192.168.0.9/dav/")
        XCTAssertEqual(try target(result, mounts: [only]),
                       .mountedFile(root.appendingPathComponent(String(result.path.dropFirst())).resolvingSymlinksInPath()))
    }

    /// 本机挂着两个 `/dav` 时无法分辨是哪一个 ⇒ 退回网页，不猜。
    func testOpenListRefusesWhenTwoDAVCandidatesAreEquallyLikely() throws {
        let result = row()
        let first = try mount("https://192.168.0.9/dav/")
        let second = try mount("https://192.168.0.10/dav/")
        XCTAssertEqual(try target(result, mounts: [first, second]), result.openTarget)
    }

    /// 挂载 URL 带账号时按账号认，不看主机名；账号对不上也不猜。
    func testOpenListPrefersTheMountWithTheSameAccount() throws {
        let result = row()
        let mine = try mount("https://tester@192.168.0.9/dav/")
        let other = try mount("https://someone@192.168.0.10/dav/")
        XCTAssertEqual(try target(result, mounts: [mine, other]),
                       .mountedFile(root.appendingPathComponent(String(result.path.dropFirst())).resolvingSymlinksInPath()))
        XCTAssertEqual(try target(result, mounts: [other]), result.openTarget,
                       "只有一个候选但账号不是本来源的 ⇒ 不能认")
    }

    // MARK: - 飞牛：结果路径是设备坐标，只能靠 Dart 给的「共享名 + 相对段」认挂载

    private func fnosRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url.appendingPathComponent("文档"), withIntermediateDirectories: true)
        try Data().write(to: url.appendingPathComponent("文档/报告.pdf"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private func fnosRow(share: String = "李青宇") throws -> SearchResult {
        var row = SearchResult(id: "fnos", name: "报告.pdf", relativePath: "/vol1/1000/文档/报告.pdf",
                               sourceID: "fnos", sourceName: "飞牛 fnOS", kind: "file", size: nil, localURL: nil)
        var components = URLComponents()
        components.scheme = "smb"; components.host = "fn.example.net"
        components.path = "/" + share + "/文档/报告.pdf"
        row.openTarget = .smbLocation(try XCTUnwrap(components.url))
        return row
    }

    private func fnosLocator(host: String = "fn.example.net") -> NASLocator {
        NASLocator(sourceID: "fnos", host: host, shares: ["vol1"], scopePrefixes: ["/vol1/1000/"],
                   preferredSMBUser: "admin1")
    }

    private func smb(_ host: String = "10.20.30.96", _ share: String = "李青宇",
                     user: String = "admin1", at root: URL) throws -> SMBMountCandidate {
        try XCTUnwrap(SMBMountCandidate.parse(origin: "//\(user)@\(host)/\(share)", mountPath: root.path))
    }

    func testFnOSOpensTheShareMountedUnderAnotherHost() throws {
        let mountRoot = try fnosRoot()
        let mounted = try smb(at: mountRoot)
        let target = try NASResultOpening.target(for: try fnosRow(), vendor: .fnos, origin: origin,
                                                 locator: fnosLocator(), smbMounts: [mounted], webDAVMounts: [])
        XCTAssertEqual(target, .mountedFile(mountRoot.appendingPathComponent("文档/报告.pdf").resolvingSymlinksInPath()),
                       "来源填域名、Finder 用局域网 IP 挂着同账号同共享 ⇒ 必须本地打开")
    }

    func testFnOSDoesNotGuessWhenTheAccountOrShareDiffers() throws {
        let mountRoot = try fnosRoot()
        let otherAccount = try smb(user: "someone", at: mountRoot)
        let otherShare = try smb("10.20.30.96", "部门文档", at: mountRoot.appendingPathComponent("文档"))
        for mounts in [[otherAccount], [otherShare]] {
            let target = try NASResultOpening.target(for: try fnosRow(), vendor: .fnos, origin: origin,
                                                     locator: fnosLocator(), smbMounts: mounts, webDAVMounts: [])
            XCTAssertEqual(target, try fnosRow().openTarget, "账号或共享名对不上时不许猜")
        }
    }

    func testOpenListNeverUsesSameHostSMBMount() throws {
        let smb = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/A0003",
                                                       mountPath: root.appendingPathComponent("A0003").path))
        let result = row()
        XCTAssertEqual(try target(result, smb: [smb]), result.openTarget)
    }
    func testSubdirectoryMountMapsOnlyItsOwnLogicalDirectory() throws {
        let result = row()
        let sub = try mount("https://files.example.com/dav/A0003/", at: root.appendingPathComponent("A0003"))
        guard case .mountedFile = try target(result, mounts: [sub]) else { return XCTFail("子目录挂载没有被匹配") }
        let sibling = try mount("https://files.example.com/dav/A00030/", at: root.appendingPathComponent("A0003"))
        XCTAssertEqual(try target(result, mounts: [sibling]), result.openTarget)
        let directory = row("/A0003")
        XCTAssertEqual(try target(directory, mounts: [sub]), .mountedFile(root.appendingPathComponent("A0003").resolvingSymlinksInPath()))
    }
    func testWrongSourceOutOfScopeAndTraversalAreRejectedBeforeIO() throws {
        var wrongSource = row(); wrongSource.sourceID = "another"
        XCTAssertThrowsError(try target(wrongSource, mounts: [mount()]))
        for path in ["/A00030/file", "/A0003/../secret", "/A0003/./file", "/A0003//file"] {
            XCTAssertThrowsError(try target(row(path), mounts: [mount()]), path)
        }
    }
    func testSymlinkOutsideMountFallsBackToWeb() throws {
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("A0003/escape"),
                                                   withDestinationURL: root.deletingLastPathComponent())
        let result = row("/A0003/escape")
        XCTAssertEqual(try target(result, mounts: [mount()]), result.openTarget)
    }
    func testInvalidWebFallbackCannotBeUsedToReachLocalFile() throws {
        var result = row(); result.openTarget = .webURL(URL(string: "https://other.example.com/A0003/file")!)
        XCTAssertThrowsError(try target(result, mounts: [mount()]))
    }
    /// ★★ 来源填**域名**、Finder 里用**局域网 IP** 挂着同一个共享 ⇒ 必须走 SMB。
    ///
    /// 2026-10-29 真机报障：「群晖登陆域名还是打不开本地的 smb 连接」。
    /// 用户来源地址是 `nas.example.com`，访达里挂的是
    /// `smb://admin1@10.20.30.96/李青宇`，主机名永远不相等 ⇒ 旧实现判成「没挂载」，
    /// 双击开浏览器。能对上号的旁证只有「谁在登录这个共享」（SMB 账号 = NAS 账号），
    /// 所以认亲规则是「共享名 + 登录账号」，且必须只落在一台主机上。
    func testDomainSourceFindsMountBySameAccountOnAnotherHost() throws {
        let mountRoot = root.appendingPathComponent("A0003")
        let mount = try XCTUnwrap(SMBMountCandidate.parse(origin: "//tester@192.0.2.96/A0003",
                                                          mountPath: mountRoot.path))
        let result = row()
        guard case .mountedFile(let url) = try target(result, smb: [mount], vendor: .synology) else {
            return XCTFail("★ 域名来源 + 同账号的本机挂载就是同一台设备，必须本地打开（旧实现这里开浏览器）")
        }
        XCTAssertEqual(url.lastPathComponent, "报告 100% #1?.pdf")
        // 免核验那条兜底也要认得出它，否则网络卷一慢就退回网页。
        guard case .mountedFile = try NASResultOpening.unverifiedFallbackTarget(
            for: result, vendor: .synology, origin: origin, locator: locator,
            smbMounts: [mount], webDAVMounts: []) else {
            return XCTFail("兜底也要按同一规则认挂载")
        }
    }

    /// ★ 别的账号挂着的同名共享**不是**这个来源的。
    ///
    /// 两台 NAS 各挂一个「home」共享，账号不同 ⇒ 不能因为共享名撞了就当成同一台：
    /// 那样打开的是另一台设备上的同名文件，比开网页糟得多。
    func testAnotherAccountOnTheSameShareIsNotThisSource() throws {
        let mount = try XCTUnwrap(SMBMountCandidate.parse(origin: "//someone-else@192.0.2.96/A0003",
                                                          mountPath: root.appendingPathComponent("A0003").path))
        let result = row()
        guard case .webURL = try target(result, smb: [mount], vendor: .synology) else {
            return XCTFail("账号不同 ⇒ 认不出是不是同一台，宁可开网页")
        }
    }

    /// ★ 两台主机都满足「同名共享 + 同账号」⇒ 不许猜，退回网页。
    func testSameAccountOnTwoHostsFallsBackToWebInsteadOfGuessing() throws {
        let mountRoot = root.appendingPathComponent("A0003")
        let first = try XCTUnwrap(SMBMountCandidate.parse(origin: "//tester@192.0.2.96/A0003",
                                                          mountPath: mountRoot.path))
        let second = try XCTUnwrap(SMBMountCandidate.parse(origin: "//tester@192.0.2.97/A0003",
                                                           mountPath: mountRoot.path))
        let result = row()
        guard case .webURL = try target(result, smb: [first, second], vendor: .synology) else {
            return XCTFail("两台的账号和共享名都一样时，猜错就打开另一台的同名文件——必须退回网页")
        }
    }

    /// 主机精确匹配仍然是第一优先：账号对不上也照样走本地。
    ///
    /// 这一条守的是「别为了认亲把原来就对的匹配收紧了」——来源填 IP、访达里也用
    /// 同一个 IP 挂着，但挂载账号是别人（共享多用户挂载）是完全正常的情形。
    func testExactHostStillWinsEvenWhenTheAccountDiffers() throws {
        let mount = try XCTUnwrap(SMBMountCandidate.parse(origin: "//other-user@files.example.com/A0003",
                                                          mountPath: root.appendingPathComponent("A0003").path))
        guard case .mountedFile = try target(row(), smb: [mount], vendor: .synology) else {
            return XCTFail("主机名相等就已经是同一台，不该再要求账号也相等")
        }
    }

    func testSynologyUsesExactShareAndFallsBackWithoutMounting() throws {
        let result = row()
        let correct = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/A0003",
                                                           mountPath: root.appendingPathComponent("A0003").path))
        guard case .mountedFile = try target(result, smb: [correct], vendor: .synology) else {
            return XCTFail("群晖已挂载时应本地打开")
        }
        let wrong = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/other",
                                                         mountPath: root.appendingPathComponent("A0003").path))
        guard case .webURL(let url) = try target(result, smb: [wrong], vendor: .synology) else {
            return XCTFail("未匹配共享时应网页打开")
        }
        XCTAssertTrue(origin.admits(url)); XCTAssertNil(url.user); XCTAssertNil(url.password)
        let query = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems)
        XCTAssertEqual(query.first(where: { $0.name == "launchApp" })?.value, "SYNO.SDS.App.FileStation3.Instance")
        let param = try XCTUnwrap(query.first(where: { $0.name == "launchParam" })?.value)
        XCTAssertEqual(String(param.dropFirst("openfile=".count)).removingPercentEncoding, result.path)
    }
    /// ★ 免核验的兜底：**只做字符串映射，不碰文件系统**。
    ///
    /// 用户报「群晖明明挂着共享，双击却打开了浏览器」：核验要访问网络卷，
    /// 公网域名下常超出两秒预算，旧实现超时退回网页，把「确实挂着」丢了。
    /// 这条用例把挂载点故意指向一个**不存在的目录**：只要实现去看文件系统，
    /// 就拿不到本地路径 —— 也就跑不出 `.mountedFile`。
    func testUnverifiedFallbackKeepsMountedPathWithoutTouchingFiles() throws {
        let missingRoot = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let mount = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/A0003",
                                                         mountPath: missingRoot.path))
        let result = row("/A0003/missing.pdf")
        // 完整核验：文件确实不存在 ⇒ 仍退回网页（原有语义不许松）
        guard case .webURL = try target(result, smb: [mount], vendor: .synology) else {
            return XCTFail("文件不存在时必须退回网页，不能给一条打不开的本地路径")
        }
        // 免核验：主机 + 共享 + 路径归属都对上 ⇒ 给本地路径
        XCTAssertEqual(try NASResultOpening.unverifiedFallbackTarget(
            for: result, vendor: .synology, origin: origin, locator: locator,
            smbMounts: [mount], webDAVMounts: []),
                       .mountedFile(missingRoot.appendingPathComponent("missing.pdf")))
    }

    /// ★ 核验卡住时，超时必须保留挂载路径，而不是退回浏览器。
    func testTimeoutKeepsTheMountedPathInsteadOfOpeningBrowser() async throws {
        let mountRoot = root.appendingPathComponent("A0003")
        let mount = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/A0003",
                                                          mountPath: mountRoot.path))
        // 用一个**不存在的文件**：核验必然要碰文件系统，粗匹配则不需要。
        // 这样「兜底是不是免核验」这件事在测试里也能分辨出来。
        let result = row("/A0003/missing.pdf")
        let fallback = try NASResultOpening.unverifiedFallbackTarget(
            for: result, vendor: .synology, origin: origin, locator: locator,
            smbMounts: [mount], webDAVMounts: [])
        guard case .mountedFile = fallback else { return XCTFail("免核验应命中已挂载的共享") }
        let release = DispatchSemaphore(value: 0)
        let started = Date()
        let actual = try await NASResultOpening.checkMounts(fallback: fallback, timeout: 0.05) {
            release.wait()
            return result.openTarget
        }
        XCTAssertEqual(actual, fallback, "超时后必须用挂载路径，不能换成浏览器")
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        release.signal()
    }

    /// 免核验 ≠ 免校验：共享名不符、越界路径一律拒绝，绝不放宽成「同主机就认」。
    func testUnverifiedFallbackStillRejectsWrongShareAndTraversal() throws {
        let wrong = try XCTUnwrap(SMBMountCandidate.parse(origin: "//files.example.com/other",
                                                          mountPath: "/tmp/other"))
        // 群晖的网页兜底是 DS file 的 launchApp 形式，不是行里那条 webURL，
        // 所以判「有没有退回网页」用 case 匹配，不比字符串。
        guard case .webURL = try NASResultOpening.unverifiedFallbackTarget(
            for: row(), vendor: .synology, origin: origin, locator: locator,
            smbMounts: [wrong], webDAVMounts: []) else {
            return XCTFail("共享名不符时不得当成挂载")
        }
        let foreign = try XCTUnwrap(SMBMountCandidate.parse(origin: "//other.example.com/A0003",
                                                            mountPath: root.appendingPathComponent("A0003").path))
        guard case .webURL = try NASResultOpening.unverifiedFallbackTarget(
            for: row(), vendor: .synology, origin: origin, locator: locator,
            smbMounts: [foreign], webDAVMounts: []) else {
            return XCTFail("主机不符时不得当成挂载")
        }
        for path in ["/A0003/../secret", "/A0003/./file", "/A0003//file"] {
            XCTAssertThrowsError(try NASResultOpening.unverifiedFallbackTarget(
                for: row(path), vendor: .synology, origin: origin, locator: locator,
                smbMounts: [wrong], webDAVMounts: []), path)
        }
    }

    /// ★ 兜底必须走「免核验」那条路径。
    ///
    /// 这一层用行为测不到：`preferredOpenTarget` 要真的命中一条 SMB 挂载才算数，
    /// 测试机上没有。所以按本项目既有的手法扫源码切块断言——
    /// 防止有人把它「顺手改回」完整核验，那正好是用户报的那个 bug 原样复现
    /// （已挂载 + 核验超时 ⇒ 打开浏览器）。
    func testPreferredOpenTargetUsesUnverifiedFallback() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/NASResultOpening.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "func preferredOpenTarget"))
        let tail = code[start.lowerBound...]
        // 切到 `checkMounts` 之前，只留「算兜底目标」这一段。
        let end = try XCTUnwrap(tail.range(of: "checkMounts(fallback:"))
        let region = tail[..<end.lowerBound]
        XCTAssertTrue(region.contains("unverifiedFallbackTarget"),
                      "兜底目标必须用 unverifiedFallbackTarget；改回完整核验会让「已挂载但核验超时」重新变成开浏览器")
    }

    /// ★ 飞牛打开链必须先问「本机已经挂着的共享」。
    ///
    /// 这一层用行为测不到：`verifiedOpenTarget` 是 MainActor 上的实例方法，要真的连一台
    /// NAS 才能走进去。所以按本项目既有手法扫源码切块断言 —— 防止有人把这段「顺手删掉」，
    /// 那正好回到用户报的那个现象：明明挂着共享，却按域名再挂一次/开浏览器。
    func testFnOSOpeningChainAsksTheLocalMountsFirst() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent("Sources/FlashFindCore/NASSearchProvider.swift"),
                                encoding: .utf8)
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        let start = try XCTUnwrap(code.range(of: "func verifiedOpenTarget"))
        let tail = code[start.lowerBound...]
        let end = try XCTUnwrap(tail.range(of: "smbPortReachable"))
        XCTAssertTrue(tail[..<end.lowerBound].contains("localMountedTarget"),
                      "飞牛要先认本机已有的挂载；删掉它就回到「照着域名再挂一次/开浏览器」")
    }

    func testWebDAVParserRemovesCredentialsAndRejectsNonWebEndpoints() throws {
        let parsed = try mount("https://user:secret@files.example.com/dav/")
        XCTAssertNil(parsed.endpoint.user); XCTAssertNil(parsed.endpoint.password)
        XCTAssertEqual(parsed.username, "user", "账号要留下（口令不留）：认亲的第二档证据")
        XCTAssertNil(WebDAVMountCandidate.parse(origin: "smb://files.example.com/dav", mountPath: root.path))
        XCTAssertNil(WebDAVMountCandidate.parse(origin: "https://files.example.com/dav?token=secret", mountPath: root.path))
        XCTAssertNil(WebDAVMountCandidate.parse(origin: "https://files.example.com/dav", mountPath: "/"))
    }

    func testSlowMountReturnsWebBeforeBlockedFilesystemCallCompletes() async throws {
        let fallback = row().openTarget
        let release = DispatchSemaphore(value: 0)
        let finished = expectation(description: "迟到的本地核验正常收尾")
        let started = Date()
        let actual = try await NASResultOpening.checkMounts(fallback: fallback, timeout: 0.05) {
            release.wait()
            finished.fulfill()
            return .mountedFile(URL(fileURLWithPath: "/late"))
        }
        XCTAssertEqual(actual, fallback)
        XCTAssertLessThan(Date().timeIntervalSince(started), 1)
        release.signal()
        await fulfillment(of: [finished], timeout: 1)
    }

    func testResponsiveMountReturnsLocalAndErrorsArePreserved() async throws {
        let fallback = row().openTarget
        let local = SearchOpenTarget.mountedFile(root)
        let actual = try await NASResultOpening.checkMounts(fallback: fallback) { local }
        XCTAssertEqual(actual, local)
        do {
            _ = try await NASResultOpening.checkMounts(fallback: fallback) { throw FlashFindError.message("invalid") }
            XCTFail("校验错误不应被当成网页回退")
        } catch { XCTAssertEqual(error.localizedDescription, "invalid") }
    }

    func testLiveMountedWebDAVWhenConfigured() throws {
        let env = ProcessInfo.processInfo.environment
        guard let host = env["FLASHFIND_OPEN_MOUNT_HOST"], let logical = env["FLASHFIND_OPEN_MOUNT_PATH"],
              let expected = env["FLASHFIND_OPEN_MOUNT_EXPECTED"] else {
            throw XCTSkip("需要显式指定本机真实 WebDAV 挂载，不读取正式来源配置")
        }
        let origin = try XCTUnwrap(WebOrigin(scheme: "https", host: host, port: 443))
        let locator = NASLocator(sourceID: "live", host: host, shares: [], scopePrefixes: [logical + "/"], preferredSMBUser: nil)
        var row = SearchResult(id: "live", name: logical, relativePath: logical, sourceID: "live",
                               sourceName: "live", kind: "directory", size: nil, localURL: nil)
        var url = URLComponents(); url.scheme = "https"; url.host = host; url.path = logical
        row.openTarget = .webURL(try XCTUnwrap(url.url))
        let mounted = try NASResultOpening.target(for: row, vendor: .openlist, origin: origin, locator: locator,
                                                  smbMounts: [], webDAVMounts: WebDAVMountCandidate.discover())
        XCTAssertEqual(mounted, .mountedFile(URL(fileURLWithPath: expected).resolvingSymlinksInPath()))
        XCTAssertEqual(try NASResultOpening.target(for: row, vendor: .openlist, origin: origin, locator: locator,
                                                   smbMounts: [], webDAVMounts: []), row.openTarget)
    }
}
