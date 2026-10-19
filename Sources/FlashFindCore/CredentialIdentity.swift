import CryptoKit
import Foundation

/// 一条凭据**属于哪个目标**的描述：地址 + 端口 + 账号。
///
/// 为什么要把身份绑进凭据本身：来源 ID（`nas-source:<UUID>`）不随地址变化，
/// 于是「改了地址或端口」之后，旧密码仍然能被原 key 读到——
/// 那把密码属于**原来的那台设备**，却被拿来连新的目标。
/// App 层本来有 `draftIdentityChanged` 拦一道，但它漏了端口，
/// 而且只拦得住走向导的那条路（自动重连绕得过去）。
/// 这里在存储层再绑一次：拿不到与目标匹配的凭据，就等于没有凭据。
public struct CredentialIdentity: Sendable, Equatable, Hashable {

    public var host: String
    public var port: Int
    public var username: String

    public init(host: String, port: Int, username: String) {
        self.host = host
        self.port = port
        self.username = username
    }

    /// 三个要素的规范化拼接。**大小写与空白不参与区分**：
    /// `NAS.local` 与 `nas.local` 指的是同一台，别让用户改个大小写就得重输密码。
    private var canonical: String {
        let host = self.host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let user = username.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return "\(host)\u{1F}\(port)\u{1F}\(user)"
    }

    /// 不可逆摘要（SHA-256 十六进制，64 字符）。
    /// 它只回答「这把凭据是不是给这个目标的」，既存不下、也还原不出地址本身。
    ///
    /// 为什么是 SHA-256 而不是 FNV-1a：
    /// - 这个值跟凭据密文同处一个信封、一起落盘（见 `CredentialEnvelope`）。
    ///   凡是落在凭据旁边的摘要，审计时都会被当成密码学用途来审；
    ///   非密码学哈希（FNV-1a / `Hasher`）每解释一次都要重讲一遍「这里不需要抗碰撞」，
    ///   换成 SHA-256 就把这一整类质疑消掉了。
    /// - 代价为零：`CryptoKit` 是本仓既有依赖（`SMBMountDiscovery` 已在用），
    ///   不引入新模块，也不改变跨进程/跨版本稳定这个前提。
    /// - **不要改用 `Hasher`**：它的种子每进程随机，同一次启动内相同，
    ///   重启后同一个目标会算出不同的值，旧凭据必然读不出来。
    public var fingerprint: String {
        let digest = SHA256.hash(data: Data(canonical.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// 凭据的存储信封：把身份摘要与密文放在一起。
///
/// 存进后端的是一个 JSON 串 `{"v":1,"fp":…,"secret":…}`。
/// 之所以要信封而不是裸密文：后端只认 `account → value`，
/// 而「这条 value 是给哪个目标用的」必须跟着 value 一起落盘，
/// 否则换了 key 规则就等于把所有旧密码的归属信息抹掉。
public enum CredentialEnvelope {

    private static let version = 1

    public static func wrap(_ secret: String, identity: CredentialIdentity) -> String {
        let object: [String: Any] = ["v": version, "fp": identity.fingerprint, "secret": secret]
        guard let data = try? JSONSerialization.data(withJSONObject: object),
              let text = String(data: data, encoding: .utf8) else {
            // 信封造不出来就**绝不**退回裸密文：宁可这次存不上，
            // 也不能写一条将来无法判断归属的密码进去。
            return "{\"v\":\(version),\"fp\":\"\(identity.fingerprint)\",\"secret\":\"\"}"
        }
        return text
    }

    /// 解出密文。**身份不匹配返回 `nil`**，跟「没存过」无法区分——这正是要的效果。
    ///
    /// 非信封的历史值（旧版直接写的裸密码）同样返回 `nil`：
    /// 它没有任何身份信息，拿它当这把目标的密码用，等于把旧设备的密码送去新设备。
    public static func unwrap(_ raw: String, identity: CredentialIdentity) -> String? {
        guard let data = raw.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let version = object["v"] as? Int, version == Self.version,
              let fingerprint = object["fp"] as? String,
              fingerprint == identity.fingerprint,
              let secret = object["secret"] as? String, !secret.isEmpty else { return nil }
        return secret
    }
}
