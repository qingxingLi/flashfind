import XCTest
@testable import FlashFindCore

/// 「检查更新」的判定。
///
/// 这里钉的是三处**看起来对、实际会错**的地方：
///
/// 1. 版本号必须按数字段比 —— `1.0.10` 比 `1.0.9` 新，按字符串比结论正好相反；
/// 2. 返回体字段名 —— 把 `tag_name` 写成 `name` 不会报错，只会永远「已是最新」；
/// 3. 请求本身 —— GitHub 缺 `User-Agent` 直接 403，表现为「永远查不了」。
///
/// 全部用注入的假 `transport`，不碰网络：真实请求会让用例随 GitHub 的
/// 状态与限流变红，那种红没有任何信息量。
final class UpdateCheckTests: XCTestCase {

    /// 假传输里要记的东西（引用类型，闭包里可写）。
    private final class Recorder {
        var request: URLRequest?
    }

    private func response(_ code: Int,
                          url: URL = UpdateCheck.latestReleaseAPI) -> HTTPURLResponse {
        HTTPURLResponse(url: url, statusCode: code, httpVersion: "HTTP/1.1", headerFields: nil)!
    }

    private func releaseJSON(tag: String,
                             page: String? = "https://github.com/qingxingLi/flashfind/releases/tag/v1.0.2") -> Data {
        var object: [String: Any] = ["tag_name": tag]
        if let page { object["html_url"] = page }
        return try! JSONSerialization.data(withJSONObject: object)
    }

    // MARK: - 版本号比较

    /// ★ 按数字比，不按字符串比。
    ///
    /// `"1.0.10" > "1.0.9"` 在字符串里是 `false`——第 5 个字符 `1` 小于 `9`。
    /// 真按字符串比，第 10 个补丁版发布后所有用户都会被告知「已是最新」。
    func testNumericComparisonIsNotLexicographic() {
        XCTAssertTrue(UpdateCheck.isNewer("1.0.10", than: "1.0.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0.9", than: "1.0.10"))
        XCTAssertTrue(UpdateCheck.isNewer("1.10.0", than: "1.9.9"))
        XCTAssertTrue(UpdateCheck.isNewer("2.0", than: "1.99.99"))
    }

