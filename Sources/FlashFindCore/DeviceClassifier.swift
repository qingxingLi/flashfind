import Foundation

/// 一台被发现的局域网设备被判成什么。
///
/// ## 为什么要有这个类型
///
/// 用户添加 NAS 时看到的是一屏设备：自己的 Mac、同事的笔记本、打印机、
/// Apple TV，还有真正要找的那台 NAS。把它们平铺在一起，用户得一台台点开才知道哪个是 NAS——
/// 这正是用户的反馈：「如果能进一步识别电脑/NAS 则进行识别，只保留 NAS」。
///
/// 于是要把「怎么判」做成 Core 的纯函数：能用测试锁住，也避免 App 层写出
/// 「看着像 NAS 就当 NAS」这种没法核对的判断。
public enum DeviceKind: String, Sendable, CaseIterable {

    /// 判为 NAS 或服务器。默认列表要留的就是这一类。
    case nas

    /// 判为**文件服务器**：设备明确在广播文件服务（SMB/WebDAV/NFS/FTP…），
    /// 但没有证据说明它是 NAS 还是别的什么。
    ///
    /// 与 `.unknown` 的分界：**mDNS 广播文件服务**算明确证据（设备自己喊了
    /// 「我提供文件共享」），**TCP 端口开着**不算（端口证明不了身份，
    /// 实测本网段 20+ 台设备开着 445）。
    case fileServer

    /// 判为个人电脑（Mac / Windows 开了文件共享）。默认收起。
    case computer

    /// 判为外设或消费电子（打印机、AirPlay 音箱、Apple TV、路由器）。默认收起。
    case appliance

    /// **认不出来**。
    ///
    /// 认不出不等于不是：厂家怎么写广播记录没有统一约定，
    /// 拿不到证据就下判断等于替用户猜。
    case unknown

    /// 是否出现在默认列表里。
    ///
    /// 用户的规则：**默认只展示被明确识别为 NAS/文件服务器的设备**，
    /// 所有未知网络设备只放到「显示全部设备」里。
    /// （这条推翻了「认不出就全留在默认列表」的决定——
    /// 依据：实测一个家庭网段有 111 台在线主机，其中 108 台只有 ARP/端口证据，
    /// 全列出来用户照样找不到 NAS。）
    public var shownInDefaultList: Bool {
        switch self {
        case .nas, .fileServer: return true
        case .computer, .appliance, .unknown: return false
        }
    }

    /// 界面上显示的分类名。认不出要说「未知」，不许写成某个具体类型。
    public var title: String {
        switch self {
        case .nas: return "NAS"
        case .fileServer: return "文件服务器"
        case .computer: return "电脑"
        case .appliance: return "外设"
        case .unknown: return "未知设备"
        }
    }
}

/// 一次判定的结果：判成什么，以及**凭什么**。
///
/// 带上依据是为了可核对：用户问「为什么这台排在默认列表里」时得有话说，
/// 排查误判时也得能看出是哪条证据起了作用。
public struct Classification: Equatable, Sendable {
    public var kind: DeviceKind
    public var reason: String

    public init(kind: DeviceKind, reason: String) {
        self.kind = kind
        self.reason = reason
    }
}

