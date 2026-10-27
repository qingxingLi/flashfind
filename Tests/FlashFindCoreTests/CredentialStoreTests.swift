import XCTest
@testable import FlashFindCore

/// 凭据改存本机文件之后的回归。
///
/// 这里锁的是**行为契约**，不是实现细节：
/// 存过就读得到、没存就返回 nil、删不存在的也算成功、文件权限必须是 0600、
/// 进程重启（用清内存镜像模拟）之后仍然读得到。
/// 最后一条是这一整轮的目的：钥匙串方案恰恰在「重新构建之后」失效。
final class CredentialStoreTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-credential-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.useDirectory(directory)
    }

    override func tearDownWithError() throws {
        CredentialStore.useDirectory(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private let account = "nas-source:0000BBBB-1111-4222-8333-000000000002"

    func testSavedCredentialCanBeReadBack() throws {
        try CredentialStore.save("s3cret", account: account)
        XCTAssertEqual(CredentialStore.read(account: account), "s3cret")
    }

    func testMissingCredentialReadsAsNil() {
        XCTAssertNil(CredentialStore.read(account: "nas-source:不存在"))
    }

    func testEmptyValueReadsAsNil() throws {
        // 空串等于「没有可用密码」。以前钥匙串时代也是这么判的，
        // 保存空串会把界面拖进「按钮亮着但一点就说缺密码」的怪状态。
        try CredentialStore.save("", account: account)
        XCTAssertNil(CredentialStore.read(account: account))
    }

    func testSaveOverwritesPreviousValue() throws {
        try CredentialStore.save("old", account: account)
        try CredentialStore.save("new", account: account)
        XCTAssertEqual(CredentialStore.read(account: account), "new")
    }

    func testDeleteRemovesCredentialAndIsIdempotent() throws {
        try CredentialStore.save("s3cret", account: account)
        XCTAssertTrue(CredentialStore.delete(account: account))
        XCTAssertNil(CredentialStore.read(account: account))
        // 删不存在的条目也要算成功：移除来源时会被无条件调用。
        XCTAssertTrue(CredentialStore.delete(account: account))
    }

    func testCredentialsSurviveProcessRestart() throws {
        try CredentialStore.save("s3cret", account: account)
        // 清掉进程内镜像 = 模拟重新启动（也就是重新构建之后再打开）。
        CredentialStore.useDirectory(directory)
        XCTAssertEqual(CredentialStore.read(account: account), "s3cret")
    }

    /// 上一组用例都跑在重定向后的临时目录里，真实落点一行都没验。
    /// 这里只做**路径断言**（不写盘），把「App 实际会把密码写到哪儿」钉住 ——
    /// 这是向用户交待存储位置时最不能含糊的一件事。
    func testDefaultLocationIsUnderApplicationSupport() throws {
        CredentialStore.useDirectory(nil)
        defer { CredentialStore.useDirectory(directory) }
        let path = CredentialStore.fileURL.path
        XCTAssertTrue(path.hasSuffix("Library/Application Support/FlashFind2/credentials.json"),
                      "默认落点必须是 Application Support/FlashFind2，实际：\(path)")
        XCTAssertTrue(path.hasPrefix(NSHomeDirectory()), "必须落在本用户 home 下，实际：\(path)")
    }

    func testEmptyAccountIsRejected() {
        XCTAssertThrowsError(try CredentialStore.save("s3cret", account: ""))
    }

    /// 交互式读必须报一声：钥匙串授权框关掉之后要靠它把设置窗口提回前台。
    ///
    /// 判据是「这次读**允许系统交互**」，不是「读到了没有」—— 后台读
    /// （启动自动连接、设置页渲染）不该把窗口甩到前台，那是另一种骚扰。
    func testInteractiveReadReportsSoTheWindowCanBeBroughtBack() throws {
        var reports = 0
        CredentialStore.onInteractiveRead = { reports += 1 }
        defer { CredentialStore.onInteractiveRead = nil }

        try CredentialStore.save("s3cret", account: account)
        XCTAssertEqual(CredentialStore.read(account: account), "s3cret")
        XCTAssertEqual(reports, 0, "后台读不会弹授权框，不能报")

        XCTAssertEqual(CredentialStore.read(account: account, allowInteraction: true), "s3cret")
        XCTAssertEqual(reports, 1, "用户点的登录会弹授权框，读完必须报一声")
    }

    /// 用户点「拒绝」（或本机根本没有这条）时同样要报：
    /// 框一样弹过、窗口一样会被甩到别的 App 后面 —— 那种情况更需要救。
    func testInteractiveReadReportsEvenWhenNothingComesBack() {
        var reports = 0
        CredentialStore.onInteractiveRead = { reports += 1 }
        defer { CredentialStore.onInteractiveRead = nil }

        XCTAssertNil(CredentialStore.read(account: "nas-source:从没存过", allowInteraction: true))
        XCTAssertEqual(reports, 1, "读不到也不能把这一声吞掉")
    }

    func testFileIsOwnerReadWriteOnlyAndDirectoryIsOwnerOnly() throws {
        try CredentialStore.save("s3cret", account: account)
        let filePermissions = try permissions(of: CredentialStore.fileURL)
        XCTAssertEqual(filePermissions, 0o600, "凭据文件必须只有本人可读写")
        let directoryPermissions = try permissions(of: directory)
        XCTAssertEqual(directoryPermissions, 0o700, "凭据目录必须只有本人可进入")
    }

    func testNoTemporaryFileIsLeftBehind() throws {
        try CredentialStore.save("s3cret", account: account)
        try CredentialStore.save("s3cret2", account: account)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "写入用的临时文件必须被改名或清掉，实际残留：\(leftovers)")
    }

    func testSecureStorageFacadeStillUsesTheSameStore() throws {
        // 20 多处调用点都写着 `SecureStorage.*`，改名换不来收益，
        // 但门面必须真的落到文件存储上，不能只是「签名还在、其实没实现」。
        try SecureStorage.save("viaFacade", account: account)
        XCTAssertEqual(SecureStorage.read(account: account), "viaFacade")
        XCTAssertEqual(CredentialStore.read(account: account), "viaFacade")
        XCTAssertTrue(SecureStorage.delete(account: account))
        XCTAssertNil(CredentialStore.read(account: account))
    }

    func testFileReadsDoNotRequireInteraction() throws {
        try CredentialStore.save("s3cret", account: account)
        XCTAssertEqual(CredentialStore.read(account: account, allowInteraction: false), "s3cret")
        XCTAssertEqual(CredentialStore.read(account: account, allowInteraction: true), "s3cret")
    }

    func testSilentReadDefersAuthorizationUntilExplicitLoginAndCanRetry() {
        let store = InteractionStore()
        CredentialStore.install(store)
        XCTAssertNil(CredentialStore.read(account: account))
        XCTAssertEqual(CredentialStore.currentProblem, .notAuthorized)
        XCTAssertEqual(store.policies, [false], "启动不能变成交互式读取")
        XCTAssertEqual(CredentialStore.read(account: account, allowInteraction: true), "fixture-secret")
        XCTAssertEqual(SecureStorage.read(account: account), "fixture-secret")
        XCTAssertEqual(store.policies, [false, true, false], "授权后静默读取可复用进程内凭据")
    }

    func testCancelledAuthorizationCanBeRetriedWithoutLosingTheSavedCredential() {
        let store = InteractionStore()
        store.denyNextInteraction = true
        CredentialStore.install(store)
        XCTAssertNil(CredentialStore.read(account: account, allowInteraction: true))
        XCTAssertEqual(CredentialStore.currentProblem, .notAuthorized)
        XCTAssertNil(CredentialStore.read(account: account))
        XCTAssertEqual(CredentialStore.read(account: account, allowInteraction: true), "fixture-secret")
        XCTAssertEqual(store.policies, [true, false, true])
    }

    private final class InteractionStore: SecretStore, @unchecked Sendable {
        var policies: [Bool] = []
        var unlocked = false
        var denyNextInteraction = false
        func read(account: String) -> String? { read(account: account, allowInteraction: true) }
        func read(account: String, allowInteraction: Bool) -> String? {
            policies.append(allowInteraction)
            if allowInteraction, denyNextInteraction {
                denyNextInteraction = false
                return nil
            }
            if allowInteraction { unlocked = true }
            return unlocked ? "fixture-secret" : nil
        }
        func save(_ value: String, account: String) throws {}
        func delete(account: String) -> Bool { true }
        func allAccounts() -> [String] { [] }
        var unreadableReason: CredentialStoreProblem? { unlocked ? nil : .notAuthorized }
        func auditableAccounts() -> [String]? { nil }
        func existsForAudit(_ account: String) -> Bool? { nil }
    }

    func testInjectedDirectoryDoesNotTouchTheRealLocation() throws {
        // 测试绝不能写到用户真的凭据文件里。
        try CredentialStore.save("s3cret", account: account)
        let real = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/FlashFind2/credentials.json")
        XCTAssertNotEqual(CredentialStore.fileURL.path, real.path)
    }

    private func permissions(of url: URL) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return (attributes[.posixPermissions] as? NSNumber)?.intValue ?? -1
    }
}

