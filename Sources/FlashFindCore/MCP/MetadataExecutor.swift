import Foundation

/// `get_metadata` 的执行（Phase 6.4b-1）。
///
/// ## 链只有四步，一步都不能省（§4.11.1）
///
/// ```text
/// get_metadata(file_id)
///        ↓  ① 当前 MCP 权限状态（Router / PermissionPolicy，本类之前）
///        ↓  ② FileReferenceStore.lookup          身份：id → 来源 + 路径
///        ↓  ③ ref.source_id ∈ 本次 AuthorizationScope   授权：**重新判**
///        ↓  ④ snapshot.execution(for:).metadata(…)     冻结句柄上直查
/// ```
///
/// ### ① 为什么「MCP 总开关」必须在最前面
///
/// AI 关着时 `get_metadata(file_id)` 必须得到 `mcp_disabled`，
/// **不能**因为 Store 里有/没有这条映射而变成 `file_not_found`。
/// 这一步不在本类里：它在 `ToolRouter` → `PermissionPolicy` 里，
/// 本类被调到的那一刻，v² 的判定已经通过。**顺序靠类型保证**
/// （拿不到 `AuthorizationScope` 就造不出 `AuthorityRequest`，也就没有这次调用）。
///
/// ### ③ 为什么必须再判一次权（Store 不授予权限）
///
/// ```text
/// 绝不能：Store 里有这条 → 曾经授权过 → 直接去读
/// ```
///
/// 过去返回过 ≠ 现在仍授权。撤销来源、`localEnabled=false`、来源被删除，
/// 都必须对**下一次** `get_metadata` 立即生效。Store 只回答「这个 id 当初
/// 指向哪里」，它不知道那个来源现在还在不在、还授不授权。
///
/// ### ④ 为什么直查必须走冻结句柄
///
/// 若这里按 `source_id` 再去找一遍 provider，就等于第二次读注册表，
/// 6.3b 已经关掉的 TOCTOU 会在 `get_metadata` 上复活：
///
/// ```text
/// T0  判权：来源 A 已授权
/// T1  用户删掉 A，新建一个 A′（同 id、另一台设备）
/// T2  按 id 再查 → 拿到 A′，按 A 的路径去问
/// ```
///
/// 所以本类的入参里**没有注册表**，只有 `AuthorizedSourceSnapshot`。
@MainActor
public final class MetadataExecutor {

    private let store: FileReferenceStore

    public init(store: FileReferenceStore) {
        self.store = store
    }

    /// 一次执行的结果。
    public struct Run: Sendable {
        public let outcome: ToolOutcome
        /// 查到的映射（没查到则 nil）。诊断用，不进返回体。
        public let reference: FileReference?
        /// 直查走到哪一步了。诊断用。
        public var reached: Stage

        public enum Stage: String, Sendable {
            /// 表里没有这个 id。
            case unknownReference
            /// 映射的来源不在本次 scope 里。
            case outsideScope
            /// 映射的来源这次没有可用句柄。
            case noHandle
            /// 句柄上直查完了（含「这里没有这个文件」）。
            case lookedUp
        }
    }

