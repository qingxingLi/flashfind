import Foundation

/// 「AI 客户端接入提示词」——AI 设置页上那段可以直接复制给 AI 的话。
///
/// ## 为什么必须有这一段
///
/// 只给一个开关，用户知道的只是「闪寻支持 MCP」这一个事实。剩下的「用哪个程序、
/// 走什么协议、接完怎么确认接对了」全得自己去翻文档。结果是：开关打开了，
/// 界面显示「正常运行」，用户却不知道下一步做什么，最后判定成「这功能不好使」。
///
/// 这一段一次说完三件事：**用哪个可执行文件**、**stdio、无参数**、
/// **接完先做哪三步验证**。第三步是刻意的——它同时验证「配置通了」和「授权范围对」。
///
/// ## 三条硬约束
///
/// 1. **路径只能运行时拼**。App 可能被改名、被拖进 `~/Applications`，
///    写死 `/Applications/闪寻.app/...` 立刻就是一句错话。
/// 2. **内容里只有路径与工具名**，没有任何凭据、真机标识、文件名、用户名，
///    所以它天然过 `verify_clean --strict`。
/// 3. **不写任何客户端专用的配置语法**。Claude / Codex / Cursor 三家写法各不相同，
///    写一个没在真机上验过的格式，比不给更糟。这里只说「命令是这个路径、参数留空」，
///    剩下由客户端决定。
///
/// ## 为什么提示词里要提「不要猜路径」
///
/// AI 拿到一个查找工具后最容易做的错事，是照着 `file_id` 或相对路径自己拼一个
/// 绝对路径去读文件。闪寻不给绝对路径（§4.12），也从不读文件内容。这句话提前把
/// 那条路堵掉，省掉一轮「它说文件在这儿，其实不在」的误判。
public struct MCPIntegrationPrompt: Equatable, Sendable {

    /// 六个 Tool 的名字，顺序就是提示词里的顺序。
    ///
    /// ★ 「六个」这个数字**故意**在句子正文里再写一遍，不从数组长度推。
    ///   两处同时改才对得上，忘了改会被 `testThePromptListsEveryWireOperation`
    ///   抓住；如果从长度推，那句「现在不能说明有几个工具」的错误就永远看不出来。
    public static let toolNames = ["list_sources", "locate", "locate_many",
                                   "search", "get_metadata", "recent"]

    /// Helper 的绝对路径（`…/闪寻.app/Contents/Helpers/flashfind-mcp`）。
    public let helperPath: String

    public init(helperPath: String) {
        self.helperPath = helperPath
    }

    /// 从 `.app` 的位置推出包内 Helper 的路径。
    ///
    /// ★ 只看位置、**不看文件系统、也不回落到 `/Applications`**：
    ///   需求就是「App 在哪，Helper 就在哪」。回落会在一份放在别处的构建上
    ///   给出一句「去 /Applications 找」的假话，而那台机器上根本没有那个文件。
    ///
    /// ★ 用 `appendingPathComponent` 而不是字符串拼 `/Contents/...`：
    ///   传进来的 `bundleURL` 带不带尾部斜杠，结果都一样。
    public static func helperPath(forAppAt bundleURL: URL) -> String {
        bundleURL.appendingPathComponent("Contents/Helpers/flashfind-mcp").path
    }

    /// 复制给 AI 的那段话。
    ///
    /// 写成一段纯文本（不是 JSON、不是 Markdown 表格）：它是给**人和 AI 一起读**的，
    /// 粘进任何一个对话框都该原样看得懂。结构也刻意保持「配置在上、步骤在下」——
    /// 客户端只会照前几行动手，后面的步骤是给人核对用的。
    public var text: String {
        """
        请把闪寻（FlashFind）接入你这边。它是本机的一个文件查找服务，走 MCP，stdio。

        名称：flashfind
        命令：\(helperPath)
        参数：无

        能直接配置就配好，配不了就告诉我最短的手动步骤。

        接好之后按这个顺序做，每步告诉我结果：
        1. 调 list_sources，列出你现在能看到哪些来源。
        2. 调 locate，用一个关键词找一个文件（查找范围由勾选的来源决定，不接受路径参数）。
        3. 调 get_metadata 取它的 size_bytes 与 modified，再调一次 recent。

        工具就是这六个，没有别的：\(Self.toolNames.joined(separator: "、"))。
        闪寻只在用户勾选过的来源里找，不读文件内容，也不上传任何东西。
        找不到就说找不到，不要猜路径。
        """
    }
}

/// 「接入 AI 客户端」那一段的文案。
///
/// 与提示词正文分开：正文是给 AI 读的，这里几句是给**用户**读的
/// （标题、复制按钮、折叠说明、以及「还没保存」时的提示）。
public enum MCPIntegrationText {

    public static let title = "接入 AI 客户端"

    public static let copyButton = "复制接入提示词"
    public static let copied = "已复制"

    /// 还没保存时的提示。
    ///
    /// ★ 这种情况必须**单独**说一句，而不是干脆不显示这一段：用户已经把开关拨开、
    ///   正奇怪下面为什么什么都没有；一行字比一片空白好解释。
    public static let saveFirst = "保存之后，这里会出现可以复制给 AI 客户端的接入说明。"

    public static let otherClientsTitle = "换个客户端？"

    /// 折叠里的说明。只讲**闪寻这一侧**提供什么，不替任何客户端写配置格式。
    public static let otherClientsDetail = """
    各家客户端写法不一样，闪寻这边只提供一个 stdio 程序，需要你填的只有两样：命令填上面那个路径，参数留空。

    具体怎么填以各自文档里讲 MCP 的那一节为准。你不需要在这里选客户端——填进去的永远是同一个路径。
    """

    public static let footer = "把这段整个复制给 AI 客户端，它就知道该启动哪个程序、接完先验证什么。"
}