/// 凭据变更审计。
///
/// ## 为什么需要它
///
/// 真机上实测到凭据文件被写成空表 `{"records":{},"version":1}`，而能写出这个结果的
/// 只有一条路径：**删掉最后一条已存在的记录**。三处删除入口（来源移除 / 关掉记住密码 /
/// 地址账号改动）留下的文件一模一样，事后完全无法判断是谁动的。
/// 所以每次真实变更都报一条，把「哪一步动过凭据」变成可核对的事实。
final class CredentialMutationAuditTests: XCTestCase {

    private var directory: URL!
    private var observed: [CredentialStore.Mutation] = []

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-audit-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.useDirectory(directory)
        observed = []
        CredentialStore.onMutation = { [weak self] mutation in self?.observed.append(mutation) }
    }

    override func tearDownWithError() throws {
        CredentialStore.onMutation = nil
        CredentialStore.useDirectory(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private let account = "nas-source:0000AAAA-1111-4222-8333-000000000001"

    func testSaveIsReportedWithoutLeakingThePassword() throws {
        try CredentialStore.save("s3cret", account: account, reason: "连接成功后保存（向导）")
        XCTAssertEqual(observed.count, 1)
        let mutation = try XCTUnwrap(observed.first)
        XCTAssertEqual(mutation.operation, .save)
        XCTAssertEqual(mutation.storedCount, 1)
        XCTAssertEqual(mutation.reason, "连接成功后保存（向导）")
        // 记录里只允许出现来源标识：账号名前缀要去掉，密码绝不能出现。
        XCTAssertEqual(mutation.sourceKey, "0000AAAA-1111-4222-8333-000000000001")
        XCTAssertFalse(mutation.sourceKey.contains("nas-source:"), "账号名前缀要脱敏掉")
        XCTAssertFalse(String(describing: mutation).contains("s3cret"), "审计记录里不许出现密码")
    }

    /// **关键一条**：删掉最后一条记录 = 文件变成空表。这正是真机上被写入的那份内容。
    func testDeletingTheLastRecordIsReportedAsAnEmptyStore() throws {
        try CredentialStore.save("s3cret", account: account, reason: "连接成功后保存（向导）")
        observed = []
        CredentialStore.delete(account: account, reason: "地址或账号已改动，旧密码不再适用")
        let mutation = try XCTUnwrap(observed.first)
        XCTAssertEqual(mutation.operation, .delete)
        XCTAssertEqual(mutation.storedCount, 0, "删掉最后一条之后剩余条数必须是 0")
        XCTAssertEqual(mutation.reason, "地址或账号已改动，旧密码不再适用")
        // 落盘内容与真机上抓到的那一份一致：空表（真机上是 `{"records":{},"version":1}`）。
        // 这里**解码**后判空，不比对字符串：JSON 的键顺序不保证，
        // 写死顺序的断言会变成一条随时可能假红的脆弱测试。
        let data = try Data(contentsOf: CredentialStore.fileURL)
        let document = try JSONDecoder().decode(DocumentStub.self, from: data)
        XCTAssertTrue(document.records.isEmpty, "删掉最后一条之后文件里应当一条都不剩")
    }

    private struct DocumentStub: Decodable {
        var version: Int
        var records: [String: String]
    }

    /// 删一条本来就不存在的**不改文件**，因此不该报告 —— 它解释不了文件为什么变空。
    func testDeletingAMissingRecordIsNotReported() {
        XCTAssertTrue(CredentialStore.delete(account: "nas-source:不存在", reason: "来源已被用户移除"))
        XCTAssertTrue(observed.isEmpty, "没写文件就不该报变更，实际：\(observed)")
    }

    /// 观察者抛错/不存在都不能影响存储本身。
    func testMissingObserverDoesNotBreakWrites() throws {
        CredentialStore.onMutation = nil
        try CredentialStore.save("s3cret", account: account)
        XCTAssertEqual(CredentialStore.read(account: account), "s3cret")
    }
}

/// 「改用明文 HTTP 重试」的判据。
final class PlainHTTPRetryOfferTests: XCTestCase {

    private func offer(allows: Bool = true, plain: Bool = false,
                       apiCode: Int? = nil, coreFailure: Bool = true) -> Bool {
        PlainHTTPRetryOffer.shouldOffer(allowsPlainHTTPChoice: allows, usesPlainHTTP: plain,
                                        coreApiCode: apiCode, isCoreFailure: coreFailure)
    }

    func testOffersWhenTransportNeverReachedTheDevice() {
        // 这正是用户遇到的那一次：WebDAV 默认走 https，设备只讲明文，
        // 失败时核心没有拿到任何 HTTP 状态码。
        XCTAssertTrue(offer())
    }

    func testDoesNotOfferWhenTheDeviceAnsweredWithAnHTTPStatus() {
        // 拿到 401 说明链路已经通了，问题在凭据 —— 把人往明文上引是误诊。
        XCTAssertFalse(offer(apiCode: 401))
        XCTAssertFalse(offer(apiCode: 404))
    }

    func testDoesNotOfferWhenAlreadyUsingPlainHTTP() {
        XCTAssertFalse(offer(plain: true))
    }

    func testDoesNotOfferForSynology() {
        // 群晖走证书固定，核心只接受 https，给这个开关等于给一个必然失败的选项。
        XCTAssertFalse(offer(allows: false))
    }

    func testDoesNotOfferForNonAdapterFailures() {
        // 缺资源、看门狗超时、内部断言失败都与协议无关。
        XCTAssertFalse(offer(coreFailure: false))
    }

    func testMessageKeepsTheCoreSentenceInFront() {
        let text = PlainHTTPRetryOffer.message(reason: "无法连接 WebDAV 服务（TLS 握手失败）")
        XCTAssertTrue(text.hasPrefix("无法连接 WebDAV 服务（TLS 握手失败）"),
                      "核心给的那句话必须原样留在最前面，不能在包装时丢掉")
        XCTAssertTrue(text.contains("明文 HTTP"))
        XCTAssertTrue(text.contains("不会替你自动"), "必须说清这不是自动降级")
    }
}

/// 凭据文件**读不出来**时，一个字节都不许写（代码审核 OSS-04）。
///
/// ## 这条要堵的是什么
///
/// 以前「文件不在 / JSON 坏了 / 版本比本程序新」三种情况一律被折叠成空表，
/// 而空表和「第一次用、还没存过」长得一模一样。于是下一次保存就拿
/// 「空表 + 这一条」**整个覆盖**文件 —— 其余 NAS 的密码当场消失，
/// 界面还继续显示「已记住」，没有任何提示。
///
/// 判据只有一条：**读不出来就不要写**。文件原样留在磁盘上，用户至少还有救。
final class CredentialStoreCorruptionGuardTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-corrupt-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.useDirectory(directory)
    }

    override func tearDownWithError() throws {
        CredentialStore.useDirectory(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    private func writeRawFile(_ text: String) throws {
        try Data(text.utf8).write(to: CredentialStore.fileURL)
    }

    private func fileText() throws -> String {
        try String(contentsOf: CredentialStore.fileURL, encoding: .utf8)
    }

    /// 三台 NAS 都存了密码。
    private let intactJSON =
        "{\"version\":1,\"records\":{\"nas-source:aaa\":\"p1\",\"nas-source:bbb\":\"p2\",\"nas-source:ccc\":\"p3\"}}"
    /// 写坏了一半：JSON 解不开，但另外两台的账号名与密码**还在文件里**。
    private let truncatedJSON =
        "{\"version\":1,\"records\":{\"nas-source:aaa\":\"p1\",\"nas-source:bbb\":\"p2\",\"nas-source:c"

    /// 基线：文件完好的时候，保存第 4 条不该挤掉前三条。
    /// 这条在修复前后都必须绿 —— 它防的是「为了堵住覆盖而把正常写入也堵死」。
    func testSavingIntoAnIntactFileKeepsTheOtherRecords() throws {
        try writeRawFile(intactJSON)
        try CredentialStore.save("p4", account: "nas-source:ddd")
        let text = try fileText()
        for key in ["nas-source:aaa", "nas-source:bbb", "nas-source:ccc"] {
            XCTAssertTrue(text.contains(key), "原有凭据 \(key) 不该被保存动作挤掉")
        }
        XCTAssertEqual(CredentialStore.storedAccountCount, 4)
    }

    /// ★ 核心一条：文件读不出来时，保存必须拒绝写盘，一个字节都不能改。
    func testSaveRefusesToWriteWhenTheFileCannotBeDecoded() throws {
        try writeRawFile(truncatedJSON)
        let before = try fileText()
        XCTAssertThrowsError(try CredentialStore.save("p9", account: "nas-source:zzz")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("凭据"), "错误要能被人看懂，实际：\(message)")
        }
        XCTAssertEqual(try fileText(), before, "读不出来的文件必须原样保留，绝不能被覆盖")
    }

    /// ★ 反过来看数据：那两台的密码必须还躺在磁盘上。
    func testSaveRefusesToClobberCredentialsItCouldNotRead() throws {
        try writeRawFile(truncatedJSON)
        XCTAssertThrowsError(try CredentialStore.save("p9", account: "nas-source:zzz"))
        let text = try fileText()
        XCTAssertTrue(text.contains("nas-source:aaa"), "看不懂的文件里那两台的密码必须还在磁盘上")
        XCTAssertTrue(text.contains("nas-source:bbb"))
    }

    /// 版本比本程序新，同样不许覆盖 —— 它是「读不懂」，不是「没有」。
    func testSaveRefusesToWriteWhenTheFileIsFromANewerVersion() throws {
        try writeRawFile("{\"version\":99,\"records\":{\"nas-source:aaa\":\"p1\"}}")
        let before = try fileText()
        XCTAssertThrowsError(try CredentialStore.save("p9", account: "nas-source:zzz"))
        XCTAssertEqual(try fileText(), before)
    }

    /// 删除也要写盘，所以同样不许动。
    func testDeleteRefusesToWriteWhenTheFileCannotBeDecoded() throws {
        try writeRawFile(truncatedJSON)
        let before = try fileText()
        XCTAssertFalse(CredentialStore.delete(account: "nas-source:aaa"),
                       "读不出来时删除也必须失败，不能拿空表覆盖")
        XCTAssertEqual(try fileText(), before)
    }

    func testReadReturnsNilWhenTheFileCannotBeDecoded() throws {
        try writeRawFile(truncatedJSON)
        XCTAssertNil(CredentialStore.read(account: "nas-source:aaa"))
    }

    /// 文件不存在 = 第一次用，必须照常能存。上面的保护不能误伤这一条。
    func testMissingFileIsStillWritable() throws {
        try CredentialStore.save("p1", account: "nas-source:aaa")
        XCTAssertEqual(CredentialStore.read(account: "nas-source:aaa"), "p1")
    }

    /// ★ 读失败必须能被外界查到，否则界面无从解释「为什么勾了记住却没存上」。
    func testTheProblemIsExposedForTheInterfaceToReport() throws {
        try writeRawFile(truncatedJSON)
        _ = CredentialStore.read(account: "nas-source:aaa")
        XCTAssertEqual(CredentialStore.currentProblem, .undecodable)
    }

    func testNewerVersionIsReportedAsSuchNotAsAnEmptyStore() throws {
        try writeRawFile("{\"version\":99,\"records\":{\"nas-source:aaa\":\"p1\"}}")
        _ = CredentialStore.read(account: "nas-source:aaa")
        XCTAssertEqual(CredentialStore.currentProblem, .newerVersion(99))
    }

    /// 文件好的时候不该有任何「问题」，否则界面会整天误报。
    func testIntactFileReportsNoProblem() throws {
        try writeRawFile(intactJSON)
        XCTAssertEqual(CredentialStore.storedAccountCount, 3)
        XCTAssertNil(CredentialStore.currentProblem)
    }

    /// 「0 条」不等于「空表」：读失败时也必须还能查到失败本身。
    func testProblemPersistsInsteadOfBeingRememberedAsEmpty() throws {
        try writeRawFile(truncatedJSON)
        XCTAssertEqual(CredentialStore.storedAccountCount, 0)
        XCTAssertNotNil(CredentialStore.currentProblem,
                        "读失败被记住成空表的话，下一次保存就会覆盖 —— 这正是要堵的")
    }

    /// 拒绝时的话必须说清「没有写入」是保护，不是磁盘故障。
    /// 说成故障的话，用户第一反应是把文件删掉 —— 那才是真丢。
    func testRefusalMessageExplainsThatNothingWasWritten() throws {
        try writeRawFile(truncatedJSON)
        XCTAssertThrowsError(try CredentialStore.save("p9", account: "nas-source:zzz")) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? ""
            XCTAssertTrue(message.contains("没有写入"), "必须说清没写入，实际：\(message)")
            XCTAssertFalse(message.contains("/Users"), "错误文案里不许出现本机路径")
        }
    }
}

