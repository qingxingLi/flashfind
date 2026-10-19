"""受控回归（红证）：把多处实现分别改坏，验证新测试必须变红，然后还原。

用法：python3 tools/red_proof.py
- 备份 → 变异 → swift test → 记录失败用例 → finally 还原 → SHA-256 逐字节核对
- 任何一步异常都必须还原，所以用 try/finally，不依赖脚本正常结束。

变异清单：
- 五处锁 1.0.1 第一轮三项需求（外观桥接/跟随系统/字号阶梯/启动应用/应用搜索）
- 页面标题被改回 20pt  → testPageTitleMatchesSystemSettingsScale
- 外观退回竖排单选组   → testAppearancePickerIsTwoWayBoundAndAppliedForReal
- 四处锁 build 4 设备分类（_device-info / Xserve / classifyAll / nasOnly / 向导平铺）
- 两处锁 build 5 同主机去重（App 调用点不去重 / Core 直接返回原数组）
- 一处锁 build 5 端口不许按 _smb 硬掰成 5001 → testDiscoveryDoesNotRewritePortsByServiceType
- 三处锁 build 6 网段探测（补 5005 / 压超时 / 边扫边发）
- 十处锁 LAN 发现重构的 Core 纯函数（Synology TLV 编解码 / DeviceMerger / 分类优先级）
- 七处锁 2026-10-16 开源审核：凭据「读不出来就不许写」(OSS-04/05)、已选文件夹接上真实遍历 (OSS-08)
- 四处锁 2026-10-16 开源审核（build 18）：看门狗落 MainActor (OSS-06)、旧代输出不许动新核心 (OSS-07)、
  整台 Mac 不许被残留 folders 限制
- 四处锁 2026-10-17 §3.6 设置导航收敛：页面集合必须遍历 Core、导航用系统分段控件、
  内容区限宽、窗口宽度跟着收窄
- ★ 锚点纪律：`text.replace(old, new, 1)` 只改第一处。同一份文件里有多个同名样式时
  （如 `.pickerStyle(.segmented)` 同时被导航和外观用），锚点必须带上**只属于目标**的相邻行，
  否则先出现的那一处会被改掉，目标没动，红证就假绿了。
"""
import hashlib
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

CLIENT = Path(__file__).resolve().parent.parent
ROOT = CLIENT.parents[2]   # 项目根：client → FlashFind2 → 03-开发 → 项目根
FILES = {
    'AppModel': CLIENT / 'Sources/FlashFind2App/AppModel.swift',
    'ResultActionController': CLIENT / 'Sources/FlashFind2App/ResultActionController.swift',
    'NASAutoConnectRunner': CLIENT / 'Sources/FlashFindCore/NASAutoConnectRunner.swift',
    'AppearanceController': CLIENT / 'Sources/FlashFind2App/AppearanceController.swift',
    'SettingsView': CLIENT / 'Sources/FlashFind2App/SettingsView.swift',
    'SettingsWindow': CLIENT / 'Sources/FlashFind2App/SettingsWindow.swift',
    'FlashFind2App': CLIENT / 'Sources/FlashFind2App/FlashFind2App.swift',
    'SettingsTypography': CLIENT / 'Sources/FlashFindCore/SettingsTypography.swift',
    'DeviceClassifier': CLIENT / 'Sources/FlashFindCore/DeviceClassifier.swift',
    'NetworkDiscovery': CLIENT / 'Sources/FlashFindCore/NetworkDiscovery.swift',
    'SynologyDiscoveryPacket': CLIENT / 'Sources/FlashFindCore/SynologyDiscoveryPacket.swift',
    'DeviceMerger': CLIENT / 'Sources/FlashFindCore/DeviceMerger.swift',
    'WizardView': CLIENT / 'Sources/FlashFind2App/NASSourceWizardView.swift',
    'WizardController': CLIENT / 'Sources/FlashFind2App/NASSourceWizardController.swift',
    'MountDiscovery': CLIENT / 'Sources/FlashFindCore/SMBMountDiscovery.swift',
    'LocalNetworkDiscovery': CLIENT / 'Sources/FlashFind2App/LocalNetworkDiscovery.swift',
    'SearchResultRanker': CLIENT / 'Sources/FlashFindCore/SearchResultRanker.swift',
    'NASSearchProvider': CLIENT / 'Sources/FlashFindCore/NASSearchProvider.swift',
    'ConnectionFailureText': CLIENT / 'Sources/FlashFindCore/ConnectionFailureText.swift',
    'SearchQueryParser': CLIENT / 'Sources/FlashFindCore/SearchQueryParser.swift',
    'AppSearchProvider': CLIENT / 'Sources/FlashFindCore/AppSearchProvider.swift',
    'SearchFieldView': CLIENT / 'Sources/FlashFind2App/SearchFieldView.swift',
    'BrandGlyphMetrics': CLIENT / 'Sources/FlashFindCore/BrandGlyphMetrics.swift',
    'BuildTrial': CLIENT / 'scripts/build_trial.py',
    'BuildEntry': CLIENT / 'scripts/build.sh',
    # AppModel 随 Stage 3A 拆成主文件 + 分区；变异项要指向**代码现在所在的**文件。
    'AppModelWizard': CLIENT / 'Sources/FlashFind2App/AppModel+Wizard.swift',
    'AppModelConnections': CLIENT / 'Sources/FlashFind2App/AppModel+NASConnections.swift',
    'AppModelNativeSources': CLIENT / 'Sources/FlashFind2App/AppModel+NativeSources.swift',
    'AppModelSourceActions': CLIENT / 'Sources/FlashFind2App/AppModel+SourceActions.swift',
    'AppModelQuietConnect': CLIENT / 'Sources/FlashFind2App/AppModel+QuietConnect.swift',
    'SearchView': CLIENT / 'Sources/FlashFind2App/SearchView.swift',
    'Core': CLIENT / 'MyNASCore/lib/core.dart',
    'Page': CLIENT / 'MyNASCore/lib/synology_api.dart',
    'CredentialStore': CLIENT / 'Sources/FlashFindCore/CredentialStore.swift',
    'FileSecretStore': CLIENT / 'Sources/FlashFindCore/FileSecretStore.swift',
    'CredentialMigration': CLIENT / 'Sources/FlashFindCore/CredentialMigration.swift',
    'KeychainSecretStore': CLIENT / 'Sources/FlashFindCore/KeychainSecretStore.swift',
    'NASSourceConfig': CLIENT / 'Sources/FlashFindCore/NASSourceConfig.swift',
    'CredentialIdentity': CLIENT / 'Sources/FlashFindCore/CredentialIdentity.swift',
    'KeychainTierMigration': CLIENT / 'Sources/FlashFindCore/KeychainTierMigration.swift',
    'LocalSearchProvider': CLIENT / 'Sources/FlashFindCore/LocalSearchProvider.swift',
    'LocalFolderSearch': CLIENT / 'Sources/FlashFindCore/LocalFolderSearch.swift',
    'MyNASProcessBridge': CLIENT / 'Sources/FlashFindCore/MyNASProcessBridge.swift',
    'SpotlightProvider': CLIENT / 'Sources/FlashFindCore/SpotlightProvider.swift',
    'ExperimentalSources': CLIENT / 'Sources/FlashFindCore/ExperimentalSources.swift',
    'NASConnectionManager': CLIENT / 'Sources/FlashFindCore/NASConnectionManager.swift',
    'PreviewInteractionValidation': CLIENT / 'Sources/FlashFind2App/DebugSupport/PreviewInteractionValidation.swift',
}

