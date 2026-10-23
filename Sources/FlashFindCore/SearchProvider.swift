import Foundation

public enum SearchSourceType: String, Sendable { case local, nas }
public enum SearchOpenTarget: Hashable, Sendable {
    case mountedFile(URL), smbLocation(URL), unavailable
}
public struct SearchSource: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let type: SearchSourceType
    /// 对外展示给用户的来源名（设置页与结果行共用），不含 IP、端口或品牌技术细节。
    public let displayName: String
    public init(id: String, name: String, type: SearchSourceType, displayName: String? = nil) {
        self.id=id; self.name=name; self.type=type; self.displayName=displayName ?? name
    }
    public static let local = SearchSource(id: "local_mac", name: "本机", type: .local, displayName: "此 Mac")
    /// 已安装的应用程序（「搜索 app」）。
    ///
    /// 与 `local` 分开而不是并进去：结果行的来源徽标要写「应用程序」，
    /// 图标要用 app 本体自带的图标，排序也要压在本机文件前面。
    /// 同属 `.local` 一侧，因此立即出结果、不走 NAS 那条防抖。
    public static let apps = SearchSource(id: "local_apps", name: "应用程序", type: .local, displayName: "应用程序")
    /// NAS 来源 ID 由配置派生，不含任何写死的主机或共享。
    public static func nas(id: String, displayName: String) -> SearchSource {
        SearchSource(id: id, name: displayName, type: .nas, displayName: displayName)
    }
}
public enum ProviderSearchState: String, Sendable {
    case searching, completed, cancelled, timedOut, failed, degraded, blocked
    /// 结果数超过核心上限，只发布了前一部分。**这不是失败**——已经拿到的结果仍然有效。
    case truncated
    /// 登录态已失效（DSM 会话过期 / 被注销）。**这不是搜索失败**——搜索根本没开始跑。
    case needsAuth
    /// 设备没有可用的服务端搜索接口，已降级为受限的逐层目录遍历。
    case limitedTraversal
    /// 设备侧搜索任务**未就绪**：它报了 `finished` 却没有 `total`。
    ///
    /// 这**不是失败、更不是「没有找到文件」**：设备只是还没把结果算出来
    /// （设备侧在连续搜索后会进入数分钟的退化窗口）。界面上必须说成
    /// 「稍后再试」，而不是「搜索失败」或「0 条结果」。
    case deviceBusy

    /// 从核心的 `resultState` 映射到界面状态。
    ///
    /// 核心的取值集合是它的**协议**，与这里的枚举是两个独立的东西，必须显式对齐。
    ///
    /// 不能用 `ProviderSearchState(rawValue:) ?? .failed`。后果是
    /// `truncated`（结果超过上限）、`needsAuth`（登录已过期）、`limitedTraversal`
    /// 三个取值在枚举里不存在 → `rawValue` 构造返回 nil → **全部静默退化成 `failed`**。
    /// 界面上只留下一个没有任何信息量的 "failed"：
    /// 「结果太多被截断」和「登录早就过期」显示得一模一样，
    /// 用户不知道该怎么办，排查的人也不知道该往哪看。
    ///
    /// 新增核心状态时必须同时在这里登记，否则 `NASSearchStateMappingTests` 会失败。
    public static func fromCore(_ raw: String?) -> ProviderSearchState {
        switch raw {
        case .some("searching"): return .searching
        case .some("completed"): return .completed
        case .some("cancelled"): return .cancelled
        case .some("timedOut"): return .timedOut
        case .some("truncated"): return .truncated
        case .some("needsAuth"): return .needsAuth
        case .some("limitedTraversal"): return .limitedTraversal
        case .some("deviceBusy"): return .deviceBusy
        case .some("failed"): return .failed
        // 缺字段与未知取值都不能冒充成功，但也不该被当成已知原因——见下。
        default: return .failed
        }
    }

    /// 这个取值是否代表「核心把一次真实的状态变化告诉了我们」。
    /// 未知取值返回 false，调用方据此在提示里说明「未识别的状态」。
    public static func isKnownCoreState(_ raw: String?) -> Bool {
        guard let raw else { return false }
        return fromCore(raw).rawValue == raw
    }
}

