import Foundation

public enum FlashFindError: LocalizedError {
    case message(String)
    /// 核心报上来的失败：`kind` 是机器可判别的种类，`reason` 是核心那边
    /// 写好的**给人看的一句话**（可含设备原文，例如「TLS 握手失败」）。
    ///
    /// 为什么要有这个区分：`errorDescription` 必须继续返回 `kind`，
    /// 因为既有代码里到处是 `localizedDescription.contains("AuthenticationFailed")`
    /// 这类判断；直接把它换成中文句子会静默改掉这些分支的行为。
    /// 而 `reason` 只用来生成界面文案，两者各走各的。
    case coreFailure(kind: String, reason: String?, apiCode: Int?)
    public var errorDescription: String? {
        switch self {
        case let .message(text): return text
        case let .coreFailure(kind, _, _): return kind
        }
    }
    /// 核心给出的「人话原因」。没有时为 nil，界面按 `kind` 自行生成。
    public var coreReason: String? {
        if case let .coreFailure(_, reason, _) = self { return reason }
        return nil
    }
    public var coreApiCode: Int? {
        if case let .coreFailure(_, _, apiCode) = self { return apiCode }
        return nil
    }
}

public struct SearchResult: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var relativePath: String
    public var sourceID: String?
    public var sourceName: String
    public var kind: String
    public var size: Int64?
    public var localURL: URL?
    public var rank: Int
    /// 综合排序分（0…1）：匹配度 0.72 + 修改时间新近度 0.28，见 `SearchRanking`。
    ///
    /// ★ 默认 `0` 有明确含义：**这条结果没被评分**。`SearchResultMerge` 的
    /// 排序键在「两侧都是 0」时会退回旧的 `(rank, name, id)` 口径 ——
    /// 这样预览/夹具/既有测试里那些手工造的 `SearchResult` 行为完全不变，
    /// 而真实搜索路径（`NASSearchProvider.result` 等）一定会写入分数。
    ///
    /// ★ 不许在界面里现算：它是**一行一次**的成本，必须跟 `rank` 一起
    /// 在结果行生成时算完（2000 行的教训见 `DeviceTimestamp`）。
    public var score: Double = 0
    public var modifiedDate: Date?
    public var sourceType: SearchSourceType = .nas
    public var isOnline = true
    public var openTarget: SearchOpenTarget = .unavailable
    /// 这条结果是否只能通过**网页**打开。
    ///
    /// 视图层只关心这一个布尔（决定右键菜单显示哪些动作），不必在每个菜单项里
    /// 展开 `case .webURL`。判定只认 `openTarget`：`canOpen` 表示「此刻可定位」，
    /// 语义不同，混用会让 SMB 行也被当成网页行。
    public var hasWebOpenTarget: Bool {
        if case .webURL = openTarget { return true }
        return false
    }
    public var canOpen = false
    public var path: String { relativePath }
    public var fileType: String = "file"
    public var connectionID: String?
    public var connectionName: String?
    public var accountProfile: String?
    public var permissionRevision: UInt64
    public var displayPath: String { sourceID == nil ? relativePath : SMBPath.display(relativePath) }
    public init(id: String, name: String, relativePath: String, sourceID: String?, sourceName: String,
                kind: String, size: Int64?, localURL: URL?, rank: Int = 3,
                connectionID: String? = nil, connectionName: String? = nil,
                accountProfile: String? = nil, permissionRevision: UInt64 = 0) {
        self.id = id; self.name = name; self.relativePath = relativePath; self.sourceID = sourceID
        self.sourceName = sourceName; self.kind = kind; self.size = size; self.localURL = localURL; self.rank = rank
        self.fileType = kind == "directory" ? "folder" : (localURL?.pathExtension.isEmpty == false ? localURL!.pathExtension : "file")
        self.sourceType = localURL == nil ? .nas : .local
        if let localURL { self.openTarget = .mountedFile(localURL); self.canOpen = FileManager.default.fileExists(atPath: localURL.path) }
        self.connectionID = connectionID; self.connectionName = connectionName
        self.accountProfile = accountProfile; self.permissionRevision = permissionRevision
    }
}

public enum RelativePath {

