import Foundation
import CryptoKit

public enum AccountProfile {
    public static func key(address: String, username: String) -> String {
        let origin = address.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        let identity = origin + "\0" + username
        return SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    public static func directory(root: URL, address: String, username: String) -> URL {
        root.appendingPathComponent("accounts", isDirectory: true).appendingPathComponent(key(address: address, username: username), isDirectory: true)
    }
}