/// 把核心的错误 `kind` 翻译成用户能读懂、并且能据此行动的一句话。
///
/// 规划书要求失败提示说清「发生了什么、接下来怎么办」，
/// 不允许只抛 `Open failed` 这类技术文本；但 `NetworkFailure` / `SessionExpired`
/// 这种开发者术语同样不合格。这里给中文主句，并把原始 kind 与设备错误码
/// 放在括号里供排查——两者都要，缺了哪一个都会让下一次故障重新变成谜。
public enum NASSearchFailureText {
    /// 有「核心写好的原因」时优先用它。
    ///
    /// 核心的 `reason` 来自适配器，比按 `kind` 猜出来的准：同一个
    /// `AuthenticationFailed`，可能是密码错、也可能是连不上（TLS 失败）。
    /// 按 kind 猜只能猜中前者。
    public static func describe(kind: String?, apiCode: Int?, reason: String?) -> String {
        if let reason, !reason.isEmpty { return reason }
        return describe(kind: kind, apiCode: apiCode)
    }

    /// kind → 中文主句。
    ///
    /// ## 这是跨语言契约的 Swift 一侧
    ///
    /// Dart 核心在 `MyNASCore/lib/error_kinds.dart` 里登记了它会抛出的全部
    /// kind，其中 `userFacing` 那一部分**承诺界面一定有话可说**。这张字典就是
    /// 那份承诺的兑现处，两边由 `AdapterErrorKindParityTests` 逐条比对，
    /// 契约文件是 `MyNASCore/error_kinds.json`。
    ///
    /// 它若只是张手抄的 switch 表，与 Dart 侧就没有校验关系。后果是
    /// Dart 新增了 `HttpFailure`（HTTP/TLS 层失败）、`TLSRejected`、
    /// `ApiError` 等十余个 kind，Swift 一个都不认得，界面只能落到兜底分支显示
    /// 「设备返回了未预期的错误（HttpFailure）」——把技术名词甩给用户，
    /// 而核心那句「文件流请求失败（HTTP 500）」明明就躺在 `reason` 里
    /// （`reason` 为空时则连这个也没有）。
    ///
    /// 新增 Dart kind 时同步在这里登记，否则那个测试会红。
    public static let sentences: [String: String] = [
        "AuthenticationFailed": "账号或密码被设备拒绝，请在「搜索来源」里更新凭据",
        "AccountDisabled": "该账号已被设备停用",
        "PasswordLifecycle": "设备要求修改或重新设置密码",
        "NeedsOTP": "设备要求两步验证码；重新连接并填写动态码",
        "OTPRejected": "设备拒绝了这个动态验证码，请重新连接并重新填写",
        "IPBlocked": "设备的防暴力破解已封禁本机地址，请在设备上解封后重试",
        "PermissionDenied": "该账号没有这个目录的权限",
        "SessionExpired": "登录已过期，请在「搜索来源」里重新连接后再搜",
        "NeedsAuth": "登录已过期，请在「搜索来源」里重新连接后再搜",
        "IdentityUnverified": "未能确认账号身份，请重新连接",
        "NetworkFailure": "网络中断或设备没有响应",
        "TimedOut": "设备响应超时",
        "Cancelled": "这次搜索已取消",
        "TLSRejected": "TLS 握手失败：协议或端口可能不对（有些设备的管理口只讲明文 HTTP），请检查连接信息里的协议与端口",
        "HttpFailure": "设备返回了 HTTP 错误响应（与账号密码无关）",
        "HttpDenied": "设备拒绝了这次请求（HTTP 401/403）：登录态可能已失效，或该账号没有这个位置的权限",
        "RedirectRejected": "设备把请求重定向到了别的地址，闪寻已拒绝跟随（常见原因：协议或端口填错）",
        "ResponseTooLarge": "设备返回的响应过大，闪寻已停止读取；请缩小搜索范围",
        "UnsafeEndpoint": "连接地址不符合安全要求：必须是 https，且不能带用户名密码或路径",
        "ProtocolViolation": "设备返回的内容不符合预期（反向代理或登录门户页也可能造成这个现象）",
        "RateLimited": "服务器在限流（请求过多），与账号密码无关；请等几分钟再试",
        "EmptyScope": "已连接，但这个根目录下没有可搜索的文件夹（详见上方说明）",
        "UnexpectedFailure": "闪寻内部处理这次请求时出了意外，请把诊断信息反馈给我们",
        "UnknownFailure": "发生了未归类的错误，请把诊断信息反馈给我们",
        "AdapterUnavailable": "这台设备的适配器还不可用",
        "UnverifiedAdapter": "这个品牌还没有在真机上验证过，连接可能失败",
        "DirectoryUnstable": "搜索过程中目录内容发生了变化，请重试",
        "ResultsNotReady": "设备的搜索服务暂时没准备好结果（短时间内连续搜索后常见），请等一会儿再搜",
        "IncompleteResponse": "设备返回的分页数据不完整，请重新搜索",
        "UnknownSubmission": "搜索已提交但设备没有确认，任务状态不明",
        "TaskNotFound": "搜索任务已被设备清理",
        "PathMissing": "目录在设备上不存在",
        "UnsupportedApi": "该设备固件不支持文件搜索接口",
        "UnsupportedVersion": "该设备固件不支持文件搜索接口",
        "UnsupportedSearchNoFallback": "该设备没有可用的服务端搜索",
        "UnsupportedQuery": "该设备不接受这个搜索词",
        "UnsupportedVendor": "这个品牌还没有对应的接入实现，暂时无法搜索",
        "ScopeDenied": "所选目录不在该账号的可搜索范围内",
        "ScopeUnavailable": "所选目录不在该账号的可搜索范围内",
        "ScopeUnset": "还没有选择这台 NAS 的搜索位置",
        "ResultLimit": "结果超过上限",
        "UnsafeLogicalPath": "设备返回了不安全的路径，已拒绝",
        "UnknownApiError": "设备返回了未知错误",
        "ApiError": "设备返回了一个业务错误",
        "InvalidTrustConfiguration": "证书固定配置不完整或已失效，请在「搜索来源」里删除这个来源后重新添加",
        "ExplicitCertificateConfirmationRequired": "这台设备的证书需要你确认后才能继续，请在连接向导里完成确认",
    ]

