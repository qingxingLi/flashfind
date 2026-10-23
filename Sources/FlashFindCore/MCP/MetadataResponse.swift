import Foundation

/// `get_metadata` 的成功返回（§4.11.3）：**七个字段，一个不多**。
///
/// ```json
/// { "file_id": "ff1_…", "source_id": "nas_1", "name": "预算.xlsx",
///   "kind": "file", "relative_path": "允许共享/预算.xlsx",
///   "size_bytes": 40960, "modified": "2026-10-01T12:00:00Z" }
/// ```
///
/// ## 为什么没有 `absolute_path`（v0.28 正式升级，不是漏字段）
///
/// 旧的冻结表写过「绝对路径只给 `get_metadata`」，6.4b-0 的能力实测把它推翻了：
///
/// | 来源 | 有无可信的本机绝对路径 |
/// | --- | --- |
/// | 本机 | 有，但发它就是请 Agent 直接读 `/Users/…` |
/// | 群晖 | 只有设备根路径（`/共享名/…`），没有 `/Volumes/…` |
/// | WebDAV | 同上，且挂载点未必存在 |
///
/// 于是 1.1.2 的 MCP 面**不输出 synthetic `absolute_path`**：
/// `locate` / `locate_many` / `search` / `get_metadata` 一律
/// `source_id` + `relative_path`，`get_metadata` 再补元数据。
/// 硬造一个 `/Volumes/…` 只会让 Agent 拿着一个打不开的路径去行动。
///
/// ## 为什么没有 `owner` / `mime` / `etag`
///
/// 6.4b-0 的探针里它们要么压根没被解析，要么随固件变——
/// 「有时有有时没有的字段」会让 Agent 写出 `if let` 分支，
/// 而那些分支大多数是错的。契约只留**所有来源都能稳定给出**的那几项。
public struct MetadataResponse: Equatable, Sendable {

    public let fileID: FileID
    public let sourceID: String
    public let name: String
    public let kind: FileKind
    public let relativePath: String
    /// `nil` = 设备没给出大小。**不写成 0**：0 字节与「不知道」是两件事。
    public let sizeBytes: Int64?
    /// `nil` = 设备没给出时间。**不写成 1970**：那是拿一个假时间点冒充未知。
    public let modified: Date?

    public init(fileID: FileID,
                sourceID: String,
                metadata: PathMetadata,
                relativePath: String) {
        self.fileID = fileID
        self.sourceID = sourceID
        self.name = metadata.name
        self.kind = metadata.kind
        self.relativePath = relativePath
        self.sizeBytes = metadata.sizeBytes
        self.modified = metadata.modified
    }

    public func payload() -> AuthorityWire.Value {
        .object([
            AuthorityWire.ResponseKey.fileID: .string(fileID.value),
            AuthorityWire.ResponseKey.sourceID: .string(sourceID),
            AuthorityWire.ResponseKey.name: .string(name),
            AuthorityWire.ResponseKey.kind: .string(kind.rawValue),
            AuthorityWire.ResponseKey.relativePath: .string(relativePath),
            AuthorityWire.ResponseKey.sizeBytes: sizePayload,
            AuthorityWire.ResponseKey.modified: modifiedPayload
        ])
    }

    /// ★ 缺值必须是 JSON `null`，**不能是 0、也不能省略键**：
    /// 省略键时 Agent 分不清「闪寻没给」与「这个字段不存在」。
    private var sizePayload: AuthorityWire.Value {
        guard let sizeBytes else { return .null }
        return .int(Int(sizeBytes))
    }

    private var modifiedPayload: AuthorityWire.Value {
        guard let modified else { return .null }
        return .string(Self.utcFormatter.string(from: modified))
    }

    /// 时间的唯一写法：UTC + ISO 8601 + 秒精度（§4.11.3）。
    ///
    /// ★ 三个来源的时间口径不一致（6.4b-0 实测）：群晖给 UTC 带 `Z`、
    /// WebDAV 给本地时间不带偏移、本机给本地时间。不在这一层统一，
    /// 同一个文件在两个来源上的 `modified` 会差 8 小时。
    ///
    /// ★ 时区显式设为 UTC 而不是靠系统时区：系统时区一变，同一个时刻
    /// 编码出来的串就变了，逐字节比较的用例会随机失败。
    public static let utcFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()

    public func json() throws -> String {
        try AuthorityWire.jsonString(payload())
    }
}
