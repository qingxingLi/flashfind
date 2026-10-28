import Foundation

/// 一台 NAS 搜索来源的产品配置。
///
/// 这里是**唯一**存放地址、端口、账号、搜索位置的地方；
/// `NASSearchProvider` 只读这个结构，不再持有任何写死的主机或共享。
public struct NASSourceConfig: Codable, Identifiable, Hashable {
    public enum Vendor: String, Codable, CaseIterable, Identifiable {
        // 与 MyNAS 上游 `SourceType` 的存储类源对齐（上游还含 ftp/sftp/s3/upnp/local 等）。
        // `openlist` 不是 NAS 品牌，是聚合网盘服务；放在这里是因为它对闪寻而言
        // 与 NAS 同形：一个地址 + 一个账号 + 一个可搜索的目录树。
        case synology, qnap, ugreen, fnos, webdav, smb, generic, openlist
        public var id: String { rawValue }
        public var title: String {
            switch self {
            case .synology: return "群晖 Synology"
            case .qnap: return "威联通 QNAP"
            case .ugreen: return "绿联 UGREEN"
            case .fnos: return "飞牛 fnOS"
            case .webdav: return "WebDAV"
            case .smb: return "SMB / CIFS"
            case .generic: return "其他 NAS"
            case .openlist: return "OpenList"
            }
        }
        public var symbol: String {
            switch self {
            case .synology: return "externaldrive.connected.to.line.below"
            case .qnap: return "server.rack"
            case .ugreen: return "externaldrive"
            case .fnos: return "externaldrive.badge.icloud"
            case .webdav: return "globe"
            case .smb: return "network"
            case .generic: return "questionmark.circle"
            case .openlist: return "cloud"
            }
        }

        /// 列表行上的短名。
        ///
        /// `title` 是品牌全称（「群晖 Synology」），适合选型页；列表里的状态行
        /// 是「群晖 · 已连接」，用全称会显得啰嗦。两者都不含协议与端口——
        /// 那是实现细节，不该出现在行上。
        public var shortTitle: String {
            switch self {
            case .synology: return "群晖"
            case .qnap: return "威联通"
            case .ugreen: return "绿联"
            case .fnos: return "飞牛"
            case .webdav: return "WebDAV"
            case .smb: return "SMB"
            case .generic: return "网络存储"
            case .openlist: return "OpenList"
            }
        }

        /// 向导里**正式开放**的类型：不依赖「显示实验性搜索来源」也看得见。
        ///
        /// 这是 `ExperimentalSources.vendors(includingExperimental: false)` 的基线，
        /// 所以新增一项等于对所有用户开放，别往里塞没在真机上跑通的东西。
        /// 其余品牌（qnap / ugreen / webdav）仍需在高级里打开实验性开关。
        ///
        /// `openlist` 于 2026-10-24 在真实实例（v4.1.10 / commit e3c664f）上完成
        /// 登录、列存储、限定目录搜索与分页的实测，证据见
        /// `00-项目管理/任务交付/OL-AUTH-02-OpenList真实契约验证-20261024.md`。
        public static let selectableVendors: [Vendor] = [.synology, .openlist]

        /// 该品牌在闪寻里的接入状态。
        ///
        /// 从「接入/未接入」的布尔改成三态，是因为二值说法在两种情况下都不准确：
        ///   · 适配器**已经移植进来**、但**还没在真机上验证过** —— 说「支持」是骗人，
        ///     说「不支持」则会把一条本可以试的路堵死，而且真机校准的入口也没了。
        ///
        /// 这个区分来自一次真实教训：上游的飞牛适配器是「盲猜端点」写的，
        /// 实测在真实设备上它猜的第一个端点就返回 404。**结构就绪 ≠ 能用**，
        /// 界面必须能把这两种状态分开说。
        public enum AdapterStatus: Sendable {
            /// 适配器已接进闪寻，并且**在真机上验证过**。
            ///
            /// 名字取 `deviceVerified` 而非 `native`：后者容易被读成
            /// 「原生搜索可用」，而这是两个独立维度 —— 见 `hasNativeSearch`。
            /// WebDAV 就是「已验证但没有原生搜索」的那一类。
            case deviceVerified
            /// 适配器已接进闪寻，但**尚未在真机上验证**。
            case portedUnverified
            /// 移植过，但**已确认与真实设备协议不符**，实现从核心下线。
            ///
            /// 与 `notPorted` 的区别要留住：后者是「还没做」，前者是「做过、证伪了」。
            /// 合并成一种，界面就会对飞牛说「还没接入」——那是把一次真机结论
            /// 说成一句没做过的事，用户会以为「等一等就有了」。
            case retired
            /// 闪寻里还没有这个品牌的适配器。
            case notPorted
        }

        /// 闪寻核心里已经接了适配器的品牌（见 `MyNASCore/lib/adapter_registry.dart`）。
        public var adapterStatus: AdapterStatus {
            switch self {
            // WebDAV 已在飞牛 fnOS 的 5005 端口上真机跑通完整链路，
            // 故与群晖同列「已验证」。qnap / ugreen 仍只有适配器、无真机证据。
            // OpenList 于 2026-10-24 在真实实例 v4.1.10 上量过登录/列存储/限定目录搜索/分页。
            case .synology, .webdav, .openlist: return .deviceVerified
            case .qnap, .ugreen: return .portedUnverified
            // 飞牛的适配器已下线：真机探测量到它的登录/列目录/搜索全走 WebSocket，
            // 而既有实现走 HTTP 兼容层（`/api/v1/*` 一律 404）。核心侧的
            // `retiredVendors` 同样不含它，`hasBrandAdapter` 因此为 false。
            case .fnos: return .retired
            case .smb, .generic: return .notPorted
            }
        }

        /// 该品牌的管理口是否**出厂就是明文 HTTP**。
        ///
        /// qnap / fnos / ugreen 的管理界面默认跑在 http 上（实测飞牛的 5666 就是明文），
        /// 强行按 https 连会直接连不上；群晖 DSM 与 WebDAV 则默认走 https。
        /// 这只是一个**默认值**，用户可以在来源配置里显式改。
        public var defaultInsecureHTTP: Bool {
            switch self {
            case .qnap, .fnos, .ugreen: return true
            case .synology, .webdav, .smb, .generic, .openlist: return false
            }
        }