/// 局域网设备的类型判定。
///
/// ## 判定依据（都有实测来源，不是约定俗成）
///
/// macOS 访达之所以能把 Mac 画成 Mac 图标、把 NAS 画成服务器图标，依据的是设备自己
/// 注册的 `_device-info._tcp` 服务里 TXT 记录的 `model=` 字段。实测（
/// 用户局域网内的群晖 `demo-synology`）：
///
/// ```
/// dns-sd -L demo-synology _device-info._tcp
///   → can be reached at demo-synology.local.:0  model=Xserve
/// ```
///
/// 即**群晖把自己的 model 写成 `Xserve`**（Apple 停产的服务器机型），借此换来访达里的
/// 服务器图标；同一网段里 MacBook Air 的 model 则是 `MacBookAir10,1` 这种机型标识。
///
/// 证据来源有五个（Synology 官方协议 / SSDP / mDNS / ARP /
/// TCP 探测），全部汇进 `DeviceEvidence` 后再判。优先级：
///
/// 1. **Synology 官方发现协议**——型号、序列号、DSM 端口全是设备自报，最确定；
/// 2. **SSDP description.xml**——`manufacturer`/`modelDescription` 明写厂商与用途；
/// 3. **mDNS 厂商私有服务**（`_synology-dsm` / `_diskstation` / `_qnap`）——只有这些厂家的设备会广播；
/// 4. **`model=` 服务器机型** → NAS；
/// 5. **`model=` 个人电脑机型** → 电脑（**必须先于文件服务**：Mac 也广播 `_smb`）；
/// 6. **SSDP 外设特征**（MediaRenderer / InternetGatewayDevice）；
/// 7. **mDNS 打印机服务** → 外设；
/// 8. **mDNS 苹果消费电子服务**（AirPlay / 随航 / 远程配对）→ 电脑；
/// 9. **mDNS 文件服务**（SMB/WebDAV/NFS/FTP/AFP）→ 文件服务器；
/// 10. 以上都够不上 → `.unknown`，**不产生默认显示资格**。
///
/// 之所以不让 `_smb._tcp` 直接判 NAS：实测里 Mac 自己也会广播 `_smb._tcp`
/// （开了「文件共享」就是），只看 SMB 会把每台 Mac 都列成 NAS。
public enum DeviceClassifier {

    /// 从 `_device-info._tcp` 的 TXT `model=` 值判定。认不出来返回 `nil`。
    ///
    /// 返回 `nil` 是「不知道」，不是「不是 NAS」——调用方会回落到服务类型再判一次，
    /// 仍然判不出才算 `.unknown`。
    public static func kind(fromModel model: String?) -> DeviceKind? {
        guard let raw = model?.trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty else { return nil }
        if isServerModel(raw) { return .nas }
        if isComputerModel(raw) { return .computer }
        return nil
    }

