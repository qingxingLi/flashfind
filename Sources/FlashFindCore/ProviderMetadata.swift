import Foundation

// MARK: - 本机：一次 stat 就够

/// 本机来源的直查（Phase 6.4b-1）。
///
/// ★ 与其它来源相反，本机**真的有 `stat`**：一次 `attributesOfItem` 就能同时
/// 拿到大小与修改时间。所以这里不需要「列父目录再挑一条」那套退化路径。
///
/// ★ 路径还原方式来自 6.3b-0 的实测：本机 provider 给的 `relativePath` 是
/// **绝对路径**，`RelativePath.canonical` 只剥掉前导 `/`。所以直查时要把
/// 那个 `/` 加回去——不做这件事会去查一个相对当前工作目录的路径，
/// 在 `swift test` 里表现为「本机文件全部 file_not_found」。
extension LocalSearchProvider: PathMetadataProviding {

    public func metadata(canonicalRelativePath: String) async -> MetadataOutcome {
        let absolutePath = "/" + canonicalRelativePath
        // ★ 先判范围，再碰文件系统。顺序不能反：
        //   范围外的路径也去 stat 一次的话，「在 / 不在」会由耗时与返回值侧漏出去，
        //   等于把「这个文件存在，只是你不该看」告诉了调用方。
        //
        // ★ 返回 `notFound` 而不是新错误码：「范围外」对外必须与「文件不在了」
        //   完全一样。给一个专门的拒绝码，本身就是一条信息。
        //
        // 这条闸门补的是 build 28 之前的一个缺口：搜索按范围分流，metadata 却
        // 只判「来源被授权了没有」，于是收窄范围之后，AI 手里的旧 `file_id`
        // 仍能问出范围外文件的元数据。NAS 侧一直有 Dart 的 `scope.check`，
        // 本机没有对应的一道。
        guard LocalReadScope.allows(absolutePath: absolutePath,
                                    mode: mode,
                                    folders: folders) else {
            return .notFound
        }
        let values: [FileAttributeKey: Any]
        do {
            values = try FileManager.default.attributesOfItem(atPath: absolutePath)
        } catch let error as CocoaError {
            return Self.outcome(forCocoaError: error)
        } catch {
            return .unavailable
        }

        let type = values[.type] as? FileAttributeType
        let isDirectory = type == .typeDirectory
        let size = (values[.size] as? NSNumber)?.int64Value
        return .found(PathMetadata(
            name: (absolutePath as NSString).lastPathComponent,
            // ★ 目录不给 `size_bytes`：目录项大小不是「文件大小」，
            // 它随文件系统与目录内容变（本项目自己也在 6.4b-0 的探针里测到
            // 不同来源给的值完全不可比）。给一个看着像数字的数等于让 Agent
            // 拿它去算「这个文件多大」。
            kind: isDirectory ? .folder : .file,
            sizeBytes: isDirectory ? nil : size,
            modified: values[.modificationDate] as? Date))
    }

    /// POSIX 层的两种「问不出来」必须分开：
    ///
    /// ```text
    /// ENOENT → 这里没有这个文件 → file_not_found
    /// 其它    → 这次问不出来（权限、IO）→ source_unavailable
    /// ```
    ///
    /// ★ 合成 `.unavailable` 的话，文件被删会被说成「本机来源不可用」，
    /// Agent 会去让用户检查一台其实好好的 Mac。
    private static func outcome(forCocoaError error: CocoaError) -> MetadataOutcome {
        if error.code == .fileReadNoSuchFile || error.code == .fileNoSuchFile { return .notFound }
        return .unavailable
    }
}

// MARK: - NAS：列父目录 + 精确匹配