        /// 该品牌是否**允许**用户在「明文 / 加密」之间选择。
        ///
        /// 群晖是唯一不能选的：它走证书固定（sourcePin），而核心侧的
        /// `SourceEndpoint` 只接受 `https`（`MyNASCore/lib/source_trust.dart`，
        /// 否则抛 `UnsafeEndpoint`）。把开关摆给群晖用户，等于给一个必然失败的选项——
        /// 界面得为「用户明明选了却连不上」负责，所以干脆不给。
        ///
        /// WebDAV / QNAP / 飞牛 / 绿联的管理口都可以是明文，所以需要这个选择。
        public var allowsPlainHTTPChoice: Bool { self != .synology }

        /// 该品牌的连接地址是否**可能带路径前缀**。
        ///
        /// WebDAV 是典型：它的端点是服务自己决定的，不在站根上 ——
        /// OpenList / Alist 在 `/dav`，NextCloud 在 `/remote.php/dav`，
        /// 有些网关还要再加一层。只填 `host:port` 会连到站点根，
        /// 拿到 404 或一个 HTML 首页，而用户在界面上**没有办法表达**这件事。
        ///
        /// 其余品牌的管理口端点由设备固件固定（`/webapi/entry.cgi` 之类），
        /// 给一个路径输入框只会让用户填错。
        public var allowsBasePath: Bool { self == .webdav }

        /// 该品牌是否有**服务端原生搜索**。
        ///
        /// 这是**搜索能力**维度，与「真机是否验证过」（`adapterStatus`）互相独立，
        /// 不能合并：WebDAV 已经在真机上验证通过，但它**没有服务端搜索** ——
        /// 一旦合并，界面就会把 WebDAV 说成「原生搜索可用」，那是假话。
        /// 取值必须与 Dart 侧各适配器的 `capabilities.nativeSearch` 保持一致。
        public var hasNativeSearch: Bool {
            switch self {
            // fnos 不在其列：它的适配器已从核心下线，没有 `capabilities` 可对齐，
            // 说它有服务端搜索等于凭空给一个已证伪的路径加能力。
            // openlist 有 `/api/fs/search`（服务端索引搜索），真机实测可用。
            case .synology, .qnap, .ugreen, .openlist: return true
            case .fnos, .webdav, .smb, .generic: return false
            }
        }

        /// 该品牌的搜索结果能不能靠 **SMB 挂载**落到本机文件。
        ///
        /// 取值必须与核心适配器的 `exposesSMBShares` 一致
        /// （`MyNASCore/lib/adapter_contract.dart`）：OpenList 是聚合网盘服务，
        /// 它的「存储」不是 SMB 共享，逻辑路径也不与本机任何挂载同构。
        ///
        /// ★ 这条判断有两个作用，缺一个就会出真机 Bug：
        ///   * 搜索结果的**后台元数据补全**不许拿它去挂载表里找文件 —— 否则
        ///     「同主机同名路径」会把网页目标悄悄改成另一份本地文件；
        ///   * 网页目标缺失/校验失败时也**不许**退化成「先挂上再说」。
        /// 两者都以「这个来源根本没有 SMB 这一路」为前提，所以判断放在这里，
        /// 而不是在各调用点各写一遍 `vendor == .openlist`。
        public var exposesSMBShares: Bool {
            self != .openlist
        }

        /// 已接入**且已验证**的原生搜索类型 = 有服务端搜索 ∩ 真机验证过。
        ///
        /// 所以 WebDAV 虽然已验证，因为没有服务端搜索，这里仍是 false。
        /// 注意它**不是「能不能连接」** —— 那看 `hasAdapter`。
        public var nativelySupported: Bool {
            hasNativeSearch && adapterStatus == .deviceVerified
        }

        /// 是否有可用的适配器实现（含未真机验证的，不含已下线的）。
        ///
        /// 已下线的算**没有**：核心已经不认这个品牌，界面放行只会得到一个
        /// 「适配器已下线」的失败。能不能连由这里决定，见 `NASSourceWizardController`。
        public var hasAdapter: Bool {
            switch adapterStatus {
            case .deviceVerified, .portedUnverified: return true
            case .retired, .notPorted: return false
            }
        }

        /// 上游 MyNAS 里对应的适配器名。用来把「待接入」说得具体、可信——
        /// 用户听到「上游已有 FnOSAdapter」和听到「暂不支持」是完全不同的感受。
        public var upstreamAdapter: String? {
            switch self {
            case .synology: return "SynologyAdapter"
            case .qnap: return "QnapAdapter"
            case .ugreen: return "UGreenAdapter"
            case .fnos: return "FnOSAdapter"
            case .webdav: return "WebDavAdapter"
            case .smb: return "SmbAdapter"
            case .generic: return nil
            // OpenList 不是 NAS 品牌，MyNAS 上游没有对应适配器——
            // 闪寻这一份就是实现本身，没有「上游已有、移植即可」这回事。
            case .openlist: return nil
            }
        }

        /// 该类型的接入状态说明。
        ///
        /// **任何地方都可以直接用**，不必先判断 `nativelySupported`——
        /// 已接入的返回确认文案，未接入的返回「还没移植 + 上游适配器名」。
        ///
        /// 措辞统一收在这里，避免「品牌不支持的提示」散落在模型层与视图层各写一遍——
        /// 各写各的就会出现
        /// 「闪寻原生搜索走群晖 DSM 接口」这种把「还没移植」说成「能力如此」的说法。
        public var supportMessage: String {
            switch adapterStatus {
            case .deviceVerified:
                // 用户看到的是产品，不是验收报告：只说能力，不写
                // 「原生搜索已接入 / 并已在真机上验证」这类开发阶段状态话术。
                return hasNativeSearch
                    ? "支持服务端原生搜索，连接后即可在共享目录内搜索文件。"
                    : "可以连接，但这个协议本身不提供服务端搜索，搜索能力受协议限制。"
            case .portedUnverified:
                // 「已知不可用」直接说死，不再用「可以先连试试」把人送去白试。
                if let blocker = knownBlocker { return blocker }
                return hasNativeSearch
                    ? "\(title) 的适配器已经接进闪寻，但**还没在真机上验证过**。可以先连试试；如果这个型号或固件的接口不一样，可能会连不上——真机结果会用来校准适配器。"
                     : "\(title) 的适配器已经接进闪寻，但**还没在真机上验证过**，而且这个协议不提供服务端搜索。可以先连试试。"
            case .retired:
                // 与「没接入」不一样：这里必须说清是**试过、证伪了**，
                // 否则用户会当成「还没做」而继续等。
                if let blocker = knownBlocker { return blocker }
                return "\(title) 的适配器已经下线：既有实现与真实设备的协议不符，选它连不上。要连这个设备，请改用它能提供的标准协议（多数是 WebDAV）。"
            case .notPorted:
                if let adapter = upstreamAdapter {
                    return "\(title) 的原生搜索还没接进闪寻。MyNAS 上游已经有 \(adapter)，移植过来就能用；现在可以先把地址与账号存下来。"
                }
                return "\(title) 现在还没有可用的原生搜索接入方式，资料可以先保存。"
            }
        }