    /// ★ 段数不同时缺的段按 0 补：`1.0` 与 `1.0.0` 是同一个版本。
    ///
    /// 不补 0 的话，比较会在短的那一侧越界，或者把「1.0.1」判成比「1.0」旧。
    func testMissingSegmentsCountAsZero() {
        XCTAssertFalse(UpdateCheck.isNewer("1.0.0", than: "1.0"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0"))
        XCTAssertTrue(UpdateCheck.isNewer("1.1", than: "1.0.9"))
        XCTAssertFalse(UpdateCheck.isNewer("1.0", than: "1.0.1"))
    }

    /// 标签习惯带 `v`，两种前缀都要认；大小写都算。
    func testTagPrefixIsIgnored() {
        XCTAssertTrue(UpdateCheck.isNewer("v1.0.2", than: "1.0.1"))
        XCTAssertTrue(UpdateCheck.isNewer("V1.1.0", than: "v1.0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.0.1", than: "1.0.1"))
    }

    /// 同一个版本不算「有新版本」——否则每次检查都会报「有新版本 1.0.1」。
    func testSameVersionIsNotNewer() {
        XCTAssertFalse(UpdateCheck.isNewer("1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateCheck.isNewer("v1.0.1", than: "1.0.1"))
        XCTAssertFalse(UpdateCheck.isNewer(" 1.0.1 ", than: "1.0.1"))
    }

    /// ★ 同号的预发布版比正式版旧。
    ///
    /// 反过来说：用户手上是 `1.0.1` 正式版时，`1.0.1-beta` 不该提示升级。
    func testPrereleaseIsOlderThanTheSameStableVersion() {
        XCTAssertFalse(UpdateCheck.isNewer("1.0.1-beta", than: "1.0.1"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.1", than: "1.0.1-beta"))
        XCTAssertTrue(UpdateCheck.isNewer("1.0.2-beta", than: "1.0.1"))
    }

    /// 「开发构建」这类没有数字的版本号不可比较。
    func testDevBuildHasNothingToCompare() {
        XCTAssertFalse(UpdateCheck.isComparable("开发构建"))
        XCTAssertFalse(UpdateCheck.isComparable(""))
        XCTAssertFalse(UpdateCheck.isComparable("v"))
        XCTAssertFalse(UpdateCheck.isComparable("1..0"))
        XCTAssertTrue(UpdateCheck.isComparable("1.0.1"))
        XCTAssertTrue(UpdateCheck.isComparable("v1.0.1"))
    }

    /// 展示用版本号去掉 `v`。
    func testDisplayTagDropsThePrefix() {
        XCTAssertEqual(UpdateCheck.displayTag("v1.0.2"), "1.0.2")
        XCTAssertEqual(UpdateCheck.displayTag(" V1.0.2 "), "1.0.2")
        XCTAssertEqual(UpdateCheck.displayTag("1.0.2"), "1.0.2")
    }

    // MARK: - 解析

    func testParseReadsTagAndPage() throws {
        let parsed = try UpdateCheck.parseLatestRelease(releaseJSON(tag: "v1.0.2"))
        XCTAssertEqual(parsed.tag, "v1.0.2")
        XCTAssertEqual(parsed.page?.absoluteString,
                       "https://github.com/qingxingLi/flashfind/releases/tag/v1.0.2")
    }

    /// ★ 没有 `html_url` 也要能解析出标签——页面地址只影响「点哪儿」，
    /// 不该让整次检查失败。
    func testParseWithoutPageStillYieldsTheTag() throws {
        let parsed = try UpdateCheck.parseLatestRelease(releaseJSON(tag: "v1.0.2", page: nil))
        XCTAssertEqual(parsed.tag, "v1.0.2")
        XCTAssertNil(parsed.page)
    }

    /// 解析失败必须抛，不能被当成「已是最新」。
    func testParseRejectsAnythingWithoutATag() {
        for body in ["not json", "[]", "{}", #"{"tag_name":""}"#, #"{"name":"v9.9.9"}"#] {
            XCTAssertThrowsError(try UpdateCheck.parseLatestRelease(Data(body.utf8)),
                                 "这段内容不该被当成有效的发布信息：\(body)")
        }
    }

    /// ★ 只放行 http/https：这个地址随后会交给「用浏览器打开」，
    /// `file://` 之类的 scheme 不能从网络返回体里被塞进来。
    func testOnlyWebPagesAreAccepted() throws {
        let parsed = try UpdateCheck.parseLatestRelease(
            releaseJSON(tag: "v1.0.2", page: "file:///etc/passwd"))
        XCTAssertNil(parsed.page)

        let javascript = try UpdateCheck.parseLatestRelease(
            releaseJSON(tag: "v1.0.2", page: "javascript:alert(1)"))
        XCTAssertNil(javascript.page)
    }

    // MARK: - 一次检查

    func testNewerTagBecomesAnUpdateOffer() async {
        let outcome = await UpdateCheck.evaluate(current: "1.0.1") { [self] _ in
            (releaseJSON(tag: "v1.0.2"), response(200))
        }
        XCTAssertEqual(outcome, .updateAvailable(
            latest: "1.0.2",
            page: URL(string: "https://github.com/qingxingLi/flashfind/releases/tag/v1.0.2")))
    }

    func testSameTagStaysUpToDate() async {
        let outcome = await UpdateCheck.evaluate(current: "1.0.1") { [self] _ in
            (releaseJSON(tag: "v1.0.1"), response(200))
        }
        XCTAssertEqual(outcome, .upToDate(current: "1.0.1"))
    }

    /// ★ 开发构建不该发请求。
    ///
    /// 没有版本号可比还去打扰 GitHub，只会换回一个没人看得懂的结论；
    /// 这条同时钉住「拦截发生在请求之前」。
    func testDevBuildIsReportedAsIncomparableWithoutTouchingTheNetwork() async {
        let recorder = Recorder()
        let outcome = await UpdateCheck.evaluate(current: "开发构建") { _ in
            // 只要这个闭包被执行，下面那条断言就会红。
            recorder.request = URLRequest(url: UpdateCheck.latestReleaseAPI)
            throw URLError(.badServerResponse)
        }
        XCTAssertEqual(outcome, .incomparable(current: "开发构建"))
        XCTAssertNil(recorder.request, "开发构建没有可比的版本号，不该发出请求")
    }

    /// ★ 403 是限流，不是断网。说错方向会让用户一直盯着网络重试。
    func testRateLimitIsExplainedInsteadOfSwallowed() async {
        let outcome = await UpdateCheck.evaluate(current: "1.0.1") { [self] _ in
            (releaseJSON(tag: "v9.9.9"), response(403))
        }
        guard case .failed(let reason) = outcome else {
            return XCTFail("403 必须落到 failed，实际是 \(outcome)")
        }
        XCTAssertEqual(reason, UpdateCheck.Failure.httpStatus(403).text)
        XCTAssertTrue(reason.contains("频率"), "限流要说清楚是查询频率，不是网络问题：\(reason)")
        XCTAssertFalse(reason.contains("9.9.9"), "状态码不是 200 时，返回体里的版本号不能当结果")
    }

    /// 断网、超时统一落到 failed，并保留系统给的原因。
    func testTransportErrorIsReportedAsAFailure() async {
        let outcome = await UpdateCheck.evaluate(current: "1.0.1") { _ in
            throw URLError(.notConnectedToInternet)
        }
        guard case .failed(let reason) = outcome else {
            return XCTFail("网络错误必须落到 failed，实际是 \(outcome)")
        }
        XCTAssertTrue(reason.hasPrefix("连不上 GitHub"), reason)
    }

    /// 不是 HTTP 响应（理论上不会发生）也不能被当成成功。
    func testNonHTTPResponseIsAFailure() async {
        let outcome = await UpdateCheck.evaluate(current: "1.0.1") { _ in
            (Data(), URLResponse(url: UpdateCheck.latestReleaseAPI,
                                 mimeType: nil,
                                 expectedContentLength: 0,
                                 textEncodingName: nil))
        }
        guard case .failed = outcome else {
            return XCTFail("没有状态码就不能当成查成功，实际是 \(outcome)")
        }
    }

    /// ★ 请求本身要合规：地址对、带 User-Agent、不走缓存。
    ///
    /// 缺 `User-Agent` 时 GitHub 直接 403，现象是「永远查不了」；
    /// 走缓存则刚发的新版可能查不到，用户以为没更新。
    func testRequestLooksLikeAnAppAndSkipsTheCache() async throws {
        let recorder = Recorder()
        _ = await UpdateCheck.evaluate(current: "1.0.1") { [self] request in
            recorder.request = request
            return (releaseJSON(tag: "v1.0.1"), response(200))
        }
        let request = try XCTUnwrap(recorder.request)
        XCTAssertEqual(request.url, UpdateCheck.latestReleaseAPI)
        XCTAssertEqual(request.httpMethod, "GET")
        XCTAssertEqual(request.cachePolicy, .reloadIgnoringLocalCacheData)
        XCTAssertEqual(request.value(forHTTPHeaderField: "User-Agent"), "FlashFind/1.0.1",
                       "GitHub 要求带 User-Agent，缺了直接 403")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Accept"), "application/vnd.github+json")
    }

    /// ★ 仓库地址只能写对一次。
    ///
    /// 拼错用户名或仓名不会报错，只会永远 404 —— 表现成「检查更新坏了」。
    func testEndpointPointsAtThePublicRepository() {
        XCTAssertEqual(UpdateCheck.repository, "qingxingLi/flashfind")
        XCTAssertEqual(UpdateCheck.latestReleaseAPI.host, "api.github.com")
        XCTAssertEqual(UpdateCheck.latestReleaseAPI.path,
                       "/repos/qingxingLi/flashfind/releases/latest")
        XCTAssertEqual(UpdateCheck.releasesPage.absoluteString,
                       "https://github.com/qingxingLi/flashfind/releases")
        XCTAssertEqual(UpdateCheck.latestReleaseAPI.scheme, "https")
    }

    // MARK: - 文案

    func testMessagesExplainEachOutcome() {
        XCTAssertEqual(UpdateCheckText.message(for: .upToDate(current: "1.0.1")),
                       "已是最新版本（1.0.1）。")
        XCTAssertEqual(UpdateCheckText.message(for: .updateAvailable(latest: "1.0.2", page: nil)),
                       "有新版本 1.0.2 可以下载。")
        XCTAssertEqual(UpdateCheckText.message(for: .incomparable(current: "开发构建")),
                       "当前是开发构建，没有可比较的版本号。")
        XCTAssertEqual(UpdateCheckText.message(for: .failed(reason: "断网了")),
                       "检查失败：断网了")
    }

    func testButtonSaysWhatItIsDoing() {
        XCTAssertEqual(UpdateCheckText.button(checking: false), "检查更新")
        XCTAssertEqual(UpdateCheckText.button(checking: true), "正在检查…")
    }

    /// ★ 只在有东西可点时才给按钮，且地址不会落空。
    ///
    /// 「已是最新」旁边摆一个按钮、点了没反应，比不摆更糟。
    func testOnlyActionableOutcomesGetALink() {
        XCTAssertNil(UpdateCheckText.linkTitle(for: .upToDate(current: "1.0.1")))
        XCTAssertNil(UpdateCheckText.linkTitle(for: .incomparable(current: "开发构建")))
        XCTAssertEqual(UpdateCheckText.linkTitle(for: .updateAvailable(latest: "1.0.2", page: nil)),
                       "前往下载")
        XCTAssertEqual(UpdateCheckText.linkTitle(for: .failed(reason: "断网了")), "打开发布页")

        XCTAssertNil(UpdateCheckText.link(for: .upToDate(current: "1.0.1")))
        XCTAssertNil(UpdateCheckText.link(for: .incomparable(current: "开发构建")))

        let page = URL(string: "https://github.com/qingxingLi/flashfind/releases/tag/v1.0.2")!
        XCTAssertEqual(UpdateCheckText.link(for: .updateAvailable(latest: "1.0.2", page: page)), page)
        XCTAssertEqual(UpdateCheckText.link(for: .updateAvailable(latest: "1.0.2", page: nil)),
                       UpdateCheck.releasesPage,
                       "返回体没给页面时退回发版列表，那里一定有这一版")
        XCTAssertEqual(UpdateCheckText.link(for: .failed(reason: "断网了")),
                       UpdateCheck.releasesPage,
                       "查不成也要让用户能自己去看")
    }
}