/// 落盘必须**原子替换**（代码审核 OSS-05）。
///
/// 以前的写法是先 `removeItem(at: fileURL)` 再 `moveItem`：两个系统调用之间
/// 存在「凭据文件不存在」的窗口，那一刻崩掉或断电，文件就没了 ——
/// 临时文件里虽然有一份完整的，但闪寻不认它，等于全丢。
final class CredentialStoreAtomicWriteTests: XCTestCase {

    private var directory: URL!

    override func setUpWithError() throws {
        directory = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ff2-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        CredentialStore.useDirectory(directory)
    }

    override func tearDownWithError() throws {
        CredentialStore.useDirectory(nil)
        try? FileManager.default.removeItem(at: directory)
    }

    /// 去掉整行注释，否则谁在注释里提一句旧写法就会误报。
    private func storeSourceCode() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let source = try String(contentsOf: root.appendingPathComponent(
            "Sources/FlashFindCore/FileSecretStore.swift"), encoding: .utf8)
        return source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
    }

    /// 扫源码的前提是确实读到了文件，否则下面那条会假绿。
    func testStoreSourceScanActuallyReadsTheFile() throws {
        let code = try storeSourceCode()
        XCTAssertTrue(code.contains("public final class FileSecretStore"),
                      "没读到 FileSecretStore.swift，下面那条会假绿")
    }

    /// 取出一个函数体（`func <名字>` 起到缩进回退为止）。
    private func body(of name: String) throws -> String {
        let lines = try storeSourceCode().split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard let start = lines.firstIndex(where: { $0.contains("func " + name + "(") }) else {
            XCTFail("找不到函数 \(name)，相关断言会假绿"); return ""
        }
        var collected: [String] = []
        for line in lines[(start + 1)...] {
            if line == "    }" { break }
            collected.append(line)
        }
        return collected.joined(separator: "\n")
    }

    /// ★ 不许「先删后放」：中间有「文件不存在」的窗口。判据按路径分开看。
    func testPersistDoesNotDeleteTheFileBeforeReplacingIt() throws {
        let persist = try body(of: "persistLocked")
        XCTAssertFalse(persist.isEmpty, "没读到 persistLocked，下面两条会假绿")
        XCTAssertFalse(persist.contains("removeItem(at: fileURL)"),
                       "写盘路径不许先删文件再放新的，中间有「文件不存在」的窗口")
        XCTAssertTrue(persist.contains("replaceItemAt"), "必须用原子替换，旧文件在替换完成前一直要在")
    }

    /// 迁移收尾会整体删除凭据文件——那不是写盘路径，但它有个不能破的前提：先腾空。
    func testWholeFileRemovalIsOnlyForAnEmptiedStore() throws {
        let removal = try body(of: "removeStorageFile")
        XCTAssertFalse(removal.isEmpty, "没读到 removeStorageFile，这条会假绿")
        XCTAssertTrue(removal.contains("fileExists"),
                      "删之前先确认文件在；无脑 removeItem 会把失败伪装成成功")
        let caller = try coreSourceCode("CredentialStore.swift")
        let confirmed = caller.split(separator: "\n").map(String.init)
            .firstIndex { $0.contains("func confirmCredentialVerified") } != nil
        XCTAssertTrue(confirmed)
        // 调用方必须先看「记录和待验证集合都空了」，不能凭空删。
        XCTAssertTrue(caller.contains("file.allAccounts().isEmpty"),
                      "只有确认还能读到、且记录已空，才允许删掉整个凭据文件")
    }

    private func coreSourceCode(_ name: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent(
            "Sources/FlashFindCore/" + name), encoding: .utf8)
    }

    /// 覆盖写：内容要更新、权限仍须 0600、临时文件不许残留。
    func testOverwritingKeepsPermissionsAndLeavesNoTempFile() throws {
        try CredentialStore.save("p1", account: "nas-source:aaa")
        try CredentialStore.save("p2", account: "nas-source:aaa")
        XCTAssertEqual(CredentialStore.read(account: "nas-source:aaa"), "p2")
        let attributes = try FileManager.default.attributesOfItem(atPath: CredentialStore.fileURL.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: directory.path)
            .filter { $0.hasSuffix(".tmp") }
        XCTAssertTrue(leftovers.isEmpty, "临时文件不许残留，实际：\(leftovers)")
    }
}