# Dart 测试套件与 SDK。核心逻辑在 Dart 侧，只跑 swift test 会漏掉整整一半回归
# （2026-10-16 就绪判据修复正是纯 Dart 改动），所以这里一并跑。
def _find_dart() -> Path:
    """Dart SDK 的位置因人因机而异，这里不写死任何人的本机路径。

    优先环境变量 DART_SDK（可指向 sdk 根目录，也可直接指向 bin/dart），
    其次 PATH，最后兜几个常见安装位置。找不到就返回一个不存在的文件名——
    调用处会明确打印「跳过 Dart 红证」，而不是悄悄少跑一块。
    """
    import os
    import shutil
    override = os.environ.get('DART_SDK')
    candidates: list[Path] = []
    if override:
        candidates += [Path(override) / 'bin' / 'dart', Path(override)]
    which = shutil.which('dart')
    if which:
        candidates.append(Path(which))
    candidates += [
        Path.home() / 'flutter/bin/cache/dart-sdk/bin/dart',
        Path('/opt/homebrew/opt/dart-sdk/libexec/bin/dart'),
        Path('/usr/local/opt/dart-sdk/libexec/bin/dart'),
    ]
    for candidate in candidates:
        if candidate.is_file():
            return candidate
    return Path('dart-not-found')


DART_SDK = _find_dart()
DART_SUITES = ['test_search_readiness', 'test_adapters', 'test_multi_scope',
               'test_error_kinds', 'test_pending_tasks', 'test_transport_diagnostics',
               'test_admin_identity', 'test_adapter_failure_reporting']
DART_DIR = CLIENT / 'MyNASCore'