    /// 「安全的相对路径」的**唯一判定**：非空、不带前导斜杠、不含 NUL、
    /// 且没有空段 / `.` / `..`（尾随斜杠也算空段）。
    ///
    /// ★ 单独拆出来是因为它现在有两个消费者：`validate`（给用户报中文错）
    /// 与 `FileID.make`（给自己的 `MakeError`）。两处各写一份正则，
    /// 结果就是「能打开的路径」与「能生成 id 的路径」慢慢不是同一个集合。
    public static func isSafe(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0") else { return false }
        return !path.split(separator: "/", omittingEmptySubsequences: false)
            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
    }

    public static func validate(_ path: String) throws {
        guard isSafe(path) else {
            throw FlashFindError.message("文件路径不安全，已阻止访问。请回到搜索窗重新选择。")
        }
    }

    // MARK: - 规范化（方案 §3.2.1，Phase 6.3b-0 落成）

    /// 规范化的失败。**只有拒绝，没有「修补」**：
    /// 把越界路径钳到根会让 `../../secret/x` 与根内真实文件 `secret/x` 撞同一个 `file_id`
    /// （§3.2.1.1 有实测反例），那比「这条结果被跳过」严重得多。
    public enum CanonicalError: Error, Equatable, Sendable {
        /// 规范到空（空串、`/`、`.`、`//`）。它不是任何文件。
        case empty(raw: String)
        /// `..` 弹栈时栈已空：路径跑到了来源根之外。
        case escapesSourceRoot(raw: String)
    }

    /// 把 provider 给的路径变成**来源根之下的规范相对路径**（方案 §3.2.1 五条规则）：
    ///
    /// ```text
    /// ① 反斜杠 → 正斜杠
    /// ② 拆段：丢空段与 "."；".." 栈非空则回退，栈空则拒绝
    /// ③ 用 "/" 重新连接
    /// ④ 整串 NFC（APFS 给 NFC、SMB/AFP 给 NFD，不归一同一文件会有两个 file_id）
    /// ⑤ 去前导/尾随斜杠
    /// ```
    ///
    /// ## 它和 `isSafe` 的分工（别合并）
    ///
    /// `isSafe` 是**判定**：安全的相对路径长什么样，不合格就拒。`canonical` 是**收敛**：
    /// 把 provider 的原始形态变成那个样子。合并成一个函数的话，「判定」会悄悄带上
    /// 「修补」的副作用，而修补正是会让两个不同入参产出同一个身份的那类操作。
    ///
    /// ## 为什么这里可以吞掉前导斜杠
    ///
    /// 实测（`04-测试与验收/mcp-phase6-3b0-preflight-20261020/provider-path-probe.txt`）：
    /// 本机 provider 给的是绝对路径（`/Users/…`），NAS 核心给的是设备根路径（`/允许共享/…`）。
    /// 前导斜杠是「从来源根算起」的写法差异，不是信息——来源根由 `source_id` 表达。
    /// 而 `..` 是信息（它指向根外），所以一个是剥、一个是拒。
    public static func canonical(_ raw: String) throws -> String {
        var parts: [Substring] = []
        for segment in raw.replacingOccurrences(of: "\\", with: "/").split(separator: "/") {
            if segment == "." { continue }
            if segment == ".." {
                guard !parts.isEmpty else { throw CanonicalError.escapesSourceRoot(raw: raw) }
                parts.removeLast()
                continue
            }
            parts.append(segment)
        }
        guard !parts.isEmpty else { throw CanonicalError.empty(raw: raw) }
        return (parts.joined(separator: "/") as NSString).precomposedStringWithCanonicalMapping
    }

    /// 取「相对某个授权根」的路径，结果永远不带前导斜杠。
    ///
    /// 授权根本身带前导斜杠（如 `/示例共享`），`dropFirst(root.count)` 之后
    /// 剩下的是 `/示例资料/x.pdf`——**仍然以斜杠开头**，而 `validate`
    /// 第一条就拒绝前导斜杠。此前三处调用各自 `dropFirst` 却没剥这一刀，
    /// 于是**所有** NAS 结果在打开/定位时都报 "Unsafe relative path"：
    /// 能搜到、点不开。
    ///
    /// 这里只负责切，不负责判断归属——调用方必须先用 `owningRoot`
    /// 按整段比对挑出真正的根，所以 `/示例共享2` 这类兄弟目录不会被误切。
    public static func relative(_ path: String, under root: String) -> String {
        var rest = String(path.dropFirst(root.count))
        while rest.hasPrefix("/") { rest.removeFirst() }
        return rest
    }

    public static func normalized(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

