import Foundation

/// 连接 / 登录 / 读共享失败的诊断文案（向导链路）。
///
/// 不能留在 App 层当私有静态方法——私有方法一行测试都写不了，
/// 而它恰恰决定了「用户在连接向导里看到什么」。搬进 Core 之后：
/// 与 `OpenFailureText`、`NASSearchFailureText` 共用同一套中文，
/// 并且能被测试逐分支锁住。
///
/// 三条出口（握手 / 登录 / 登录后读共享）共用这一处，不是偷懒：
/// 三处各写一遍必然会漏掉其中一处——「原因被丢掉」就是这么来的。
public enum ConnectionFailureText {
    /// 把底层错误翻成「用户下一步该做什么」。
    ///
    /// - 顺序是有意的：越具体的判断越靠前。`URLError` 能区分「连不上」与
    ///   「超时」，`coreReason` 是核心写好的现场原因，都比按类型猜准。
    public static func describe(_ error: Error, host: String, port: Int) -> String {
        if let http = error as? HTTPFailure, http.status == 401 { return "账号或密码不正确" }
        if let url = error as? URLError {
            switch url.code {
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                    .serverCertificateHasUnknownRoot, .serverCertificateNotYetValid,
                    .clientCertificateRejected, .clientCertificateRequired:
                return "\(host):\(port) 无法验证证书。请确认 NAS 地址是否正确，然后按提示核对证书指纹。"
            case .cannotConnectToHost, .cannotFindHost:
                return "\(host):\(port) 连不上。请检查地址和端口，或确认这台 Mac 是否与 NAS 在同一网络。"
            case .timedOut:
                return "\(host):\(port) 响应超时。"
            default: break
            }
        }

        let text = error.localizedDescription

        if let flash = error as? FlashFindError {
            // 核心那边**已经写好了一句人话**时，优先用它。
            //
            // 品牌适配器给的原因比按 kind 猜出来的准得多：同样是
            // `AuthenticationFailed`，「TLS 握手失败」与「账号或密码不正确」
            // 要用户做的事完全不同。早期的 `contains("AuthenticationFailed")`
            // 会把前者也改写成「账号或密码不正确」——用户跑去重输密码，
            // 而真正的问题是端口只讲明文 HTTP，越试越偏。
            if let reason = flash.coreReason, !reason.isEmpty { return reason }
            switch flash {
            case let .message(message):
                return message
            case let .coreFailure(kind, _, apiCode):
                // ★ 这里必须走中文表，不能用 `localizedDescription`：
                // `coreFailure.errorDescription` 返回的是 **kind**
                // （Models.swift 里刻意如此，因为既有代码靠它做字符串判断），
                // 直接显示就是把 "TLSRejected" 甩给用户。
                // 与 OpenFailureText 同一套中文，两条链路不能说出两种话。
                if let legacy = legacyWording(for: kind) { return legacy }
                return NASSearchFailureText.describe(kind: kind, apiCode: apiCode)
            }
        }

        // 兼容：错误不是 FlashFindError、但描述里带了旧版 kind 字面量
        // （例如旧核心仍在运行、或中间层把 kind 拼进了描述）。
        // 这些分支只在此处兜底，正常路径已由上面的中文表覆盖。
        if text.contains("AuthenticationFailed") { return "账号或密码不正确" }
        if text.contains("NeedsOTP") { return "此账号需要动态口令，请填写 OTP" }
        if text.contains("UnexpectedAdminIdentity") {
            return "这个 NAS 拒绝了管理员账号。当前版本允许使用管理员搜索，请更新后再试。"
        }
        return text
    }

    /// 中文表里查不到、但历史上单独处理过的 kind。
    ///
    /// `UnexpectedAdminIdentity` 已在核心里取消（管理员账号允许使用）。
    /// 这里保留一条兼容文案：若旧版本核心仍在运行，给出可理解的说明。
    private static func legacyWording(for kind: String) -> String? {
        kind == "UnexpectedAdminIdentity"
            ? "这个 NAS 拒绝了管理员账号。当前版本允许使用管理员搜索，请更新后再试。"
            : nil
    }

    /// 这次失败是不是「设备要求动态口令（两步验证）」造成的。
    ///
    /// ## 为什么必须单独判一次
    ///
    /// 自动重连用的密码是本机凭据文件里那把，而 OTP 是**一次性的**——它根本
    /// 不在（也不该在）本机保存。于是这条死路就出现了：
    ///
    /// ```
    /// 自动重连 → login(password, otp: nil) → NeedsOTP → 状态卡片写「需要两步验证码」
    /// 点「重新登录…」→ 又走自动重连 → 还是 otp: nil → 又失败 → 点一百次也一样
    /// ```
    ///
    /// 状态卡片上那句「重新连接并填写动态码」指向的动作，界面上根本不存在——
    /// 这是最糟的一种提示：说了怎么办，却办不到。
    ///
    /// 判定必须放在 Core 里：App 层的 `reconnectSource` 无法被测试目标 import，
    /// 而「哪种失败该弹 OTP 框」正是这次报障的根因，值得被逐分支锁住。
    ///
    /// `OTPRejected` 也算：用户填错一次码之后，要能再弹一次让他重填，
    /// 而不是把他扔在「设备拒绝了这个动态验证码」上无路可走。
    public static func isOTPRequired(_ error: Error) -> Bool {
        if let flash = error as? FlashFindError {
            if case let .coreFailure(kind, _, _) = flash {
                return kind == "NeedsOTP" || kind == "OTPRejected"
            }
        }
        // 兼容：错误不是 FlashFindError、但描述里带了旧版 kind 字面量。
        let text = error.localizedDescription
        return text.contains("NeedsOTP") || text.contains("OTPRejected")
    }

    /// 需要用户补一个动态验证码时，弹窗里该说什么。
    ///
    /// 文案住 Core：这句要同时出现在弹窗标题、说明与状态卡片上，
    /// 三处各写一遍必然走样（同 kind 不得两种说法）。
    public static func otpPromptText(sourceName: String) -> String {
        "「\(sourceName)」开启了登录两步验证。动态验证码是手机验证器或短信里那 6 位数字，"
            + "每次登录都不一样，本机不会保存它，所以这次需要你重新填一个。"
    }
}

/// 连接尝试的序号闸门：让「上一次尝试」在飞行途中失效。
///
/// 抽出来的理由是它是**纯逻辑但极易写错**，而 App 层测不了：
/// 用户双击「连接」、取消后重连、改配置再连，都会并发起第二条
/// discover→login 流程，两条互相覆盖会话与证书确认——
/// 表现就是「偶发登录失败 / 证书弹两次 / 连上又断」。
///
/// 语义只有一条：**最新那次尝试才允许写连接状态**。
public final class ConnectionAttemptGate: @unchecked Sendable {
    private let lock = NSLock()
    private var current = 0

    public init() {}

    /// 开一次新尝试：让此前所有在飞的尝试失效，返回本次序号。
    @discardableResult
    public func next() -> Int {
        lock.lock(); defer { lock.unlock() }
        current += 1
        return current
    }

    /// 这次尝试是否仍是「最新的那次」。
    public func isCurrent(_ attempt: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return attempt == current
    }

    /// 让所有在飞的尝试失效，但**不开始**新的一次。
    ///
    /// 取消 / 关闭窗口用这个：此时不该有「当前尝试」，
    /// 用 `next()` 会让界面误以为又开了一次连接。
    public func invalidate() {
        lock.lock(); defer { lock.unlock() }
        current += 1
    }
}