    /// 认得、但**不配用户文案**的种类。
    ///
    /// 它们是连接/启动/协议层的内部取值，界面另有专门处理或根本不该出现。
    /// 登记在这里是为了让契约校验能区分「不认得」和「认得但故意不给文案」。
    ///
    /// 一旦其中某个开始出现在失败提示上，就应当移进 [sentences] 并配文案。
    public static let internalKinds: Set<String> = [
        "AuthInProgress", "InputTooLarge", "OriginChanged", "ShuttingDown",
        "SourceExists", "TrustStoreFailure", "UnknownSource", "UnsafeApiPath",
        "UnsafeOpenTarget", "UnsupportedCommand", "UnsupportedFormat", "UnsupportedMode",
    ]

    /// Swift 认得的全部 kind。`sentences` 与 `internalKinds` 之和。
    public static var registeredKinds: Set<String> {
        Set(sentences.keys).union(internalKinds)
    }

    public static func describe(kind: String?, apiCode: Int?) -> String {
        let sentence: String
        if let kind, let hit = sentences[kind] {
            sentence = hit
        } else if let kind {
            sentence = "设备返回了未预期的错误（\(kind)）"
        } else {
            sentence = "设备没有说明原因"
        }
        // 设备错误码是最有排查价值的单个字段，必须带出来。
        if let apiCode { return "\(sentence)（设备错误码 \(apiCode)）" }
        if let kind, kind != "UnknownApiError" { return "\(sentence)（错误类型 \(kind)）" }
        return sentence
    }
}
public struct ProviderEvent: Sendable {
    public let queryID: UUID
    public let sourceID: String
    public let results: [SearchResult]
    public let state: ProviderSearchState
    public let message: String?
    /// 结果是否**可能不完整**：达到时间/数量上限、设备侧 truncated、
    /// 部分目录读不到或跳过。含义只有「结果全不全」，与「请求结没结束」无关。
    ///
    /// ★ 这两件事以前挤在同一个字段 `isComplete` 里：本机侧用它表示「结果没收全」，
    /// 取消路径又把它默认成 `false`，于是同一个 `.cancelled` 终态在「排队时被取消」
    /// 与「在跑时被取消」两种来源下取值不同。字段拆开后各只剩一个含义。
    ///
    /// ★ 名字故意不叫 `truncated`：本机遍历的 warnings 里有「部分目录读不到」
    /// 「已跳过越界路径」，它们同样意味着结果可能缺项，但都不是「截断」。
    public let resultsIncomplete: Bool
    public let reportedTotal: Int?
    public let cleanupState: String?
    public let isMetadataUpdate: Bool

