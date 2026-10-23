import Foundation

/// `search` 返回的一条结果。**只有五个字段**（方案 §4.4.2，v0.27 冻结）。
///
/// ## 为什么没有 `score` / `reasons`
///
/// 这不是漏了，是产品语义：`search` 是**宽口径检索**，它没有 composite 分
/// ——不做修改时间加权，也不做历史加权（§4.3）。硬给它一个分会有两个坏处：
///
/// ① Agent 会拿它去和 `locate` 的 `score` 比较，而两者不是同一把尺子
///    （一个是 lexical 档位、一个是 0…1 的加权和），比出来的大小没有意义；
/// ② 为了「看起来完整」而把 lexical 档位除以 4 变成 0…1，是在**编造**一个
///    §4.5 定义之外的分数——那个字段从此有第二种含义。
///
/// 顺序本身就是信号：结果按 `SearchResultRanker` 的档位（整名 → 文件名前缀 →
/// 文件名全词 → 仅路径命中）排好，同档按 `relative_path` 升序，再同则按
/// `source_id` 升序。想看强弱就调 `locate`。
public struct SearchHit: Equatable, Sendable {

    public enum Error: Swift.Error, Equatable, Sendable {
        /// 不是安全的相对路径（绝对路径、`..`、空段、NUL、尾随斜杠…）。
        case unsafePath
    }

    public let fileID: FileID
    public let name: String
    public let relativePath: String
    public let sourceID: String
    public let kind: FileKind

    /// ★ 路径守卫与 `LocateResult` 用**同一套** `RelativePath.isSafe`。
    /// 两处各写一份判断，早晚会出现「locate 会丢 `..`、search 不会」。
    public init(fileID: FileID,
                name: String,
                relativePath: String,
                sourceID: String,
                kind: FileKind) throws {
        guard RelativePath.isSafe(relativePath) else { throw Error.unsafePath }
        self.fileID = fileID
        self.name = name
        self.relativePath = relativePath
        self.sourceID = sourceID
        self.kind = kind
    }

    /// 登记进 `FileReferenceStore` 的那条映射（6.4b-1）。
    ///
    /// 与 `LocateResult.reference` 同一个形状：`search` 与 `locate` 发出的 id
    /// 必须能被同一张表反查，否则「先在 search 里看到、再问 get_metadata」
    /// 这条路径会断。
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
            AuthorityWire.ResponseKey.kind: .string(kind.rawValue)
        ])
    }
}

/// `search` 的成功返回（方案 §4.4.2）。
///
/// ```json
/// { "results": [ … ], "truncated": false, "limit_applied": 10, "warnings": [] }
/// ```
///
/// `truncated` 的语义与 `locate` **完全一致**（§4.4.1）：候选数 > `limit_applied`
/// 才算「确实还有更多」。两者共用同一条边界，所以开窗也只留一处
/// ——`init(selecting:application:warnings:)`，与 `LocateResponse` 同一个形状。
///
/// ★ 空结果也是成功：`results: []` = 搜过了，没有。
public struct SearchResponse: Equatable, Sendable {

    public let results: [SearchHit]
    public let truncated: Bool
    public let limitApplied: Int
    public let warnings: [String]

    public init(selecting candidates: [SearchHit],
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
