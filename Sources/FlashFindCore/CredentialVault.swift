import Foundation

/// 所有凭据收在**同一条**钥匙串条目里。
///
/// ## 为什么合并
///
/// 系统钥匙串的访问授权是**按条目**记的：每多一条条目，用户在 App 换版本之后
/// 就要多点一次「始终允许」。1.1.4 之前是「一台 NAS 一条条目」，于是
/// 「登录两台输两次、三台输三次」——用户看到的弹窗数量正好等于 NAS 台数。
///
/// 收成一条之后，无论存了几台 NAS，一次启动最多只问一次。
///
/// ## 为什么在这里做、而不是在 `KeychainSecretStore` 里就地拼字符串
///
/// 编码/解码/合并全是纯函数，可以在 XCTest 里跑；钥匙串访问一次都不能进测试
/// （见 `NoKeychainAccessTests`：那类副作用是进程外的，本机跑一百遍都是绿的）。
/// 所以「装什么」由这个文件决定，「怎么放进钥匙串」留给后端。
///
/// ## 损坏与版本
///
/// 读得到但读不懂**不算空**：把它当空会让下一次保存用一份新表覆盖掉全部密码
/// （OSS-04）。所以解码结果分三档：`empty`（键不存在）/ `ok` / `damaged`，
/// 只有前两档允许写。
public struct CredentialVault: Equatable, Sendable {

    /// 这条条目在钥匙串里的 account。**不要改**：改了等于让老用户的密码消失。
    public static let itemAccount = "vault"

    /// 信封版本。将来换结构时靠它挡住「新写的被旧版读成空表」。
    public static let currentVersion = 1

    /// 解码结果。三档分开是**故意的**——「没有」和「读不懂」的处理方式相反。
    public enum Decoded: Equatable, Sendable {
        /// 条目不存在：首次运行，或用户把所有 NAS 都删了。
        case empty
        case ok(CredentialVault)
        /// 条目在，但读不懂。此时一律**不许写**。
        case damaged(CredentialStoreProblem)
    }

    /// account → 密文（信封已经在这一层之外套好，这里存的仍是不透明串）。
    public private(set) var entries: [String: String]

    public init(entries: [String: String] = [:]) {
        self.entries = entries.filter { !$0.key.isEmpty }
    }

    public var isEmpty: Bool { entries.isEmpty }

    /// 已存账号，**排序后**给出：编码结果与断言都靠它稳定。
    public var accounts: [String] { entries.keys.sorted() }

    public func value(for account: String) -> String? {
        guard let value = entries[account], !value.isEmpty else { return nil }
        return value
    }

    public mutating func set(_ value: String, for account: String) {
        guard !account.isEmpty else { return }
        // 空串 = 没存。留着它会让「密码是空的」和「没有密码」混成一种状态，
        // 而且编码出来还是一份看着非空的表。
        guard !value.isEmpty else {
            entries.removeValue(forKey: account)
            return
        }
        entries[account] = value
    }

    public mutating func remove(_ account: String) {
        entries.removeValue(forKey: account)
    }

    // MARK: - 编码

    public func encoded() -> String {
        // 手写而不是 JSONEncoder：键序要**确定**（排序），否则同内容两次编码字节不同，
        // `SecItemUpdate` 会白写一次，红证的锚点也稳不住。
        let body = accounts.map { account in
            "\"\(Self.escape(account))\":\"\(Self.escape(entries[account] ?? ""))\""
        }.joined(separator: ",")
        return "{\"v\":\(Self.currentVersion),\"entries\":{\(body)}}"
    }

    /// 解析。`nil` 与空串都算「没有」——`SecItemCopyMatching` 这两种情况都可能给。
    public static func decode(_ json: String?) -> Decoded {
        guard let json, !json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .empty
        }
        guard let data = json.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return .damaged(.undecodable)
        }
        if let version = root["v"] as? Int, version > currentVersion {
            return .damaged(.newerVersion(version))
        }
        guard let raw = root["entries"] as? [String: Any] else {
            return .damaged(.undecodable)
        }
        var entries: [String: String] = [:]
        for (key, value) in raw {
            guard let text = value as? String else { return .damaged(.undecodable) }
            if !key.isEmpty, !text.isEmpty { entries[key] = text }
        }
        return .ok(CredentialVault(entries: entries))
    }

    /// JSON 字符串转义。只处理结构字符与反斜杠——密文是 base64/JSON 信封，
    /// 但账号名里可能带任意字符，不能漏。
    private static func escape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 8)
        for character in text.unicodeScalars {
            switch character {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if character.value < 0x20 {
                    out += String(format: "\\u%04x", character.value)
                } else {
                    out.unicodeScalars.append(character)
                }
            }
        }
        return out
    }
}