/// 「已知不可用」与「未验证」必须分开说。
final class VendorKnownBlockerTests: XCTestCase {

    func testFnOSIsReportedAsKnownUnusable() {
        let blocker = NASSourceConfig.Vendor.fnos.knownBlocker
        XCTAssertNotNil(blocker, "飞牛已在真机上量过：HTTP 兼容层接不住 WebSocket，必须说死")
        XCTAssertTrue(blocker!.contains("WebSocket"))
        XCTAssertTrue(blocker!.contains("WebDAV"), "要给出可操作的替代：改选 WebDAV")
        XCTAssertFalse(blocker!.contains("可以先连试试"))
    }

    /// 「已下线」不能被说回「没做完」。
    ///
    /// 飞牛拿到真机结论后从「已接入未验证」降为「已下线」，文案跟着改了：
    /// 说「还没接进闪寻」会让人以为等一等就有了，而那是一次已经做完的结论。
    /// 反方向的旧坑同样要防：说成「不支持」等于抹掉真机证据。
    func testFnOSBlockerSaysRetiredNotWorkInProgress() {
        let message = NASSourceConfig.Vendor.fnos.supportMessage
        XCTAssertTrue(message.contains("下线"), "必须说清适配器已下线：\(message)")
        XCTAssertFalse(message.contains("还没接进闪寻"),
                       "已下线 ≠ 没接入，说成后者会让人以为等一等就有：\(message)")
    }

    func testFnOSSupportMessageIsTheBlockerNotAnInvitationToTry() {
        let message = NASSourceConfig.Vendor.fnos.supportMessage
        XCTAssertEqual(message, NASSourceConfig.Vendor.fnos.knownBlocker)
        XCTAssertFalse(message.contains("可以先连试试"),
                       "已知连不上的品牌不能再邀请用户去试")
    }

    func testNoBlockerClaimedWithoutDeviceEvidence() {
        // qnap / ugreen 只是「没在真机上验证过」，不能顺手说成「已知不可用」。
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen, .synology, .webdav, .smb, .generic] {
            XCTAssertNil(vendor.knownBlocker, "\(vendor.rawValue) 没有真机证据，不该有 knownBlocker")
        }
    }

    func testUnverifiedVendorsStillInviteARetry() {
        // 没有证据的仍然邀请用户试 —— 真机结果正是校准适配器唯一的数据来源。
        XCTAssertTrue(NASSourceConfig.Vendor.qnap.supportMessage.contains("可以先连试试"))
        XCTAssertTrue(NASSourceConfig.Vendor.ugreen.supportMessage.contains("可以先连试试"))
    }
}
