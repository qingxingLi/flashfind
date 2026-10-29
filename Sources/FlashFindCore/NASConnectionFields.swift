import Foundation

/// WebDAV 路径前缀的输入与显示转换。
public enum BasePathField {
    /// 支持完整 URL；移除查询、锚点和点路径段，空路径返回 nil。
    public static func parse(_ text: String) -> String? {
        var body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if body.isEmpty { return nil }
        if let range = body.range(of: "://") {
            // 丢掉 scheme://host[:port]，只留路径。
            body = String(body[range.upperBound...])
            if let slash = body.firstIndex(of: "/") { body = String(body[slash...]) } else { return nil }
        }
        if let cut = body.firstIndex(where: { $0 == "?" || $0 == "#" }) { body = String(body[..<cut]) }
        let segments = body
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
            .filter { $0 != "." && $0 != ".." }
        guard !segments.isEmpty else { return nil }
        return "/" + segments.joined(separator: "/")
    }

    /// 反方向：把路径还原成输入框文本。没填时显示空串，让占位提示生效。
    public static func text(for path: String?) -> String { parse(path ?? "") ?? "" }
}

/// 端口文本逐次解析，避免数字输入框延迟提交使连接按钮无法及时启用。
public enum PortField {
    /// 解析用户输入的端口文本。非数字字符一律忽略（`5a0` 视作 `50`）。
    /// 超出 1–65535 或解析不出数字时返回 `nil`。
    public static func parse(_ text: String) -> Int? {
        let digits = text.filter { $0.isNumber }
        guard let value = Int(digits), (1...65535).contains(value) else { return nil }
        return value
    }

    /// 反方向：把端口值还原成输入框文本。无效端口显示空串，让占位提示生效。
    public static func text(for port: Int) -> String {
        (1...65535).contains(port) ? String(port) : ""
    }
}

/// 根据连接状态和凭据判断按钮可用性，避免视图重建影响输入状态。
public enum ConnectButtonState {
    /// hasPort 包括写在地址里的端口；无需账号密码的品牌可跳过凭据检查。
    public static func canConnect(busy: Bool, host: String, hasPort: Bool,
                                  username: String, hasTypedPassword: Bool,
                                  hasStoredPassword: Bool,
                                  requiresCredential: Bool = true) -> Bool {
        if busy { return false }
        if host.isEmpty || !hasPort { return false }
        guard requiresCredential else { return true }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        // 密码二选一：本次输入的，或钥匙串里已有的。
        return hasTypedPassword || hasStoredPassword
    }

    /// 返回按钮不可用的原因；连接中不显示额外提示。
    public static func disabledReason(busy: Bool, host: String, hasPort: Bool,
                                       username: String, hasTypedPassword: Bool,
                                       hasStoredPassword: Bool,
                                       requiresCredential: Bool = true) -> String? {
        if busy { return nil }   // 正在连接，不需要解释
        if host.isEmpty { return "请填写 NAS 地址" }
        if !hasPort { return "请填写端口（也可以直接写进地址，像 192.0.2.96:5001）。闪寻不做自动探测——自签名证书的 NAS 在探测阶段就会被误判为不可用。" }
        guard requiresCredential else { return nil }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 NAS 账号" }
        if !hasTypedPassword && !hasStoredPassword { return "请输入密码" }
        return nil
    }
}

/// 仅在传输失败时提示可选的明文重试；协议降级由用户决定。
public enum PlainHTTPRetryOffer {

    /// 已收到 HTTP 状态码时链路可达，不提示切换协议。
    public static func shouldOffer(allowsPlainHTTPChoice: Bool, usesPlainHTTP: Bool,
                                   coreApiCode: Int?, isCoreFailure: Bool) -> Bool {
        guard allowsPlainHTTPChoice, !usesPlainHTTP, isCoreFailure else { return false }
        return coreApiCode == nil
    }

    /// 提示文案。**把核心给的原话留在前面**，用户已经能从那里看到真因。
    public static func message(reason: String) -> String {
        "\(reason)\n\n连不上的原因很可能在协议上：不少 NAS 的 WebDAV / 管理口只提供明文 HTTP。"
            + "闪寻不会替你自动换成不加密的连接——要试的话，点下面的按钮，它会打开「使用明文 HTTP」再重连一次。"
    }
}
