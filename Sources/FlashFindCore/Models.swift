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

public struct Source: Codable, Identifiable, Hashable {
    public var id: String
    public var name: String
    public var generation: String
    public var smbEndpoint: String
    public var shareRelativeRoot: String
    public var indexState: String
    public var minValidCursor: String
    public var maxChangeID: String
    public var snapshotID: String
    public var snapshotChangeID: String
    enum CodingKeys: String, CodingKey {
        case id = "source_id", name, generation, smbEndpoint = "smb_endpoint"
        case shareRelativeRoot = "share_relative_root", indexState = "index_state"
        case minValidCursor = "min_valid_cursor", maxChangeID = "max_change_id"
        case snapshotID = "snapshot_id", snapshotChangeID = "snapshot_change_id"
    }
}

public struct Manifest: Decodable {
    public let schemaVersion: Int
    public let capabilities: [String]
    public let sources: [Source]
    enum CodingKeys: String, CodingKey { case schemaVersion = "schema_version", capabilities, sources }
}

public struct RemoteFile: Codable, Equatable {
    public var relativePath: String
    public var kind: String
    public var size: String
    public var mtimeNS: String
    enum CodingKeys: String, CodingKey {
        case relativePath = "relative_path", kind, size, mtimeNS = "mtime_ns"
    }
    public init(relativePath: String, kind: String = "file", size: String = "0", mtimeNS: String = "0") {
        self.relativePath = relativePath; self.kind = kind; self.size = size; self.mtimeNS = mtimeNS
    }
    public func validate() throws {
        try RelativePath.validate(relativePath)
        guard ["file", "directory"].contains(kind), let sizeValue = Int64(size), sizeValue >= 0,
              Int64(mtimeNS) != nil else { throw FlashFindError.message("Invalid file metadata") }
    }
}

public struct RemoteChange: Decodable {
    public let changeID: String
    public let op: String
    public let relativePath: String
    public let kind: String?
    public let size: String?
    public let mtimeNS: String?
    enum CodingKeys: String, CodingKey {
        case changeID = "change_id", op, relativePath = "relative_path", kind, size, mtimeNS = "mtime_ns"
    }
}

public struct ChangePage: Decodable {
    public let schemaVersion: Int
    public let sourceID: String
    public let generation: String
    public let untilChangeID: String
    public let nextCursor: String
    public let hasMore: Bool
    public let changes: [RemoteChange]
    enum CodingKeys: String, CodingKey {
        case schemaVersion = "schema_version", sourceID = "source_id", generation
        case untilChangeID = "until_change_id", nextCursor = "next_cursor"
        case hasMore = "has_more", changes
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
    public var modifiedDate: Date?
    public var sourceType: SearchSourceType = .nas
    public var isOnline = true
    public var openTarget: SearchOpenTarget = .unavailable
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
    public static func validate(_ path: String) throws {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\0"),
              !path.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })
        else { throw FlashFindError.message("文件路径不安全，已阻止访问。请回到搜索窗重新选择。") }
    }

    /// 取「相对某个授权根」的路径，结果永远不带前导斜杠。
    ///
    /// 授权根本身带前导斜杠（如 `/示例共享`），`dropFirst(root.count)` 之后
    /// 剩下的是 `/供应商资料/x.pdf`——**仍然以斜杠开头**，而 `validate`
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

public struct MountBinding: Codable {
    public var root: URL
    public var mountedSharePrefix: String
    public var bookmark: Data?
    public init(root: URL, mountedSharePrefix: String = "", bookmark: Data? = nil) {
        self.root = root; self.mountedSharePrefix = mountedSharePrefix; self.bookmark = bookmark
    }
    public func resolve(source: Source, relativePath: String) throws -> URL {
        try RelativePath.validate(relativePath)
        if !source.shareRelativeRoot.isEmpty { try RelativePath.validate(source.shareRelativeRoot) }
        if !mountedSharePrefix.isEmpty { try RelativePath.validate(mountedSharePrefix) }
        var insideShare = [source.shareRelativeRoot, relativePath].filter { !$0.isEmpty }.joined(separator: "/")
        if !mountedSharePrefix.isEmpty {
            guard insideShare.hasPrefix(mountedSharePrefix + "/") else { throw FlashFindError.message("File is outside the bound share subdirectory") }
            insideShare.removeFirst(mountedSharePrefix.count + 1)
        }
        var actualRoot = root
        guard FileManager.default.fileExists(atPath: actualRoot.path) else { throw FlashFindError.message("SMB 共享未连接，请先重新连接共享") }
        if let bookmark {
            var stale = false
            do {
                actualRoot = try URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], bookmarkDataIsStale: &stale)
            } catch {
                throw FlashFindError.message("SMB 目录绑定已失效，请在设置中重新绑定共享根目录")
            }
            guard !stale else { throw FlashFindError.message("SMB 目录绑定已失效，请在设置中重新绑定共享根目录") }
        }
        guard FileManager.default.fileExists(atPath: actualRoot.path) else { throw FlashFindError.message("SMB share is not mounted") }
        let resolved = insideShare.split(separator: "/").reduce(actualRoot) { $0.appendingPathComponent(String($1)) }
        let canonicalRoot = actualRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let canonicalFile = resolved.resolvingSymlinksInPath().standardizedFileURL.path
        guard canonicalFile.hasPrefix(canonicalRoot + "/") else { throw FlashFindError.message("Resolved file escaped the mount binding") }
        return resolved
    }
}