        /// 「该选哪一项」的一句话指引。
        ///
        /// 同一个品牌的**文件服务**与**管理口**不是同一个东西，选错了
        /// 端口填得再对也连不上，而且失败信息里看不出是选错了类型。
        /// 这不是凑字数： 用户就把飞牛的 WebDAV 端口（5005）
        /// 配上了「飞牛 fnOS」类型，只看到一句无从下手的「连接失败」。
        ///
        /// 措辞只写**真机确认过**的事实（见各适配器 `capabilities.notes`），
        /// 没验证过的不写数字。
        public var serviceHint: String {
            switch self {
            case .fnos:
                return "这一项走的是飞牛的**管理口**接口（管理口在 5666，其登录实际走 WebSocket）。要连飞牛的 **WebDAV 文件服务**（常见 5005），请改选「WebDAV」，并按那项服务自己的协议填。"
            case .webdav:
                return "填 WebDAV 服务自己的地址与端口。端点不在站点根时（OpenList / Alist 在 /dav）再填下面的「路径」。**多数设备只提供明文 HTTP**：如果浏览器里访问的是 http://，请把下面的协议开关切到明文。"
            case .openlist:
                return "填 OpenList **网站本身**的地址与端口（默认 5244）——不是 WebDAV 那个 /dav 端点。用 OpenList 的账号登录。**「搜索位置」要勾具体的存储**：这个服务按目录检索，不勾任何存储就搜不到东西。"
            case .synology:
                return "填 DSM 的地址与端口（走 HTTPS，证书固定），用 NAS 账号登录即可。"
            case .qnap, .ugreen:
                return "填设备管理口的地址与端口（这类设备的管理口出厂多为明文 HTTP，协议开关已按此默认打开）。"
            case .smb:
                return "SMB 只用于打开文件，不参与索引搜索。要能搜，需要另配上面几种类型之一。"
            case .generic:
                return "先用上面最接近的类型试；都不行时地址与账号可以先存下来。"
            }
        }

        /// 「连接信息」这一块下面的页脚：**去哪看地址与端口**。
        ///
        /// 与 [serviceHint] 分工不同：那个说「这一类设备该怎么填、别填错什么」，
        /// 这个只说「去哪儿找这串地址」。
        ///
        /// ★ 这段话原本是硬编码在视图里的，写的是「群晖常见端口是 5001」——
        /// 于是**所有品牌**的用户都被指去开「NAS 管理页面」找 5001。
        /// 2026-10-24 用户把 OpenList 的站点地址填给这个框时，
        /// 页面下方还在提示他去看群晖的 5001，等于把人往错的方向推。
        /// 端口数字没有通用值，必须按品牌说；不知道的就不说数字。
        public var connectionFooter: String {
            switch self {
            case .synology:
                return "在浏览器打开 DSM 管理页面，地址栏里的就是地址与端口。群晖常见端口是 5001（HTTPS）。"
            case .openlist:
                return "在浏览器打开 OpenList 网站，地址栏里的地址与端口就是这里要填的（默认 http://…:5244）。"
            case .qnap, .ugreen:
                return "在浏览器打开设备的管理页面，地址栏里的就是地址与端口（这类管理口出厂多为明文 HTTP）。"
            case .webdav:
                return "填能在浏览器里列出文件的那个地址。路径见上面的「路径」框。"
            case .smb:
                return "填提供 SMB 共享的那台机器的地址与端口（默认 445）。"
            case .fnos:
                return "填飞牛管理口的地址与端口；文件服务请改用「WebDAV」。"
            case .generic:
                return "填这台设备的地址与端口。不确定就先存下来。"
            }
        }

        /// 已经**在真机上确认过**、导致这一类设备现在必然连不上的原因；没有这种证据时返回 `nil`。
        ///
        /// 「未验证」与「已知不可用」必须分开写：前者是「不知道」，
        /// 后者是「已经拿真机量过、注定失败」。把后者说成前者，
        /// 用户就会花时间去试一个不可能成功的连接——这条反馈正是如此：
        /// 用户把飞牛的 WebDAV 端口配上「飞牛 fnOS」类型，试了两轮，
        /// 界面一句「可以先连试试」，等于让他白试。
        ///
        /// 只有拿得出真机证据时才填这里。
        ///
        /// 措辞必须同时成立两件事，少一件都会误导：
        ///   - 「适配器已经下线」 —— 是做过、证伪了，不是「还没做」；
        ///   - 「试过、且注定失败」 —— 拿真机量过，不是「不知道」。
        /// 由 `VendorKnownBlockerTests.testFnOSBlockerSaysRetiredNotWorkInProgress` 锁着。
        public var knownBlocker: String? {
            switch self {
            case .fnos:
                return "飞牛 fnOS 的适配器**已经下线**：真机探测证明它与真实设备的协议不符——闪寻的实现走 HTTP 兼容层，而真机上量到，飞牛的登录 / 列目录 / 搜索全部走 WebSocket（`ws://<host>/websocket?type=main`），HTTP 侧 `/api/v1/*` 一律 404。**这跟你端口和账号怎么填无关。**要连飞牛的 **WebDAV 文件服务**（5005 上的那个），请把类型改成「WebDAV」。"
            default:
                return nil
            }
        }
    }

    public var id: String
    public var name: String
    public var vendor: Vendor
    /// 用户填写的地址。允许 `192.0.2.96`、`nas.local` 或 `192.0.2.96:5003`。
    public var host: String
    /// 用户填写的端口。**必填**——自动探测在自签名证书的 NAS 上不可靠
    /// （标准 URLSession 会在 TLS 握手阶段失败，把「端口通」误判成「端口不通」，
    /// 实测 `.96` 的 5001/443 都是通的，却全部被判失败）。因此改为显式手填。
    public var port: Int
    public var username: String

