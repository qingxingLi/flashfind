import XCTest

/// `flashfind-mcp` 的打包身份契约（Phase 10）。
///
/// Helper 是**独立命令行可执行文件**，躺在 `闪寻.app/Contents/Helpers/` 里，
/// `Bundle.main` 不指向宿主 App。实测在那个位置 `Bundle.main.infoDictionary`
/// 就是 `nil`，`AppVersion.machineReadable` 会回落成 `0.0.0-dev`，于是 MCP 客户端
/// 握手拿到的 `serverInfo.version` 是个假值——而 Phase 10 的硬 Gate 要它等于
/// 发布版本号。
///
/// 修法是链接期把 `Resources/Packaging/HelperInfo.plist` 嵌进 Mach-O 的
/// `__TEXT,__info_plist`（见 `Package.swift`）。于是版本事实变成**两份文件**：
/// 主 `Info.plist` 是唯一出处，`HelperInfo.plist` 是它的派生副本。
///
/// 两份文件不一致时不会有任何编译错误、不会有任何测试变红——只会让发布出去的
/// Helper 报一个错版本号，而这件事**只在用户机器上才看得见**。所以这里逐字比对。
///
/// 这些断言读的是仓库里的真实文件（不是传进来的假数据）：要防的正是「有人改了
/// 主 plist 忘记同步派生副本」这种真实漏改，用假 fixture 就防不住了。
final class HelperPackagingTests: XCTestCase {

    private var packaging: URL {
        // …/client/Tests/FlashFindCoreTests/HelperPackagingTests.swift
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // …/Tests/FlashFindCoreTests
            .deletingLastPathComponent()   // …/Tests
            .deletingLastPathComponent()   // …/client
            .appendingPathComponent("Resources/Packaging")
    }

    private func plist(_ name: String, file: StaticString = #filePath, line: UInt = #line) -> [String: Any] {
        let url = packaging.appendingPathComponent(name)
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("missing packaging file: \(url.path)", file: file, line: line)
            return [:]
        }
        guard let parsed = try? PropertyListSerialization.propertyList(from: data, format: nil),
              let dict = parsed as? [String: Any] else {
            XCTFail("not a plist dictionary: \(url.path)", file: file, line: line)
            return [:]
        }
        return dict
    }

    /// 派生副本的版本必须与主 plist 逐字相同。
    func testHelperVersionMatchesTheApp() {
        let app = plist("Info.plist")
        let helper = plist("HelperInfo.plist")
        XCTAssertEqual(helper["CFBundleShortVersionString"] as? String,
                       app["CFBundleShortVersionString"] as? String,
                       "HelperInfo.plist 的短版本必须与 Info.plist 一致；改版本号时两份一起改")
        XCTAssertEqual(helper["CFBundleVersion"] as? String,
                       app["CFBundleVersion"] as? String,
                       "HelperInfo.plist 的构建号必须与 Info.plist 一致；改版本号时两份一起改")
    }

    /// 空值同样危险：`serverInfo.version` 变成 null 时客户端会当成「未知版本」，
    /// 而 Gate 断言的是具体版本号。
    func testBothVersionKeysAreActuallyFilled() {
        for name in ["Info.plist", "HelperInfo.plist"] {
            let dict = plist(name)
            let short = dict["CFBundleShortVersionString"] as? String ?? ""
            let build = dict["CFBundleVersion"] as? String ?? ""
            XCTAssertFalse(short.trimmingCharacters(in: .whitespaces).isEmpty, "\(name) 缺少短版本")
            XCTAssertFalse(build.trimmingCharacters(in: .whitespaces).isEmpty, "\(name) 缺少构建号")
        }
    }

    /// 身份从主 App 派生：`com.flashfind.v2` → `com.flashfind.v2.mcp`。
    ///
    /// 写成「派生」而不是「写死 expected 字符串」，是为了让「主 App 换标识符」
    /// 这件事只改一处；两条并列写死的话，改一条忘一条也没人拦得住。
    func testHelperIdentifierIsDerivedFromTheApp() {
        let appID = plist("Info.plist")["CFBundleIdentifier"] as? String ?? ""
        XCTAssertFalse(appID.isEmpty, "主 Info.plist 缺少 CFBundleIdentifier")
        XCTAssertEqual(plist("HelperInfo.plist")["CFBundleIdentifier"] as? String, appID + ".mcp")
    }

    /// `CFBundleExecutable` 必须就是打包后的文件名。
    ///
    /// 嵌进 `__TEXT,__info_plist` 的 plist 描述的就是这个二进制自己；名字对不上时
    /// `Bundle.main.executablePath` 一类 API 会指到不存在的文件，而 `infoDictionary`
    /// 仍然读得到——这种半对的状态最难查。
    func testHelperExecutableNameMatchesThePackagedFileName() {
        XCTAssertEqual(plist("HelperInfo.plist")["CFBundleExecutable"] as? String, "flashfind-mcp")
    }

    /// 键集合是闭集。
    ///
    /// 嵌入的 plist 只该描述「我是谁、我几版」。混进 `LSUIElement`、`NSAppleEvents…`
    /// 这类只对 App 生效的键，说明有人把主 plist 整个拷了一份过来——那份副本以后
    /// 就会跟着主 plist 一起漂移，而 Helper 根本不需要其中任何一个。
    func testHelperPlistCarriesOnlyBundleIdentityKeys() {
        let expected: Set<String> = [
            "CFBundleIdentifier",
            "CFBundleName",
            "CFBundleExecutable",
            "CFBundlePackageType",
            "CFBundleShortVersionString",
            "CFBundleVersion",
        ]
        XCTAssertEqual(Set(plist("HelperInfo.plist").keys), expected)
    }
}
