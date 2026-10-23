import Foundation

/// 客户端 `initialize` 里 `capabilities.experimental` 的兼容清洗（Phase 11-lite）。
///
/// ## 为什么需要这一层
///
/// MCP 规范把 `experimental` 定义成「客户端自定义的对象」，值可以是任何 JSON 值。
/// 但 swift-sdk 0.12.1 把它建模成 `[String: String]?`（已确认上游 `main` 分支至今同样），
/// 于是**只要某个客户端发来非字符串的值，整个 `initialize` 解码就失败**——
/// 服务端只能回 `-32603 Internal error: The data couldn't be read because it isn't
/// in the correct format.`，客户端连 Tools 都列不出来。
///
/// Codex（`codex-mcp-client`，0.163.0-alpha.11）实测就发：
///
/// ```json
/// "capabilities": {
///   "experimental": { "codex/auth-change": {} },
///   "elicitation": { "form": {}, "url": {} }
/// }
/// ```
///
/// 二分实验（2026-10-22）确认**只有**这个字段会让解码失败：
///
/// | 改法 | 结果 |
/// |---|---|
/// | 原样（对象值） | 失败 |
/// | 去掉 `experimental` | 成功 |
/// | `experimental` 值是字符串 | 成功 |
/// | 去掉 `elicitation`（保留对象值 experimental） | 仍然失败 |
/// | 去掉 `clientInfo.title`（保留对象值 experimental） | 仍然失败 |
///
/// ## 为什么在我们这边兜，而不是等上游
///
/// 升级依赖解决不了：上游 `main` 的字段声明还是 `[String: String]?`。
/// 而这个缺陷会让**第一主 Gate 客户端连不上**，属于发布阻塞项。
///
/// ## 清洗规则（窄到只碰这一个字段）
///
/// 1. 只处理 `method == "initialize"` 的报文，其它一律**逐字节原样返回**。
/// 2. `experimental` 缺失、或全部值都是字符串 → **逐字节原样返回**（不做无谓重编码）。
/// 3. `experimental` 是对象但有非字符串值 → **只保留字符串值的条目**，
///    非字符串条目丢弃；一条不剩就整键删掉。
/// 4. `experimental` 根本不是对象（字符串/数组/null） → 整键删掉。
/// 5. 报文不是 JSON、或缺 `params` / `capabilities` → 原样返回（不抛、不猜）。
///
/// ★ 丢弃是安全的：服务端从来**不读** `experimental`（它只描述客户端自己的能力），
///   我们既不按它分支、也不把它转给权威端。
/// ★ 第 2 条保证「合规客户端的字节不被改写」——这一点很重要，否则我们会成为
///   一个「对谁都动手」的中间层，出问题时分不清是谁改的。
public enum ClientCapabilitySanitizer {

    /// 需要清洗时才重编码；其余情况返回**同一个** `Data`。
    public static func sanitize(_ raw: Data) -> Data {
        guard let root = try? JSONSerialization.jsonObject(with: raw),
              var object = root as? [String: Any],
              object["method"] as? String == "initialize",
              var params = object["params"] as? [String: Any],
              var capabilities = params["capabilities"] as? [String: Any],
              let experimental = capabilities["experimental"]
        else { return raw }

        // 已经是合法形态：一个字节都不改。
        if let map = experimental as? [String: Any] {
            let kept = map.filter { $0.value is String }
            if kept.count == map.count { return raw }
            if kept.isEmpty {
                capabilities.removeValue(forKey: "experimental")
            } else {
                capabilities["experimental"] = kept
            }
        } else {
            capabilities.removeValue(forKey: "experimental")
        }

        params["capabilities"] = capabilities
        object["params"] = params

        guard let rewritten = try? JSONSerialization.data(withJSONObject: object,
                                                          options: [.sortedKeys])
        else { return raw }

        // 传输层按行分帧：原来带换行就还带换行，别把帧边界弄丢。
        if raw.last == UInt8(ascii: "\n") {
            return rewritten + Data([UInt8(ascii: "\n")])
        }
        return rewritten
    }
}