    /// 是否用明文 HTTP 连接。
    ///
    /// 三态：`nil` = 按品牌默认（`Vendor.defaultInsecureHTTP`），
    /// `true`/`false` = 用户显式选择。
    ///
    /// 存成**可选**而不是直接给默认值，是为了让旧配置能解码 ——
    /// 给一个非可选字段配默认值，已经保存的来源在升级后会解不出来。
    public var usePlainHTTP: Bool?

    /// 实际生效的连接协议。
    public var usesPlainHTTP: Bool { usePlainHTTP ?? vendor.defaultInsecureHTTP }

    /// 连接地址里的**路径前缀**（如 OpenList / Alist 的 `/dav`）。
    ///
    /// 存成可选，理由与 `usePlainHTTP` 相同：给非可选字段配默认值，
    /// 已经保存的来源在升级后会解不出来。`nil` = 没填 = 站点根。
    public var basePath: String?

    /// 真正会拼进 endpoint 的路径前缀（带前导斜杠；没有则为空串）。
    ///
    /// **只有允许填路径的品牌才生效**（见 `Vendor.allowsBasePath`）：
    /// 换品牌时残留的 `/dav` 会被这里挡掉，不会跑到群晖的端点上。
    /// 解析规则走 `BasePathField.parse`，与输入框共用同一套。
    public var effectiveBasePath: String {
        guard vendor.allowsBasePath else { return "" }
        return BasePathField.parse(basePath ?? "") ?? ""
    }

    /// 换品牌：**必须把明文 HTTP 的显式选择清回「按品牌默认」**。
    ///
    /// `usePlainHTTP` 是显式值，写过一次就会盖住新品牌的默认协议：
    /// 用户在飞牛（默认明文）上开过开关，再切到 WebDAV（默认 https）时
    /// 它仍然生效，于是「https 的设备被按 http 连」——
    /// 界面看不出任何异常，只是连不上。
    ///
    /// 群晖不给协议选择（见 `Vendor.allowsPlainHTTPChoice`），这里一并清掉，
    /// 避免配置里残留一个界面无法解释、又会让连接以 `UnsafeEndpoint` 失败的显式值。
    ///
    /// 路径同理：`/dav` 是 WebDAV 才有的东西，带到别的品牌上只会拼出一个
    /// 谁也解释不了的地址（`https://nas:5001/dav`）。
    public mutating func adoptVendor(_ newVendor: Vendor) {
        vendor = newVendor
        usePlainHTTP = nil
        basePath = nil
        // 切类型 = 换一种完全不同的服务：上一类型的地址、端口、账号对新类型
        // 只有误导作用。 用户反馈：在 WebDAV 里填了 openlist 域名，
        // 切到绿联/飞牛后这些字段原样带着走，看起来像「新类型已经配好了」，
        // 于是照着一个必然错的地址点连接。密码不在配置里（模型层只有账号），
        // 会话态密码由 `AppModel.cancelDraft` 负责，这里只清配置内字段。
        host = ""
        port = 0
        username = ""
    }
    /// 用户选择的搜索位置（DSM 逻辑共享路径，如 `/示例共享`）。空表示尚未选择。
    ///
    /// 多个位置用 `scopes` 表示。`scope` 是兼容旧配置（单值）的便捷访问，
    /// 读写时以 `scopes` 为准。
    public var scopes: [String]
    public var scope: String { scopes.first ?? "" }
    /// 用户确认过的叶证书 SHA-256（不含分隔符的小写十六进制）。
    public var certificateSHA256: String
    /// 证书已过期时用户是否仍然确认。真实设备上 .96 的证书即属此类。
    public var allowExpiredCertificate: Bool
    public var enabled: Bool
    /// Finder 打开时优先使用的 SMB 账号；为空时按挂载表里的实际用户匹配。
    public var smbUsername: String?
    public var rememberPassword: Bool

    public init(id: String = UUID().uuidString, name: String = "", vendor: Vendor = .synology,
                host: String = "", port: Int = 0, username: String = "", scope: String = "", scopes: [String]? = nil,
                certificateSHA256: String = "", allowExpiredCertificate: Bool = false,
                enabled: Bool = true, smbUsername: String? = nil, rememberPassword: Bool = true,
                basePath: String? = nil) {
        self.id=id; self.name=name; self.vendor=vendor; self.host=host; self.port=port
        self.username=username
        // scopes 优先；未提供时才用单值 scope（兼容旧调用点与旧配置）。
        let resolved = scopes ?? (scope.isEmpty ? [] : [scope])
        // 去重、去空白、保持用户勾选顺序——顺序影响结果里 SMB 共享名的推导顺序。
        var seen = Set<String>()
        self.scopes = resolved.filter { !$0.isEmpty && seen.insert($0).inserted }
        self.certificateSHA256=certificateSHA256
        self.allowExpiredCertificate=allowExpiredCertificate; self.enabled=enabled
        self.smbUsername=smbUsername; self.rememberPassword=rememberPassword
        self.basePath=basePath
    }

    /// 凭据在钥匙串里的账号名。只用主机与账号派生，不含密码。
    public var credentialAccount: String { CredentialAccount.source(id) }
    /// 这条凭据**属于哪个目标**。保存与读取都要带上：地址、端口、账号任一变化，
    /// 旧密码就自动不适用（见 `CredentialIdentity`）。
    ///
    /// 端口取 `effectivePort` 而不是 `port` 字段——用户可能把端口写进地址栏，
    /// 那时字段是 0，拿 0 参与指纹等于所有设备共用一个指纹。
    public var credentialIdentity: CredentialIdentity {
        CredentialIdentity(host: hostName, port: effectivePort, username: username)
    }
    /// 协议 sourceID：只允许字母数字下划线连字符。
    ///
    /// 这套字符集必须与 Dart 侧**完全一致**（`harness.dart` 的 identifier 与
    /// `source_trust.dart` 的 SourceEndpoint 都是 `^[a-zA-Z0-9_-]{1,64}$`）。
    /// 之前这里多放了一个 `.`，Swift 认为 `nas.office` 合法、Dart 直接 ProtocolViolation——
    /// 契约不一致表现为「客户端看着没问题，一发请求就失败」，极难定位。
    public var sourceID: String { Self.protocolIdentifier(for: id) }

