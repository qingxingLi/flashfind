import Foundation

/// 「检查更新」：读公开仓的最新发布，跟当前版本比一比。
///
/// ## 为什么只判断、不自动装
///
/// 更新包还没有 Developer ID 签名与公证（见发布说明），自动替换 App 的那套
/// （下载 → 验签 → 替换 → 失败回滚）在不签名的前提下反而更危险：验签这一步
/// 要么必然失败，要么被骗着跳过。所以这里只回答「有没有新版」，
/// 有的话把用户送到发版页，下载与拖动交给他自己——出问题也看得见。
///
/// ## 为什么判定全放在 Core
///
/// 三件事都容易写错，而 App 层是 `executableTarget`、测试目标 import 不到：
///
/// 1. **版本号比较**：`1.0.10` 比 `1.0.9` 新，按字符串比会得出相反结论；
/// 2. **返回体字段**：把 `tag_name` 写成 `name` 会一直显示「已是最新」；
/// 3. **失败的说法**：GitHub 限流（403）跟断网是两件不同的事，
///    用同一句话糊过去，用户只会反复重试。
///
/// 因此判定收成纯函数，网络请求由调用方注入（`transport`），
/// 单元测试不需要联网，也不会因为 GitHub 抖一下就红。
public enum UpdateCheck {

    /// 公开仓。写死在这里、不读 Info.plist：它是产品行为的一部分，
    /// 跟着发行包走的话，某次打包漏了键就会静默变成「永远最新」。
    public static let repository = "qingxingLi/flashfind"

    /// `/releases/latest` 只返回**已发布且非预发布**的最新一版，
    /// 正好是「要不要提示用户升级」想要的语义。
    public static var latestReleaseAPI: URL {
        // 字面量拼装不会失败；用 `!` 是为了不给调用点一个「URL 可能没有」的分支。
        URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!
    }

    /// 发版列表页。检查失败时给用户一个自己去看的地方，
    /// 也让「有新版本」在没有 `html_url` 时仍有落点。
    public static var releasesPage: URL {
        URL(string: "https://github.com/\(repository)/releases")!
    }

    /// 取数方式。默认走 `URLSession`，测试注入假实现。
    public typealias Transport = (URLRequest) async throws -> (Data, URLResponse)

    public static let live: Transport = { request in
        try await URLSession.shared.data(for: request)
    }

    /// `/releases/latest` 里我们真正需要的两个字段。
    public struct LatestRelease: Equatable, Sendable {
        /// 标签原文，通常带 `v`（`v1.0.2`）。
        public let tag: String
        /// 这一版发布的页面地址。
        public let page: URL?

        public init(tag: String, page: URL?) {
            self.tag = tag
            self.page = page
        }
    }

    /// 一次检查的结论。
    ///
    /// **没有 `.checking`**：那是界面状态，由 App 层用一个布尔位表示。
    /// 混进结论里，「有没有结果」就变得要判断两次。
    public enum Outcome: Equatable, Sendable {
        /// 已是最新。`current` 供展示。
        case upToDate(current: String)
        /// 有新版本。`latest` 已去掉 `v` 前缀，`page` 是发版页。
        case updateAvailable(latest: String, page: URL?)
        /// 当前不是数字版本（从源码直接跑的裸二进制），没有可比较的对象。
        case incomparable(current: String)
        /// 没查成。`reason` 是给人看的一句话。
        case failed(reason: String)
    }

    /// 检查过程中可能出现的、能说清楚原因的失败。
    ///
    /// 走 `Error` 而不是直接返回字符串，是为了让 `evaluate` 能把「我们自己
    /// 判定出来的失败」与「`URLSession` 抛的错」分开说——后者只有
    /// `localizedDescription`，措辞随系统语言变。
    public enum Failure: Error, Equatable {
        case httpStatus(Int)
        case malformedResponse

        public var text: String {
            switch self {
            case .httpStatus(403):
                // 匿名请求按 IP 限流（每小时 60 次）。连点几下「检查更新」就可能撞上，
                // 这时说「连不上」会让用户去查网络，方向全错。
                return "GitHub 暂时限制了查询频率，请过一会儿再试"
            case .httpStatus(404):
                return "公开仓里还没有发布版本"
            case .httpStatus(let code):
                return "GitHub 返回了 HTTP \(code)"
            case .malformedResponse:
                return "GitHub 返回的内容看不懂，接口可能变了"
            }
        }
    }

    // MARK: - 版本号比较

    /// 这个版本号能不能参与比较。
    public static func isComparable(_ version: String) -> Bool {
        numbers(in: version) != nil
    }

    /// `candidate` 是否比 `current` 新。
    ///
    /// 规则：去掉 `v` 前缀，按 `.` 切段**逐段比数字**，缺的段按 0 补
    /// （`1.0` 与 `1.0.0` 相同）；数字全等时，带 `-beta` 这类后缀的
    /// 视为同一版本的预发布，**比正式版旧**。
    ///
    /// 任一侧不是数字版本（如「开发构建」）时返回 `false`——
    /// 这种情况 `evaluate` 会提前拦下，界面走不到这里。
    public static func isNewer(_ candidate: String, than current: String) -> Bool {
        guard let a = numbers(in: candidate), let b = numbers(in: current) else { return false }
        for index in 0 ..< max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return isPrerelease(current) && !isPrerelease(candidate)
    }