MUTATIONS = [
    ('外观桥接被删', FILES['AppModel'],
     'appearanceBridge = appearance.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }',
     'appearanceBridge = nil'),
    ('跟随系统被硬套成浅色', FILES['AppearanceController'],
     'case .system: return nil',
     'case .system: return NSAppearance(named: .aqua)'),
    ('分段标题不用字号阶梯', FILES['SettingsView'],
     'Text(text).font(.system(size: SettingsTypography.sectionHeader, weight: .semibold))',
     'Text(text).font(.system(size: 13, weight: .semibold))'),
    ('启动不应用外观', FILES['FlashFind2App'],
     '        model.applyAppearance()\n', ''),
    ('应用搜索不进协调器', FILES['AppModelNativeSources'],
     'var list: [any SearchProvider] = [self.localProvider, self.appProvider]',
     'var list: [any SearchProvider] = [self.localProvider]'),
    ('页面标题被改回 20pt', FILES['SettingsTypography'],
     'public static let pageTitle: CGFloat = 17',
     'public static let pageTitle: CGFloat = 20'),
    # ★ 锚点必须带上 appearance-choice：变异是 replace(old, new, 1)，只改第一处。
    # 一级导航的分段控件在文件更靠前的位置，只锁 `.pickerStyle(.segmented)`
    # 会先命中导航那一处，外观那处反而没被动，红证就成了假绿。
    ('外观退回竖排单选组', FILES['SettingsView'],
     """.pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance-choice")""",
     """.pickerStyle(.radioGroup)
                    .labelsHidden()
                    .accessibilityIdentifier("appearance-choice")"""),
    ('不浏览 _device-info（拿不到型号）', FILES['NetworkDiscovery'],
     '        "_device-info._tcp",\n',
     ''),
    ('Xserve 被当成个人电脑', FILES['DeviceClassifier'],
     'static let serverModelHints: [String] = ["xserve", "rackmac"]',
     'static let serverModelHints: [String] = ["rackmac"]'),
    ('只看 NAS 时把文件服务器也筛掉', FILES['NetworkDiscovery'],
     'devices.filter { $0.kind.shownInDefaultList }',
     'devices.filter { $0.kind == .nas }'),
    ('publish 漏掉 ARP 证据', FILES['LocalNetworkDiscovery'],
     """        let all = Array(bonjourEvidence.values)
            + arpEvidence""",
     '        let all = Array(bonjourEvidence.values)'),
    ('向导把全部设备平铺出来', FILES['WizardView'],
     'showAllNearbyDevices ? discovery.devices : NetworkDiscovery.shownByDefault(discovery.devices)',
     'discovery.devices'),
    ('端口按 _smb 硬掰成 5001', FILES['LocalNetworkDiscovery'],
     '        if NetworkDiscovery.vendorHint(forServiceType: serviceType) == .synology {\n            return reported\n        }\n        return reported',
     '        if serviceType.hasPrefix("_smb") { return 5001 }\n        return reported'),
    ('探测端口漏掉 WebDAV 5005', FILES['NetworkDiscovery'],
     'public static let probePorts = [5001, 5000, 5005, 445]',
     'public static let probePorts = [5001, 5000, 445]'),
    ('加端口却不压缩单口超时', FILES['NetworkDiscovery'],
     'public static let probeTimeout: Double = 0.9',
     'public static let probeTimeout: Double = 1.2'),
    # ---- LAN 发现重构（2026-10-15，Core 纯函数）----
    ('query 不带协议版本字段', FILES['SynologyDiscoveryPacket'],
     'packet.append(tlv(0xA4, u32(0x01020000)))   // 协议版本',
     'packet.append(tlv(0xA4, u32(0)))'),
    ('model 字段被丢掉', FILES['SynologyDiscoveryPacket'],
     'case 0x78: response.model = stringValue(value)',
     'case 0x78: break'),
    ('build 号按字符串解', FILES['SynologyDiscoveryPacket'],
     'case 0x49: response.dsmBuild = u32Value(value)',
     'case 0x49: response.platform = stringValue(value)'),
    ('query 环回不被丢弃', FILES['SynologyDiscoveryPacket'],
     'if response.packetType == 1 { return nil }',
     'if response.packetType == 99 { return nil }'),
    ('merger 不按序列号/MAC 归并', FILES['DeviceMerger'],
     '''            var keys = Set(item.serials.compactMap { normalizeKey($0) })
            if let mac = item.mac, let normalized = normalizeKey(mac) { keys.insert(normalized) }
            // ★ Synology 自述里的序列号/MAC 也是身份键。
            //   实测 DS1621+：.88 只有 Synology 自述（序列号 SNFAKEDSM0001、MAC），
            //   .152 只有 SSDP（serialNumber 是同一个值）——两边不同协议、不同 IP，
            //   靠这两个键才能归成一台。少了它，三块网卡就是「三台 NAS」。
            if let serial = item.synology?.serial, let normalized = normalizeKey(serial) {
                keys.insert(normalized)
            }
            if let mac = item.synology?.mac, let normalized = normalizeKey(mac) {
                keys.insert(normalized)
            }
            // SSDP 的 serialNumber 实测填的是去冒号 MAC，也是身份键。
            if let serial = item.ssdp?.serialNumber, let normalized = normalizeKey(serial) {
                keys.insert(normalized)
            }''',
     '            var keys = Set<String>()'),
    ('显示名按纯字典序挑主机名', FILES['DeviceMerger'],
     '''        // ★ 用户自己起的实例名优先于 `.local` 主机名：`.local` 是 mDNS 按机器名
        //   自动生成的（`MacBook-Air.local`），而实例名才是用户在 NAS 上填的那个。
        //   纯字典序会让 `z.local` 排到「公司 NAS」前面——中文排序总吃亏。
        if let named = names.filter({ !$0.hasSuffix(".local") }).sorted().first { return named }''',
     ''),
    ('主 IP 退回字典序', FILES['DeviceMerger'],
     'let sortedMembers = members.sorted(by: Self.ipLess)',
     'let sortedMembers = members.sorted()'),
    ('merger 忽略 DSM 自报端口', FILES['DeviceMerger'],
     '''        if let https = evidence.synology?.dsmHTTPSPort { candidates.insert(https) }
        if let http = evidence.synology?.dsmHTTPPort { candidates.insert(http) }''',
     '        let _ = evidence.synology'),
    ('电脑型号判定被删（Mac 会挤进默认列表）', FILES['DeviceClassifier'],
     r'''        // 5. 型号：个人电脑机型。★ 必须先于文件服务：Mac 开了文件共享也广播 _smb。
        if let model = models.first(where: { isComputerModel($0) }) {
            return Classification(kind: .computer, reason: "型号 \(model)（个人电脑）")
        }''',
     '        // 5. 型号：个人电脑机型。★ 必须先于文件服务：Mac 开了文件共享也广播 _smb。'),
    ('SSDP 的 NAS 识别被删', FILES['DeviceClassifier'],
     '''        let manufacturer = ssdp.manufacturer?.lowercased() ?? ""
        let description = ssdp.modelDescription?.lowercased() ?? ""''',
     '''        let manufacturer = ""
        let description = ""'''),
    ('_webdavs 从浏览清单删掉', FILES['NetworkDiscovery'],
     '        "_webdavs._tcp",\n',
     ''),
    ('文件服务清单漏掉 AFP', FILES['DeviceClassifier'],
     '        "_afpovertcp._tcp",\n        "_ftp._tcp",',
     '        "_ftp._tcp",'),
    # 这条的锚点里带注释：两行代码被四行注释隔着，只能整块锚。
    # 注释文案改动时要同步这里，否则会平白失配。
    ('TCP 探测不边扫边发', FILES['LocalNetworkDiscovery'],
     """                    probeEvidence[hit.0] = item
                    // ★ 边扫边发：整轮要十几秒，等扫完才发布的话，第 5 秒就探到的
                    // 设备要等到最后才出现；而 Bonjour 那几台是增量回调的，
                    // 界面看着像「已经扫完了」，用户就以为剩下的设备没被识别出来
                    // （实测教训）。
                    publish()""",
     """                    probeEvidence[hit.0] = item
                    // ★ 边扫边发：整轮要十几秒，等扫完才发布的话，第 5 秒就探到的
                    // 设备要等到最后才出现；而 Bonjour 那几台是增量回调的，
                    // 界面看着像「已经扫完了」，用户就以为剩下的设备没被识别出来
                    // （实测教训）。"""),
    ('TCP 探测退回整网扫描（不看 ARP）', FILES['LocalNetworkDiscovery'],
     '        var hosts = onlineHosts',
     '        var hosts: [String] = []'),
    ('SSDP 的 SERVER 头兜底被删', FILES['DeviceClassifier'],
     """            guard let hint = SSDPDescriptionParser.vendorHint(fromServerHeader: ssdp.server) else {
                return nil
            }
            return Classification(kind: .nas, reason: "SSDP SERVER：\\(ssdp.server ?? "")（\\(hint)）")""",
     '            return nil'),
    ('装配不标已添加', FILES['NetworkDiscovery'],
     'alreadyAdded: existingHosts.contains(device.host)',
     'alreadyAdded: false'),
    # ---- 搜索结果排序（2026-10-15，rank 计算）----
    ('NAS result 不计算 rank', FILES['NASSearchProvider'],
     'row.rank = SearchResultRanker.rank(name: name, path: path, query: query)',
     'row.rank = 3'),
    # 下面这条必须排在「NAS 结果不把查询词传进 ranker」**之前**：
    # 那条的目标串是 `self.result($0, query: text)`，得先由这一条把
    # `query: parsed.keywords` 变回 text，它才找得到。
    ('NAS 结果用整串而不是剥离后的关键词算 rank', FILES['NASSearchProvider'],
     'query: parsed.keywords',
     'query: text'),
    ('NAS 结果不把查询词传进 ranker', FILES['NASSearchProvider'],
     'self.result($0, query: text)',
     'self.result($0)'),
    ('ranker 把精确匹配降级', FILES['SearchResultRanker'],
     'if foldedName == foldedQuery { return 0 }',
     'if foldedName == foldedQuery { return 2 }'),
    # ---- OTP 重新登录（2026-10-15，两步验证弹窗）----
    ('OTP 判定把核心 kind 全部判成 false', FILES['ConnectionFailureText'],
     'return kind == "NeedsOTP" || kind == "OTPRejected"',
     'return kind.isEmpty'),
    ('OTP 判定把非核心错误也判成 true', FILES['ConnectionFailureText'],
     'return text.contains("NeedsOTP") || text.contains("OTPRejected")',
     'return true'),
    ('reconnectSource 不看 needsOTP 标记', FILES['AppModelSourceActions'],
     'if sourceStatus(id).needsOTP {',
     'if false {'),
    ('OTP 失败后状态不标记 needsOTP', FILES['AppModelQuietConnect'],
     '''                $0.requiredAction = needsOTP ? .login : .retry
                $0.needsOTP = needsOTP''',
     '''                $0.requiredAction = .retry
                $0.needsOTP = false'''),
    ('连接成功后不清 needsOTP', FILES['AppModelQuietConnect'],
     '''                $0.requiredAction = nil
                // 连上了就把 OTP 标记清掉：不清的话用户下次点「重新登录…」
                // 还会被问一次动态码，而这次会话根本不需要。
                $0.needsOTP = false''',
     '''                $0.requiredAction = nil
                // 连上了就把 OTP 标记清掉：不清的话用户下次点「重新登录…」
                // 还会被问一次动态码，而这次会话根本不需要。
                $0.needsOTP = true'''),
    ('弹 OTP 框前不激活应用', FILES['AppModelSourceActions'],
     '''        NSApp.activate(ignoringOtherApps: true)

        let response = alert.runModal()''',
     '''        let response = alert.runModal()'''),
    ('重连向导不显示窗口', FILES['AppModelWizard'],
     '''        wizard.openReconnectWizard(id, reason: reason)
        NSApp.activate(ignoringOtherApps: true)
        NASWizardWindow.shared.show(model: self)''',
     '''        wizard.openReconnectWizard(id, reason: reason)'''),
    # ---- 开机自动连接重试（2026-10-15）----
    ('开机自动连接不走重试驱动器', FILES['AppModelQuietConnect'],
     '        switch await runner.run() {',
     '        switch NASAutoConnectOutcome.settled {'),
    ('重试间隙不复核连接意图', FILES['NASAutoConnectRunner'],
     '            guard stillValid() else { return .settled }',
     '            if false { return .settled }'),
    ('连接成功之后还继续重试', FILES['NASAutoConnectRunner'],
     'if try await attempt() { return .connected }',
     'if try await attempt() { }'),
    ('退避表与重试次数不一致', FILES['NASAutoConnectRunner'],
     'public static let maxAttempts = 5',
     'public static let maxAttempts = 6'),
    # ---- 名称 + 格式搜索（2026-10-15）----
    ('打开文件成功后不收起浮窗', FILES['ResultActionController'],
     '''                    if NSWorkspace.shared.open(url) {
                        // 成功打开才收起浮窗：失败时要留着浮窗显示错误提示。
                        // 与 reveal 分支同一教训：打开动作之后闪寻必须让位，
                        // NSWorkspace.open 自己会激活目标 App，不许再抢焦点。
                        onHidePanel()
                    } else {''',
     '''                    if NSWorkspace.shared.open(url) {
                        _ = url
                    } else {'''),
    ('格式词被留在发给设备的名字模式里', FILES['NASSearchProvider'],
     'let pattern = parsed.keywords.isEmpty && parsed.hasFormatFilter ? "*" : parsed.keywords',
     'let pattern = text'),
    ('NAS 结果不按格式收敛', FILES['NASSearchProvider'],
     '.filter { parsed.matches($0.name) }',
     '.filter { _ in true }'),
    ('格式解析不加同族连带', FILES['SearchQueryParser'],
     '"ppt": ["ppt", "pptx"],',
     '"ppt": ["ppt"],'),
    ('点后面的数字后缀也被当扩展名', FILES['SearchQueryParser'],
     'let first = ext.first, !first.isNumber else { return nil }',
     'let first = ext.first, first != nil else { return nil }'),
    ('扩展名判定不限制 ASCII', FILES['SearchQueryParser'],
     'ext.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) })',
     'ext.allSatisfy({ $0.isLetter || $0.isNumber })'),
    ('「文件」被塞回类别词', FILES['SearchQueryParser'],
     '        "文档": ["doc", "docx", "pdf", "txt", "md", "rtf", "pages", "wps", "odt", "epub"],',
     '        "文档": ["doc", "docx", "pdf", "txt", "md", "rtf", "pages", "wps", "odt", "epub"],\n'
     '        "文件": ["doc", "docx", "pdf"],'),
    ('格式匹配放行一切', FILES['SearchQueryParser'],
     'return extensions.contains(Self.extensionOf(name))',
     'return true'),
    ('点开头的文件名也被当扩展名', FILES['SearchQueryParser'],
     'guard let dot = name.lastIndex(of: "."), dot > name.startIndex else { return "" }',
     'guard let dot = name.lastIndex(of: ".") else { return "" }'),
    ('同一格式词重复入列', FILES['SearchQueryParser'],
     'if !extensions.contains(lowered) { extensions.append(lowered) }',
     'extensions.append(lowered)'),
    ('应用搜索不拦格式限制', FILES['AppSearchProvider'],
     'guard !parsed.hasFormatFilter, !parsed.keywords.isEmpty else {',
     'guard !parsed.keywords.isEmpty else {'),
    # ---- 搜索框前导品牌字形（2026-10-15）----
    ('搜索框退回系统放大镜', FILES['SearchFieldView'],
     '''            Image(nsImage: StatusIcon.searchFieldGlyph())
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)''',
     '''            Image(systemName: "magnifyingglass")
                .font(.system(size: 22, weight: .regular))
                .foregroundStyle(.secondary)'''),
    # 22pt 框偏要用状态栏那套 18/36px 素材：能编译、能跑、图标也照样出来，
    # 只是 Retina 上被放大 1.22 倍发虚——只有源码结构能锁住。
    ('搜索框复用状态栏低密度素材', FILES['FlashFind2App'],
     'glyph(named: "ShanXunGlyph", height: BrandGlyphMetrics.searchFieldHeight)',
     'glyph(named: "ShanXunMenuIcon", height: BrandGlyphMetrics.searchFieldHeight)'),
    # 打包脚本漏拷 22pt 素材：App 运行时静默退回系统放大镜，编译与测试都发现不了。
    ('22pt 素材不进包', FILES['BuildTrial'],
     "SEARCH_GLYPH_NAMES = ('ShanXunGlyph.png', 'ShanXunGlyph@2x.png')",
     "SEARCH_GLYPH_NAMES = ('ShanXunMenuIcon.png', 'ShanXunMenuIcon@2x.png')"),
    # ── 2026-10-16：重新搜索按钮（用户报障 IncompleteResponse 时的一键重来）──
    ('重新搜索按钮整个被删', FILES['SearchFieldView'],
     '            // 重新搜索：放在清除按钮与「更多」菜单之间——用户报障时指的就是这一角。\n            // 图标而非文字，是为了不挤占关键词输入框的宽度；名字走 help 与读屏。\n            Button(action: research) {\n                Image(systemName: "arrow.clockwise").font(.system(size: 17))\n            }\n            .buttonStyle(.plain).foregroundStyle(.secondary)\n            // 关键词为空时重搜没有意义（changedQuery 会直接清空返回），\n            // 所以置灰，别给一个点了没反应的按钮。\n            .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)\n            .help("重新搜索").accessibilityLabel("重新搜索")\n',
     ''),
    # 按钮还在，但动作被换成空闭包——「画了却没接线」正是本项目最典型的假状态。
    ('重新搜索按钮没接到 changedQuery', FILES['SearchView'],
     'research: model.changedQuery', 'research: {}'),
    # ── 2026-10-16：就绪判据（Dart 侧核心修复）──
    # 退回「有 total 就放行」。这一条 Swift 测试一条都抓不到，
    # 只有 Dart 的 test_search_readiness 能抓住——所以红证必须跑 Dart。
    ('就绪判据退回「有 total 就放行」', FILES['Page'],
     'bool get ready => total != null && finished != false;',
     'bool get ready => total != null;'),
    # 「忘了缩放、直接用素材原始像素宽」——注意别挑「拉成正方形」当变异：
    # 那条返回值与「素材尺寸非法按正方形兜底」完全重合，两个变异一起应用时互相抵消
    # （2026-10-15 实测：兜底守卫被删干净测试照样绿）。
    ('字形不缩放素材原始宽', FILES['BrandGlyphMetrics'],
     'return CGSize(width: height * (naturalWidth / naturalHeight), height: height)',
     'return CGSize(width: naturalWidth, height: height)'),
    ('搜索框图标高度不再是 22pt', FILES['BrandGlyphMetrics'],
     'public static let searchFieldHeight: CGFloat = 22',
     'public static let searchFieldHeight: CGFloat = 18'),
    ('非法高度不再返回 zero', FILES['BrandGlyphMetrics'],
     '        guard height > 0, height.isFinite else { return .zero }\n',
     ''),
    ('图稿尺寸非法不再兜底', FILES['BrandGlyphMetrics'],
     '''        guard naturalWidth > 0, naturalHeight > 0,
              naturalWidth.isFinite, naturalHeight.isFinite else {
            return CGSize(width: height, height: height)
        }
''', ''),
    # 调用点是跨行的，只改第二行也能编译——写死 18 就绕开了 Core 的常量。
    ('状态栏不走同一条换算', FILES['FlashFind2App'],
     'height: BrandGlyphMetrics.menuBarHeight)',
     'height: 18)'),
    # ---- 凭据文件（2026-10-16 审核 OSS-04 / OSS-05）----
    # 这几条的共同点：把「读不出来」重新折叠成空表。折叠之后保存就会
    # 拿「空表 + 这一条」整个覆盖文件，其余 NAS 的密码当场消失且无任何提示。
    ('JSON 解不开被当成空表', FILES['FileSecretStore'],
     '            } catch is DecodingError {\n                result = .problem(.undecodable)',
     '            } catch is DecodingError {\n                result = .records([:])'),
    ('更新版本的文件被当成空表', FILES['FileSecretStore'],
     '                result = document.version > Self.currentVersion\n'
     '                    ? .problem(.newerVersion(document.version))\n'
     '                    : .records(document.records)',
     '                result = .records(document.records)'),
    ('读不出来时保存不再拒绝', FILES['FileSecretStore'],
     '            throw CredentialStoreError.storeUnreadable(problem)',
     '            return'),
    ('读不出来时删除照样报成功', FILES['FileSecretStore'],
     '        case .problem:\n'
     "            // 删除也要落盘，读不出来时不能删——否则又是拿空表覆盖。\n"
     '            // 返回 false：「删除成功」会让人以为那条凭据确实没了。\n'
     '            return false',
     '        case .problem:\n'
     "            // 删除也要落盘，读不出来时不能删——否则又是拿空表覆盖。\n"
     '            return true'),
    ('落盘退回先删后放', FILES['FileSecretStore'],
     '            if manager.fileExists(atPath: fileURL.path) {\n'
     '                _ = try manager.replaceItemAt(fileURL, withItemAt: temporary,\n'
     '                                              backupItemName: nil,\n'
     '                                              options: .usingNewMetadataOnly)\n'
     '            } else {\n'
     '                try manager.moveItem(at: temporary, to: fileURL)\n'
     '            }',
     '            try? manager.removeItem(at: fileURL)\n'
     '            try manager.moveItem(at: temporary, to: fileURL)'),
    ('读失败不再暴露给界面', FILES['FileSecretStore'],
     '        if case let .problem(problem) = loadedLocked() { return problem }\n'
     '        return nil',
     '        return nil'),

    # ---- 已选文件夹模式接上真实遍历（2026-10-16 审核 OSS-08）----
    # 这一组锁的是「调用点」而不是定义：遍历实现早就写好且有测试，
    # 缺的正是产品代码去调它。
    ('文件夹模式退回系统索引', FILES['LocalSearchProvider'],
     '        case .selectedFolders:\n'
     '            await searchSelectedFolders(parsed, queryID: queryID, emit: emit)',
     '        case .selectedFolders:\n'
     '            await searchWithSpotlight(parsed, queryID: queryID, emit: emit)'),
    ('App 不把搜索方式交给 provider', FILES['AppModelConnections'],
     ';localProvider.mode=localSearchMode', ''),
    ('文件夹模式丢掉格式限制', FILES['LocalSearchProvider'],
     'try LocalFolderSearch.search(keywords, folders: folders, extensions: extensions)',
     'try LocalFolderSearch.search(keywords, folders: folders)'),
    ('取消不再传到后台遍历', FILES['LocalSearchProvider'],
     '        folderTask?.cancel()', ''),
    ('遍历不再按格式过滤', FILES['LocalFolderSearch'],
     'terms.allSatisfy({ name.contains($0) }), parsed.matches(name), identities.insert(value.path).inserted',
     'terms.allSatisfy({ name.contains($0) }), identities.insert(value.path).inserted'),

    # ---- 核心进程桥的并发与代次（2026-10-16 审核 OSS-06 / OSS-07）----
    # OSS-06：把兜底看门狗退回「DispatchWorkItem + global().asyncAfter」，也就是
    # 让 180 秒后的 `timeOut` 在**全局队列**上直接调 MainActor 上的方法。
    # 这两条必须成对：`watchdogs` 的存放类型跟着变，只改一条编不过。
    # 回来的正是审核看到的那份代码，不是编出来的假象。
    ('看门狗退回全局队列定时器', FILES['MyNASProcessBridge'],
     '    private var watchdogs: [String: Task<Void, Never>] = [:]',
     '    private var watchdogs: [String: DispatchWorkItem] = [:]'),
    ('看门狗跨线程调 timeOut', FILES['MyNASProcessBridge'],
     '            let seconds = watchdogSeconds\n'
     '            watchdogs[id] = Task { [weak self] in\n'
     '                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))\n'
     '                guard !Task.isCancelled else { return }\n'
     '                self?.timeOut(id)\n'
     '            }',
     '            let watchdog = DispatchWorkItem { [weak self] in self?.timeOut(id) }\n'
     '            watchdogs[id] = watchdog\n'
     '            DispatchQueue.global().asyncAfter(deadline: .now() + watchdogSeconds, execute: watchdog)'),
    # OSS-07：读循环投递不再核对代次。旧核心退出前排进主线程队列的坏帧会照样生效，
    # 把新核心连它的连接与搜索一起拆掉 —— 表现是「刚连上又断了」。
    ('旧代输出不再被丢弃', FILES['MyNASProcessBridge'],
     'private func stillCurrent(_ generation: Int) -> Bool { generation == processGeneration }',
     'private func stillCurrent(_ generation: Int) -> Bool { true }'),

    # ---- 整台 Mac 被残留的旧文件夹框住（2026-10-16 审核新发现）----
    # `folders` 是 provider 上的状态，切回全盘时并不清空；一旦这一行又把它转发给
    # Spotlight，`searchScopes` 就从「本机全盘」缩成那几个旧目录。
    ('整台 Mac 又把残留 folders 转发给 Spotlight', FILES['LocalSearchProvider'],
     'provider.search(parsed.keywords, extensions: parsed.extensions)',
     'provider.search(parsed.keywords, extensions: parsed.extensions, folders: folders)'),
    # ---- 2026-10-17 凭据生命周期（第一阶段核心目标）----
    ('读取不校验归属（改了目标还拿得到旧密码）', FILES['CredentialStore'],
     '        guard let identity else { return raw }\n        return CredentialEnvelope.unwrap(raw, identity: identity)',
     '        guard let identity else { return raw }\n        return raw'),
    ('保存不封身份（将来无法判断这条凭据属于谁）', FILES['CredentialStore'],
     '        let payload = identity.map { CredentialEnvelope.wrap(value, identity: $0) } ?? value',
     '        let payload = value'),
    ('身份不认端口（换端口仍复用旧密码）', FILES['NASSourceConfig'],
     '        CredentialIdentity(host: hostName, port: effectivePort, username: username)',
     '        CredentialIdentity(host: hostName, port: 0, username: username)'),
    ('关掉「记住密码」不删凭据', FILES['CredentialStore'],
     '        guard !remember else { return false }',
     '        return false'),
    ('删来源时又去看 rememberPassword（留下孤儿条目）', FILES['CredentialStore'],
     '        delete(account: config.credentialAccount, reason: "来源已被用户移除")',
     '        guard config.rememberPassword else { return false }\n        return delete(account: config.credentialAccount, reason: "来源已被用户移除")'),
    ('没验证就删明文（密码两头落空）', FILES['CredentialStore'],
     '        guard file.pendingVerification.contains(account) else { return false }',
     ''),
    ('迁完留一个空凭据文件', FILES['CredentialStore'],
     '        return (try? file.removeStorageFile()) != nil',
     '        return dropped'),
    ('GUI 又装回文件后端（第一阶段核心目标失效）', FILES['FlashFind2App'],
     '        CredentialStore.install(KeychainSecretStore(), plaintextSource: FileSecretStore())',
     '        CredentialStore.install(FileSecretStore())'),
    ('钥匙串不做 entitlement 兜底（记住密码静默失效）', FILES['KeychainSecretStore'],
     '        guard status == errSecMissingEntitlement, protecting else { return status }',
     '        guard status == errSecDuplicateItem, protecting else { return status }'),


    ('迁移失败却标成已迁移（明文会被提前删掉）', FILES['CredentialMigration'],
     '                report.failures.append(Failure(account: account, reason: String(describing: error)))',
     '                source.markMigrated(account)'),
    ('启动不触发一次性迁移（旧明文永远躺在那儿）', FILES['FlashFind2App'],
     '            CredentialStore.migrateLegacyPlaintext()\n',
     ''),

    # ---- 2026-10-17 第二阶段开局：摘要算法与旧键清理 ----
    ('身份摘要退回 FNV-1a（不再是 SHA-256）', FILES['CredentialIdentity'],
     '        let digest = SHA256.hash(data: Data(canonical.utf8))\n        return digest.map { String(format: "%02x", $0) }.joined()',
     '        var hash: UInt64 = 0xcbf29ce484222325\n        for byte in canonical.utf8 { hash ^= UInt64(byte); hash = hash &* 0x100000001b3 }\n        return String(hash, radix: 16, uppercase: false)'),
    ('清理旧副本时把新键当成旧键删掉', FILES['CredentialStore'],
     '        return delete(account: legacyAccount, reason: reason)',
     '        return delete(account: account, reason: reason)'),
    ('新旧同键时不挡（删掉唯一的活凭据）', FILES['CredentialStore'],
     '        guard legacyAccount != account else { return false }\n',
     ''),
    ('没有旧键时拿新键顶上（no-op 变成误删）', FILES['CredentialStore'],
     '        guard let legacyAccount, !legacyAccount.isEmpty else { return false }',
     '        let legacyAccount = legacyAccount ?? account\n        guard !legacyAccount.isEmpty else { return false }'),
    # 锚点**不能**与其它变异共用同一行：变异是按列表顺序逐个 replace 的，
    # 前一个改掉了这一行，后一个就找不到标记（脚本会直接判失败）。
    ('清理旧副本前去读一次后端（多一次系统授权）', FILES['CredentialStore'],
     '        // 更要紧的是——此时「旧键」就是刚写进去的那份活凭据，删它等于清掉唯一副本。\n',
     '        // 更要紧的是——此时「旧键」就是刚写进去的那份活凭据，删它等于清掉唯一副本。\n        _ = read(account: account)\n'),
    ('App 层不接旧键清理（旧条目永远没人删）', FILES['AppModelConnections'],
     """                 if let legacy = profile.legacyCredentialAccount, credentialAccessAllowed {
                     CredentialStore.removeLegacyItem(legacy,
                                                      migratedTo: profile.credentialAccount,
                                                      reason: "旧键规则的副本已由新键接管")
                 }
""",
     ''),
    ('旧键清理被提到登录之前（还没证明能用就删）', FILES['AppModelConnections'],
     '                try await connection.login(password: secret)',
     """                if let legacy = profile.legacyCredentialAccount, credentialAccessAllowed {
                    CredentialStore.removeLegacyItem(legacy, migratedTo: profile.credentialAccount, reason: "提前清理")
                }
                try await connection.login(password: secret)"""),

    # ---- 2026-10-17 经典 → DP 钥匙串升迁（entitlement 到位那天才会真的发生）----
    ('升迁后不删经典侧（留下两份密码）', FILES['KeychainTierMigration'],
     '            classic.delete(account: account)\n            report.moved.append(account)',
     '            report.moved.append(account)'),
    # 「先删后写」这条变异**不能**插在成功路径上：那条路本来就要删经典侧，
    # 插进去等于什么也没变，反而会把「永不删经典侧」那条变异的红灯盖掉
    # （红证实测：两条同时应用时 120/121，缺的就是它）。
    # 因此改成让「写失败也照删」来表达顺序被破坏。
    ('DP 侧写失败也照删经典侧（顺序被破坏）', FILES['KeychainTierMigration'],
     '                report.failures.append(Failure(account: account, reason: String(describing: error)))\n                continue',
     '                report.failures.append(Failure(account: account, reason: String(describing: error)))'),
    ('经典侧没存过也算失败（真故障会被淹没）', FILES['KeychainTierMigration'],
     '                report.absentOnClassic.append(account)\n                continue',
     '                report.failures.append(Failure(account: account, reason: "经典侧没有这条"))\n                continue'),
    ('缺 entitlement 不中止（逐条重试到底）', FILES['KeychainTierMigration'],
     '                report.abortedForMissingEntitlement = true\n                return report',
     '                report.failures.append(Failure(account: account, reason: "missing entitlement"))\n                continue'),
    ('钉在经典层的实例仍自称走 DP', FILES['KeychainSecretStore'],
     '        case .classic: dataProtection.value = false',
     '        case .classic: break'),
    ('非钥匙串后端也照跑升迁', FILES['CredentialStore'],
     '        guard store is KeychainSecretStore, !accounts.isEmpty else { return .init() }',
     '        guard !accounts.isEmpty else { return .init() }'),
    ('启动路径上不登记层级升迁', FILES['FlashFind2App'],
     '            CredentialStore.migrateKeychainTier(accounts: model.nasSources.map { $0.credentialAccount })\n',
     ''),
    # ---- 2026-10-17 第二阶段：内部工作区路径 / 已下线品牌 ----
    # 变异里的路径只保留「工作区」这个被断言的词（测试断言 path 不含「工作区」），
    # 其它部分换成中性写法：内部顶层目录名与工作包编号不进公开仓，
    # 而哨兵守的是「不许拼开发工作区路径」这件事本身，与具体编号无关。
    ('桥接状态目录又拼回内部工作区（换机即失效）', FILES['NASConnectionManager'],
     '            ? parent.appendingPathComponent(".build/mynas-state/trust")',
     '            ? parent.appendingPathComponent("开发工作区/历史工作包/app-state/trust")'),
    ('向导又把全部枚举值下发（已下线的品牌重新可选）', FILES['ExperimentalSources'],
     '        return NASSourceConfig.Vendor.allCases.filter(\\.hasAdapter)',
     '        return NASSourceConfig.Vendor.allCases'),
    ('已下线的品牌仍算「有适配器」（界面放行、核心接不住）', FILES['NASSourceConfig'],
     '            case .retired, .notPorted: return false',
     '            case .notPorted: return false\n            case .retired: return true'),
    ('飞牛退回「已接入未验证」（抹掉真机结论）', FILES['NASSourceConfig'],
     '            case .fnos: return .retired',
     '            case .fnos: return .portedUnverified'),
    ('已下线的文案说回「还没接入」（用户会以为等一等就有）', FILES['NASSourceConfig'],
     '                return "飞牛 fnOS 的适配器**已经下线**',
      '                return "飞牛 fnOS 的适配器**还没接进闪寻**'),
    # ---- 2026-10-17 §2.6 Preview/Fixture 的 Release 隔离 ----
    # 用 `#if true` 而不是删掉包裹：删了会因多余的 #endif 编译失败，
    # 那样红的是编译器而不是断言，验证不到「这条测试真的会红」。
    ('取证设施改用 #if true（Release 里照样编进去）', FILES['PreviewInteractionValidation'],
     '#if DEBUG\n', '#if true\n'),
    # ── 2026-10-17：clean clone 下不许产出缺 NAS 运行时的 App ──
    # 整块检查被拿掉后，build.sh app 退回裸 swift build：编译照样成功，
    # 产出的 App 却缺 mynas-core，要等用户点到 NAS 搜索才炸。
    # 这个「成功」比报错贵得多，所以必须有一条红证盯着它。
    ('app 子命令不再检查 MyNAS 运行时', FILES['BuildEntry'],
     '''    auto_core=0
    if [ "${1:-}" = "--with-core" ]; then auto_core=1; shift; fi
    core_bin="$CLIENT/Resources/MyNAS/bin/mynas-core"
    helper_bin="$CLIENT/Resources/MyNAS/native/TrustHTTP"
    if [ ! -x "$core_bin" ] || [ ! -x "$helper_bin" ]; then
        if [ "$auto_core" = 1 ]; then
            echo "==> MyNAS 运行时不在位，先构建 core（--with-core）"
            bash "$CLIENT/tools/install-mynas-core.sh" || exit 1
        else
            echo "build.sh: MyNAS 运行时不在位：" >&2
            for f in "$core_bin" "$helper_bin"; do
                [ -x "$f" ] || echo "    缺 $f" >&2
            done
            echo "Resources/MyNAS/ 是构建产物、不进 Git，clean clone 后必须先补建。" >&2
            echo "    先执行：      ./scripts/build.sh core" >&2
            echo "    或一步到位：  ./scripts/build.sh app --with-core" >&2
            exit 1
        fi
    fi
''',
     '    auto_core=0\n'),
    # ---- 2026-10-17 §3.6 设置导航收敛（三页走顶部分段控件，侧栏撤掉）----
    ('一级导航不遍历 Core 的页面集合（视图里另写一份）', FILES['SettingsView'],
     'ForEach(SettingsPane.allCases) { item in',
     'ForEach([SettingsPane.general]) { item in'),
    # 锚点同样要带标识行：文件里有两处 `.pickerStyle(.segmented)`（导航 + 外观），
    # 只锁样式名会改到先出现的那一处。
    ('一级导航退回竖排单选组（不再用系统分段控件）', FILES['SettingsView'],
     """.pickerStyle(.segmented)
        .labelsHidden()
        .accessibilityIdentifier("settings-pane-picker")""",
     """.pickerStyle(.radioGroup)
        .labelsHidden()
        .accessibilityIdentifier("settings-pane-picker")"""),
    # 内容区不限宽：窗口拉宽时表单标签与控件之间会空出一大片。
    ('内容区又无限横向拉伸', FILES['SettingsView'],
     'maxWidth: SettingsLayout.contentMaxWidth',
     'maxWidth: .infinity'),
    # 窗口宽度不跟着收窄：侧栏已经撤掉，880 里就有一整条是空的。
    ('窗口宽度不跟着导航收窄', FILES['SettingsWindow'],
     'width: 640',
     'width: 880'),
    # ---- 2026-10-19 打开失败提示条被压成窄边（真机报障）----
    # 浮窗高度是算出来的：漏掉提示条这一项，提示条会被挤成一条只露出标题和
    # 两个按钮的窄边，正文整段切掉。编译、运行都不报错，只有结构断言能抓住。
    ('浮窗高度漏算打开失败提示条', FILES['SearchView'],
     'SearchLayout.searchHeight + expandedHeight + hintHeight + openFailureBannerHeight',
     'SearchLayout.searchHeight + expandedHeight + hintHeight'),
    # 提示条不跟着查询走：查询清空后它还挂在面板上，对着空列表喊「无法打开文件」。
    ('打开失败提示条跨查询残留', FILES['AppModelConnections'],
     '        openFailure = nil\n',
     ''),
    # ---- 2026-10-19 「.96 能搜不能开」（真机报障）----
    # 证书确认那条路自己造 Provider，漏装 mountService：同一份代码，
    # 证书正常的 NAS 能开、需要确认证书的那台点开就报「尚未连接共享」。
    ('证书确认路径自己造 Provider（漏装挂载服务）', FILES['WizardController'],
     'let provider = makeProvider(sharedBridge, config: config, port: candidate.port)',
     'let provider = NASSearchProvider(bridge: sharedBridge, config: config, port: candidate.port)'),
    # 只认 smbfs：早年用 AFP 挂载的老群晖（DS124）于是「能搜到、点开打不开」。
    ('挂载候选只认 smbfs', FILES['MountDiscovery'],
     'guard fileSystem == "smbfs" || fileSystem == "afpfs" else { return nil }',
     'guard fileSystem == "smbfs" else { return nil }'),
    # ---- 2026-10-19 界面只体现版本号（不带内部构建号）----
    # 空串不是漏填：不传这一项，系统会把 Info.plist 里的内部序号填进括号，
    # 面板变成「版本 1.0.1 (19)」。把它填成版本号本身也一样难看（变成 (1.0.1)）。
    ('关于面板把内部序号塞回括号', FILES['FlashFind2App'],
     '            .version: "",',
     '            .version: version,'),
]

