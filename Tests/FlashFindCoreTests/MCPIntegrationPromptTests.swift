import XCTest
@testable import FlashFindCore

/// 「接入提示词」（Phase 9-lite 追加）。
///
/// 这一段是**用户会原样复制给 AI** 的一段话。它写错不会编译失败、也不会让谁崩，
/// 只会在别人机器上表现成「AI 说它找不到这个程序」或者「AI 照着猜出来的路径去读文件」。
/// 所以这里守五件事：路径跟着包走、工具名一个不多一个不少、配置三要素齐、
/// 隐私承诺跟着一起走、绝不混进本机标识。
final class MCPIntegrationPromptTests: XCTestCase {

    /// 常规形态：装在 `/Applications`。
    private let installed = MCPIntegrationPrompt(
        helperPath: "/Applications/闪寻.app/Contents/Helpers/flashfind-mcp")

    /// 被挪走的形态：改了名、还放在 `~/Applications`。
    private let moved = MCPIntegrationPrompt(
        helperPath: "/Users/someone/Applications/闪寻 Beta.app/Contents/Helpers/flashfind-mcp")

    // MARK: - 路径

    /// 路径必须按包的位置推，不许写死安装位置。
    func testTheHelperPathFollowsTheBundle() {
        XCTAssertEqual(
            MCPIntegrationPrompt.helperPath(forAppAt: URL(fileURLWithPath: "/Applications/闪寻.app")),
            "/Applications/闪寻.app/Contents/Helpers/flashfind-mcp")
        // 改名 + 换目录。App 可以被拖到任何地方，这一句必须跟着走。
        XCTAssertEqual(
            MCPIntegrationPrompt.helperPath(
                forAppAt: URL(fileURLWithPath: "/Users/someone/Applications/闪寻 Beta.app")),
            "/Users/someone/Applications/闪寻 Beta.app/Contents/Helpers/flashfind-mcp")
    }

    /// 路径里不能出现双斜杠。
    ///
    /// ★ 实测过：`URL.path` 会把尾部斜杠吃掉（`…/闪寻.app/` → `…/闪寻.app`），
    ///   所以「字符串拼 `/Contents/...`」与 `appendingPathComponent` 结果**一样**，
    ///   拿它当变异是零效应。真正会写错、而且会坏的是给
    ///   `appendingPathComponent` 多传一个前导斜杠——那会拼出 `闪寻.app//Contents/…`。
    func testTheHelperPathNeverDoublesASlash() {
        for raw in ["/Applications/闪寻.app", "/Applications/闪寻.app/"] {
            let path = MCPIntegrationPrompt.helperPath(forAppAt: URL(fileURLWithPath: raw))
            XCTAssertFalse(path.contains("//"), "路径拼出了双斜杠：\(path)")
            XCTAssertEqual(path, "/Applications/闪寻.app/Contents/Helpers/flashfind-mcp",
                           "输入 \(raw) 时的路径不对")
        }
    }

    /// 提示词里出现的路径，就是给它的那一个；不许额外混进别的安装位置。
    func testThePromptCarriesThePathItWasGivenAndNoOther() {
        XCTAssertTrue(moved.text.contains(moved.helperPath))
        XCTAssertFalse(moved.text.contains("/Applications/闪寻.app/Contents/Helpers"),
                       "提示词里混进了写死的安装位置——包被挪走之后这句话就是错的")
    }

    // MARK: - 工具名

    /// 六个工具名 = wire 上除 `ping` 之外的全部操作。
    ///
    /// ★ 这是一条**防漂移**用例：将来加第七个 Tool 却忘了改提示词，这里立刻红。
    ///   `ping` 不算：它只走 socket，不作为 MCP Tool 暴露（见 `AuthorityWire.Operation`）。
    func testThePromptListsEveryWireOperation() {
        let exposed = AuthorityWire.Operation.allCases
            .filter { $0 != .ping }
            .map(\.rawValue)
        XCTAssertEqual(Set(MCPIntegrationPrompt.toolNames), Set(exposed))
        for name in MCPIntegrationPrompt.toolNames {
            XCTAssertTrue(installed.text.contains(name), "提示词里没有 \(name)")
        }
    }

