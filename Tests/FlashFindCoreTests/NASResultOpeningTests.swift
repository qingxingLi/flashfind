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
        for endpoint in ["https://other.example.com/dav/", "https://files.example.com:8443/dav/",
                         "http://files.example.com/dav/", "https://files.example.com/other/",
                         "https://files.example.com/davX/"] {
            let result = row()
            XCTAssertEqual(try target(result, mounts: [mount(endpoint)]), result.openTarget, endpoint)
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
    func testWebDAVParserRemovesCredentialsAndRejectsNonWebEndpoints() throws {
        let parsed = try mount("https://user:secret@files.example.com/dav/")
        XCTAssertNil(parsed.endpoint.user); XCTAssertNil(parsed.endpoint.password)
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