EXPECTED = {
    # ---- 已选文件夹模式接上真实遍历（2026-10-16 审核 OSS-08）----
    # 哨兵 testSpotlightModeDoesNotPretendToBeFolderScope **不在这里**：它守的是
    # 「整台 Mac 那条路不被带偏」，修复前后都该是绿的。
    'testSelectedFoldersModeTraversesTheChosenDirectory',
    'testSelectedFoldersResultsAreMarkedAsFolderScope',
    'testSelectedFoldersModeRejectsFileSystemRoot',
    'testSelectedFoldersWithoutAnyFolderSaysSo',
    'testFolderModeHonorsFormatFilter',
    'testFolderModeAcceptsFormatOnlyQuery',
    'testCancellationReachesTheBackgroundTraversal',
    'testSearchHandsTheLocalSearchModeToTheProvider',
    # ---- 凭据文件：读不出来就不许写（2026-10-16 审核 OSS-04 / OSS-05）----
    'testSaveRefusesToWriteWhenTheFileCannotBeDecoded',
    'testSaveRefusesToClobberCredentialsItCouldNotRead',
    'testSaveRefusesToWriteWhenTheFileIsFromANewerVersion',
    'testDeleteRefusesToWriteWhenTheFileCannotBeDecoded',
    'testTheProblemIsExposedForTheInterfaceToReport',
    'testNewerVersionIsReportedAsSuchNotAsAnEmptyStore',
    'testProblemPersistsInsteadOfBeingRememberedAsEmpty',
    'testRefusalMessageExplainsThatNothingWasWritten',
    'testPersistDoesNotDeleteTheFileBeforeReplacingIt',
    'testAppearanceChangesAreBridgedToAppModel',
    'testAppearancePickerIsTwoWayBoundAndAppliedForReal',
    'testAppearanceIsAppliedBeforeAnyWindowAppears',
    'testSectionHeadersUseTheSharedTypographyScale',
    # ---- 2026-10-17 §3.6 设置导航收敛（三页走顶部分段控件）----
    'testTopLevelNavigationUsesANativeSegmentedControl',
    'testWidthsShrankWithTheSidebar',
    'testAppSearchIsWiredIntoTheSearchPipeline',
    'testPageTitleMatchesSystemSettingsScale',
    'testDiscoveryBrowsesDeviceInfoService',
    'testShownByDefaultKeepsOnlyNASAndFileServers',
    'testWizardDefaultsToIdentifiedDevicesAndKeepsShowAll',
    'testXserveModelIsTreatedAsNAS',
    'testDiscoveryDeduplicatesByHostBeforePublishing',
    'testDiscoveryDoesNotRewritePortsByServiceType',
    'testProbePortsCoverWebDAVForSilentDevices',
    'testFullSubnetScanStaysWithinBudget',
    'testSubnetScanPublishesAsItGoes',
    # LAN 发现重构（Core 纯函数）
    'testBuildQueryIsTheMinimalTwentyBytePacket',
    'testParseRealDS1621PlusResponse',
    'testBuildNumberIsNumericNotText',
    'testQueryEchoIsDropped',
    'testMultiNICSynologyIsMergedIntoOneDevice',
    'testBestPortPrefersDSMOverEverythingElse',
    'testComputerModelBeatsFileService',
    'testSSDPManufacturerIsNAS',
    'testBrowseListCoversWebDAVs',
    'testServerHeaderAloneIdentifiesSynology',
    'testMakeDevicesMarksAndSortsAlreadyAddedLast',
    'testTCPProbeIsAFallbackBehindARP',
    'testEveryFileServiceTypeMakesAFileServer',
    'testDisplayNamePreferenceOrder',
    'testMACNormalizationMatchesAcrossFormats',
    # 搜索结果排序
    'testExactMatchIsRankZero',
    'testNASSearchProviderAssignsRankFromQuery',
    'testSearchPipelinePassesQueryAndAssignsRank',
    # OTP 重新登录
    'testNeedsOTPIsRecognisedAsOTPRequired',
    'testRejectedOTPIsAlsoRecognised',
    'testOtherFailuresDoNotTriggerOTPPrompt',
    'testReconnectPromptsForOTPWhenStatusNeedsOTP',
    'testOpenFileHidesPanelAndDoesNotStealFocus',
    # 2026-10-19 真机报障：提示条被压成窄边 + 查询清空后还挂在面板上。
    'testOpenFailureBannerOwnsItsHeightAndLeavesWithTheQuery',
    # 2026-10-19 真机报障：证书确认路径漏装挂载服务 / 只认 smbfs 导致 AFP 挂载不认。
    'testWizardBuildsEveryProviderThroughOneFactory',
    'testAFPMountCountsAsConnectedShare',
    # 2026-10-19 界面只体现版本号：关于面板显式清空的 `.version` 不能被填回去。
    'testAboutPanelAndSettingsShareOneVersionSource',
    'testOTPPromptActivatesAppBeforeRunModal',
    'testOpenReconnectWizardShowsWizardWindow',
    'testQuietConnectMarksNeedsOTPThroughCore',
    # 开机自动连接重试
    'testAutoConnectRetriesThroughRunner',
    'testFirstAttemptSucceeds',
    'testRetriesUntilNetworkComesBack',
    'testGivesUpAfterBudgetedAttempts',
    'testDoesNotRetryWhenDeviceWantsOTP',
    'testStopsRetryingAfterUserDisconnects',
    'testBackoffCoversEveryRetryGap',
    'testSuccessfulConnectClearsNeedsOTP',
    # 名称 + 格式搜索
    'testFormatWordIsStrippedFromPattern',
    'testFormatWordBeforeKeywordParsesTheSame',
    'testOnlyFormatWordUsesWildcardPattern',
    'testResultsKeepOnlyRequestedFormats',
    'testRankUsesStrippedKeywords',
    'testFormatWordAfterKeyword',
    'testFamilyExpansionCoversBothGenerations',
    'testRedundantFormatWordsDeduplicated',
    'testNumericSuffixStaysInKeyword',
    'testChineseAfterDotIsNotExtension',
    'testGenericWordFileIsNotCategory',
    'testMatchesHonorsFamily',
    'testDotFileNameHasNoExtension',
    'testAppSearchStaysQuietWithFormatFilter',
    # 搜索框前导品牌字形
    'testSearchFieldShowsBrandGlyphNotSystemMagnifier',
    'testSearchGlyphAssetsExistAndArePackaged',
    'testFittedSizePreservesAspectRatio',
    'testFittedSizeReturnsZeroForNonPositiveHeight',
    'testFittedSizeReturnsZeroForNonFiniteHeight',
    'testFittedSizeFallsBackToSquareWhenArtworkSizeIsUnknown',
    'testDocumentedHeights',
    'testSearchFieldResearchButtonIsWiredForReal',
    # ---- 核心进程桥的并发与代次（2026-10-16 审核 OSS-06 / OSS-07）----
    'testWatchdogFiresOnTheMainActor',
    'testStaleHelperOutputCannotAbortTheNewCore',
    # ---- 整台 Mac 被残留的旧文件夹框住（2026-10-16 审核新发现）----
    'testWholeMacSearchDoesNotForwardResidualFolders',
    # ---- 凭据生命周期（2026-10-17 第一阶段收口）----
    'testChangingHostDoesNotReuseTheOldCredential',
    'testChangingPortDoesNotReuseTheOldCredential',
    'testChangingUsernameDoesNotReuseTheOldCredential',
    'testIdentityFingerprintFollowsAllThreeFields',
    'testLegacyPlainValueNeverSatisfiesAnIdentity',
    'testTurningRememberPasswordOffDeletesTheCredential',
    'testRemovingASourceCleansUpEvenWhenItWasNotRemembered',
    'testMigrationFailureKeepsThePlaintext',
    'testVerifiedMigrationRemovesThePlaintext',
    'testPlaintextSurvivesUntilItWasVerified',
    'testGUIAppInstallsTheKeychainBackend',
    'testGUIAppDoesNotFallBackToTheFileBackend',
    'testGUIAppPassesThePlaintextSourceSoMigrationCanRead',
    'testMigrationRunsAtLaunch',
    'testKeychainStoreFallsBackWhenTheEntitlementIsMissing',
    'testSavesCarryTheIdentity',
    # ---- 2026-10-17 第二阶段开局：摘要算法与旧键清理 ----
    'testIdentityFingerprintIsSHA256OverTheCanonicalForm',
    'testIdentityFingerprintIsA64CharacterLowercaseHexDigest',
    'testLegacyCopyIsRemovedOnceTheNewKeyHoldsThePassword',
    'testLegacyCleanupRefusesToDeleteWhenBothKeysAreTheSame',
    'testLegacyCleanupIsANoOpWithoutALegacyKey',
    'testLegacyCleanupDoesNotReadTheBackend',
    'testLegacyCleanupIsWiredOnlyAfterALoginSucceeded',
    # ---- 经典 → DP 钥匙串升迁 ----
    'testKeychainStoreCanBePinnedToATier',
    'testTierMigrationMovesTheValueAndDropsTheClassicCopy',
    'testTierMigrationKeepsTheClassicCopyWhenTheDPCopyFailed',
    'testTierMigrationSkipsAccountsThatAreNotOnClassic',
    'testTierMigrationAbortsWhenTheEntitlementIsMissing',
    'testTierMigrationIsASkipWhenTheBackendIsNotKeychain',
    'testTierMigrationIsRegisteredOnTheLaunchPath',
    # ---- 2026-10-17 第二阶段：工作区路径 / 已下线品牌不下发 ----
    'testDevelopmentStateDirectoryStaysInsideTheBuildDirectory',
    'testAdapterStatusKeepsRetiredSeparateFromNeverPorted',
    'testRetiredVendorMessageDoesNotSoundLikeWorkInProgress',
     'testFnOSBlockerSaysRetiredNotWorkInProgress',
     # ---- 2026-10-17 §2.6 Preview/Fixture 的 Release 隔离 ----
     'testPreviewEvidenceFacilitiesAreExcludedFromReleaseBuilds',
    # ---- clean clone 下不许产出缺 NAS 运行时的 App（2026-10-17）----
    'testBuildScriptRefusesToProduceAppWithoutNASRuntime',
}

