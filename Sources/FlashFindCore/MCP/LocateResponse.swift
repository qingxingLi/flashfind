import Foundation

/// `locate` 结果里 `reasons` 的取值集合（**闭集**，方案 §7.1）。
///
/// ★ 做成枚举而不是 `[String]`：`reasons` 是给 Agent 读的**因果说明**，
/// 一旦允许自由文本，就会有人往里写「很匹配」，然后没有任何用例能断言它。
/// 闭集还带来一个副作用：权重表（§7.1）与这里的 case 是同一组名字，
/// 加一个信号必须同时改两处——那正是该停下来想一秒的地方。
public enum LocateReason: String, Equatable, Sendable, CaseIterable {
    case nameMatch = "name-match"
    case recentlyModified = "recently-modified"
    case metadataAccess = "metadata-access"
    case locatedRecently = "located-recently"
}

/// `locate` 返回的一条结果。**只有七个字段**。
///
/// ## 为什么没有 `size` / `modified_at` / `source_name`
///
/// * 大小与时间在 provider 之间不一致（本机有，某些 WebDAV 没有），做成
///   「有时有有时没有」的字段会让 Agent 写出 `if let` 分支；
/// * 完整元数据只有一个出口：`get_metadata`（这也是 1.1.2 「先 locate 再取详情」
///   两步设计的原意）；
/// * 来源名字属于「未授权来源连名字都不告诉 Agent」那条规则的边界（§4.3.1）：
///   结果里只放 `source_id`，名字让 `list_sources` 一处去说。
///
/// ## 为什么路径只有相对路径
///
/// 绝对路径是本机概念。NAS 结果给不出来，硬凑一个 `/Volumes/…` 就是假装；
/// 而本机结果的绝对路径发给 Agent，下一步就会变成「请读取 /Users/…」。
public struct LocateResult: Equatable, Sendable {

    public enum Error: Swift.Error, Equatable, Sendable {
        /// 不是安全的相对路径（绝对路径、`..`、空段、NUL、尾随斜杠…）。
        case unsafePath
        /// `score` 越出 `0…1` 或不是有限数。
        case scoreOutOfRange
    }

    public let fileID: FileID
    public let name: String
    public let relativePath: String
    public let sourceID: String
    public let kind: FileKind
    /// `0…1` 的**相对排序分**，不是概率（§4.5）。
    public let score: Double
    public let reasons: [LocateReason]

    /// ★ 两处校验都在这里，而不是交给调用方记得做：
    /// 一条坏结果进了数组，最后就会出现在 Agent 的上下文里，
    /// 而那时已经分不清是哪一环算错的。
    public init(fileID: FileID,
                name: String,
                relativePath: String,
                sourceID: String,
                kind: FileKind,
                score: Double,
                reasons: [LocateReason]) throws {
        guard RelativePath.isSafe(relativePath) else { throw Error.unsafePath }
        guard score.isFinite, (0...1).contains(score) else { throw Error.scoreOutOfRange }
        self.fileID = fileID
        self.name = name
        self.relativePath = relativePath
        self.sourceID = sourceID
        self.kind = kind
        self.score = score
        self.reasons = reasons
    }

    /// 登记进 `FileReferenceStore` 的那条映射（6.4b-1）。
    ///
    /// ★ 三列来自**同一个值对象**：来源 id 与路径若各自再取一次，
    /// 「结果里的路径」与「库里的路径」迟早不是同一串。
    var reference: FileReference {
        FileReference(fileID: fileID, sourceID: sourceID, canonicalRelativePath: relativePath)
    }

    /// 线上形态。键名只从 `AuthorityWire.ResponseKey` 取。
    var payload: AuthorityWire.Value {
        .object([
            AuthorityWire.ResponseKey.fileID: .string(fileID.value),
            AuthorityWire.ResponseKey.name: .string(name),
            AuthorityWire.ResponseKey.relativePath: .string(relativePath),
            AuthorityWire.ResponseKey.sourceID: .string(sourceID),
            AuthorityWire.ResponseKey.kind: .string(kind.rawValue),
            AuthorityWire.ResponseKey.score: .double(score),
            AuthorityWire.ResponseKey.reasons: .array(reasons.map { .string($0.rawValue) })
        ])
    }
}

/// `locate` 的成功返回（方案 §4.4）。
///
/// ```json
/// { "results": [ … ], "truncated": false, "limit_applied": 5, "warnings": [] }
/// ```
///
/// ★ **空结果也是成功**：`results: []` 的语义是「搜过了，没有」。
/// 「这条路径还没接上」是另一件事，用 `internal_error` 说（§4.9）——
/// 两者在 Agent 眼里完全不同：前者让它下结论，后者让它告诉用户去更新。
///
/// ★ 不带 `ok`：那是报文层（`AuthorityWire.Response.ok`）的事。
/// 结果体里再放一个 `ok` 就有两个「成功」可说，迟早互相矛盾。
public struct LocateResponse: Equatable, Sendable {

    public let results: [LocateResult]
    /// **本次确实还有更多合格结果没返回**（候选数 > `limit_applied`）。
    ///
    /// ★ 它**不是**「参数被钳位」的意思（Phase 6.3b-0 复审锁死）：
    ///
    /// ```text
    /// 请求 limit=100，上限 20，候选只有 3 条   → limit_applied=20, truncated=false
    /// 请求 limit=20，候选正好 20 条            → limit_applied=20, truncated=false
    /// 请求 limit=20，候选 21 条                → limit_applied=20, truncated=true
    /// ```
    ///
    /// 也**不表示**「搜索不完整」：某个来源掉线、设备侧截断、有目录读不到，
    /// 都是 `warnings` / 来源失败的事。把那些塞进 `truncated` 会让 Agent 得出
    /// 「加个参数就能看全」的错误结论。
    public let truncated: Bool
    public let limitApplied: Int
    /// 部分失败的说明，原样带出（`source_denied:<id>`），**不含来源名**。
    public let warnings: [String]

    /// 唯一的构造入口：**候选进、窗口出**。
    ///
    /// 调用方给的是「限制之前」的全部候选，`truncated` 与 `results` 都由这里切。
    ///
    /// 之所以不提供 `(results:truncated:limitApplied:)` 那种直给构造：那会留下
    /// 两个能决定 `truncated` 的地方（调用方说 true、而候选其实只有 3 条），
    /// 而这两处一旦矛盾，Agent 看到的就是「说还有更多，可怎么加参数都没有」。
    /// 现在 `truncated` 在这份代码里**只出现一次赋值**，变异也只有一处可改。
    public init(selecting candidates: [LocateResult],
                application: LimitApplication,
                warnings: [String]) {
        self.results = Array(candidates.prefix(application.applied))
        self.truncated = candidates.count > application.applied
        self.limitApplied = application.applied
        self.warnings = warnings
    }

    public func payload() -> AuthorityWire.Value {
        .object([
            AuthorityWire.ResponseKey.results: .array(results.map(\.payload)),
            AuthorityWire.ResponseKey.truncated: .bool(truncated),
            AuthorityWire.ResponseKey.limitApplied: .int(limitApplied),
            AuthorityWire.ResponseKey.warnings: .array(warnings.map { .string($0) })
        ])
    }

    /// 单行 JSON。键序固定（`jsonString` 走 `sortedKeys`），同一输入两次逐字节相同。
    public func json() throws -> String {
        try AuthorityWire.jsonString(payload())
    }
}