    /// 取出数字段。切出空段、或某段不以数字开头，就返回 `nil`（不可比较）。
    ///
    /// `1.0.1` → `[1, 0, 1]`；`v1.0.2` → `[1, 0, 2]`；
    /// `1.0.1-beta` → `[1, 0, 1]`（后缀在 `isPrerelease` 里另算）；`开发构建` → `nil`。
    static func numbers(in version: String) -> [Int]? {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        if let dash = text.firstIndex(of: "-") { text = String(text[..<dash]) }
        guard !text.isEmpty else { return nil }
        var result: [Int] = []
        for part in text.split(separator: ".", omittingEmptySubsequences: false) {
            let digits = part.prefix { $0.isNumber }
            guard !digits.isEmpty, let value = Int(digits) else { return nil }
            result.append(value)
        }
        return result.isEmpty ? nil : result
    }

    static func isPrerelease(_ version: String) -> Bool {
        var text = version.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text.contains("-")
    }

    /// 展示用的版本号：GitHub 的标签习惯带 `v`，界面上不必跟着带。
    public static func displayTag(_ tag: String) -> String {
        var text = tag.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("v") || text.hasPrefix("V") { text.removeFirst() }
        return text
    }

    // MARK: - 解析

    /// 解析 `/releases/latest` 的返回体。
    ///
    /// 只取 `tag_name` 与 `html_url`。用 `JSONSerialization` 而不是 `Codable`：
    /// 两个字段建一整套结构体，还得跟着 GitHub 的字段增减维护，
    /// 真正的风险（字段名写错）它一样挡不住。
    public static func parseLatestRelease(_ data: Data) throws -> LatestRelease {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let root = object as? [String: Any],
              let raw = root["tag_name"] as? String else {
            throw Failure.malformedResponse
        }
        let tag = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tag.isEmpty else { throw Failure.malformedResponse }
        return LatestRelease(tag: tag, page: releasePage(from: root["html_url"] as? String))
    }

    /// 只放行 http/https：这个地址马上要交给「用浏览器打开」，
    /// 别的 scheme（`file:`、`javascript:`）一律不认。
    static func releasePage(from raw: String?) -> URL? {
        guard let raw,
              let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http",
              url.host != nil else { return nil }
        return url
    }

    // MARK: - 一次检查

    /// 查一次并给出结论。
    ///
    /// 所有分支都必须落到一个可展示的 `Outcome`：失败也返回 `.failed`，
    /// 不抛给界面——用户点的是一个按钮，看到的应该是一句话，不是一个弹窗。
    public static func evaluate(current: String,
                                transport: Transport = UpdateCheck.live) async -> Outcome {
        // 开发构建没有版本号可比。这一句必须**在发请求之前**：
        // 比不了还去打扰 GitHub，只会换来一个没人看得懂的结论。
        guard isComparable(current) else { return .incomparable(current: current) }

        var request = URLRequest(url: latestReleaseAPI)
        request.httpMethod = "GET"
        request.timeoutInterval = 15
        // 走缓存的话，刚发的新版要过一阵才看得到；手动点「检查更新」时，
        // 用户要的是「现在」的答案。
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub 的 API 要求带 User-Agent，缺了直接 403——表现为「永远查不了」。
        request.setValue("FlashFind/" + current, forHTTPHeaderField: "User-Agent")

        let body: Data
        do {
            let (data, response) = try await transport(request)
            guard let http = response as? HTTPURLResponse else { throw Failure.malformedResponse }
            guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }
            body = data
        } catch let failure as Failure {
            return .failed(reason: failure.text)
        } catch {
            return .failed(reason: "连不上 GitHub：\(error.localizedDescription)")
        }

        do {
            let latest = try parseLatestRelease(body)
            guard isNewer(latest.tag, than: current) else { return .upToDate(current: current) }
            return .updateAvailable(latest: displayTag(latest.tag), page: latest.page)
        } catch let failure as Failure {
            return .failed(reason: failure.text)
        } catch {
            return .failed(reason: error.localizedDescription)
        }
    }
}

/// 「检查更新」的界面文案。
///
/// 与 `ConnectionFailureText` 同理：放在 Core 才测得到，而这里恰恰是最容易
/// 出现「失败了好几种、说法只有一句」的地方。
public enum UpdateCheckText {

    /// 按钮标题。检查中换文案，让用户知道点下去之后发生了什么。
    public static func button(checking: Bool) -> String {
        checking ? "正在检查…" : "检查更新"
    }

    /// 结论一句话。
    public static func message(for outcome: UpdateCheck.Outcome) -> String {
        switch outcome {
        case .upToDate(let current):
            return "已是最新版本（\(current)）。"
        case .updateAvailable(let latest, _):
            return "有新版本 \(latest) 可以下载。"
        case .incomparable(let current):
            return "当前是\(current)，没有可比较的版本号。"
        case .failed(let reason):
            return "检查失败：\(reason)"
        }
    }

    /// 结论旁边的次要按钮。没有可点的东西就返回 `nil`——
    /// 不摆一个点了没反应的死按钮。
    public static func linkTitle(for outcome: UpdateCheck.Outcome) -> String? {
        switch outcome {
        case .updateAvailable: return "前往下载"
        case .failed: return "打开发布页"
        case .upToDate, .incomparable: return nil
        }
    }

    /// 次要按钮的目标地址。
    ///
    /// 「有新版本」优先用返回体里给的页面；没给就退回发版列表——
    /// 那上面一定有这一版。失败时也给发版列表，用户可以自己去看。
    public static func link(for outcome: UpdateCheck.Outcome) -> URL? {
        switch outcome {
        case .updateAvailable(_, let page): return page ?? UpdateCheck.releasesPage
        case .failed: return UpdateCheck.releasesPage
        case .upToDate, .incomparable: return nil
        }
    }
}