    /// 正文里「这六个」这个数字与数组长度对得上。
    ///
    /// ★ 数字是**故意硬写**在句子里的（不从 `count` 推）：两处同时改才对得上，
    ///   只改一处会在这里红。从 `count` 推的话，「多了一个工具、句子还说六个」这种
    ///   错误永远看不出来。
    func testTheSpelledOutCountMatchesTheToolList() {
        XCTAssertEqual(MCPIntegrationPrompt.toolNames.count, 6)
        XCTAssertTrue(installed.text.contains("这六个"), "数字与工具列表脱节了")
    }

    // MARK: - 配置与验证步骤

    /// 配置三要素：名称、通道（stdio）、参数（留空）。
    func testThePromptPinsStdioAndEmptyArguments() {
        XCTAssertTrue(installed.text.contains("stdio"))
        XCTAssertTrue(installed.text.contains("参数：无"))
        XCTAssertTrue(installed.text.contains("flashfind"))
    }

    /// 接完先做三步，且第一步必须是 `list_sources`——
    /// 它一步同时验证「配置通了」与「授权范围对」，是唯一有这种双重作用的调用。
    func testTheThreeVerificationStepsStartWithListSources() {
        for marker in ["1. 调 list_sources", "2. 调 locate", "3. 调 get_metadata"] {
            XCTAssertTrue(installed.text.contains(marker), "缺少验证步骤：\(marker)")
        }
        XCTAssertTrue(installed.text.contains("recent"), "第三步没有落到 recent")
    }

    /// 第 2 步不许诱导 AI 传目录参数。
    ///
    /// ★ 2026-10-23 实测：旧文案「在我提到的目录里找一个文件」会让 AI 给 locate 传
    ///   `root=…`，必然撞 `Unknown argument 'root'`，AI 就误判「工具坏了」。
    ///   locate/search 只收关键词，范围由勾选的来源决定——这句话必须明说。
    func testTheLocateStepRejectsPathArguments() {
        XCTAssertTrue(installed.text.contains("不接受路径参数"),
                      "第 2 步没有声明 locate 不收路径参数")
        XCTAssertTrue(installed.text.contains("查找范围由勾选的来源决定"),
                      "第 2 步没有说清范围来自勾选的来源")
        XCTAssertFalse(installed.text.contains("在我提到的目录"),
                       "又出现了诱导传目录的旧文案")
    }

    /// AI 拿到查找工具后最容易做的错事，是照着相对路径自己拼绝对路径去读文件。
    /// 闪寻不给绝对路径，也从不读文件内容，这句话必须提前把那条路堵掉。
    func testThePromptForbidsGuessingPaths() {
        XCTAssertTrue(installed.text.contains("不要猜路径"))
    }

    /// 隐私承诺要跟着提示词一起走：只在勾选来源里找、不读内容、不上传。
    func testThePromptCarriesThePrivacyPromise() {
        XCTAssertTrue(installed.text.contains("勾选"))
        XCTAssertTrue(installed.text.contains("不读文件内容"))
        XCTAssertTrue(installed.text.contains("不上传"))
    }

    // MARK: - 卫生

    /// ★ 这段文字是要给人复制的，绝不能带本机标识。
    ///
    /// 它也是 `verify_clean --strict` 的天然通道：源文件里只有相对路径，
    /// 真正的路径在运行时才拼出来。
    func testThePromptCarriesNoMachineIdentifiers() {
        for token in ["/Users/", "192.168.", "password", "密码", "token"] {
            XCTAssertFalse(installed.text.contains(token), "提示词里混进了 \(token)")
        }
    }

    /// 折叠说明只讲**闪寻这一侧**填什么，不替任何客户端写配置格式。
    ///
    /// 三家客户端的写法各不相同，写一个没在真机上验过的格式，比不给更糟。
    func testTheOtherClientsNoteNamesNoClientSyntax() {
        let note = MCPIntegrationText.otherClientsDetail
        for forbidden in ["config.toml", "mcpServers", "claude mcp add"] {
            XCTAssertFalse(note.contains(forbidden),
                           "折叠说明里写了没验证过的客户端语法：\(forbidden)")
        }
        XCTAssertTrue(note.contains("命令"), "没说清要填的是命令")
        XCTAssertTrue(note.contains("参数"), "没说清参数留空")
    }
}