    /// 综合设备型号与命中的服务类型判定。
    ///
    /// 这是 `classify(_:)` 的便捷重载：只有 mDNS 证据时用。
    /// - Parameters:
    ///   - model: `_device-info._tcp` TXT 里的 `model=` 值，拿不到传 `nil`。
    ///   - serviceTypes: 这台设备命中的所有 Bonjour 服务类型，形如 `_smb._tcp`（结尾的点可有可无）。
    public static func classify(model: String?, serviceTypes: Set<String>) -> DeviceKind {
        var evidence = DeviceEvidence(host: "")
        if let model, !model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            evidence.models = [model]
        }
        evidence.serviceTypes = serviceTypes
        return classify(evidence).kind
    }

    /// 综合全部证据判定设备类型。
    ///
    /// 这是重构后的主入口：每个发现协议只往 `DeviceEvidence` 里填事实，
    /// 「这是什么」由这里一次判完——判定逻辑因此只有一份，也能被测试锁住。
    public static func classify(_ evidence: DeviceEvidence) -> Classification {
        let types = Set(evidence.serviceTypes.map(Self.normalize))
        let models = evidence.models
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .sorted()

        // 1. Synology 官方发现协议：设备自报型号/序列号/DSM 端口，最确定。
        if let synology = evidence.synology {
            let version = synology.dsmVersion.map { "（DSM \($0)）" } ?? ""
            return Classification(kind: .nas,
                                  reason: "Synology 发现协议：\(synology.model ?? "未知型号")\(version)")
        }

        // 2. SSDP description.xml。
        if let nas = nasFromSSDP(evidence.ssdp) { return nas }

        // 3. mDNS 厂商私有服务。
        let nasServices = types.intersection(nasServiceTypes)
        if !nasServices.isEmpty {
            return Classification(kind: .nas,
                                  reason: "mDNS NAS 服务：\(nasServices.sorted())")
        }

        // 4. 型号：服务器机型。
        //    先扫全部型号找服务器特征，再找个人电脑特征——顺序反了会被
        //    「RackMac」这种名字里有 Mac 的服务器机型误判。
        if let model = models.first(where: { isServerModel($0) }) {
            return Classification(kind: .nas, reason: "型号 \(model)（服务器机型）")
        }

        // 5. 型号：个人电脑机型。★ 必须先于文件服务：Mac 开了文件共享也广播 _smb。
        if let model = models.first(where: { isComputerModel($0) }) {
            return Classification(kind: .computer, reason: "型号 \(model)（个人电脑）")
        }

        // 6. SSDP 外设特征。
        if let appliance = applianceFromSSDP(evidence.ssdp) { return appliance }

        // 7. mDNS 打印机 / 扫描仪。
        let printerServices = types.intersection(printerServiceTypes)
        if !printerServices.isEmpty {
            return Classification(kind: .appliance,
                                  reason: "打印机服务：\(printerServices.sorted())")
        }

        // 8. mDNS 苹果消费电子服务。
        let consumerServices = types.intersection(consumerServiceTypes)
        if !consumerServices.isEmpty {
            return Classification(kind: .computer,
                                  reason: "苹果消费电子服务：\(consumerServices.sorted())")
        }

        // 9. mDNS 文件服务：设备明确在广播「我提供文件共享」。
        //    注意这里只认 mDNS 广播，**不认 TCP 端口**——端口证明不了身份。
        let fileServices = types.intersection(fileServiceTypes)
        if !fileServices.isEmpty {
            return Classification(kind: .fileServer,
                                  reason: "mDNS 文件服务：\(fileServices.sorted())")
        }

        // 10. 都够不上 → 不替用户猜，也不给默认显示资格。
        if !evidence.openPorts.isEmpty {
            return Classification(kind: .unknown,
                                  reason: "仅 TCP 端口证据 \(evidence.openPorts.sorted())（端口证据不产生默认显示资格）")
        }
        if evidence.ssdp != nil {
            return Classification(kind: .unknown, reason: "SSDP 设备但未识别为 NAS")
        }
        if !evidence.sources.isEmpty {
            return Classification(kind: .unknown, reason: "无识别证据（来源：\(evidence.sources.map(\.rawValue).sorted())）")
        }
        return Classification(kind: .unknown, reason: "无识别证据")
    }

    // MARK: - SSDP 判定

    /// SSDP 身份是否说明这是 NAS。
    ///
    /// 实测群晖的 description.xml：`manufacturer: Synology`、
    /// `modelDescription: Synology NAS`、`modelName: DS1621+`。
    /// 这条通道**不依赖 mDNS**——那台一条 mDNS 都不广播的 DS1621+ 就是靠它
    /// （加上 Synology 发现协议）被认出来的。
    static func nasFromSSDP(_ ssdp: SSDPIdentity?) -> Classification? {
        guard let ssdp else { return nil }
        let manufacturer = ssdp.manufacturer?.lowercased() ?? ""
        let description = ssdp.modelDescription?.lowercased() ?? ""
        guard manufacturer == "synology" || manufacturer == "qnap" || description.contains("nas") else {
            // ★ SERVER 头是最后一道、也是**拉不到 XML 时唯一的一道**。
            //   实测 DS1621+ 的 SSDP LOCATION 指向它的第三块网卡（另一个网段的
            //   地址），从本机连不上（超时）——但响应头明写
            //   `SERVER: Synology/DSM/<地址>`，这一行就够定性了。
            guard let hint = SSDPDescriptionParser.vendorHint(fromServerHeader: ssdp.server) else {
                return nil
            }
            return Classification(kind: .nas, reason: "SSDP SERVER：\(ssdp.server ?? "")（\(hint)）")
        }
        let parts = [ssdp.manufacturer, ssdp.modelName, ssdp.modelDescription]
            .compactMap { $0 }.filter { !$0.isEmpty }
        return Classification(kind: .nas, reason: "SSDP：\(parts.joined(separator: " "))")
    }

    /// SSDP 身份是否说明这是外设（音箱/电视/路由器）。
    static func applianceFromSSDP(_ ssdp: SSDPIdentity?) -> Classification? {
        guard let ssdp else { return nil }
        if ssdp.modelDescription?.lowercased().contains("renderer") == true {
            return Classification(kind: .appliance, reason: "SSDP MediaRenderer")
        }
        if let type = ssdp.deviceType,
           type.contains("InternetGatewayDevice") || type.contains("dial-multiscreen") {
            return Classification(kind: .appliance, reason: "SSDP \(type)")
        }
        return nil
    }

    // MARK: - 依据表

    /// 明确是 NAS/服务器的私有服务类型。
    ///
    /// * `_synology-dsm._tcp` —— 实测群晖 DSM 7 广播的就是它；
    /// * `_diskstation._tcp` / `_synology._tcp` / `_qnap._tcp` —— 来自 MyNAS
    ///   （`chenqi92/my-nas`）的浏览清单，本网未实测到；收着不亏：
    ///   没有设备广播时浏览它们只是空等，有设备广播时能直接认出厂家。
    static let nasServiceTypes: Set<String> = [
        "_synology-dsm._tcp",
        "_diskstation._tcp",
        "_synology._tcp",
        "_qnap._tcp",
    ]

    /// 明确在提供文件服务的服务类型。
    ///
    /// 命中说明设备**自己喊了**「我提供文件共享」，因此够得上「文件服务器」。
    /// 注意：**TCP 端口不在这个表里**——开着 445 证明不了身份（实测本网段
    /// 20+ 台设备开着 445，其中绝大多数与文件共享无关）。
    static let fileServiceTypes: Set<String> = [
        "_smb._tcp",
        "_webdav._tcp",
        "_webdavs._tcp",     // 实测群晖广播的是这个（5006），不是 _webdav
        "_afpovertcp._tcp",
        "_ftp._tcp",
        "_sftp-ssh._tcp",
        "_nfs._tcp",
    ]

    /// 服务器机型的 model 前缀。每条都要有出处，不许凭印象加。
    ///
    /// * `xserve` —— 实测群晖 `demo-synology` 报的就是它；
    /// * `rackmac` —— Apple 机架式 Mac 服务器，与个人 Mac mini 区分；
    static let serverModelHints: [String] = ["xserve", "rackmac"]

    /// 个人电脑机型的 model 前缀（Apple 的机型标识符写法）。
    static let computerModelHints: [String] = ["macbook", "macmini", "macpro", "imac", "mac"]

    /// 明确的打印机 / 扫描仪服务。
    static let printerServiceTypes: Set<String> = [
        "_ipp._tcp", "_ipps._tcp", "_printer._tcp", "_pdl-datastream._tcp",
        "_scanner._tcp", "_uscan._tcp", "_uscan._tcp",
    ]

    /// 明确的苹果消费设备服务：AirPlay/隔空播放、随航、远程配对。
    ///
    /// 命中说明这台是 Mac/iPad/iPhone/Apple TV/音箱一类，**不是 NAS**。
    static let consumerServiceTypes: Set<String> = [
        "_airplay._tcp", "_raop._tcp", "_companion-link._tcp", "_remotepairing._tcp",
    ]

    /// 服务类型归一化：去结尾的点、统一小写。
    ///
    /// `NetService` 给的类型可能带尾点（`_smb._tcp.`），也可能不带，不统一就匹配不上。
    /// App 层也要用它去记「这台主机命中了哪些服务」，所以对外可见。
    public static func normalize(_ serviceType: String) -> String {
        var value = serviceType.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }

    /// 是不是服务器机型。**先判这个再判个人电脑**——RackMac 名字里也有 Mac。
    static func isServerModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        if serverModelHints.contains(where: { lowered.hasPrefix($0) }) { return true }
        return lowered.hasSuffix("server")
    }

    /// 是不是个人电脑机型。
    static func isComputerModel(_ model: String) -> Bool {
        let lowered = model.lowercased()
        return computerModelHints.contains(where: { lowered.hasPrefix($0) })
    }
}
