import Foundation

/// 一个位置**此刻**的元数据（§4.11，`get_metadata` 的唯一产物）。
///
/// ## 它为什么不能复用 `FileItem` / `SearchResult`（6.4b-0 探针实测）
///
/// 搜索结果里的 `size` 是「顺手拿到的一份」，而 `get_metadata` 的 `size` 是
/// **这次问出来的答案**。两者会漂到不同的口径上：
///
/// * 群晖设备不给 `additional` 时，搜索结果里那一项是 `nil`；
/// * WebDAV 设备不给 `getcontentlength` 时，适配器把它**折成了 `0`**
///   （`FileItem.size` 是非空 `int`，表达不了「未知」）。
///
/// 复用搜索结果类型，等于让「设备没告诉我」与「这个文件是空的」共用同一个值，
/// Agent 拿到的是假数据。所以直查有自己的类型，而且两个字段都**可空**：
///
/// ```text
/// size_bytes: Int64?     nil ≠ 0
/// modified:   Date?      nil ≠ 1970
/// ```
public struct PathMetadata: Equatable, Sendable {

    /// 路径的最后一段。它与 `FileReference` 里的路径必须指同一个位置。
    public let name: String
    public let kind: FileKind
    /// 字节数。`nil` = 设备没给出大小（**不是 0 字节**）。
    ///
    /// ★ 目录的字节数不是「文件大小」：本机 `stat` 会给目录的目录项大小，
    /// DSM 给 0 或 4096，随固件变。所以目录一律 `nil`，不给一个看着像数字的数。
    public let sizeBytes: Int64?
    /// 最后修改时间。`nil` = 设备没给出时间。
    public let modified: Date?

    public init(name: String, kind: FileKind, sizeBytes: Int64?, modified: Date?) {
        self.name = name
        self.kind = kind
        self.sizeBytes = sizeBytes
        self.modified = modified
    }
}

/// 一次「按路径直查」的四选一结果。
///
/// ★ `notFound` 与 `unavailable` 必须分开：前者是「这里确实没有这个文件」
/// （`file_not_found`），后者是「这次没问到」（`source_unavailable`）。
/// 合成一个 `.failed` 的话，设备掉线会被说成「文件没了」，
/// Agent 会去让用户找一个其实还好好的文件。
public enum MetadataOutcome: Equatable, Sendable {

    case found(PathMetadata)
    /// 来源可用，但这个路径不在了。
    case notFound
    /// 这次问不出来（掉线 / 任务被取消 / 设备忙）。
    case unavailable
    /// 登录态失效，要用户重新连接。
    case needsAuth
    /// 这个 provider 不具备「按路径直查」的能力（§15 #31：闪寻的缺口，
    /// 不是设备的问题）。对外一律折成 `internal_error`，不新立错误码。
    case unsupported
}

/// 「按路径直接取元数据」的能力。
///
/// ## 为什么它是一个独立协议，而不是 `SearchProvider` 的第 N 个要求
///
/// `SearchProvider` 是**搜索**契约，六个 Tool 里只有 `get_metadata` 需要直查。
/// 塞进那个协议会让「所有 provider 都要会直查」变成类型上的义务——
/// 于是 `AppSearchProvider`（应用程序来源）也得硬编一个，而「一个 app 的
/// 字节数」根本没有意义。
///
/// 结果是能力**缺口**能被如实表达（`.unsupported` → `internal_error`），
/// 而不是被一个假实现盖住。
///
/// ## 它必须由句柄调用，不能由调用方自己拿着 provider 调
///
/// 见 `SourceExecutionHandle.metadata(canonicalRelativePath:)`：
/// 直查与搜索一样消费**判权那一刻冻结的** provider（§15 #23）。
@MainActor
public protocol PathMetadataProviding: AnyObject {

    /// 直查一个已经规范化的相对路径。
    ///
    /// - Parameter canonicalRelativePath: 已经过 `RelativePath.canonical` 的路径。
    ///   本协议的实现**不负责**再规范化一次——路径在进 `FileReferenceStore`
    ///   之前就已经是规范形态了，进到这里再做一次等于把「修路径」的动作
    ///   撒到适配器里（§3.2.1）。
    func metadata(canonicalRelativePath: String) async -> MetadataOutcome
}
