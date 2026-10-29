import Foundation

/// 跨线程定位所需的来源与授权范围快照。
public struct NASLocator: Sendable {
    public let sourceID: String
    public let host: String
    public let shares: Set<String>
    public let scopePrefixes: [String]
    public let preferredSMBUser: String?
    /// 非 SMB 来源必须在访问文件系统前拒绝 SMB 定位。
    public var exposesSMBShares: Bool = true
    /// 飞牛的 SMB 共享名由设备侧映射，不在授权 scopes 中。
    public var smbSharesFromDevice: Bool = false
    public static let empty = NASLocator(sourceID: "", host: "", shares: [], scopePrefixes: [], preferredSMBUser: nil)

    /// 逐段匹配授权根，避免把 /共享备份误认作 /共享 的子目录。
    public func owningRoot(path: String) -> String? {
        for prefix in scopePrefixes {
            if prefix == "/" { return "/" }
            let root = String(prefix.dropLast())
            let a = root.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            let b = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
            if b.count >= a.count && zip(a, b).allSatisfy({ $0 == $1 }) { return root }
        }
        return nil
    }

    /// 整根授权不对应单个 SMB 共享。
    public func owningShare(root: String) -> String? {
        if root == "/" { return nil }
        let share = String(root.dropFirst())
        return shares.contains(share) ? share : nil
    }

    public func contains(path: String?) -> Bool {
        guard let path else { return false }
        return owningRoot(path: path) != nil
    }
}