    /// 本条事件是不是这次 Provider 请求的**终态**。
    ///
    /// ★ 由 `state` 与 `isMetadataUpdate` 唯一决定，**不允许调用方传**：
    /// 能传就能传错，而「同一件事两种取值」正是 v0.7 复审指出的契约矛盾。
    /// 定义与 `SearchCompletionTracker` 共用这一处，别再在别处重写判据。
    ///
    /// 终态 = `completed / cancelled / failed / timedOut / truncated /
    /// limitedTraversal / degraded / blocked / needsAuth` 之一；`searching`
    /// 只是「还在跑」，元数据补发（`isMetadataUpdate`）更不是终态。
    ///
    /// ★ **枚举契约（1.1.2 冻结）：`ProviderSearchState` 里除 `.searching` 以外
    /// 的取值全部是终态。** 这条是上面那行实现的**前提**，不是它的结论——
    /// 以后若给枚举加上非终态的中间状态（`.connecting` / `.waiting` /
    /// `.retrying` 之类），`state != .searching` 会把它**静默当成终态**，
    /// 于是「还在等设备回包」被记成「这次搜索结束了」，界面提前收声。
    /// 加这类取值时必须同步改这一行（改成显式的终态集合），
    /// 并在 `ProviderTerminalContractTests` 里补一条对应用例。
    public var isTerminal: Bool { !isMetadataUpdate && state != .searching }

    public init(queryID: UUID, sourceID: String, results: [SearchResult] = [], state: ProviderSearchState, message: String? = nil, resultsIncomplete: Bool = false, reportedTotal:Int? = nil, cleanupState:String? = nil, isMetadataUpdate:Bool = false) {
        self.queryID=queryID;self.sourceID=sourceID;self.results=results;self.state=state;self.message=message;self.resultsIncomplete=resultsIncomplete;self.reportedTotal=reportedTotal;self.cleanupState=cleanupState;self.isMetadataUpdate=isMetadataUpdate
    }
}
@MainActor public protocol SearchProvider: AnyObject {
    var source: SearchSource { get }
    /// 跑一次搜索。
    ///
    /// ★ **终态契约（恰好一次）**：一次 `search` 调用期间、在它 `return` 之前，
    /// 必须已经发出**恰好一个** `isTerminal` 事件（`completed` / `cancelled` /
    /// `failed` / `timedOut` / `blocked` / `degraded` …）。
    ///
    /// - 正常结束 → 自己的终态；
    /// - 被 `cancel(queryID:)` 打断 → **仍然要补发 `.cancelled`**，不能只是
    ///   清掉内部状态然后沉默返回。沉默的后果不是「少一条日志」：上层
    ///   `SearchCompletionTracker` 会一直把这个来源记在 pending 里，界面
    ///   永久显示「正在搜索」。
    /// - 不许发第二个终态：`.cancelled` 之后所有分支都已被
    ///   `guard active == queryID` 挡住，别在 cancel 与 return 两处各发一次。
    func search(_ text: String, queryID: UUID, emit: @escaping @MainActor (ProviderEvent) -> Void) async
    /// 带发起方的入口（见 `SearchOwner`）。
    ///
    /// ★ 它必须是**协议要求**，不能只是 protocol extension 里的方法：
    /// 通过 `any SearchProvider` 调用时，非要求的扩展方法走静态派发，
    /// `NASSearchProvider` 里写的「跨 owner 不取消」实现根本不会被调用——
    /// 编译期毫无提示，运行时表现为跨 owner 照样互相取消。
    func search(_ text: String, queryID: UUID, owner: SearchOwner,
                emit: @escaping @MainActor (ProviderEvent) -> Void) async
    func cancel(queryID: UUID)
}

extension SearchProvider {
    /// 默认实现：不知道发起方的 provider（本机、应用程序、测试假件）等价于 GUI 发起。
    public func search(_ text: String, queryID: UUID, owner: SearchOwner,
                       emit: @escaping @MainActor (ProviderEvent) -> Void) async {
        await search(text, queryID: queryID, emit: emit)
    }
}
public enum NASQueryPolicy {
    // Only a contiguous literal containing >=2 Han/Latin/digit characters. No DSM glob.
    public static func accepted(_ text: String) -> Bool {
        let text=text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return false }
        var count=0
        for scalar in text.unicodeScalars {
            let n=scalar.value
            if (0x3400...0x9fff).contains(n) || (0x20000...0x3134f).contains(n) || (65...90).contains(n) || (97...122).contains(n) || (48...57).contains(n) { count += 1 }
            else if scalar != " " && scalar != "_" && scalar != "-" && scalar != "." { return false }
        }
        return count >= 2
    }
}
