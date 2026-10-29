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
            case let .authorizationRequired(url, _, _, _):
                // 走到这里说明上层没有单独处理授权态（正常路径应当先接住它、
                // 给出「打开链接 + 填授权码」的界面）。兜底文案必须**带上地址**：
                // 只说「需要授权」而不给入口，用户只能干看着。
                return "这台设备需要在浏览器里完成授权。请打开 \(url.absoluteString)，"
                    + "登录后把页面上显示的授权码填回闪寻。"
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
    public static func isOTPRequired(_ error: Error) -> Bool { otpFailure(error) != nil }

    /// 把失败的**哪一种** OTP 判出来。
    ///
    /// ★ 这一层是 2026-10-26 加的：只判「是不是 OTP」不够用。
    /// 用户报障原话：
    ///
    ///   「输入 OTP 验证码错误，不会提示验证码错误，而是没有什么反应，
    ///     还是在外边提示需要动态码，需再次点击登陆。」
    ///
    /// 成因就是这里只回了一个 Bool —— 上层于是只能拿同一句话去问，
    /// 「还没填过码」与「填了但被拒」被说成一回事，用户看不出自己错在哪。
    /// 现在两种分开：`.required` 说明这台设备要两步验证，`.rejected` 直说码不对。
    public static func otpFailure(_ error: Error) -> OTPFailure? {
        if let flash = error as? FlashFindError,
           case let .coreFailure(kind, _, _) = flash {
            if kind == "OTPRejected" { return .rejected }
            if kind == "NeedsOTP" { return .required }
            return nil
        }
        // 兼容：错误不是 FlashFindError、但描述里带了旧版 kind 字面量。
        // 先判 `OTPRejected`：它的字面量里不含 `NeedsOTP`，但顺序写死了更不怕以后被改写。
        let text = error.localizedDescription
        if text.contains("OTPRejected") { return .rejected }
        if text.contains("NeedsOTP") { return .required }
        return nil
    }

    /// 需要用户补一个动态验证码时，弹窗里该说什么。
    ///
    /// 文案住 Core：这句要同时出现在弹窗标题、说明与状态卡片上，
    /// 三处各写一遍必然走样（同 kind 不得两种说法）。
    ///
    /// - Parameter failure: `nil` / `.required` = 还没填过码；`.rejected` = 刚填的那个被拒。
    public static func otpPromptText(sourceName: String, failure: OTPFailure? = nil) -> String {
        switch failure {
        case .rejected:
            // ★ 首句必须直说「输入错误」。用户原话要求：
            //   「对话框内容里说明动态码输入错误，请再次输入」。
            return "动态码输入错误，请再次输入。「\(sourceName)」没有接受刚才那 6 位数字"
                + "（验证器每 30 秒换一个新码，别用刚用过的那个，前后也别带空格）。"
        case .required, .none:
            return "「\(sourceName)」开启了登录两步验证。动态验证码是手机验证器或短信里那 6 位数字，"
                + "每次登录都不一样，本机不会保存它，所以这次需要你重新填一个。"
        }
    }

    /// 弹窗标题按失败类型选。
    ///
    /// 码错时标题必须换：NSAlert 里最显眼的是标题，用户扫一眼就该知道
    /// 「刚才那个码不对」，而不是去正文第三行找原因。
    public static func otpDialogTitle(for failure: OTPFailure?) -> String {
        failure == .rejected ? otpRejectedTitle : otpDialogTitle
    }

    /// 动态码弹窗的标题。
    ///
    /// 2026-10-22 起**所有登录路径统一改成弹窗式**：设备要求动态码时就弹一个
    /// 独立的输入框，填完自动接着连，不再让用户回到表单里再点一次「连接」。
    /// 标题住 Core 是为了让弹窗、状态卡片、状态行说的是同一件事——
    /// 三处各写一遍必然走样（同 kind 不得两种说法）。
    public static let otpDialogTitle = "输入两步验证动态码"

    /// 上一次填的码被设备拒了：标题直接说错在哪。
    ///
    /// 与 `otpDialogTitle` 并列而不是在调用点写三元：
    /// 「两种说法」这类走样都是散在调用点开始积累的。
    public static let otpRejectedTitle = "动态码输入错误"

    /// 弹窗被取消之后，状态行里补的那一句：下一次怎么把它叫回来。
    ///
    /// ★ 上一版写的是「请在下方『该账号需要动态口令？』里填…」，
    /// 而那块折叠区改成弹窗式之后**已经不在界面上了** —— 指路指到一个
    /// 不存在的位置，等于没说；这正是上一版报障的成因。
    ///
    /// ★ 2026-10-26：改成带按钮名。两个入口的按钮**叫法本来就不一样**——
    /// 向导里是「连接」，来源卡片上是「登录」。写死一个名字，另一半用户就会
    /// 去找一个界面上不存在的按钮（同一条「不许指错控件」的教训）。
    /// 所以按钮名由调用方给，句子的其余部分仍只有一处，不会走样。
    public static func otpRetryHint(buttonTitle: String = "连接") -> String {
        "已跳过。再点一次「\(buttonTitle)」会重新弹出动态码输入框，填上手机验证器或短信中的 6 位数字即可。"
    }

    // MARK: - 浏览器授权（OAuth 授权码）

    /// 授权弹窗的标题。
    ///
    /// 与动态码那两条并列，理由相同：标题是用户扫一眼就看到的东西，
    /// 「请去授权」与「上次的码不对」必须是两个标题。
    public static let authorizeDialogTitle = "在浏览器里授权这台设备"
    public static let authorizeRejectedTitle = "授权码没有被接受"

    /// 浏览器授权弹窗里的说明：**授权地址 + 有效期 + code 在哪**。
    ///
    /// 三件事缺一不可：
    ///   * 地址要给全（用户要粘到浏览器里；截断就白搭）；
    ///   * 有效期要说（飞牛实测 5 分钟，超时后那串 code 交上去必然被拒，
    ///     而错误信息只会说「没有被接受」，用户会以为是自己抄错了）；
    ///   * 要说清 code 是**页面上那串**，不是它的登录密码。
    ///
    /// ★ 首句说「**已经**在浏览器里打开」，不说「点某个按钮打开」（2026-10-29 用户要求：
    ///   「点击连接直接弹出浏览器打开这个网页登陆授权就行」）。弹窗出现前 App 层已经
    ///   自动开过一次浏览器，文案再教用户去点，就变成让他做一件已经做完的事；
    ///   而真正该做的那一步（把码粘回来）反而被压到第二句。
    ///   「重新打开」按钮仍然保留 —— 页面被关掉时有路可走。
    public static func authorizationPromptText(sourceName: String, url: URL,
                                               validFor: TimeInterval,
                                               rejected: Bool) -> String {
        let minutes = max(1, Int((validFor / 60).rounded()))
        let head = rejected
            // 「没有被接受」必须整句连着出现：用户输错一次之后，首句就要让他
            // 知道是刚才那串错了（与动态码被拒同一类要求）。
            ? "刚才那串授权码没有被接受：「\(sourceName)」没有收下它。请重新授权。"
            : "「\(sourceName)」的登录要在浏览器里完成，这里没有账号密码可用。"
        return head
            + "授权页面已经在浏览器里打开了：登录并同意授权后，页面上会显示一串"
            // NSAlert 的 informativeText 是纯文本，不吃 Markdown —— 这里不许出现 `**`，
            // 否则用户看到的就是两个星号。要强调就把动作写进句子的顺序里。
            + "一次性授权码。请把它粘到下面的输入框里，再点「连接」。"
            + "页面关掉了就点「重新打开授权页面」。"
            + "这串码只有 \(minutes) 分钟有效期，过期需要再来一次。\n\n\(url.absoluteString)"
    }

    /// 向导里「授权码内联在表单上」时的状态行（2026-10-29 用户改流程，不再弹窗）。
    ///
    /// 与 `authorizationPromptText` 的分工必须分清楚，**不能互相借用**：
    ///   * 弹窗那条说「粘到下面的输入框」「页面关掉了就点『重新打开授权页面』」；
    ///   * 这条说「粘到「授权码」框里，再点「连接」」，获取入口叫「获取授权码」。
    /// 指路指到一个界面上不存在的控件，是这类文案最常犯的错
    /// （`otpRetryHint` 就踩过：把用户指去一个已经删掉的折叠区）。
    ///
    /// - Parameter rejected: 上一次交的码被设备拒了。此时首句必须直说「没有被接受」，
    ///   而不是让用户对着同一句「去授权」猜自己刚才那串到底怎么了。
    public static func authorizeInlinePrompt(sourceName: String, rejected: Bool,
                                              validFor: TimeInterval) -> String {
        let minutes = max(1, Int((validFor / 60).rounded()))
        let head = rejected
            ? "刚才那串授权码没有被接受：「\(sourceName)」没有收下它，已经重新打开了授权页面。"
            : "「\(sourceName)」的登录要在浏览器里完成，这里没有账号密码可用。授权页面已经在浏览器打开。"
        return head
            // 与弹窗文案同一条纪律：纯文本里不许出现 Markdown 记号，
            // 要强调就把动作写进句子顺序里。
            + "登录并同意授权后，把页面上那串一次性授权码粘到「授权码」框里，再点「连接」。"
            + "这串码只有 \(minutes) 分钟有效期，过期了就点一次「获取授权码」重新拿。"
    }

    /// 授权弹窗被取消之后，状态行里补的那一句。
    ///
    /// 取消不是失败，但界面上必须留一句「下次怎么继续」——
    /// 否则用户只看到一句「连接失败」，会以为是设备的问题。
    public static let authorizationCancelled =
        "已取消授权。这台设备要先在浏览器里完成授权才能连接，再点一次「连接」会重新生成授权地址。"

    /// 后台自动连接撞上「要授权」时，状态行里补的那一句。
    ///
    /// 与 `authorizationCancelled` 的区别：那条是用户点了取消，这条**没人可弹**。
    /// 后台连接发生在开机/定时重试里，弹窗会把一个不在电脑前的人堵住，
    /// 所以只留一句「需要你点一下」，把「什么时候做」交给用户。
    public static let authorizationNeededHint =
        "这台设备要在浏览器里完成授权才能连接。点「登录」会打开授权页面。"
}

/// 设备到底要的是「还没填过的码」还是「换个码」。
///
/// 单独的 enum 而不是两个 Bool：这两种情况的文案、标题、状态标记全都不一样，
/// 用一个类型带着走，调用点就不可能只处理其中一种。
public enum OTPFailure: Sendable, Equatable {
    /// 设备要求两步验证（码还没发上去）。
    case required
    /// 设备拒了刚才那个码。
    case rejected
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