/// NAS / 品牌来源的直查（Phase 6.4b-1）。
///
/// ## 直查 = 一次父目录列举（6.4b-0 实测，不是设计缺陷）
///
/// ```text
/// 群晖   SYNO.FileStation.List/list 列父目录，additional:['size','time','type']
/// WebDAV PROPFIND depth:1 列父目录
/// QNAP / 绿联  同样退化成「列父目录再挑一条」
/// ```
///
/// **没有一个来源有 `stat`**，所以 `get_metadata` 的一次请求就是一次小目录列举。
/// 这一点必须写进契约：它决定了一个目录里文件很多时，直查的代价不是 O(1)。
///
/// ## 为什么匹配在 Swift 侧做，而不是让 Dart 侧挑好
///
/// 匹配规则必须与 `FileID` 一致（**NFC 归一化 + 精确 + 大小写敏感**）。
/// Dart 没有内建的 Unicode 归一化，把规则搬过去就得手写一个 NFC；
/// 而 Swift 侧既有 `precomposedStringWithCanonicalMapping`，
/// 又已经是 `FileID.make` 那一套规则的唯一来源。
///
/// ★ 直接在 Dart 侧按原始字节比，会让 NFD 文件（部分 SMB / AFP 设备）在
/// 未来某一天变成假 `file_not_found`：文件明明在，就是匹配不上。
extension NASSearchProvider: PathMetadataProviding {

    public func metadata(canonicalRelativePath: String) async -> MetadataOutcome {
        // 没连上就是「这次问不出来」，不是「文件不在了」。
        // 顺序不能反：掉线的 NAS 上每个文件都会 `file_not_found` 的话，
        // 用户会去删文件，而其实只是设备没连。
        guard ready else { return .unavailable }

        let target = "/" + canonicalRelativePath
        let segments = target.split(separator: "/", omittingEmptySubsequences: true)
        guard let name = segments.last else { return .notFound }
        // 父目录：根下第一层时父目录就是 `/` 本身（设备路径以根起算）。
        let parent = segments.count > 1
            ? "/" + segments.dropLast().joined(separator: "/")
            : "/"

        let rows: [[String: Any]]
        do {
            let reply = try await bridge.command("list", sourceID: source.id, fields: ["path": parent])
            rows = (reply["files"] as? [[String: Any]]) ?? []
        } catch let error as FlashFindError {
            return Self.outcome(forCoreKind: error.errorDescription)
        } catch {
            return .unavailable
        }

        // ★ 精确匹配，三件事都不做：
        //   不 `contains`、不 `hasPrefix`、不 `caseInsensitiveCompare`。
        //   `FileID` 的身份本来就是大小写敏感的：`Report.pdf` 与 `report.pdf`
        //   是两个不同的文件、两个不同的 id。含糊匹配会让 `get_metadata`
        //   返回另一个文件的大小与时间，而 Agent 无从察觉。
        let wanted = String(name).precomposedStringWithCanonicalMapping
        for row in rows {
            guard let rowName = row["name"] as? String,
                  row["sourceID"] as? String == source.id else { continue }
            guard rowName.precomposedStringWithCanonicalMapping == wanted else { continue }
            return .found(PathMetadata(
                name: rowName,
                kind: row["fileType"] as? String == "folder" ? .folder : .file,
                // ★ 缺字段是 `null` 而不是 0（WebDAV 的未知大小由 Dart 侧
                //   的 `sizeKnown` 如实带出来，见 `brand_session.row`）。
                sizeBytes: (row["size"] as? NSNumber)?.int64Value,
                modified: Self.modifiedDate(in: row)))
        }
        // 父目录列出来了、里面没有那一条 = 这个文件现在不在了。
        return .notFound
    }

    private static func modifiedDate(in row: [String: Any]) -> Date? {
        guard let raw = row["modifiedDate"] as? String else { return nil }
        // 两个来源给的形态不同（6.4b-0 实测）：群晖带小数秒、WebDAV 不一定。
        // 两种都试一遍，认不出来就按「设备没给出时间」返回 nil ——
        // 不拿 1970 冒充未知。解析器与搜索结果行共用一份（`DeviceTimestamp`）。
        return DeviceTimestamp.parse(raw)
    }

    /// 核心错误 kind → 直查结论（§4.11.2）。
    ///
    /// ★ `PathMissing` 归到 `notFound`：父目录在设备上不存在，等价于
    /// 「这个文件不在了」。归到 `unavailable` 的话，删掉一个文件夹里的文件
    /// 会变成「来源不可用」，而设备一切正常。
    private static func outcome(forCoreKind kind: String?) -> MetadataOutcome {
        switch kind {
        case "NeedsAuth", "SessionExpired", "AuthenticationFailed", "AccountDisabled",
             "PasswordLifecycle", "NeedsOTP", "OTPRejected":
            return .needsAuth
        case "PathMissing", "PermissionDenied", "ScopeDenied", "ScopeUnavailable":
            return .notFound
        default:
            return .unavailable
        }
    }
}