    /// 四步链。
    ///
    /// - Parameters:
    ///   - fileID: 要查的引用。
    ///   - snapshot: 本次授权快照。
    ///   - history: History 的写入端（Phase 7c）。**旁路**：写失败不影响本次返回——
    ///     与映射表那条规则正相反（§6.6）。本参数为 `nil` 时不记事件。
    /// - Returns: 成功 = 七字段 JSON；失败 = §4.11.2 的四种错误之一。
    public func run(fileID: FileID,
                    snapshot: AuthorizedSourceSnapshot,
                    history: HistorySink? = nil,
                    now: Date = Date()) async -> Run {

        // ② 身份：Store 只查表，不授权。
        let reference: FileReference
        do {
            guard let found = try store.lookup(fileID) else {
                return Run(outcome: Self.failure(.fileNotFound), reference: nil, reached: .unknownReference)
            }
            reference = found
        } catch {
            // 库坏了 / 行坏了：那是我们的问题（§15 #31 → internal_error）。
            // 绝不能顺手折成 `file_not_found`——那会把「我们的库坏了」
            // 说成「文件不在了」。
            return Run(outcome: Self.failure(.internalError), reference: nil, reached: .unknownReference)
        }

        // ③ 授权：**每一次都判**。撤销来源在这一步生效。
        guard snapshot.contains(reference.sourceID) else {
            return Run(outcome: Self.failure(.sourceDenied), reference: reference, reached: .outsideScope)
        }

        // ④ 句柄：判权那一刻冻结的那个 provider。
        guard let handle = snapshot.execution(for: reference.sourceID) else {
            return Run(outcome: Self.failure(.sourceUnavailable), reference: reference, reached: .noHandle)
        }

        let outcome = await handle.metadata(canonicalRelativePath: reference.canonicalRelativePath)
        switch outcome {
        case .found(let metadata):
            let response = MetadataResponse(fileID: fileID,
                                            sourceID: reference.sourceID,
                                            metadata: metadata,
                                            relativePath: reference.canonicalRelativePath)
            guard let json = try? response.json() else {
                return Run(outcome: Self.failure(.internalError), reference: reference, reached: .lookedUp)
            }
            // ★ 只在**真的要回成功**的这一刻才记 `metadata`：失败不记，
            //   否则 Phase 8 的 `1-exp(-n/5)` 会把「查不到」也算成「感兴趣」。
            if let history {
                history.metadata(AccessEvent(sessionID: history.context.sessionID,
                                             agentID: history.context.agentID,
                                             fileID: fileID,
                                             sourceID: reference.sourceID,
                                             action: .metadata,
                                             timestamp: now,
                                             lastKnownRelativePath: reference.canonicalRelativePath))
            }

            return Run(outcome: .success(json: json), reference: reference, reached: .lookedUp)

        case .notFound:
            // 来源可用，但这个文件现在不在了（真的被删了、或改名了）。
            return Run(outcome: Self.failure(.fileNotFound), reference: reference, reached: .lookedUp)

        case .unavailable:
            return Run(outcome: Self.failure(.sourceUnavailable), reference: reference, reached: .lookedUp)

        case .needsAuth:
            return Run(outcome: Self.failure(.authRequired), reference: reference, reached: .lookedUp)

        case .unsupported:
            // 这个 provider 没有直查能力。这是闪寻的缺口，不是设备的问题，
            // 所以**不新立错误码**（§15 #31），沿用 internal_error。
            return Run(outcome: Self.failure(.internalError), reference: reference, reached: .lookedUp)
        }
    }

    // MARK: - 对外错误码（§4.11.2 的闭集）

    public enum FailureCode: String, Equatable, Sendable, CaseIterable {
        case fileNotFound = "file_not_found"
        case sourceDenied = "source_denied"
        case sourceUnavailable = "source_unavailable"
        case authRequired = "auth_required"
        case internalError = "internal_error"

        /// 对外文案。**英文、固定、不含来源 id 或名字**（§4.3.1）。
        public var message: String {
            switch self {
            case .fileNotFound:
                return "That file is no longer at the path FlashFind recorded for it. "
                     + "It may have been moved, renamed, or deleted. "
                     + "Search again to get a current file_id."
            case .sourceDenied:
                return "This file belongs to a source that is not available for AI access right now. "
                     + "Ask the user to enable it in FlashFind settings."
            case .sourceUnavailable:
                return "That source is not reachable right now. "
                     + "Ask the user to check it, then try again."
            case .authRequired:
                return "A source needs to be signed in again in FlashFind before it can be read. "
                     + "Ask the user to reconnect it, then try again."
            case .internalError:
                return "FlashFind could not read the metadata for this file."
            }
        }
    }

    static func failure(_ code: FailureCode) -> ToolOutcome {
        .failure(code: code.rawValue, message: code.message)
    }
}