# Dart 侧的期望：这些套件在对应变异下必须失败。
EXPECTED_DART = {'test_search_readiness'}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main() -> int:
    before = {k: sha(p) for k, p in FILES.items()}
    backup = Path(tempfile.mkdtemp(prefix='ff-red-proof-'))
    try:
        for k, p in FILES.items():
            shutil.copy2(p, backup / k)

        for _, path, old, new in MUTATIONS:
            text = path.read_text(encoding='utf-8')
            if old not in text:
                print(f'FAIL 变异标记没找到：{path.name}: {old[:50]}')
                return 1
            path.write_text(text.replace(old, new, 1), encoding='utf-8')
        print(f'{len(MUTATIONS)} 处变异已应用')

        result = subprocess.run(['swift', 'test'], cwd=CLIENT, capture_output=True, text=True)
        output = result.stdout + result.stderr
        # 失败行形如：
        # Test Case '-[FlashFindCoreTests.AppLayerStructureTests testXxx]' failed (0.17 seconds).
        failed = set()
        for line in output.splitlines():
            if "]' failed (" not in line:
                continue
            inner = line.split("'", 2)[1]           # -[Class testName]
            name = inner.rsplit(' ', 1)[-1].rstrip(']')
            failed.add(name)
        hit = sorted(f for f in failed if f in EXPECTED)
        print(f'变红的测试（{len(hit)}/{len(EXPECTED)}）：')
        for name in hit:
            print('  RED', name)
        missing = sorted(EXPECTED - failed)
        if missing:
            print('没有变红的（测试抓不到对应回归，失败）：')
            for name in missing:
                print('  MISS', name)
            return 1

        # ── Dart 侧：核心逻辑（含 2026-10-16 就绪判据修复）只能靠它抓。
        # 各套件的「失败」判据不同（❌ 前缀 / 非零退出），统一按「有没有失败痕迹」判。
        if not DART_SDK.is_file():
            print(f'跳过 Dart 红证：找不到 SDK（{DART_SDK}）')
            return 0
        dart_failed = set()
        for suite in DART_SUITES:
            r = subprocess.run([str(DART_SDK), '--disable-dart-dev', 'run', f'{suite}.dart'],
                               cwd=DART_DIR, capture_output=True, text=True, timeout=600)
            out = r.stdout + r.stderr
            broke = ('\u274c' in out) or ('失败' in out and '失败 0' not in out) or r.returncode != 0
            print(f'  Dart {suite}: {"RED（如预期变红）" if broke else "green"}')
            if broke:
                dart_failed.add(suite)
        dart_hit = sorted(dart_failed & EXPECTED_DART)
        print(f'Dart 变红的套件（{len(dart_hit)}/{len(EXPECTED_DART)}）：')
        for name in dart_hit:
            print('  RED', name)
        dart_missing = sorted(EXPECTED_DART - dart_failed)
        if dart_missing:
            print('Dart 没有变红的（失败）：')
            for name in dart_missing:
                print('  MISS', name)
            return 1
        return 0
    finally:
        for k, p in FILES.items():
            shutil.copy2(backup / k, p)
        shutil.rmtree(backup, ignore_errors=True)
        same = all(sha(p) == before[k] for k, p in FILES.items())
        print('还原后 SHA-256 逐字节一致：', same)
        if not same:
            return 1


if __name__ == '__main__':
    sys.exit(main())

