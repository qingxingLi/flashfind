import Foundation

/// 凭据 account 键的**唯一出处**。
///
/// 以前同一件事有三处各写一遍（`nas-source:<id>`、`nas:<id>:<指纹>`、`<地址>|<账号>`），
/// 改键规则只能靠人记住要改三处。这里收敛之后，换规则只改本文件。
public enum CredentialAccount {

    /// NAS 来源的凭据键。身份要素不含地址——来源换了地址仍指向同一条来源记录。
    public static func source(_ id: String) -> String { "nas-source:" + id }

    /// 连接档案的凭据键。带地址与账号的指纹：**地址或账号一变，键就变**，
    /// 于是旧密码自动不再适用，不需要额外的失效逻辑。
    public static func profile(id: String, address: String, username: String) -> String {
        "nas:" + id + ":" + AccountProfile.key(address: address, username: username)
    }

    /// 早期拼法（`<地址>|<账号>`），CLI 与旧版读过它存的凭据。
    ///
    /// 它**不含 sourceID**，因此身份绑定的强度弱于另外两种；保留是因为存量凭据就按它存的，
    /// 改掉等于让老用户重新输一遍密码。
    public static func legacy(address: String, username: String) -> String {
        address + "|" + username
    }

    /// 三个前缀，供审计脱敏与日志识别。
    public static let sourcePrefix = "nas-source:"
    public static let profilePrefix = "nas:"
}
