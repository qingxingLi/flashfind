import Foundation

public enum NASNextAction: String { case none, configure, connect, selectSources, sync, enableSearch, resumeSync }
public enum NASFailureKind: String { case credentials, authorization, resync, setup, rateLimited, permissionVerification, certificate, network, unknown }
public struct NASConnectionGuidance {
    public let title: String
    public let detail: String
    public let action: NASNextAction
    public let actionTitle: String
    public init(title: String, detail: String, action: NASNextAction = .none, actionTitle: String = "") {
        self.title = title; self.detail = detail; self.action = action; self.actionTitle = actionTitle
    }
}