    /// 把任意 id 换算成**协议口径**的 sourceID。
    ///
    /// ★ 抽成静态函数是因为它现在有两个消费者：这里下发请求用，
    ///   `SearchResultFilter` 做「这条结果属于哪个位置」的比对时也要用。
    ///   两处各写一遍，只要其中一处漏了 `nas_` 前缀，界面表现就是
    ///   **某个共享下的结果永远筛不出来**——而搜索本身完全正常，极难定位。
    ///
    /// ★ 这个函数**幂等**：对已经合法的 id（含 `nas_xxx`）再算一次原样返回。
    ///   所以调用方不必先判断「这是原始 id 还是协议 id」，两侧都过一遍即可。
    public static func protocolIdentifier(for rawID: String) -> String {
        let direct = String(rawID.prefix(48))
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-")
        if !direct.isEmpty, direct.allSatisfy({ allowed.contains($0) }) { return direct }
        // 非法字符一律替换成 `-`，并加 `nas_` 前缀避免与 Dart 侧的裸标识混淆。
        let cleaned = rawID.map { ch -> Character in
            (ch.isLetter && ch.isASCII) || ch.isNumber || ch == "_" || ch == "-" ? ch : "-" }
        return "nas_" + String(cleaned.prefix(48))
    }
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? vendor.title : trimmed
    }
    /// 主机名（不含端口），用于 SMB 挂载匹配与 openTarget。
    public var hostName: String { EndpointProbe.host(of: host) ?? "" }

    /// 两份配置是不是**同一条连接**（只看连接参数，不看名字）。
    ///
    /// `NASConnectionManager.rebuild` 原本拿 `existing.config == source` 决定「复用还是重建」。
    /// 整份 `==` 把 `name` 也算进去了，于是**改个名字就会被判成换了设备**：
    /// 旧 Provider 被 disconnect、换成一个从未登录的空白实例——
    /// 用户看到的就是「改完名字 NAS 掉线了，还要重新输密码」。
    ///
    /// 写法是把 `name` 抹平再整体比较（而不是逐字段列举）：
    /// 以后往 `NASSourceConfig` 加连接相关字段时，这里自动跟上，不会漏。
    public func hasSameConnection(as other: NASSourceConfig) -> Bool {
        var mine = self
        var theirs = other
        mine.name = ""
        theirs.name = ""
        return mine == theirs
    }

    /// 端口字段本身是否填了有效值。
    public var hasPort: Bool { (1...65535).contains(port) }

    /// 从地址文本里取出用户顺带写进去的端口。
    ///
    /// 用户的直觉是「地址栏就该把 `192.0.2.96:5001` 一次写完」，
    /// 而端口另有独立输入框——两者都写、只写地址、只写端口，都得能用。
    /// 这里只负责解析；真正决定连接用哪个端口的是 `effectivePort`。
    public static func portFromHost(_ text: String) -> Int? {
        var t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        for scheme in ["https://", "http://"] where t.lowercased().hasPrefix(scheme) {
            t = String(t.dropFirst(scheme.count)); break
        }
        if let slash = t.firstIndex(of: "/") { t = String(t[..<slash]) }
        if let at = t.lastIndex(of: "@") { t = String(t[t.index(after: at)...]) }
        guard let colon = t.lastIndex(of: ":") else { return nil }
        let digits = t[t.index(after: colon)...]
        guard !digits.isEmpty, digits.allSatisfy({ $0.isNumber }),
              let value = Int(digits), (1...65535).contains(value) else { return nil }
        return value
    }

    /// 本次连接**实际会使用**的端口。
    ///
    /// 真实故障：用户把 `192.0.2.96:5001` 整串写进地址栏、端口框留空，
    /// 而「连接」按钮的可点判定只看端口字段（`hasPort`），于是按钮一直是灰的——
    /// 用户看到的是「我明明写了端口，为什么点不了」。
    /// 现在判定改用这个值：端口字段优先，字段为空时从地址里取。
    public var effectivePort: Int {
        if hasPort { return port }
        return Self.portFromHost(host) ?? 0
    }

    /// 有效端口是否可用。UI 与连接流程统一用这个，不要再用 `hasPort`。
    public var hasEffectivePort: Bool { (1...65535).contains(effectivePort) }

    /// 是否与另一份配置指向同一个「主机 + 账号」。
    ///
    /// 钥匙串条目只按来源 ID 存，**不含**主机与账号。因此用户把 `.96` 改成 `.88`、
    /// 或把 `demo_user` 改成 `admin` 之后，条目的 key 没变、里面还是旧密码——
    /// 若不拦住，就会把 A 机器的密码发给 B 机器。
    public func hasSameEndpoint(as other: NASSourceConfig) -> Bool {
        hostName == other.hostName && username == other.username
    }

    /// 是否具备发起搜索的最低配置。
    ///
    /// 端口判定一律走 `hasEffectivePort`：用户把 `192.0.2.96:5001` 整串
    /// 写进地址栏时端口字段是空的，只看字段会把「明明填了端口」判成未配置。
    public var isSearchConfigured: Bool {
        !hostName.isEmpty && hasEffectivePort
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !scopes.isEmpty
            && scopes.allSatisfy { $0.hasPrefix("/") && $0 != "/" }
    }
    /// 是否具备发起连接的最低配置（尚可未选搜索位置）。
    public var isConnectConfigured: Bool {
        !hostName.isEmpty && hasEffectivePort
            && !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

public extension NASSourceConfig {
    /// 规范化用户输入：去掉协议前缀、路径与空白；地址里若带了端口，顺手记进端口字段。
    ///
    /// 端口不再由「自动探测」决定（探测已在自签名证书的 NAS 上证明不可靠），
    /// 但用户把 `192.0.2.96:5001` 整串写进地址是常见写法，
    /// 所以这里把端口**搬**到端口字段，让后续流程与界面显示一致。
    mutating func normalizeHost() {
        var text = host.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { host = ""; return }
        for scheme in ["https://", "http://"] where text.lowercased().hasPrefix(scheme) {
            text = String(text.dropFirst(scheme.count)); break
        }
        // 地址里顺带写的路径（`http://host:5244/dav`）：
        // 对**允许填路径的品牌**把它搬进 `basePath`，而不是悄悄丢掉。
        //
        // 用户从 OpenList / Alist 复制来的就是整条 URL。丢掉 `/dav` 之后连接会
        // 指向站点根 —— 界面看不出任何异常，只是连不上；而这里恰好是唯一
        // 能把这层意思保留下来的地方。
        if let slash = text.firstIndex(of: "/") {
            if vendor.allowsBasePath, let derived = BasePathField.parse(String(text[slash...])) {
                basePath = derived
            }
            text = String(text[..<slash])
        }
        if let at = text.lastIndex(of: "@") { text = String(text[text.index(after: at)...]) }
        // 去掉用户可能顺手填的端口，端口一律由探测决定，避免填错就再也连不上。
        if let colon = text.lastIndex(of: ":"), text[colon...].dropFirst().allSatisfy({ $0.isNumber }),
           let typed = Int(text[text.index(after: colon)...]), (1...65535).contains(typed) {
            port = typed
            text = String(text[..<colon])
        }
        host = text
    }
}

/// 连接地址里的**路径前缀**输入框（WebDAV 专用）的「文本 ↔ 路径」转换。
///
/// 为什么要有这个字段：WebDAV 的服务端点不在站根上 —— OpenList / Alist 在
/// `/dav`，NextCloud 在 `/remote.php/dav`。只让用户填 `host:port`，他就
/// **没有任何办法**表达这件事，只能看着「连不上」而不知道差在哪。
///
/// 解析规则做成纯函数放在这里，理由与 `PortField` 相同：App 层是
/// executableTarget，测试目标 import 不到，规则留在视图里就锁不住。
public enum BasePathField {
    /// 解析用户填写的路径。
    ///
    /// 宽容到「整条 URL 粘进来也能用」，因为这是最常见的输入方式：
    ///   * 有 `://` 时丢掉 scheme + host 部分（`http://h:5244/dav` → `/dav`）；
    ///   * 丢掉查询串与锚点（`?` 之后的都不属于路径）；
    ///   * 丢掉 `.` 与 `..` 段 —— 它们只会拼出「越过 baseUrl」的地址；
    ///   * 合并重复斜杠、补前导斜杠、去尾随斜杠。
    ///
    /// 返回 `nil` 表示**等价于没填**（空串、纯空白、或只剩一个 `/`），
    /// 让调用方能把它当成「走站点根」而不是「填了个空路径」。
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

/// 来源在产品层的可见状态。刻意与底层 phase 解耦：
/// 普通用户只需要知道「正常 / 连接中 / 离线 / 需要处理」。
public enum NASSourceHealth: String, Sendable {
    case unconfigured, connecting, ready, offline, needsAttention
    public var title: String {
        switch self {
        case .unconfigured: return "未配置"
        case .connecting: return "正在连接"
        case .ready: return "正常"
        case .offline: return "离线"
        case .needsAttention: return "需要处理"
        }
    }
    public var symbol: String {
        switch self {
        case .unconfigured: return "circle.dashed"
        case .connecting: return "arrow.triangle.2.circlepath"
        case .ready: return "checkmark.circle.fill"
        case .offline: return "circle.dashed"
        case .needsAttention: return "exclamationmark.circle.fill"
        }
    }
}

public struct NASSourceStatus: Sendable {
    public var health: NASSourceHealth = .unconfigured
    public var message = ""
    public var availableShares: [String] = []
    public var selectedScope = ""
    public var discoveredPort: Int?
    public var searching = false
    /// 出问题时用户该做的那**一件**事。
    ///
    /// `message` 是给详情页读的完整句子；这一项是给列表行决定「画哪个按钮」用的。
    /// 两者分开，是因为光看文案推不出按钮——「读取共享目录失败」与
    /// 「本机没有保存密码，请连接一次」都落在 `needsAttention`，
    /// 但前者要去继续设置，后者是要登录。写成文本匹配一定会错。
    /// `nil` 表示当前没有需要用户处理的事。
    public var requiredAction: NASSourceRequiredAction?
    /// 最近一次失败是不是因为设备要求 OTP。
    ///
    /// 这是一个**状态标记**，不是按钮本身。标记为 true 时，
    /// 详情页的「重新登录…」要先弹 OTP 输入框，再把码带进去重连；
    /// 连接成功后必须清掉，否则用户下次点重新登录还会被问 OTP。
    public var needsOTP: Bool = false
    /// 最近一次失败是不是**上一次那个码被拒了**（而不是「还没填过码」）。
    ///
    /// `needsOTP` 只回答「要不要问码」，回答不了「问的时候该说什么」。
    /// 用户点取消、过一会儿再点「登录」时，弹窗必须还能说出
    /// 「动态码输入错误，请再次输入」——那件事只存在于状态里，不在调用栈里。
    public var otpRejected: Bool = false
    public init() {}
}

/// 自绘密码框（AppKit `NSSecureTextField` 包 SwiftUI）的回写规则。
///
/// 真实故障：密码框「每敲一个字符就被截回上一个长度」，表现为只能打一个字。
/// 成因是 `NSViewRepresentable` 的 Coordinator 只创建一次，
/// 它持有的 `@Binding` 在外层视图重建后指向旧存储位置，
/// 于是**用户输入被写进了一个没人读的地方**；
/// 随后 `updateNSView` 拿旧值回写文本框，把刚输入的字符吃掉。
///
/// 修复分两层：① 每次 `updateNSView` 都把最新绑定交回 Coordinator；
/// ② 用户正在编辑时**绝不回写**。第 ② 条是兜底——
/// 即使绑定再次出现异常，也不会在输入过程中打断用户。
///
/// 这里把第 ② 条提炼成可测的纯函数，因为 App 层的 `NSViewRepresentable`
/// 无法被测试目标 import，而这个规则值得被锁住。
public enum SecureFieldEcho {
    /// 是否应该把绑定值写回文本框。
    ///
    /// - Parameters:
    ///   - fieldValue: 文本框当前显示的内容。
    ///   - boundValue: 绑定的值。
    ///   - isEditing: 用户是否正在此框内输入（`currentEditor() != nil`）。
    public static func shouldWrite(fieldValue: String, boundValue: String, isEditing: Bool) -> Bool {
        // 编辑中一律不回写：回写会移动光标与选区，并可能吞掉刚输入的字符。
        if isEditing { return false }
        return fieldValue != boundValue
    }
}

/// 搜索浮窗的会话记忆策略。
///
/// 需求：关闭后短时间内再次打开，保留上一次的查询与结果——
/// 常见场景是「关掉 → 去别的应用复制一行 → 回来接着看同一个结果」，
/// 这时把词重敲一遍很烦。但保留太久又会让人误以为搜的还是那个词。
///
/// 所以两条规则，缺一不可：
/// 1. **时间窗内**才保留（`isWithinMemoryWindow`）；
/// 2. **结果仍有效**才保留（`shouldRestore`）——
///    搜索范围、启用的来源、显示隐藏文件等设置一旦变了，
///    旧结果就不再对应当前状态，拿出来显示等于骗人。
public enum SearchSessionMemory {
    /// 保留时长 30 秒。够覆盖一次「关掉—复制—回来」，又不至于跨天还挂着旧结果。
    public static let windowSeconds: TimeInterval = 30

    /// 距离隐藏是否仍在保留期内。
    public static func isWithinMemoryWindow(hiddenAt: Date?, now: Date = Date()) -> Bool {
        guard let hiddenAt else { return false }
        let elapsed = now.timeIntervalSince(hiddenAt)
        // 负数表示系统时间被回拨（少见但可能发生），一律当作仍在窗口内，
        // 免得用户莫名其妙丢掉正在看的结果。
        return elapsed <= windowSeconds
    }

    /// 是否应该恢复上一次的查询与结果。
    ///
    /// - Parameters:
    ///   - hiddenAt: 浮窗上次隐藏的时刻；`nil` 表示从未隐藏过。
    ///   - hasQuery: 上一次是否有查询词。
    ///   - resultsAreValid: 上一次的结果是否仍对应当前设置
    ///     （搜索范围、启用的来源、显示隐藏文件等都没变）。
    public static func shouldRestore(hiddenAt: Date?, hasQuery: Bool, resultsAreValid: Bool,
                                     now: Date = Date()) -> Bool {
        guard isWithinMemoryWindow(hiddenAt: hiddenAt, now: now) else { return false }
        guard hasQuery else { return false }
        // 结果已过期时不能恢复：宁可让用户重搜一次，也不能显示不对应的结果。
        return resultsAreValid
    }
}

/// 端口输入框的「文本 ↔ 端口值」转换。
///
/// 端口字段不能直接绑 `Int`（`TextField(value:format: .number)`）：
/// macOS 上带 `format:` 的 TextField 与普通 `TextField(text:)` 的写回时机不同，
/// 用户敲完 `5001` 界面看着已经有值，绑定的 `Int` 可能还没更新，
/// 于是依赖 `port > 0` 的「连接」按钮仍然是灰的（要等失焦或回车才亮）。
///
/// 改为让输入框始终是字符串、每次按键即时解析，按钮状态就能实时跟随。
/// 解析规则做成纯函数放在这里，因为 App 层是 executableTarget、测试目标 import 不到。
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

/// 「连接」按钮是否可用的判定。
///
/// 这个判定原来写在视图里（`.disabled(model.draftBusy || host.isEmpty || … || model.nativeNASPassword.isEmpty)`），
/// 导致一个自我失效的循环：
///
/// 1. 用户敲第一个字符 → `nativeNASPassword` 变化；
/// 2. 密码框下方那句「将使用钥匙串中已保存的密码」是**依赖同一值**的条件视图，
///    真假一变 SwiftUI 就重建整个 `VStack`，`PlainSecureField` 被销毁重建；
/// 3. 重建后的按钮可用性判断拿到的是**刚重建、还没回写的空值**；
/// 4. 于是按钮变灰——用户明明填了密码却点不了。
///
/// 关键教训：**控件的可用性判断不要放在会因该控件输入而重建的视图层级里。**
/// 判定必须放在模型层、用不依赖视图重建的状态计算。
public enum ConnectButtonState {
    /// 能否发起连接。
    ///
    /// - Parameters:
    ///   - busy: 是否有连接正在进行。
    ///   - host: 规范化后的主机名（已通过格式校验）。
    ///   - hasPort: **有效**端口是否可用。调用方应传 `hasEffectivePort`
    ///     ——端口写在地址里（`192.0.2.96:5001`）时端口字段可能是空的，
    ///     只看字段会让按钮永远点不亮。
    ///   - username: 账号是否非空。
    ///   - hasTypedPassword: 本次是否输入了密码。
    ///   - hasStoredPassword: 钥匙串里是否有可用密码。
    public static func canConnect(busy: Bool, host: String, hasPort: Bool,
                                  username: String, hasTypedPassword: Bool,
                                  hasStoredPassword: Bool) -> Bool {
        if busy { return false }
        if host.isEmpty || !hasPort { return false }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
        // 密码二选一：本次输入的，或钥匙串里已有的。
        return hasTypedPassword || hasStoredPassword
    }

    /// 按钮不可用时给用户的一句话，说明到底缺什么。
    ///
    /// 之前按钮只是「变灰」，用户完全不知道为什么点不了——
    /// 灰按钮不解释自己，是最容易被当成程序坏了的界面。
    public static func disabledReason(busy: Bool, host: String, hasPort: Bool,
                                       username: String, hasTypedPassword: Bool,
                                       hasStoredPassword: Bool) -> String? {
        if busy { return nil }   // 正在连接，不需要解释
        if host.isEmpty { return "请填写 NAS 地址" }
        if !hasPort { return "请填写端口（也可以直接写进地址，像 192.0.2.96:5001）。闪寻不做自动探测——自签名证书的 NAS 在探测阶段就会被误判为不可用。" }
        if username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "请填写 NAS 账号" }
        if !hasTypedPassword && !hasStoredPassword { return "请输入密码" }
        return nil
    }
}

/// 「断开之后点重新连接」该怎么走。
///
/// ## 为什么要有这条判定
///
/// 用户断开一台 NAS 之后想连回来，遇到的是一条**写死的**向导提示
/// 「请输入密码以重新连接」——即使本机凭据文件里就存着这把密码。
/// 一半的故障是这句话造成的（用户以为必须重输，实际不必）；
/// 另一半是凭据真的不在，那句「请输入密码」又没说是为什么。
///
/// 所以把「能不能用已保存的密码」做成一条显式判定，结果只有三种：
/// 有 → 静默用；没有但用户勾过记住 → 说清为什么没有、输一次以后就不用了；
/// 没勾记住 → 说清这是他自己的选择，以及勾上以后会怎样。
public enum ReconnectRoute: Equatable {
    /// 本机有可用密码：直接静默重连，**不问用户**。
    case storedCredential
    /// 必须输一次密码，附带一句说清为什么。
    case askForPassword(reason: String)
}

public enum ReconnectEntryState {

    /// 断开后「重新连接」的路由。
    ///
    /// - Parameters:
    ///   - rememberPassword: 该来源配置里是否勾了「记住这台 NAS 的密码」。
    ///   - hasStoredCredential: 本机凭据文件里现在是否真有这把密码。
    ///     只看前者是不够的：勾了却没存上（保存失败、被清除）时，
    ///     界面若还宣称「有已保存的密码」就是在骗人。
    public static func route(rememberPassword: Bool, hasStoredCredential: Bool) -> ReconnectRoute {
        if rememberPassword && hasStoredCredential { return .storedCredential }
        if !rememberPassword { return .askForPassword(reason: notRememberedReason) }
        return .askForPassword(reason: missingStoredReason)
    }

    /// 没勾「记住密码」时的说明。不许暗示「程序忘了」——这是用户的选择。
    public static let notRememberedReason =
        "这台 NAS 没有勾选「记住这台 NAS 的密码」，需要输入一次。"
        + "勾上之后，断开再重连就不用再输了。"

    /// 勾了却没存上时的说明。
    ///
    /// 措辞刻意不猜原因（「没存上」「被清除」都列出来）：事后从凭据文件里
    /// 分辨不出是哪一种，写成确定语气就是编造。
    public static let missingStoredReason =
        "本机凭据文件里没有这台 NAS 的密码（可能上次没存上，或刚被清除）。"
        + "请在这里输入一次；连接成功且勾了「记住密码」，以后重连会直接连上。"

    public static func canReconnectSilently(rememberPassword: Bool, hasStoredCredential: Bool) -> Bool {
        route(rememberPassword: rememberPassword, hasStoredCredential: hasStoredCredential) == .storedCredential
    }
}

/// 来源卡片行内按钮该显示「断开」还是「重新连接」。
///
/// ⚠️ UI 简化后，来源行上**已经不再有**这两个按钮（断开/重连属于
/// NAS 管理操作，已从列表撤下，异常时才由 `NASSourceRowModel` 给一个按钮）。
/// 这条判定与其单测**刻意保留**：`disconnectSource` 仍然存在且被
/// `NASDisconnectIsolationTests` 覆盖，将来若重新暴露断开入口，
/// 这里那套「不能只看 `ready`」的结论必须原样复用，不要再重新踩一遍。
///
/// ## 为什么不能只看 Provider 的 `ready`
///
/// 用户点「断开」后，界面上「已断开」的状态是**同步**写入的，
/// 但 Provider 的 `ready` 要等 `disconnectOne` 异步收尾（含向核心发 disconnect 命令）
/// 跑完才翻转。若按钮只认 `ready`，就会出现用户报障的那一幕：
/// 文字说「已断开」，按钮却还是「断开」，得再点一次才能触发重渲染、露出「重新连接」。
/// 断开意图一旦确立（状态已标记离线），按钮应**立刻**切到「重新连接」，
/// 不让用户等网络往返。
public enum NASRowAction: Equatable {
    case disconnect
    case reconnect

    /// - Parameters:
    ///   - ready: Provider 当前是否处于已连接（`ready == true`）。
    ///   - markedOffline: 该来源的状态是否已被显式标记为离线（用户点了断开，
    ///     或断开流程已确立）。此时即使 `ready` 还没走完异步收尾，
    ///     也必须给「重新连接」。
    public static func decide(ready: Bool, markedOffline: Bool) -> NASRowAction {
        if ready && !markedOffline { return .disconnect }
        return .reconnect
    }
}

/// 「这次失败该不该提示用户改用明文 HTTP 重试」的判定。
///
/// ## 为什么需要这条独立判定
///
/// 大量 NAS 的 WebDAV / 管理口**只提供明文 HTTP**（已在真机上验证的飞牛 5005 就是）。
/// 而 WebDAV 品牌的协议开关默认是**加密**（`Vendor.defaultInsecureHTTP == false`），
/// 于是「端口填对了、账号也对」仍然连不上，报出来的原因是一句
/// 「TLS 握手失败」——用户读不出「去把那个开关打开」这一步。
///
/// 更隐蔽的是：切品牌时开关会被清回新品牌的默认值（这是为了修
/// 「在飞牛上开过明文的来源，切到群晖后仍按明文连」那个历史故障，不能去掉）。
/// 用户在飞牛上开了明文、再切到 WebDAV，开关就被悄悄清掉了。
///
/// 所以**失败之后**再给一次一键改写的机会：不猜、不自动降级，
/// 但仍然把「要不要不加密」的决定权留在用户手里（点一下才算数）。
public enum PlainHTTPRetryOffer {

    /// 是否应当提示。
    ///
    /// - Parameters:
    ///   - allowsPlainHTTPChoice: 该品牌是否允许用户选协议（群晖不允许，见 `Vendor.allowsPlainHTTPChoice`）。
    ///   - usesPlainHTTP: 本次尝试实际用的协议。
    ///   - coreApiCode: 核心返回的 `apiCode`。**有值说明请求已经打到设备并拿到了 HTTP 状态码**
    ///     （例如 401）——链路是通的，问题不在协议，就不该把人往明文上引。`nil` 才是传输层没走通。
    ///   - isCoreFailure: 失败是否来自核心的适配器（`CoreError`）。
    ///     其它错误（缺资源、超时兜底、内部断言失败）与协议无关，不提示。
    public static func shouldOffer(allowsPlainHTTPChoice: Bool, usesPlainHTTP: Bool,
                                   coreApiCode: Int?, isCoreFailure: Bool) -> Bool {
        guard allowsPlainHTTPChoice, !usesPlainHTTP, isCoreFailure else { return false }
        return coreApiCode == nil
    }

    /// 提示文案。**把核心给的原话留在前面**，用户已经能从那里看到真因。
    public static func message(reason: String) -> String {
        "\(reason)\n\n连不上的原因很可能在协议上：不少 NAS 的 WebDAV / 管理口只提供**明文 HTTP**。"
            + "闪寻不会替你自动换成不加密的连接——要试的话，点下面的按钮，它会打开「使用明文 HTTP」再重连一次。"
    }
}
