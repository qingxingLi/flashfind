import Foundation
import CryptoKit

/// 一个文件的**稳定身份**：`ff1_` + 32 位小写 hex（方案 §4.6）。
///
/// ## 为什么它是一个类型，而不是两处 `String` 拼接
///
/// 6.2 之前，`ff1_ + 32 位 hex` 这条规则只存在于 `ToolRouter` 的校验里，**没有生成侧**；
/// 接真 `locate` 时生成侧必然要再拼一遍——于是同一个格式两份实现，改了校验那份、
/// 生成那份没改，Agent 就会拿到「自己刚收到的 id 被自己拒掉」这种玄学 bug。
/// 本项目已经因为「同一事实写两遍」栽过两次（`limit` 上限、`kind` 枚举），
/// 所以这一次先把类型立起来，再谈搜索。
///
/// ```text
/// make(sourceID:canonicalRelativePath:)   唯一生成入口
/// parse(_:)                               唯一解析入口
/// ```
///
/// `get_metadata` 以后也只消费 `FileID`，**不再 parse**——它拿到的是别人给的值，
/// 再解析一遍就等于给了第二处「什么算合法」的判定。
///
/// ## 哈希前像（**改动等于让所有历史 id 失效**）
///
/// ```text
/// utf8(source_id) + 0x1F + utf8("path:") + utf8(归一化后的相对路径)
/// ```
///
/// * `0x1F`（Unit Separator，ASCII 的非打印控制符）不可能出现在来源 id 或路径里，
///   所以两个字段的边界无歧义；
/// * `"path:"` 是**字段标签**：将来若出现以别的形态标识的文件（比如按 inode），
///   前像里能一眼看出这是路径型身份；
/// * 取 SHA-256 的前 128 位（32 个 hex 字符）。128 位对「一台机器上的文件数」来说
///   碰撞概率可以忽略，而短一半的 id 能明显省 Agent 的上下文。
public struct FileID: Hashable, Sendable, CustomStringConvertible {

    /// 线上前缀。**只有这一处定义**——`Sources/` 里别的文件不许再出现这个字面量
    /// （`FileIDTests.testTheFormatLiteralLivesInExactlyOneSourceFile` 守着）。
    public static let prefix = "ff1_"
    /// hex 字符数（= 128 位）。
    public static let hexLength = 32
    /// 前像的字段分隔符。
    public static let separator: UInt8 = 0x1F
    /// 路径型身份的字段标签。
    public static let pathTag = "path:"

    /// 来源 id 的字节上限。来源 id 来自我们自己的注册表，这里只是兜底：
    /// 一个几百 KB 的 id 会让前像没法解释，也会把诊断日志撑爆。
    public static let maxSourceIDBytes = 128

    /// 线上形态，恒为 `ff1_` + 32 位小写 hex。
    public let value: String

    private init(value: String) {
        self.value = value
    }

    public var description: String { value }

    // MARK: - 生成

    public enum MakeError: Error, Equatable, Sendable {
        /// 来源 id 为空、过长、或含控制字符 / 分隔符。
        case unusableSourceID
        /// 路径不是安全的相对路径（绝对路径、`..`、空段、NUL、尾随斜杠…）。
        case unsafePath
    }

    /// 唯一生成入口。
    ///
    /// - Parameters:
    ///   - sourceID: `list_sources` 给出的来源 id。
    ///   - canonicalRelativePath: 相对授权根的路径，**不带前导斜杠**。
    ///     这里会做一次 NFC 归一化：macOS 本地卷给的是 NFD、NAS 通常给 NFC，
    ///     不归一化的话同一个文件在两条路径上会得到两个 id。
    ///     ★ 归一化**只做 Unicode 组合形式**，不折叠大小写、不做 percent 解码——
    ///     那些都会让两个真实不同的文件撞成一个身份。
    public static func make(sourceID: String, canonicalRelativePath: String) throws -> FileID {
        guard isUsable(sourceID) else { throw MakeError.unusableSourceID }
        let canonical = canonicalRelativePath.precomposedStringWithCanonicalMapping
        guard RelativePath.isSafe(canonical) else { throw MakeError.unsafePath }
        let digest = DigestHex.prefix(preimage(sourceID: sourceID, canonicalPath: canonical),
                                      characters: hexLength)
        return FileID(value: prefix + digest)
    }

    /// 唯一解析入口。**不 trim、不修大小写、不补前缀**：
    /// 到这一层还带着空白说明调用方绕过了 Router，那种情况应当失败。
    public static func parse(_ value: String) -> FileID? {
        guard value.hasPrefix(prefix), value.count == prefix.count + hexLength else { return nil }
        let hex = value.dropFirst(prefix.count)
        guard hex.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) else { return nil }
        return FileID(value: value)
    }

    // MARK: - 前像

    /// 哈希前像。测试会逐字节断言它（golden + 分隔符）。
    static func preimage(sourceID: String, canonicalPath: String) -> Data {
        var data = Data(sourceID.utf8)
        data.append(separator)
        data.append(contentsOf: Data(pathTag.utf8))
        data.append(contentsOf: Data(canonicalPath.utf8))
        return data
    }

    static func isUsable(_ sourceID: String) -> Bool {
        guard !sourceID.isEmpty, sourceID.utf8.count <= maxSourceIDBytes else { return false }
        return sourceID.unicodeScalars.allSatisfy { scalar in
            scalar.value >= 0x20 && scalar.value != 0x7F && scalar.value != UInt32(separator)
        }
    }
}

// MARK: - 摘要

/// SHA-256 的 hex 前缀。`FileID` 与 `MCPOwner` 都用它，避免各自写一份 hex 编码。
enum DigestHex {

    /// 前 `characters` 个 hex 字符（小写）。`characters` 必须是偶数——
    /// 否则半个字节会被截断，两个不同的前像可能得到同一个串。
    static func prefix(_ data: Data, characters: Int) -> String {
        precondition(characters % 2 == 0, "hex 前缀必须是整字节")
        let digest = SHA256.hash(data: data)
        var hex = String()
        hex.reserveCapacity(64)
        for byte in digest {
            hex.append(Character(UnicodeScalar(hexDigits[Int(byte >> 4)])))
            hex.append(Character(UnicodeScalar(hexDigits[Int(byte & 0x0F)])))
            if hex.count >= characters { break }
        }
        return String(hex.prefix(characters))
    }

    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)
}
