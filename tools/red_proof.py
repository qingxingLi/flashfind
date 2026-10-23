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
- 十处锁 2026-10-20 Phase 5.5 SDK 装配层：stdout 只有协议、tools/list 出自 ToolCatalog、
  入参与错误码原样、权限每请求重算、协议版本来自 SDK、占位执行端不许假装成功
- 四处锁 2026-10-17 §3.6 设置导航收敛：页面集合必须遍历 Core、导航用系统分段控件、
  内容区限宽、窗口宽度跟着收窄
- ★ 锚点纪律：`text.replace(old, new, 1)` 只改第一处。同一份文件里有多个同名样式时
  （如 `.pickerStyle(.segmented)` 同时被导航和外观用），锚点必须带上**只属于目标**的相邻行，
  否则先出现的那一处会被改掉，目标没动，红证就假绿了。
"""
import hashlib
import re
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
    'LastWindowClosePolicy': CLIENT / 'Sources/FlashFindCore/LastWindowClosePolicy.swift',
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
    'SearchCoordinator': CLIENT / 'Sources/FlashFindCore/SearchCoordinator.swift',
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
    # 6.3b-4 起 MCP 执行侧也要套本机搜索范围，这一分区成了装配点之一。
    'AppModelAIAccess': CLIENT / 'Sources/FlashFind2App/AppModel+AIAccess.swift',
    'MCPAuthority': CLIENT / 'Sources/FlashFind2App/MCPAuthority.swift',
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
    'UpdateCheck': CLIENT / 'Sources/FlashFindCore/UpdateCheck.swift',
    'AppModelUpdateCheck': CLIENT / 'Sources/FlashFind2App/AppModel+UpdateCheck.swift',
    'PreviewInteractionValidation': CLIENT / 'Sources/FlashFind2App/DebugSupport/PreviewInteractionValidation.swift',
    # Phase 3（2026-10-20）：搜索会话隔离的两个实现文件。
    'SearchScheduler': CLIENT / 'Sources/FlashFindCore/SearchScheduler.swift',
    'SearchProvider': CLIENT / 'Sources/FlashFindCore/SearchProvider.swift',
    # Phase 4（2026-10-20）：AI 访问的权限判定与设置状态。
    'PermissionPolicy': CLIENT / 'Sources/FlashFindCore/PermissionPolicy.swift',
    'AIAccessSettings': CLIENT / 'Sources/FlashFindCore/AIAccessSettings.swift',
    # 9-lite：AI 页上「助手状态」「历史」两行的文案与判定。
    'AISettingsStatus': CLIENT / 'Sources/FlashFindCore/MCP/AISettingsStatus.swift',
    'MCPIntegrationPrompt': CLIENT / 'Sources/FlashFindCore/MCP/MCPIntegrationPrompt.swift',
    'SettingsPane': CLIENT / 'Sources/FlashFindCore/SettingsPane.swift',
    # Phase 10：Helper 的身份与打包顺序。前者是链接期嵌进 Mach-O 的那份 plist
    # （改一个字符，发布出去的 Helper 就报错版本），后者是签名的先后。
    'HelperInfo': CLIENT / 'Resources/Packaging/HelperInfo.plist',
    # Phase 11-lite：客户端 capability 兼容清洗（纯规则 + 传输层包装）。
    'ClientSanitizer': CLIENT / 'Sources/FlashFindCore/MCP/ClientCapabilitySanitizer.swift',
    'SanitizingTransport': CLIENT / 'Sources/FlashFindCore/MCP/SanitizingTransport.swift',
    'BuildTrial': CLIENT / 'scripts/build_trial.py',
    # Phase 5（2026-10-20）：Tool 定义（不 import MCP，所以工具链阻塞也挡不住它）。
    'ToolSchema': CLIENT / 'Sources/FlashFindCore/ToolSchema.swift',
    'ToolRouter': CLIENT / 'Sources/FlashFindCore/ToolRouter.swift',
    # Phase 5.5（2026-10-20）：SDK 装配层与可执行文件。★ 这两个文件是**新的一类**
    # 变异目标：一个在 Core 里（可测），一个在 executableTarget 里（只能扫源码）。
    'MCPHandler': CLIENT / 'Sources/FlashFindCore/MCP/MCPHandler.swift',
    # Phase 6.1（2026-10-20）：IPC 传输层。
    'AuthorityWire': CLIENT / 'Sources/FlashFindCore/MCP/AuthorityWire.swift',
    'UnixSocket': CLIENT / 'Sources/FlashFindCore/MCP/UnixSocket.swift',
    'AuthorityListener': CLIENT / 'Sources/FlashFindCore/MCP/AuthorityListener.swift',
    'AuthorityLinkSocket': CLIENT / 'Sources/FlashFindCore/MCP/UnixSocketAuthorityLink.swift',
    'AuthorityLink': CLIENT / 'Sources/FlashFindCore/MCP/AuthorityLink.swift',
    'MCPMain': CLIENT / 'Sources/FlashFindMCP/main.swift',
    # Phase 6.2（2026-10-20）：权限判定收回 App authority（v0.18 的 B 方案）。
    'RoutingAuthorityService': CLIENT / 'Sources/FlashFindCore/MCP/RoutingAuthorityService.swift',
    'PackageManifest': CLIENT / 'Package.swift',
    # Phase 6.3b-0（2026-10-20）：四处 preflight。
    'AuthorizedSourceSnapshot': CLIENT / 'Sources/FlashFindCore/MCP/AuthorizedSourceSnapshot.swift',
    'Models': CLIENT / 'Sources/FlashFindCore/Models.swift',
    'MCPOwner': CLIENT / 'Sources/FlashFindCore/MCP/MCPOwner.swift',
    # Phase 6.3b-1（2026-10-21）：locate 真执行。
    'LocateExecution': CLIENT / 'Sources/FlashFindCore/MCP/LocateExecution.swift',
    # 6.4a 起叫 LocateRanker：它在 `SearchResultRanker` 之上组合 locate 独有信号。
    'LocateRanker': CLIENT / 'Sources/FlashFindCore/MCP/LocateRanker.swift',
    'SourceExecutionHandle': CLIENT / 'Sources/FlashFindCore/MCP/SourceExecutionHandle.swift',
    # Phase 6.4a（2026-10-21）：`search` 与 `locate_many` 的返回结构。
    'SearchResponse': CLIENT / 'Sources/FlashFindCore/MCP/SearchResponse.swift',
    'LocateManyResponse': CLIENT / 'Sources/FlashFindCore/MCP/LocateManyResponse.swift',
    # Phase 6.4b-0（2026-10-21）：`file_id → 来源 + 路径` 的三列映射表。
    'FileReferenceStore': CLIENT / 'Sources/FlashFindCore/MCP/FileReferenceStore.swift',
    # Phase 6.4b-1（2026-10-21）：get_metadata 的执行链、返回结构与两个 provider 的直查实现。
    'MetadataExecutor': CLIENT / 'Sources/FlashFindCore/MCP/MetadataExecutor.swift',
    'MetadataResponse': CLIENT / 'Sources/FlashFindCore/MCP/MetadataResponse.swift',
    'PathMetadata': CLIENT / 'Sources/FlashFindCore/MCP/PathMetadata.swift',
    'ProviderMetadata': CLIENT / 'Sources/FlashFindCore/ProviderMetadata.swift',
    # build 29（2026-10-23）：本机读范围闸门（代码审核 BUG-112-01）。
    'LocalReadScope': CLIENT / 'Sources/FlashFindCore/LocalReadScope.swift',
    # `SearchScheduler` / `MCPOwner` / `Models` 在上面已有键，这里不重复定义
    # （重复的字典键会被后一条静默覆盖，看着像两个文件其实只有一个）。
    # Phase 6.3a（2026-10-20）：三个契约——FileID / owner / locate 返回结构。
    'FileID': CLIENT / 'Sources/FlashFindCore/FileID.swift',
    'LocateResponse': CLIENT / 'Sources/FlashFindCore/MCP/LocateResponse.swift',
    # Phase 7a / 7b（2026-10-21）：History 的身份标签与落库。
    'HistoryContext': CLIENT / 'Sources/FlashFindCore/MCP/HistoryContext.swift',
    'HistoryStore': CLIENT / 'Sources/FlashFindCore/MCP/HistoryStore.swift',
    'HistorySink': CLIENT / 'Sources/FlashFindCore/MCP/HistorySink.swift',
    # Phase 7d（2026-10-21）：`recent` 的执行。
    'RecentExecution': CLIENT / 'Sources/FlashFindCore/MCP/RecentExecution.swift',
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
               'test_admin_identity', 'test_adapter_failure_reporting',
               'test_share_contract']
DART_DIR = CLIENT / 'MyNASCore'

# Helper 当前的构建号。**从 Info.plist 现读，不写死**：
# 写死的话每次发版升构建号，㊿₈₆ 那条变异的锚点就悄悄失效
# （`replace` 找不到原文 → 变异没应用 → 记成假 MISS）。
# 2026-10-22 从 23 升到 24 时踩过一次。
def _plist_build_number() -> str:
    import re as _re
    text = FILES['HelperInfo'].read_text(encoding='utf-8')
    m = _re.search(r'<key>CFBundleVersion</key>\s*<string>([^<]*)</string>', text)
    return m.group(1) if m else ''


HELPER_BUILD = _plist_build_number()


# Helper 当前的短版本号。同样**从 plist 现读，不写死**。
# ★ 2026-10-23 升 1.1.2→1.1.3 时，㊿₈₅ 的锚点还写着 `1.1.2`，批跑直接
#   `FAIL 变异标记没找到`——因为源文件里已经没有那个串了。和构建号那次是同一个坑，
#   所以这里连「退一格」都现算，不留任何随发版变化的字面量。
def _plist_short_version() -> str:
    import re as _re
    text = FILES['HelperInfo'].read_text(encoding='utf-8')
    m = _re.search(r'<key>CFBundleShortVersionString</key>\s*<string>([^<]*)</string>', text)
    return m.group(1) if m else ''


def _previous_patch(_version: str) -> str:
    """把最后一段减一（1.1.3 → 1.1.2），用来模拟「派生副本忘了跟版本」。"""
    head, _, patch = _version.rpartition('.')
    if not head or not patch.isdigit():
        raise SystemExit(f'版本号形状不认识，无法算出「上一格」：{_version!r}')
    return f'{head}.{int(patch) - 1}'


HELPER_SHORT_VERSION = _plist_short_version()
HELPER_PREVIOUS_VERSION = _previous_patch(HELPER_SHORT_VERSION)

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
            //   实测 DS1621+：.88 只有 Synology 自述（序列号 FAKE000000001、MAC），
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
    # ---- OTP 输入框打不开（2026-10-22，用户报「详情界面不弹 OTP」）----
    #
    # 这一条换过三版：折叠区打不开 → 模型持开关自动展开（还得回表单再点连接）
    # → **弹窗式**（现在，与详情页「重新登录…」共用同一扇窗）。
    # Core 能锁的是「取消之后那句提示指哪儿、说没说清填什么」。
    ('取消弹窗后那句提示不指「连接」按钮', FILES['ConnectionFailureText'],
     '再点一次「连接」会重新弹出动态码输入框',
     '再点一次会重新弹出动态码输入框'),
    ('取消弹窗后那句提示不说填几位', FILES['ConnectionFailureText'],
     '填上手机验证器或短信中的 6 位数字即可。',
     '填上手机验证器或短信中的验证码即可。'),
    # ---- 全部登录路径统一弹窗（2026-10-22 用户要求「改成 OTP 弹窗的形式」）----
    #
    # App 层测不到（executableTarget），所以锁的是源码结构：
    # 「判定成立就必须弹窗」与「拿到码必须自己接着连」这两条各有一条结构测试守着。
    # ★ ⑧ 结构断言的 body 截取要防「吞进同符号的定义行」：测试按 `\n    func `
    #   截 finishFailedAttempt 的 body，吞不下下一行 `    private func …`
    #   的定义，只断言符号名时**定义行本身就把它满足了**——调用点删没删测试都绿
    #   （2026-10-22 批跑 MISS，靠单条变异复现定位）。断言必须锁调用点专属形态。
    ('向导 OTP 失败只写状态不弹窗', FILES['WizardController'],
     '            promptForOTPThenReconnect(sourceName: config.displayName)',
     '            otpFailureStatus = prefix + reason'),
    ('弹窗拿到码不自动续连', FILES['WizardController'],
     '            self.nativeNASOTP = code\n            self.connectDraft()',
     '            self.nativeNASOTP = code'),
    ('向导自己再造一个 OTP 弹窗', FILES['WizardController'],
     'guard let code = self.otpPrompter?(sourceName), !code.isEmpty else {',
     'guard let code = "" as String?, !code.isEmpty else {'),
    # ---- 关掉最后一个窗口 = 闪退（2026-10-22，用户报「OTP 账号点登录后闪退」）----
    #
    # 真因不是崩溃：日志里是 `SearchPanel finishing close` 之后紧跟
    # `termination reported by launchd (0, 0, 0)` —— 进程以 0 正常退出，
    # 所以**没有任何崩溃报告**。两条变异分别锁「该不该放回浮窗」与
    # 「自动终止的禁用理由不能是空的」。
    ('关窗后判定反了：有窗口才放回浮窗', FILES['LastWindowClosePolicy'],
     '        !hasOtherVisibleWindow\n',
     '        hasOtherVisibleWindow\n'),
    ('禁用自动终止的理由写成空串', FILES['LastWindowClosePolicy'],
     '        "闪寻常驻：窗口全部关闭后靠全局快捷键唤起，不应被系统回收"',
     '        ""'),
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
    # 6.3b-4 起这一对赋值搬进 `applyLocalScopeToProvider`（GUI 与 MCP 共用一处）。
    ('App 不把搜索方式交给 provider', FILES['AppModelAIAccess'],
     '        localProvider.mode = localSearchMode\n', ''),
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
     r'        return NASSourceConfig.Vendor.allCases.filter(\.hasAdapter)',
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
    # ---- 2026-10-19 CI 首红复盘：取消之后才到的批次被放行 ----
    # 取消把 queryID 置空，事件守卫里的 `self.queryID==id` 就是「这次查询还算数吗」的闸门。
    # 去掉它，界面上会先显示结果、随后被一次取消的搜索覆盖。
    #
    # ★ 这条标记 2026-10-20 修过一次：Phase 3 把 SearchCoordinator.run() 里的闭包
    #   从两层缩进改成了一层，标记里的 28 空格没跟着改，于是脚本在「应用变异」阶段
    #   就 `FAIL 变异标记没找到` 退出——**一条测试都没跑**。而当时的记录只看了
    #   「137 变异」这一行，没有校验退出码，把「没跑起来」当成了「跑绿了」。
    #   改标记时务必同步断言：脚本退出码必须是 0。
    ('取消后仍把迟到批次送到界面', FILES['SearchCoordinator'],
     '                guard let self, self.queryID == id, event.queryID == id else { return }',
     '                guard let self, event.queryID == id else { return }'),
    # ---- 2026-10-19 设置-高级：检查更新 ----
    # 版本号按字符串比：`1.0.10` 会判成比 `1.0.9` 旧，第 10 个补丁版发布后
    # 所有用户都被告知「已是最新」。
    ('版本号按字符串比较', FILES['UpdateCheck'],
     '            if left != right { return left > right }',
     '            if left != right { return String(left) > String(right) }'),
    # 缺的段不按 0 补：`1.0.0` 会被判成比 `1.0` 新。
    ('缺位版本段用 -1 补', FILES['UpdateCheck'],
     '            let right = index < b.count ? b[index] : 0',
     '            let right = index < b.count ? b[index] : -1'),
    # 同号预发布当正式：用户手上的 1.0.1 会被提示升级到 1.0.1-beta。
    ('同号预发布版算作新版本', FILES['UpdateCheck'],
     '        return isPrerelease(current) && !isPrerelease(candidate)',
     '        return false'),
    # 开发构建也去查：比不了还发请求，结论没人看得懂。
    ('开发构建照样去请求 GitHub', FILES['UpdateCheck'],
     '        guard isComparable(current) else { return .incomparable(current: current) }',
     '        guard isComparable(current) else { return .upToDate(current: current) }'),
    # 不看状态码：403/404 的返回体也被当版本号解析。
    ('不检查 HTTP 状态码', FILES['UpdateCheck'],
     '            guard http.statusCode == 200 else { throw Failure.httpStatus(http.statusCode) }',
     '            guard http.statusCode != 0 else { throw Failure.httpStatus(http.statusCode) }'),
    # 不带 User-Agent：GitHub 直接 403，表现为「永远查不了」。
    ('请求不带 User-Agent', FILES['UpdateCheck'],
     '        request.setValue("FlashFind/" + current, forHTTPHeaderField: "User-Agent")',
     '        request.setValue(nil, forHTTPHeaderField: "User-Agent")'),
    # 失败的说法糊成一句：限流与断网分不出来。
    ('失败文案退化成只有原因', FILES['UpdateCheck'],
     '        case .failed(let reason):\n            return "检查失败：\\(reason)"',
     '        case .failed(let reason):\n            return reason'),
    # 按钮接了空动作：界面还在，点了什么都不发生。
    ('检查更新按钮没有接上动作', FILES['SettingsView'],
     '                            model.checkForUpdates()',
     '                            model.status = ""'),
    # ---- 2026-10-20 Phase 3：搜索会话隔离（方案 §1.6）----
    # MCP 也自动取代前一条：locate_many 展开的 5 条同 session 子查询会互相取消，
    # 结果只剩最后一条。这是「加了 MCP 之后偶发搜不到」的典型成因。
    ('MCP 也自动取代前一条', FILES['SearchScheduler'],
     'let supersede = supersedePrevious ?? owner.isUserInteractive',
     'let supersede = supersedePrevious ?? true'),
    # GUI 插队退化成排队尾：用户输入要先等两个 Agent 排队项跑完，
    # 体感是「打字没反应」。注意插队**不等于**抢占，active 仍不能被取消。
    ('GUI 插队退化成分段排队尾', FILES['SearchScheduler'],
     'queues[sid, default: []].insert(entry, at: 0)',
     'queues[sid, default: []].append(entry)'),
    # 排队永不超时：慢 NAS 上排队项无限堆积，调用方也永远拿不到终态。
    ('排队项永不超时', FILES['SearchScheduler'],
     'guard entry.deadline <= t else { kept.append(entry); continue }',
     'guard entry.deadline > t else { kept.append(entry); continue }'),
    # 带 owner 的入口从「协议要求」退回「仅 extension 方法」：
    # 通过 any SearchProvider 调用时走静态派发，provider 里的 owner 判断全部失效，
    # 而编译期毫无提示——这是 Swift 里最隐蔽的一类「改了但没生效」。
    ('owner 入口退回静态派发', FILES['SearchProvider'],
     '    func search(_ text: String, queryID: UUID, owner: SearchOwner,\n                emit: @escaping @MainActor (ProviderEvent) -> Void) async\n',
     ''),
    # ---- 2026-10-20 Phase 3 第二轮：调度器状态机补洞（v0.7）----
    # 这 8 条不是人工编的「可能写错」，每一条都对应 v0.6 里**真实存在过**的写法。
    # 共同点：全都只在状态**组合**处出事，所以 14 条 happy-path 用例全绿也照样漏。
    #
    # ① 取代时直接把槽位丢掉，不经过 cancelling：
    #    running 清空 + queue 非空 → 无人 drain；旧查询返回时 finished 的守卫又直接 return。
    #    结果这个来源永久卡死（新 GUI 与排队的 MCP 都永远不跑）。
    ('取代时直接丢弃槽位导致来源卡死', FILES['SearchScheduler'],
     '                  entry.queryID != queryID else { continue }\n'
     '            running[sid] = nil\n'
     '            cancelling[sid] = entry\n'
     '            entry.provider.cancel(queryID: entry.queryID)',
     '                  entry.queryID != queryID else { continue }\n'
     '            running[sid] = nil\n'
     '            entry.provider.cancel(queryID: entry.queryID)'),
    # ② 被取代的排队项从数组里直接删掉、不发终态：
    #    调用方永远停在 pending（界面一直转圈），而且没有任何报错。
    ('被取代的排队项静默消失没有终态', FILES['SearchScheduler'],
     '                guard entry.owner == owner, entry.queryID != queryID else {\n'
     '                    kept.append(entry); continue\n'
     '                }\n'
     '                emitTerminal(entry, state: .cancelled)',
     '                guard entry.owner == owner, entry.queryID != queryID else {\n'
     '                    kept.append(entry); continue\n'
     '                }'),
    # ③ cancelAll 恢复旧顺序（先取消在跑的 + drain，再清队列）：
    #    队首往往就是同一个 owner 的排队项，于是「要求全取消」反而把它启动了。
    ('cancelAll 先 drain 再清队列反向启动排队项', FILES['SearchScheduler'],
     '        // ① 先清排队项，逐条发终态。\n'
     '        for sid in Array(queues.keys) {\n'
     '            guard let queued = queues[sid] else { continue }\n'
     '            var kept: [Entry] = []\n'
     '            for entry in queued {\n'
     '                guard entry.owner == owner else { kept.append(entry); continue }\n'
     '                emitTerminal(entry, state: .cancelled)\n'
     '            }\n'
     '            queues[sid] = kept.isEmpty ? nil : kept\n'
     '        }\n'
     '\n'
     '        // ② 再请求取消在跑的。\n'
     '        for sid in Array(running.keys) {\n'
     '            guard let entry = running[sid], entry.owner == owner else { continue }\n'
     '            running[sid] = nil\n'
     '            cancelling[sid] = entry\n'
     '            entry.provider.cancel(queryID: entry.queryID)\n'
     '        }',
     '        for sid in Array(running.keys) where running[sid]?.owner == owner {\n'
     '            guard let entry = running[sid] else { continue }\n'
     '            entry.provider.cancel(queryID: entry.queryID)\n'
     '            running[sid] = nil\n'
     '            drain(sid)\n'
     '        }\n'
     '        for sid in Array(queues.keys) {\n'
     '            guard let queued = queues[sid] else { continue }\n'
     '            let kept = queued.filter { $0.owner != owner }\n'
     '            queues[sid] = kept.isEmpty ? nil : kept\n'
     '        }'),
    # ④ 取消时直接释放槽位：旧 search 还在退出，新查询已经压进同一个 provider
    #    ——「同来源一次最多一个请求」当场被破坏。
    ('取消时立刻释放槽位', FILES['SearchScheduler'],
     '            running[sid] = nil\n'
     '            cancelling[sid] = entry\n'
     '            entry.provider.cancel(queryID: queryID)',
     '            running[sid] = nil\n'
     '            entry.provider.cancel(queryID: queryID)'),
    # ⑤ 跨 owner 取消不校验（在跑的 + 排队的各一处）：
    #    owner 隔离退化成一句注释，任何拿到别人 queryID 的 Agent 都能取消 GUI。
    ('跨 owner 取消在跑项不校验', FILES['SearchScheduler'],
     '            guard entry.owner == requester else {\n'
     '                reject(requester: requester, target: entry)\n'
     '                continue\n'
     '            }\n',
     ''),
    ('跨 owner 取消排队项不校验', FILES['SearchScheduler'],
     '                guard entry.owner == requester else {\n'
     '                    reject(requester: requester, target: entry)\n'
     '                    kept.append(entry)          // 跨 owner 的项原样留在队列里\n'
     '                    continue\n'
     '                }\n',
     ''),
    # ⑥ 复活 lastQuery（属性 + 无条件广播取消）：
    #    已完成 / 从未发出的查询都会被再取消一遍，而 provider.cancel 不幂等。
    ('复活 lastQuery 的记账属性', FILES['SearchScheduler'],
     '    /// 每个来源的等待队列。**键是 source_id**，见类型注释规则 2。\n'
     '    private var queues: [String: [Entry]] = [:]',
     '    /// 每个来源的等待队列。**键是 source_id**，见类型注释规则 2。\n'
     '    private var queues: [String: [Entry]] = [:]\n'
     '    private var lastQuery: [SearchOwner: UUID] = [:]'),
    # ★ 锚点故意避开 `let supersede = ...` 那一行：上面的「MCP 也自动取代」变异
    #   会先把那一行改成 `?? true`，用同一行当标记就永远找不到了（顺序敏感）。
    ('复活 lastQuery 的无条件广播取消', FILES['SearchScheduler'],
     '        if supersede {\n'
     '            // 取代是**跨来源**的',
     '        if supersede, let previous = lastQuery[owner], previous != queryID {\n'
     '            for provider in providers { provider.cancel(queryID: previous) }\n'
     '        }\n'
     '        lastQuery[owner] = queryID\n'
     '        if supersede {\n'
     '            // 取代是**跨来源**的'),
    # ---- 2026-10-20 第三轮：Provider 终态契约（v0.8，方案 §1.6.5）----
    # ⑦ 终态判据收窄成「只有成功才算结束」：取消/失败/超时都不再是终态，
    #    上层 SearchCompletionTracker 于是永远等不到它们 → 界面永久「正在搜索」。
    ('终态判据只认 completed', FILES['SearchProvider'],
     '    public var isTerminal: Bool { !isMetadataUpdate && state != .searching }',
     '    public var isTerminal: Bool { !isMetadataUpdate && state == .completed }'),
    # ⑧ 取消不补发终态（本机）：cancel 只清状态就返回，调用方永远收不到 cancelled。
    ('本机取消不补发终态', FILES['LocalSearchProvider'],
     '        emit?(ProviderEvent(queryID: queryID, sourceID: source.id, state: .cancelled))\n',
     ''),
    # ⑨ 取消不补发终态（NAS）：同上，设备侧命令照发，但上层看不见这次结束。
    ('NAS 取消不补发终态', FILES['NASSearchProvider'],
     '        if !alreadyTerminal, let emit = activeEmit, activeEmitQueryID == queryID {\n'
     '            emit(ProviderEvent(queryID: queryID, sourceID: source.id, state: .cancelled))\n'
     '        }\n',
     ''),
    # ⑩ 把「结果不全」丢掉：核心说没收集全，事件却报完整。
    #    以前这类信息塞在 isComplete 里，拆成 resultsIncomplete 后必须有人守住。
    ('终态丢弃不完整信息', FILES['NASSearchProvider'],
     '                               message: failureMessage(state: state, kind: error, apiCode: apiCode, reason: reason)\n'
     '                                        ?? skippedNote(unparsed: unparsed, duplicates: duplicates),\n'
     '                               resultsIncomplete: terminalIncomplete,',
     '                               message: failureMessage(state: state, kind: error, apiCode: apiCode, reason: reason)\n'
     '                                        ?? skippedNote(unparsed: unparsed, duplicates: duplicates),\n'
     '                               resultsIncomplete: false,'),
    # ⑪ **搜索结束不摘占用的槽位**（2026-10-22 现场，Release Blocker 级）。
    #    只置终态不摘状态机，于是「占用」永远是上一次那个已经结束的查询：
    #    同一个 owner 看不出来（它走「取代」分支顺手清掉了），**换 owner 就必撞**——
    #    现场表现是「GUI 搜过一次之后 MCP 全废 / MCP 搜过一次之后 GUI 全废」，
    #    文案是「这个来源正在被另一个调用方搜索」，MCP 再把它折成 source_unavailable，
    #    看起来像「NAS 不可用」。
    #    ★ 只用这一条变异就能打红：源码里**没有**第二个兜底机制
    #      （曾加过 `!running.isTerminal` 守卫，它会掩盖这条变异 → 已撤掉；
    #      调度器的下一条是在 `search()` 返回之后用新 Task 启动的，不需要那个兜底）。
     ('搜索结束不摘槽位', FILES['NASSearchProvider'],
      '            if activeMachine === machine {\n                activeMachine = nil',
      '            if false {\n                activeMachine = nil'),

    # ---- 2026-10-20 Phase 4：权限判定（方案 §5.1 / §5.2）----
    # 这一层的失效方式全部是**静默放行**：没有崩溃、没有报错，只是把没授权的
    # 来源搜了。所以每条都要有一条用例盯着「不许放行」或「不许说出去」。

    # ① 总开关失效：关着也照样放行。
    ('总开关关着也放行', FILES['PermissionPolicy'],
     '        guard mcpEnabled else { return .deny(code: .mcpDisabled, message: switchOffMessage) }\n',
     ''),

    # ② `requested == nil` 被当成「全部来源」——最容易写错、也最致命的一处：
    #    有未授权来源时，这一行会把私人 NAS 一起搜了。
    ('未点名时当成搜全部来源', FILES['PermissionPolicy'],
     '        guard let requested else {\n'
     '            return .allow(sources: usable.sorted(), warnings: [])\n'
     '        }\n',
     '        guard let requested else {\n'
     '            return .allow(sources: existing.sorted(), warnings: [])\n'
     '        }\n'),

    # ③ 空数组被当成「没传」：一次参数错误静默变成一次范围更大的搜索。
    ('空数组退化成没传', FILES['PermissionPolicy'],
     '        guard !requested.isEmpty else { return .deny(code: .sourceDenied, message: nothingRequestedMessage) }\n',
     '        if requested.isEmpty { return .allow(sources: usable.sorted(), warnings: []) }\n'),

    # ④ 点名时不按 allowlist 过滤（只看「这个来源在不在」）：未授权来源直接可搜。
    #    ★ 锚点刻意避开 ⑤ 的那一行：两条变异先后应用，共用锚点会让后一条
    #    「标记没找到」，整批在应用阶段就 FAIL 退出（2026-10-20 真踩过）。
    ('点名时不看 allowlist', FILES['PermissionPolicy'],
     '            if usable.contains(id) {',
     '            if existing.contains(id) {'),

    # ⑤ 不按「是否还存在」过滤：删掉的 NAS 仍然出现在结果与 list_sources 里。
    ('已删除的来源照样返回', FILES['PermissionPolicy'],
     '        let usable = allowedSources.intersection(existing)\n',
     '        let usable = allowedSources\n'),

    # ⑥ warnings 用错码：把「没授权」说成「连不上」，Agent 会去让用户检查 NAS。
    ('部分失败用错错误码', FILES['PermissionPolicy'],
     r'                warnings.append("source_denied:\(id)")',
     r'                warnings.append("source_unavailable:\(id)")'),

    # ⑦ 拒绝信息里带上被点名的来源：名字/ID 进了 Agent 上下文，撤不回来。
    ('拒绝信息泄露来源 id', FILES['PermissionPolicy'],
     '        guard !granted.isEmpty else { return .deny(code: .sourceDenied, message: nothingUsableMessage) }',
     '        guard !granted.isEmpty else { return .deny(code: .sourceDenied, message: nothingUsableMessage + " " + requested.joined(separator: ",")) }'),

    # ⑧ 判定不再纯：自己去读偏好。撤销授权于是变成「重启后生效」。
    ('判定自己去读偏好', FILES['PermissionPolicy'],
     '    public static func decision(mcpEnabled: Bool,',
     '    static let cachedEnabled = UserDefaults.standard.bool(forKey: "ff2.aiAccess.enabled.v1")\n\n'
     '    public static func decision(mcpEnabled: Bool,'),

    # ⑨ 「开着但一个来源都没勾」也能保存：界面上的置灰就不是约束了。
    ('开着零来源也能保存', FILES['AIAccessSettings'],
     '    public var canSave: Bool { !isEnabled || !allowedSources.isEmpty }',
     '    public var canSave: Bool { true }'),

    # ⑩ 落盘不校验：把「开着但零来源」写成已保存状态。
    ('存储层不校验就落盘', FILES['AIAccessSettings'],
     '        guard settings.canSave else { return false }\n',
     ''),

    # ⑪ 读到自相矛盾的状态照原样返回：界面显示「已开启」，AI 却什么都搜不到。
    ('损坏状态照原样读出', FILES['AIAccessSettings'],
     '        return settings.canSave ? settings : .initial',
     '        return settings'),

    # ⑫ 保存时不剔除已删除的来源：授权里留着永远搜不到的 id。
    #    ★ 锚点只取 `allowedSources:` 这一行，不整块替换——下一行是 ⑬ 的锚点，
    #    整块替换会把 ⑬ 的标记一起改掉，整批在应用阶段 FAIL（2026-10-20 踩过）。
    ('保存不剔除已删除来源', FILES['AIAccessSettings'],
     '                                allowedSources: remaining)',
     '                                allowedSources: allowedSources)'),

    # ⑬ 剔空之后不关门：留下「开着但零来源」。界面显示 [开]，MCP 却全拒。
    ('剔空来源后仍保持开启', FILES['AIAccessSettings'],
     'isEnabled && !remaining.isEmpty',
     'isEnabled'),

    # ---- 2026-10-20 Phase 5.2：Tool 定义（方案 §4.1 / §4.3）----
    # 这一层写错不会有编译错误，只会在真实对话里表现为「Agent 传错参数」或
    # 「Agent 根本不用这个工具」，所以每条都要有一条用例盯着。

    # ⑭ 宽口径的那个被压成窄的：search 的上限退化成 locate 的量级。
    # ★ 锚点打在 LimitRange 的常量上，不打在 switch 分支上：
    #    Schema 里的 maximum 现在从常量派生，改 switch 不会影响 Schema，
    #    只改一处的话这条变异根本不会红（第一次跑就踩到了）。
    ('search 上限退化成 locate 的量级', FILES['ToolSchema'],
     '    public static let search = LimitRange(defaultValue: 10, maximum: 50)',
     '    public static let search = LimitRange(defaultValue: 10, maximum: 20)'),

    # ⑮ `limit <= 0` 被静默改成默认值：Agent 永远不知道自己传错了。
    ('非正 limit 静默用默认值', FILES['ToolSchema'],
     '        guard requested > 0 else { return .invalid }',
     '        guard requested > 0 else { return .applied(LimitApplication(applied: defaultValue, wasClamped: false)) }'),

    # ⑯ 超上限不报告截断：Agent 以为拿到的就是全部。
    ('超上限不报截断', FILES['ToolSchema'],
     '            return .applied(LimitApplication(applied: maximum, wasClamped: true))',
     '            return .applied(LimitApplication(applied: maximum, wasClamped: false))'),

    # ⑰ `kind` 多出一个取值：Agent 会传一个我们没实现的过滤条件。
    ('kind 多出一个未实现的取值', FILES['ToolSchema'],
     r'allowedValues: FileKind.allCases.map(\.rawValue)),',
     r'allowedValues: FileKind.allCases.map(\.rawValue) + ["any"]),'),

    # ⑱ 给 get_metadata 开一个 path 入参：路径穿越与「Agent 猜路径」都回来了。
    ('get_metadata 接受路径入参', FILES['ToolSchema'],
     '                ToolParameter(name: "file_id", kind: .string, isRequired: true,',
     '                ToolParameter(name: "path", kind: .string,\n'
     '                              summary: "Absolute path of the file."),\n'
     '                ToolParameter(name: "file_id", kind: .string, isRequired: true,'),

    # ---- 2026-10-20 Phase 5.3：ToolRouter（方案 §4.2 / §4.3 / §5.1）----
    # 这一层是「Agent 说了算」与「权限说了算」的接缝，每条变异都对应一种
    # 「看起来成功、实际越界或悄悄放宽」的故障。

    # ⑲ 未知工具落回第一个 schema：Agent 拼错工具名，结果搜了一次别的东西。
    ('未知工具落回第一个 schema', FILES['ToolRouter'],
     '        guard let schema = ToolCatalog.schema(named: tool) else {',
     '        guard let schema = ToolCatalog.schema(named: tool) ?? ToolCatalog.all.first else {'),

    # ⑳ 空白 query 被放过：搜索引擎收到空串等于全量返回，看起来还「成功」。
    ('空白 query 被放过', FILES['ToolRouter'],
     '        guard !trimmed.isEmpty else {\n'
     '            throw InvalidArgument(argument: "query", message: "query must not be empty.")',
     '        guard true else {\n'
     '            throw InvalidArgument(argument: "query", message: "query must not be empty.")'),

    # ㉑ `limit <= 0` 静默换成默认值：Agent 永远不知道自己传错了。
    ('Router 把非正 limit 换成默认值', FILES['ToolRouter'],
     '        case .invalid:\n'
     r'            throw InvalidArgument(argument: name, message: "\(name) must be greater than 0.")',
     '        case .invalid:\n'
     '            return LimitApplication(applied: range.defaultValue, wasClamped: false)'),

    # ㉒ 钳位后不报 truncated：Agent 以为拿到的就是全部。
    ('Router 钳位后不报截断', FILES['ToolRouter'],
     '        case .applied(let application):\n'
     '            return application',
     '        case .applied(let application):\n'
     '            return LimitApplication(applied: application.applied, wasClamped: false)'),

    # ㉓ ★ 没传 source_ids 变成空数组：语义从「搜 allowlist」塌成「拒绝」。
    #    反向塌陷（空数组→nil）也有一条（㉕）。两个方向都必须红。
    ('没传 source_ids 被当成空数组', FILES['ToolRouter'],
     '        guard let raw = arguments["source_ids"] else { return nil }',
     '        guard let raw = arguments["source_ids"] else { return [] }'),

    # ㉔ ★ 显式空数组降级成「没传」：一次参数错误静默放大成一次更大范围的搜索。
    ('空 source_ids 被当成没传', FILES['ToolRouter'],
     '        // 空数组原样交给权限层：它按「点了名但一个都没给」拒绝。\n'
     '        return trimmed',
     '        // 空数组原样交给权限层：它按「点了名但一个都没给」拒绝。\n'
     '        return trimmed.isEmpty ? nil : trimmed'),

    # ㉕ `null` 当成没传：权限参数上唯一不许走的方向（只许收紧，不许放宽）。
    ('null source_ids 被当成没传', FILES['ToolRouter'],
     '        guard case .stringArray(let values) = raw else {\n'
     '            throw InvalidArgument(argument: "source_ids",\n'
     '                                  message: "source_ids must be an array of source_id strings. "\n'
     '                                         + "Omit it to search every authorized source.")\n'
     '        }',
     '        guard case .stringArray(let values) = raw else { return nil }'),

    # ㉖ 未知参数被忽略：Agent 传一个 path 进来，我们当没看见照常搜。
    ('未知参数被静默忽略', FILES['ToolRouter'],
     r'        let declared = Set(schema.parameters.map(\.name))',
     r'        let declared = Set(schema.parameters.map(\.name)).union(arguments.providedNames)'),

    # ㉗ kind 不校验闭集：Agent 传 kind=pdf，我们当成「不过滤」而不是报错。
    ('kind 不校验闭集', FILES['ToolRouter'],
     '        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)\n'
     '        guard let kind = FileKind(rawValue: trimmed) else {',
     '        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)\n'
     '        let kind = FileKind(rawValue: trimmed) ?? .file\n'
     '        if false {'),

    # ㉘ file_id 不校验形状：Agent 编一个 id（或塞路径）变成一次 file_not_found。
    #
    # ★ v0.20 起这条变异**换了位置**：形状判定搬进 `FileID.parse` 之后，Router 里
    #   已经没有「校验 / 不校验」这个分支可删了（`FileID` 的 init 是 private，
    #   不经过 `parse` 造不出值）。所以「放宽校验」现在只能改 `parse` 自己，
    #   由 `file_id 不校验形状` 那一条承担（锚点已搬到 `FileID.parse`）。
    ('file_id 不校验形状', FILES['FileID'],
     '        guard value.hasPrefix(prefix), value.count == prefix.count + hexLength else { return nil }',
     '        guard value.hasPrefix(prefix) else { return nil }'),

    # ㉙ ★ 权限被绕过：deny 时用 allowlist 兜出一个 scope。这是整套权限模型的总闸。
    ('权限拒绝被绕过', FILES['ToolRouter'],
     '            guard let scope = AuthorizationScope(granting: decision) else {\n'
     '                if case .deny(let code, let message) = decision {\n'
     '                    return .failed(.permissionDenied(code: code, message: message))\n'
     '                }',
     '            guard let scope = AuthorizationScope(granting: decision)\n'
     '                    ?? AuthorizationScope(granting: .allow(sources: permission.allowedSources.sorted(),\n'
     '                                                           warnings: [])) else {\n'
     '                if case .deny(let code, let message) = decision {\n'
     '                    return .failed(.permissionDenied(code: code, message: message))\n'
     '                }'),

    # ㉚ within_days 的下界不生效（schema 说 >=1，实现放宽一档）。
    ('within_days 下界不生效', FILES['ToolRouter'],
     '        if let minimum = schema.parameter(named: name)?.minimum, value < minimum {',
     '        if let minimum = schema.parameter(named: name)?.minimum, value < minimum - 1 {'),

    # ㉛ 解析不了的时间戳静默变成「现在」：按时间过滤变成了没过滤。
    ('坏时间戳静默变成现在', FILES['ToolRouter'],
     '        let parsed = iso8601WithZone.date(from: trimmed) ?? iso8601WithZoneAndFraction.date(from: trimmed)',
     '        let parsed: Date? = iso8601WithZone.date(from: trimmed) ?? iso8601WithZoneAndFraction.date(from: trimmed) ?? Date()'),

    # ── Phase 5.5（2026-10-20）：SDK 装配层。十处，两条只能扫源码、八条能跑用例。──

    # ㉜ ★ 一句调试 `print` 写进 stdout：客户端解析失败，整个功能不可用，
    #    而且报错信息不会指向我们（§8.3）。只能靠结构测试抓。
    ('启动日志写进 stdout', FILES['MCPMain'],
     r'note("starting \(MCPHandler.serverName) \(MCPHandler.serverVersion) over stdio")',
     r'print("starting \(MCPHandler.serverName) \(MCPHandler.serverVersion) over stdio")'),

    # ㉝ tools/list 少给一个 Tool：schema 与实现分叉的经典形态。
    ('tools/list 少一个 Tool', FILES['MCPHandler'],
     'public static var tools: [MCP.Tool] { ToolCatalog.all.map(tool(from:)) }',
     'public static var tools: [MCP.Tool] { ToolCatalog.all.dropLast().map(tool(from:)) }'),

    # ㉞ 参数一个都不翻译：请求照发，但内容全丢。测「交出去的东西真的是从入参来的」。
    ('入参不翻译（全丢）', FILES['MCPHandler'],
     'arguments: Self.arguments(from: parameters.arguments),',
     'arguments: ToolArguments(),'),

    # ㉟ 错误码在适配层被抹平成 internal_error：Agent 再也分不清「该改参数」还是「该找用户」。
    ('错误码被抹平', FILES['MCPHandler'],
     'let body = Body(code: code, message: message, ok: false)',
     'let body = Body(code: "internal_error", message: message, ok: false)'),

    # ㊱ v0.18 撤回了 `facts`，这条变异换成它的当代形态：**判定不再读实时设置**，
    #    退化成「替 App 猜一个最安全的值」（6.1 的 `main.swift` 正是这么写的）。
    #    结果就是「开启/撤销都不生效」，而每个请求仍然返回一个看起来合法的答案。
    ('权限事实被写死为关闭', FILES['RoutingAuthorityService'],
     'mcpEnabled: currentSettings.isEnabled,',
     'mcpEnabled: false,'),

    # ㊲ 协议版本被手写进 Core：SDK 升级时必然滞后，而滞后的表现是「新客户端连不上」。
    ('协议版本被手写', FILES['MCPHandler'],
     '    public static let instructions =',
     '    public static let protocolVersion = "2025-11-25"\n    public static let instructions ='),

    # ㊳ limit 的上限不翻译：schema 上说没有上限，Router 却照样钳位——两个事实分叉。
    ('limit 上限没进 schema', FILES['MCPHandler'],
     'if let maximum = parameter.maximum { object["maximum"] = .int(maximum) }\n',
     ''),

    # ㊴ SDK 渗进 Router：这一层一旦认识 SDK，升级 SDK 就会把红证一起拖下水。
    ('SDK 渗进 Router', FILES['ToolRouter'],
     'import Foundation\n',
     'import Foundation\nimport MCP\n'),

    # ㊵ JSON-RPC 错误号进 Router：`unknown_tool` 与「未知方法」从此分不开（§4.2）。
    ('Router 说 JSON-RPC 错误号', FILES['ToolRouter'],
     "return \"Unknown tool '\\(name)'. Call tools/list to see the available tools.\"",
     "return \"Unknown tool '\\(name)' (-32601).\""),

    # ㊶ ★ 连不上执行端时假装成功：空结果会被 Agent 读成「搜过了，没有这个文件」。
    #    5.5 守的是占位执行端，6.1 起守的是真实的 socket 客户端（同一个不变量）。
    ('连不上执行端假装成功', FILES['AuthorityLinkSocket'],
     '        } catch let error as UnixSocketError where error.meansNobodyIsListening {\n'
     '            return .failure(.init(code: appUnavailableCode, message: appUnavailableMessage))',
     '        } catch let error as UnixSocketError where error.meansNobodyIsListening {\n'
     '            return .success(AuthorityWire.Response(id: request.id, ok: true, result: .object(["results": .array([])])))'),

    # ── Phase 6.1（2026-10-20）：Unix Socket 传输层。十三处，大部分只能靠真起 socket 的用例抓。──

    # ㊷ 目录权限从 0700 放宽到 0755：同机上别的账户能看见我们的 socket 文件。
    ('IPC 目录权限放宽', FILES['AuthorityListener'],
     '        guard chmod(directory, 0o700) == 0 else {',
     '        guard chmod(directory, 0o755) == 0 else {'),

    # ㊸ socket 从 0600 放宽到 0644：权限位是第一道，放宽了 `getpeereid` 就成了唯一一道。
    ('socket 权限放宽', FILES['AuthorityListener'],
     '        guard chmod(path, 0o600) == 0 else {',
     '        guard chmod(path, 0o644) == 0 else {'),

    # ㊹ ★ 启动时无条件抢 socket（v0.2 的错误写法）：第二个实例把第一个的路径删掉，
    #    两个都活着但第一个不可达——「唯一权威端」被静默破坏（§1.3.3.1）。
    ('第二个实例抢走 socket', FILES['AuthorityListener'],
     '            if UnixSocketAuthorityLink.ping(path: path, limits: limits) {\n'
     '                log("another instance owns the IPC socket")\n'
     '                return .ownedByAnotherInstance\n'
     '            }',
     '            log("another instance owns the IPC socket")'),

    # ㊺ 探活把「没拿到 pong」当成活着：stale socket 永远不会被接管，App 再也起不来 authority。
    ('探活失败也算活着', FILES['AuthorityLinkSocket'],
     '        guard case .success(let response) = roundTrip(AuthorityWire.pingRequest(), path: path, limits: probe) else {\n'
     '            return false\n'
     '        }',
     '        guard case .success(let response) = roundTrip(AuthorityWire.pingRequest(), path: path, limits: probe) else {\n'
     '            return true\n'
     '        }'),

    # ㊻ 请求上限不判：一个写错（或死循环）的客户端能把 App 内存拖上去（§1.3.4）。
    ('请求上限不生效', FILES['UnixSocket'],
     '            if buffer.count + count > maxBytes { throw UnixSocketError(.tooLarge) }',
     '            if false { throw UnixSocketError(.tooLarge) }'),

    # ㊼ 读空闲超时不生效：半死连接会把连接线程一直占着。
    #    ★ build 29 起 `readLine` 多了 `deadline` 参数，锚点跟着调整
    #      （服务端等请求这一处仍然是「连上却不说话就该掐」）。
    #    ★★ 只改 `idleTimeout` 是**零效应**（2026-10-23 批跑实测 MISS）：
    #      现在的实现里 `deadline` 也是拿 `readIdleTimeout` 算出来的，
    #      它照样会在 0.2 秒后把连接掐掉 ⇒ 变异必须两行一起改。
    ('读空闲超时不生效', FILES['AuthorityListener'],
     '                deadline: Date().addingTimeInterval(limits.readIdleTimeout),\n'
     '                idleTimeout: limits.readIdleTimeout)',
     '                deadline: Date().addingTimeInterval(3600),\n'
     '                idleTimeout: 3600)'),

    # ---- build 29（2026-10-23）：首帧预算与中途空闲分开（代码审核 BUG-112-02）。
    #
    # 下面三条都锚在 `readLine` 里同一行 `let wait = …` 上，所以批跑只能带一条。
    # 留在批跑的是**审核报告里那个原始故障**：首帧也被 `readIdleTimeout` 压住。
    # 另外两条进 `SINGLE_ONLY`（同一行上第二条变异会报「标记没找到」）。
    # ㊿₁₀₅ 首帧也等空闲超时：正常跑 5–8 秒的 `locate`/`search` 被客户端提前判超时，
    #      而 App 那边还在好好地算 —— 症状是「每个会话第一次调用必失败」。
    ('首帧也等读空闲超时', FILES['UnixSocket'],
     '            let wait = buffer.isEmpty ? remaining : min(idleTimeout, remaining)',
     '            let wait = min(idleTimeout, remaining)'),
    # ㊿₁₀₆ 中途停顿改用整段预算：回到一半卡住要拖到总预算才报错。
    ('中途停顿改用整段预算', FILES['UnixSocket'],
     '            let wait = buffer.isEmpty ? remaining : min(idleTimeout, remaining)',
     '            let wait = buffer.isEmpty ? remaining : remaining'),
    # ㊿₁₀₇ 每块都续命：分段慢速发送能把一次请求拖成任意长，总预算形同虚设。
    ('每块都续命不受总预算', FILES['UnixSocket'],
     '            let wait = buffer.isEmpty ? remaining : min(idleTimeout, remaining)',
     '            let wait = buffer.isEmpty ? remaining : idleTimeout'),
    # ㊿₁₀₈ 退回「先按事件取候选、再折叠」（BUG-112-03 的原形状）：
    #    一个文件刷 20 次就能占满预采样窗口，另一个文件被整个挤掉，还报 truncated=false。
    #
    # ★★ 这条**必须同时改两处**，只改一处是零效应（2026-10-23 实测推演）：
    #    · 只把 `recentDistinct` 换成 `recent`：上层翻页会一路取到「另一个文件」，
    #      最终仍回满 2 条 ⇒ 用例全绿；
    #    · 只掐掉翻页（`scanned == 0`）：SQL 的按文件收敛让第一页就含两个文件 ⇒ 同样全绿。
    #    真正的回归是**两件事同时退回**：limit 数的是事件条数，而且只取这一页。
    #    所以锚点从循环头一直包到调用点，替换体把两者一起写回去。
    #
    # ★★ 因此它顶掉的是 `recent 不看本次 scope`（㊿₂₂）的那段锚点（同一块代码），
    #    只能进 `SINGLE_ONLY`；对应用例 `testOneFileFloodingHistoryDoesNotEvictAnother`
    #    **不在** `EXPECTED` 里（批跑里它该是绿的），由逐条登记证红。
    ('recent 先限量再去重', FILES['RecentExecution'],
     '        while hits.count < target && scanned < scanBudget {\n'
     '            // 一页至少 8 条：够填满 limit 还留余量，又不必为一条结果来回跑。\n'
     '            let need = max(target - hits.count, 8)\n'
     '            let events: [AccessEvent]\n'
     '            do {\n'
     '                events = try history.recentDistinct(limit: need,\n'
     '                                                    sourceIDs: snapshot.ids,\n'
     '                                                    withinDays: withinDays,\n'
     '                                                    now: now,\n'
     '                                                    offset: offset)',
     '        while scanned == 0, hits.count < target {\n'
     '            let need = application.applied\n'
     '            let events: [AccessEvent]\n'
     '            do {\n'
     '                events = try history.recent(limit: need,\n'
     '                                            sourceIDs: snapshot.ids,\n'
     '                                            withinDays: withinDays,\n'
     '                                            now: now)'),
    # ★ 不给 `recentDistinct` 本身再配一条「GROUP BY 加上 id」的变异：
    #   那样做**零效应**——上层会翻页直到把不同文件取满，结果仍然正确
    #   （2026-10-23 推演：0 效应变异不给它登记，免得变成永久 MISS）。

    # ㊿₁₀₉ 阻塞往返回到协作线程池（2026-10-23 公开仓 CI 首跑的真实回归）：
    #    8 个并发在 3 核 runner 上 6 个 timeout。根因不是慢，是放置位置——
    #    `Task.detached` 跑在协作池上，池宽≈核心数且不允许阻塞；调用端把池占满，
    #    服务端自己的 `Task.detached { await service.handle }` 也在同一个池里，
    #    于是抢不到线程。本机 10 核恒绿，只有低核机器才看得出（症状是超时，不是崩溃）。
    ('阻塞往返占用协作线程池', FILES['AuthorityLinkSocket'],
     '        let path = self.path\n'
     '        let limits = self.limits\n'
     '        return await withCheckedContinuation { (continuation: CheckedContinuation<ToolOutcome, Never>) in\n'
     '            Self.ioQueue.async {\n'
     '                continuation.resume(returning: UnixSocketAuthorityLink.outcome(\n'
     '                    UnixSocketAuthorityLink.roundTrip(wire, path: path, limits: limits)))\n'
     '            }\n'
     '        }',
     '        return await Task.detached(priority: .userInitiated) { [path, limits] in\n'
     '            UnixSocketAuthorityLink.outcome(\n'
     '                UnixSocketAuthorityLink.roundTrip(wire, path: path, limits: limits))\n'
     '        }.value'),

    # ㊿₁₁₀ 承载阻塞往返的队列改成串行：不会超时（每个请求都很快），
    #    但把「并发」悄悄降级成「串行」——八个请求排一队，后到的只能等前面跑完。
    #    属于「没坏但退化了」那一类，靠结构断言守 `attributes: .concurrent`。
    ('阻塞往返队列改成串行', FILES['AuthorityLinkSocket'],
     '    private static let ioQueue = DispatchQueue(label: "flashfind.authority.link.io",\n'
     '                                               qos: .userInitiated,\n'
     '                                               attributes: .concurrent)',
     '    private static let ioQueue = DispatchQueue(label: "flashfind.authority.link.io",\n'
     '                                               qos: .userInitiated)'),

    # ㊽ 响应上限不判：4 MB 的正文直接发出去，客户端只能靠 alloc 撞墙。
    ('响应上限不生效', FILES['AuthorityListener'],
     '        if data.count > limits.maxResponseBytes {',
     '        if false {'),

    # ㊾ 单请求总预算不生效：一次卡住的搜索会让 Agent 一直等到客户端超时，
    #    而它拿不到 `timeout` 就不知道该重试还是该找用户。
    ('总预算不生效', FILES['AuthorityListener'],
     '        if semaphore.wait(timeout: .now() + limits.requestTimeout) == .timedOut {',
     '        if semaphore.wait(timeout: .now() + 60) == .timedOut {'),

    # ㊿ 响应不回原 id：同 UID 下并发两个 Helper 时，客户端认不出哪条回复是自己的。
    ('响应不回原 id', FILES['AuthorityListener'],
     '        respond(fd, response(for: run(job), id: request.id))',
     '        respond(fd, response(for: run(job), id: ""))'),

    # 51 ★ 6.2 的反向错误：App **相信**报文里的 `source_ids`，把它当成「已批准」。
    #    Agent（或任何同 UID 进程）只要点名一个未授权的来源 id，就拿到了那个来源。
    #    这条是 §5.2.2 的正面反例：授权永远不能由报文说了算。
    ('App 相信报文里的 source_ids', FILES['RoutingAuthorityService'],
     'allowedSources: currentSettings.allowedSources,',
     'allowedSources: currentSettings.allowedSources.union('
     r'Set((job.arguments["source_ids"]?.arrayValue ?? []).compactMap(\.stringValue))),'),

    # 52 `source_ids: null` 在搬运时被丢掉 → App 看成「没传」→ 一次参数错误
    #    静默变成一次范围更大的搜索（§4.3.1：只许收紧，不许放宽）。
    ('null 参数被当成没传', FILES['AuthorityWire'],
     '        for (name, value) in args {',
     '        for (name, value) in args where value != .null {'),

    # 53 整数被解成 Double：`limit: 5` 变 `5.0`，比大小、比相等都会错位。
    ('整数解成 double', FILES['AuthorityWire'],
     '        if let value = try? container.decode(Int.self) { self = .int(value); return }',
     '        if let value = try? container.decode(Int.self) { self = .double(Double(value)); return }'),

    # 54 `ok: true` 但没有正文时静默补一个 null：Agent 拿到的是「搜过了，结果是 null」。
    ('没有正文也算成功', FILES['AuthorityLinkSocket'],
     '            guard let value = response.result,\n'
     '                  let text = try? AuthorityWire.jsonString(value) else {',
     '            guard let value = response.result ?? Optional(AuthorityWire.Value.null),\n'
     '                  let text = try? AuthorityWire.jsonString(value) else {'),

    # ── Phase 6.2（2026-10-20）：权限判定收回 App authority。十二处 ──
    #    ★ 这一组的主题只有一个：**授权范围的产生点**。任何一处把它挪回助手、
    #      或者让 App 相信报文的说法，都必须有用例变红。

    # 55 现读设置变成「用默认值」：用户开了 AI 也永远是关的（6.1 的 main.swift 那种猜法）。
    ('设置不现读（用默认值）', FILES['RoutingAuthorityService'],
     '        let currentSettings = await settings()',
     '        let currentSettings = AIAccessSettings.initial'),

    # 56 ★ 注册表里多出来的来源（未授权）也进了返回体：**名字**泄露面（§4.3.1）。
    ('未授权来源也出现在 list_sources', FILES['AuthorizedSourceSnapshot'],
     '        for id in scope.sourceIDs where seen.insert(id).inserted {',
     '        for id in byID.keys where seen.insert(id).inserted {'),

    # 57 list_sources 不排序：同一份设置两次请求可能产出不同串，用例只能写成「解析后相等」。
    ('list_sources 不排序', FILES['AuthorizedSourceSnapshot'],
     '        kept.sort()',
     '        kept.sort(by: >)'),

    # 58 一次请求判两次权限：第一次允许、第二次拒绝这类分叉只有并发才复现。
    ('每请求判两次权限', FILES['RoutingAuthorityService'],
     '        switch route(job.op.rawValue, AuthorityWire.toolArguments(from: job.arguments), facts) {',
     '        _ = route(job.op.rawValue, AuthorityWire.toolArguments(from: job.arguments), facts)\n'
     '        switch route(job.op.rawValue, AuthorityWire.toolArguments(from: job.arguments), facts) {'),

    # 59 未知 op 回 invalid_argument（6.1 的码）：Agent 因此拿到两种不同的「工具不存在」。
    ('未知 op 回 invalid_argument', FILES['AuthorityListener'],
     '                                              code: "unknown_tool",',
     '                                              code: "invalid_argument",'),

    # 60 ★ 层次错误：助手又去引用 Router。**只改一行代码**就能让「第二份参数语义」回来，
    #    所以它必须由结构测试守着，而不是靠 review。
    ('助手又引用了 Router', FILES['MCPHandler'],
     'public struct MCPHandler: Sendable {',
     'public struct MCPHandler: Sendable {\n\n    static let routerType = ToolRouter.self'),

    # 61 报文层重新带上「授权范围」这个概念（6.1 的形状）：scope 从 App 内部漏到线上。
    ('报文层重新带上授权范围', FILES['AuthorityWire'],
     '        public var operation: Operation? { Operation(rawValue: op) }',
     '        public var scope: String? { nil }\n'
     '        public var operation: Operation? { Operation(rawValue: op) }'),

    # 62 ★ 开发期工具被打进 products：它就成了「被签名的产品的一部分」，
    #    第二个能连 authority socket 的二进制被我们主动分发出去（§5.2.2）。
    ('AuthoritySmoke 进了 products', FILES['PackageManifest'],
     '    products: [.library(name: "FlashFindCore", targets: ["FlashFindCore"]),',
     '    products: [.executable(name: "flashfind-authority-smoke", targets: ["AuthoritySmoke"]),\n'
     '               .library(name: "FlashFindCore", targets: ["FlashFindCore"]),'),

    # 63 打包脚本把开发期工具拷进 .app：Phase 10 加 `Contents/Helpers/` 时的闸。
    ('打包脚本拷了开发期工具', FILES['BuildTrial'],
     "shutil.copyfile(binary, macos / 'FlashFind2App')",
     "shutil.copyfile(binary, macos / 'FlashFind2App')\n"
     "shutil.copyfile(scratch / 'release/AuthoritySmoke', macos / 'AuthoritySmoke')"),

    # 64 适配层顺手把结果正文包一层：Agent 拿到的就不是 App 给的那个 JSON 了，
    #    而两边的用例都可能仍然「能解析」。适配层只许转发（§8.1）。
    ('结果正文被适配层改写', FILES['MCPHandler'],
     '            return Self.success(json)',
     '            return Self.success("[" + json + "]")'),

    # ---- Phase 6.3a：FileID / owner / locate 返回结构 ----

    # 65 哈希前像里去掉来源：两个 NAS 上的同名文件撞成一个 id，
    #    `get_metadata` 有可能去错来源找文件（跨来源串号）。
    ('file_id 前像里没有来源', FILES['FileID'],
     '        var data = Data(sourceID.utf8)',
     '        var data = Data()'),

    # 66 分隔符换成 NUL：`a` + NUL + `path:b` 与 `a\0path:b` 这类拼接会分不清边界。
    ('前像分隔符换成 0x00', FILES['FileID'],
     '    public static let separator: UInt8 = 0x1F',
     '    public static let separator: UInt8 = 0x00'),

    # 67 生成大写 hex：同一个文件会得到两个 id（校验侧只认小写）。
    ('file_id 生成大写 hex', FILES['FileID'],
     '    private static let hexDigits: [UInt8] = Array("0123456789abcdef".utf8)',
     '    private static let hexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)'),

    # 68 不做 NFC 归一化：本机（NFD）与 NAS（NFC）上的同一个文件得到两个 id。
    ('file_id 不归一化 Unicode', FILES['FileID'],
     '        let canonical = canonicalRelativePath.precomposedStringWithCanonicalMapping',
     '        let canonical = canonicalRelativePath'),

    # 69 路径安全判定放宽（去掉 `..` / 空段检查）：`../escape.pdf` 能生成 id。
    ('相对路径安全判定被放宽', FILES['Models'],
     '        return !path.split(separator: "/", omittingEmptySubsequences: false)\n'
     '            .contains(where: { $0.isEmpty || $0 == "." || $0 == ".." })',
     '        return true'),

    # 70 ★ Router 又自带一份形状规则：行为完全正确，所有行为用例都绿——
    #    只有「格式只有一个出处」那条结构测试抓得住。
    ('Router 又自带形状规则', FILES['ToolRouter'],
     '        var requested: Int?',
     '        _ = { (candidate: String) -> Bool in\n'
     '            candidate.count == 36 && candidate.allSatisfy { $0.isHexDigit }\n'
     '        }\n'
     '        var requested: Int?'),

    # 71 Router 对坏 file_id 兜一个默认值：「Agent 编的 id」变成了「某个真实 id」。
    ('坏 file_id 被兜成默认 id', FILES['ToolRouter'],
     '        guard let id = FileID.parse(trimmed) else {',
     '        guard let id = FileID.parse(trimmed)\n'
     '                ?? FileID.parse("ff1_" + String(repeating: "0", count: 32)) else {'),

    # 72 owner 变成固定值：所有 Agent 共用一个 owner，互相取消。
    ('owner 变成固定 sessionID', FILES['MCPOwner'],
     '        if isUsable(requestID) { return requestID }',
     '        return "fixed-session"'),

    # 73 owner 落成 .ui：Agent 的搜索会按「GUI 最新输入优先」被取代。
    ('owner 落成 .ui', FILES['MCPOwner'],
     '        .mcp(sessionID: sessionID(for: requestID))',
     '        .ui'),

    # 74 不可信的 id 不夹：4KB 的 id 直接进调度器的键与诊断标签。
    ('不可信 id 不夹长度', FILES['MCPOwner'],
     '        guard (1...maxSessionIDBytes).contains(requestID.utf8.count) else { return false }',
     '        guard !requestID.isEmpty else { return false }'),

    # 75 报文 id 不过河：App 侧所有请求都落进同一个空 id 的 owner。
    ('报文 id 不过河', FILES['AuthorityListener'],
     '        let job = AuthorityJob(id: request.id,',
     '        let job = AuthorityJob(id: "",'),

    # 76 locate 结果漏掉 warnings 的内容：部分失败的信息消失，Agent 以为全都搜过了。
    ('locate 结果没有 warnings 内容', FILES['LocateResponse'],
     '            AuthorityWire.ResponseKey.warnings: .array(warnings.map { .string($0) })',
     '            AuthorityWire.ResponseKey.warnings: .array([])'),

    # 77 reasons 被改写：Agent 拿到的不是闭集里的值，断言就没法做。
    ('reasons 被改写成大写', FILES['LocateResponse'],
     '            AuthorityWire.ResponseKey.reasons: .array(reasons.map { .string($0.rawValue) })',
     '            AuthorityWire.ResponseKey.reasons: .array(reasons.map { .string($0.rawValue.uppercased()) })'),

    # 78 分数越界不判：`87` 会被 Agent 读成「87%」。
    ('分数越界不判', FILES['LocateResponse'],
     '        guard score.isFinite, (0...1).contains(score) else { throw Error.scoreOutOfRange }',
     '        _ = score'),

    # 79 绝对路径不判：本机绝对路径直接发给 Agent（「请读取 /Users/…」）。
    ('绝对路径不判', FILES['LocateResponse'],
     '        guard RelativePath.isSafe(relativePath) else { throw Error.unsafePath }',
     '        _ = relativePath'),

    # 80 结果被重排：locate 的全部价值就是顺序，重排等于把排序算了又扔掉。
    ('locate 结果被重排', FILES['LocateResponse'],
     r'            AuthorityWire.ResponseKey.results: .array(results.map(\.payload)),',
     r'            AuthorityWire.ResponseKey.results: .array(results.sorted { $0.name < $1.name }.map(\.payload)),'),

    # 81 truncated 写死 false：Agent 以为「没有更多了」。
    ('truncated 写死 false', FILES['LocateResponse'],
     '        self.truncated = candidates.count > application.applied',
     '        self.truncated = false'),

    # 82 字段名退回 4.4 的老名字 `path`：这正是「schema 先冻结」要挡住的那种漂移。
    ('relative_path 退回老名字 path', FILES['LocateResponse'],
     '            AuthorityWire.ResponseKey.relativePath: .string(relativePath),',
     '            "path": .string(relativePath),'),

    # ── Phase 6.3b-0（2026-10-20）：四个 preflight。八处 ──

    # 83 ★ 越界路径被「钳到根」：`../../secret/x` 与根内 `secret/x` 撞同一个 file_id，
    #    两个不同文件从此共用一条 History。这是 §3.2.1 明令禁止的那种「修理」。
    ('越界路径被钳到根', FILES['Models'],
     '                guard !parts.isEmpty else { throw CanonicalError.escapesSourceRoot(raw: raw) }\n'
     '                parts.removeLast()',
     '                if parts.isEmpty { continue }\n'
     '                parts.removeLast()'),

    # 84 规范化不做 NFC：APFS 给 NFC、SMB/AFP 给 NFD，同一个文件迁移来源后 id 会变。
    ('规范化不做 NFC', FILES['Models'],
     '        return (parts.joined(separator: "/") as NSString).precomposedStringWithCanonicalMapping',
     '        return parts.joined(separator: "/")'),

    # 85 空段与尾随斜杠不再丢弃：`abc//x` 与 `abc/x` 变成两个路径，`abc/x/` 直接不安全。
    ('空段与尾随斜杠不丢弃', FILES['Models'],
     '        for segment in raw.replacingOccurrences(of: "\\\\", with: "/").split(separator: "/") {',
     '        for segment in raw.replacingOccurrences(of: "\\\\", with: "/").split(separator: "/", omittingEmptySubsequences: false) {'),

    # 86 `count >= applied`：正好用满上限也被说成「还有更多」。
    ('truncated 把「用满上限」也算成截断', FILES['LocateResponse'],
     '        self.truncated = candidates.count > application.applied',
     '        self.truncated = candidates.count >= application.applied'),

    # 87 ★ 退回本轮要修的那个 bug：把「参数被钳位」当成「结果被截断」。
    ('truncated 退回「参数被钳位」', FILES['LocateResponse'],
     '        self.truncated = candidates.count > application.applied',
     '        self.truncated = application.wasClamped'),

    # 88 truncated 恒 true：没有更多结果时也说有，Agent 会一直加参数。
    ('truncated 恒 true', FILES['LocateResponse'],
     '        self.truncated = candidates.count > application.applied',
     '        self.truncated = true'),

    # 89 ★ 执行侧自己再读一次注册表：判权之后来源被换掉，这次请求就拿到了新来源（§15 #23）。
    ('执行侧再读一次注册表', FILES['RoutingAuthorityService'],
     '            let snapshot = AuthorizedSourceSnapshot(scope: request.scope, registry: currentSources)',
     '            let snapshot = AuthorizedSourceSnapshot(scope: request.scope, registry: await sources())'),

    # 90 摘要退回 32 位：本轮复审明确要求「完整 SHA-256」，改短即违背契约。
    ('owner 摘要截断回 32 位', FILES['MCPOwner'],
     '    static let digestCharacters = 64',
     '    static let digestCharacters = 32'),

    # 91 没有名字就现编一个：list_sources 里出现 id 当名字，等于凭空造事实。
    ('没有名字就现编一个', FILES['AuthorizedSourceSnapshot'],
     '        ids.compactMap { id in names[id].map { AuthoritySource(id: id, name: $0) } }',
     '        ids.map { id in AuthoritySource(id: id, name: names[id] ?? id) }'),

    # ---- 2026-10-21 Phase 6.3b-1：locate 真执行 ----
    # ① 「执行层提前砍到 limit」= truncated 永远算不出来的那种写法。
    ('执行层提前砍到 limit', FILES['LocateExecution'],
     r'        let ordered = Self.ordered(collected.flatMap(\.results), report: &report)' + '\n        report.candidates = ordered.count',
     r'        let ordered = Array(Self.ordered(collected.flatMap(\.results), report: &report).prefix(application.applied))' + '\n        report.candidates = ordered.count'),
    # ② 部分失败的 warning 被折平：超时伪装成「连不上」。
    ('超时伪装成连不上', FILES['LocateExecution'],
     r'            + snapshot.ids.compactMap { id in failureByID[id].map { "\($0.rawValue):\(id)" } }',
     r'            + snapshot.ids.compactMap { id in failureByID[id].map { _ in "source_unavailable:\(id)" } }'),
    # ③ 失败来源根本不进 warnings（只有全失败那条路才写）。
    # 失败来源不进 warnings：**锚在唯一的聚合函数上**（6.4a 之后 run/runSearch/runMany
    # 三处都有同样的 `if let code = …` 块，锚在那里会变成「只改到第一个工具」）。
    # ★ 锚只到 `compactMap { id in` 为止：内层 `"\\($0.rawValue):\\(id)"` 被前面的
    #   `超时伪装成连不上` 改写过，带上它就会在批跑中途「标记没找到」。
    ('失败来源不进 warnings', FILES['LocateExecution'],
     '        snapshot.warnings\n            + snapshot.ids.compactMap { id in',
     '        snapshot.warnings\n            + snapshot.ids.prefix(0).compactMap { id in'),
    # ④' socket 不关 SIGPIPE：客户端提前断开就把 App 打死。
    #    ★ 两条 SIGPIPE 变异都**不能进批跑**：变异体下测试进程会收到真正的
    #    `SIGPIPE`（`Exited with unexpected signal code 13`），后面所有用例
    #    不再执行 → 红证变成一片假 MISS。实测过一次（249 条 MISS），见
    #    `SINGLE_ONLY` 与 `tools/mutate_each_mapped.py` 的登记。
    ('socket 不关 SIGPIPE', FILES['UnixSocket'],
     '        suppressSIGPIPE(fd)\n        return fd',
     '        return fd'),
    # ④'' accepted fd 不关 SIGPIPE：accept 不继承这个选项。
    ('accepted 连接不关 SIGPIPE', FILES['AuthorityListener'],
     '            UnixSocket.suppressSIGPIPE(client)\n',
     '            _ = client\n'),
    # ④ 预算到期折成「来源不可用」。
    ('预算到期折成不可用', FILES['LocateExecution'],
     '        if snapshot.timedOut { return .timeout }',
     '        if snapshot.timedOut { return .sourceUnavailable }'),
    # ⑤ 凭据失效折成「来源不可用」（最该让用户处理的那个没了）。
    ('凭据失效折成不可用', FILES['LocateExecution'],
     '        case .needsAuth:\n            return .authRequired',
     '        case .needsAuth:\n            return .sourceUnavailable'),
    # ⑥ 设备不接受这个词被说成设备掉线。
    ('参数问题说成掉线', FILES['LocateExecution'],
     '            return .invalidArgument\n        case .cancelled:',
     '            return .sourceUnavailable\n        case .cancelled:'),
    # ⑦ 被取消当成「搜过了，没有」。
    ('取消当成空结果', FILES['LocateExecution'],
     '        case .cancelled:\n            return .internalError',
     '        case .cancelled:\n            return nil'),
    # ⑧ 优先级表取反。
    ('错误优先级取反', FILES['LocateExecution'],
     '        guard let worst = codes.min(by: { $0.priority < $1.priority }) else {',
     '        guard let worst = codes.max(by: { $0.priority < $1.priority }) else {'),
    # ⑨ supersedePrevious 改成 true：同会话的两个并发请求互相取代。
    ('同会话请求互相取代', FILES['LocateExecution'],
     '                                        supersedePrevious: false) { event in',
     '                                        supersedePrevious: true) { event in'),
    # ⑩ 搜索挂到 GUI 的 owner 上（MCP 冒充界面）。
    ('MCP 冒充 GUI owner', FILES['LocateExecution'],
     '                item.handle.scheduler.submit(text: text,\n                                             queryID: queryID,\n                                             owner: owner,',
     '                item.handle.scheduler.submit(text: text,\n                                             queryID: queryID,\n                                             owner: .ui,'),
    # ⑪ 句柄按「随便拿一个」而不是按 id：执行侧拿到未授权的 provider。
    ('句柄不按 id 取', FILES['AuthorizedSourceSnapshot'],
     '    public func execution(for id: String) -> SourceExecutionHandle? { handles[id] }',
     '    public func execution(for id: String) -> SourceExecutionHandle? { handles.values.first }'),
    # ⑫ 同分时的字典序反向（同一输入两次跑出不同顺序）。
    ('同分不按路径升序', FILES['LocateExecution'],
     '            if lhs.relativePath != rhs.relativePath { return lhs.relativePath < rhs.relativePath }',
     '            if lhs.relativePath != rhs.relativePath { return lhs.relativePath > rhs.relativePath }'),
    # 去重被短路：同一个文件出现两次。
    # ★ 6.4a 之后 `orderedHits` 里也有一模一样的 `guard let existing = best[key] else {`，
    #   所以锚要带上两行上文，只命中 `locate` 的那一处（`for result in results`）。
    ('去重被短路', FILES['LocateExecution'],
     '        for result in results {\n            let key = result.fileID.value\n            guard let existing = best[key] else {',
     '        for result in results {\n            let key = result.fileID.value\n            guard let existing = best[key], false else {'),
    # ⑭ 名字档距缩小：一个刚改过的文件能把名字更准的挤下去。
    ('名字档距被缩小', FILES['LocateRanker'],
     '        case 1: return 0.75',
     '        case 1: return 0.6'),
    # ⑮ 「近期修改过」不再看年龄。
    ('三年前也叫近期修改', FILES['LocateRanker'],
     '            if let modified, abs(now.timeIntervalSince(modified)) <= reasonMaxAge {',
     '            if let modified {'),
    # ⑯ modified_after 不做比较（等于没过滤）。
    ('时间过滤只判有无', FILES['LocateExecution'],
     '                guard let modified = row.modifiedDate, modified > modifiedAfter else {',
     '                guard let modified = row.modifiedDate else {'),
    # ⑰ source_id 取自 provider 给的行（数据当授权事实）。
    ('source_id 取自结果行', FILES['LocateExecution'],
     '                                        sourceID: sourceID,\n                                        kind: fileKind,',
     '                                        sourceID: row.sourceID ?? sourceID,\n                                        kind: fileKind,'),
    # ⑱ 越界路径被「修好」而不是丢弃（钳根 = 两个文件撞同一个 id）。
    ('越界路径被修好', FILES['LocateExecution'],
     '            guard let path = try? RelativePath.canonical(row.relativePath) else {',
     '            guard let path = try? RelativePath.canonical(row.relativePath.replacingOccurrences(of: "../", with: "")) else {'),
    # ⑲ 超预算的搜索不停掉（继续占着设备那一台唯一槽位）。
    ('超预算不停搜索', FILES['LocateExecution'],
     '        if timedOutAny {\n            for run in runs {',
     '        if false {\n            for run in runs {'),
    # ⑳ 成功但空的来源被当成失败。
    # 空结果被当成失败：`completed` + 0 条 = 「搜过了，没有」，不是失败。
    # ★ 锚必须带上下面的 `let results = locateResults(`（`run` 独有），
    #   否则同样的 `else { sawUsableSource = true }` 在 `runSearch` 里也有一份。
    ('空结果被当成失败', FILES['LocateExecution'],
     '            } else {\n                sawUsableSource = true\n            }\n            if entry.snapshot.resultsIncomplete || entry.snapshot.state == .truncated {\n                report.incompleteSources.append(entry.id)\n            }\n            let results = locateResults(from: candidates(rows: entry.snapshot.rows,',
     '            } else {\n                sawUsableSource = false\n            }\n            if entry.snapshot.resultsIncomplete || entry.snapshot.state == .truncated {\n                report.incompleteSources.append(entry.id)\n            }\n            let results = locateResults(from: candidates(rows: entry.snapshot.rows,'),

    # ---- Phase 6.3b-3（2026-10-21）：NAS 来源根 / 共享名语义 ----
    # ★ 这四条守的都是**已经存在的产品语义**（本轮为零改动落成），
    #   所以它们不是「新代码的护栏」，而是把复审拍板的那条决定钉死在源码上：
    #   一个 NAS source_id = 一台设备的来源实例，共享名是真实的路径组件。
    #
    # ㉑ canonical「顺手把第一段当设备根剥掉」——正是被否掉的那个方案。
    #    剥掉之后 `/共享A/a.pdf` 与 `/共享B/a.pdf` 会撞成同一个 file_id。
    #    ★ 锚在 `parts.append(segment)` 而不是最后的 return 行：那条 return 已经
    #      被 `规范化不做 NFC` 占着，两条钉同一行会让批跑后一条永远找不到标记。
    ('canonical 剥掉第一段（当成设备根）', FILES['Models'],
     '            parts.append(segment)',
     '            parts.append(segment)\n'
     '            if parts.count > 1 { parts.removeFirst() }'),
    # ㉒ 「只有一段 = 没有路径」：共享根 `/共享A` 会被判成空。
    #    批跑里它与 ㉑ 锚在同一函数的不同行（guard / return），不冲突。
    ('单段路径也算空', FILES['Models'],
     '        guard !parts.isEmpty else { throw CanonicalError.empty(raw: raw) }',
     '        guard parts.count > 1 else { throw CanonicalError.empty(raw: raw) }'),
    # ㉓ Provider 不再按授权 scope 收口：设备根 ≠ 全部可见。
    ('Provider 不按 scope 收口', FILES['NASSearchProvider'],
     '        guard let path = m["path"] as? String, locatorSnapshot.contains(path: path),',
     '        guard let path = m["path"] as? String, locatorSnapshot.contains(path: path) || true,'),
    # ㉔ 结果行允许 `..`：`/共享A/../共享B/x` 被“修”进另一个 share。
    ('结果行允许 ..', FILES['NASSearchProvider'],
     '|| $0 == ".." || $0 == "@eaDir"',
     '|| $0 == "@eaDir"'),
    # ---- Phase 6.3b-4：产品装配（只能由真 App 的跨进程 E2E 抓，见 SINGLE_ONLY）----
    # ㉕ MCP 执行侧不套本机搜索范围：用户在设置里选的是「只搜索指定文件夹」，
    #    Agent 先来搜时 provider 还停在默认的整台 Mac（6.3b-4 真实抓到的缺陷）。
    ('MCP 执行侧不套本机搜索范围', FILES['AppModelAIAccess'],
     '        applyLocalScopeToProvider()\n        var map: [String: any SearchProvider]',
     '        var map: [String: any SearchProvider]'),
    # ㉖ 来源列表照旧列出来，但执行句柄不传：`locate` 会变成 `source_unavailable`。
    #    这条守的是「判权与执行用的是同一份来源」在**产品装配**里也成立。
    ('MCP 来源不传执行句柄', FILES['MCPAuthority'],
     '                            handle = SourceExecutionHandle(provider: provider, scheduler: scheduler)',
     '                            handle = nil; _ = (provider, scheduler)'),
    # ---- Phase 6.4a：locate_many / search（2026-10-21）----
    # ㉗ 分组按查询词排序：顺序不再是输入顺序（并发完成的次序会变成可见语义）。
    ('locate_many 分组按查询词排序', FILES['LocateExecution'],
     '        return runs.map { run in',
     '        return runs.sorted { $0.text < $1.text }.map { run in'),
    # ㉘ 每条子查询各领一张预算券：5 条就是 5 × budget，对外 10 s 契约当场破。
    #    ★ 变异体是「remaining × 份数」而不是「换成 deadline.budget」：所有 wait 任务是
    #      同一瞬间起步的，那一刻 remaining() ≈ budget，换字段是**等价变异**，
    #      批跑与逐条都红不了（2026-10-21 实测 0 条变红）。能被观察到的缺陷形态是
    #      「总时长 = 份数 × budget」，所以这里直接把券按份数放大。
    ('每条子查询各领一张预算券', FILES['LocateExecution'],
     '                let remaining = deadline.remaining()',
     '                let remaining = deadline.remaining() * Double(queries.count)'),
    # ㉘b 券永不消耗：`remaining()` 恒等于 budget，上面那条用例照样绿（wait 同一瞬间起步）。
    ('预算券永不消耗', FILES['LocateExecution'],
     '        return max(0, budget - elapsed)',
     '        return max(0, budget)'),
    # ㉙ 「locate_many 子查询互相取代」不另立一条：它和 ⑨「同会话请求互相取代」
    #    锚在**同一行**（`supersedePrevious: false`），批跑里后一条永远找不到标记。
    #    ⑨ 改成 true 之后，`locate_many` 的 5 条子查询同样会互相取消，
    #    `testFiveSubQueriesOnOneSourceAllComeBack` 就是它的具名抓手。
    # ㉚ 每组的窗口不截断：整组返回，这一组的 truncated 永远 false。
    ('每组窗口不截断', FILES['LocateExecution'],
     '            let response = LocateResponse(selecting: ordered, application: application, warnings: [])',
     '            let response = LocateResponse(selecting: ordered, application: LimitApplication(applied: max(application.applied, ordered.count), wasClamped: false), warnings: [])'),
    # ㉛ 0 命中的组被丢掉：Agent 分不清「这条搜过了没有」与「这条压根没搜」。
    ('空组被丢掉', FILES['LocateExecution'],
     '            groups.append(LocateManyGroup(query: outcome.text, response: response))',
     '            if !response.results.isEmpty { groups.append(LocateManyGroup(query: outcome.text, response: response)) }'),
    # ㉜ search 偷偷按 kind 过滤：它没有 kind 参数，目录不该消失。
    ('search 偷偷过滤目录', FILES['LocateExecution'],
     '            let rows = candidates(rows: entry.snapshot.rows,\n                                  sourceID: entry.id,\n                                  kind: nil,',
     '            let rows = candidates(rows: entry.snapshot.rows,\n                                  sourceID: entry.id,\n                                  kind: .file,'),
    # ㉝ search 的结果带上 score：两个 Tool 的分从此可以互相比较，而它们不是同一把尺子。
    ('search 结果带上 score', FILES['SearchResponse'],
     '            AuthorityWire.ResponseKey.kind: .string(kind.rawValue)',
     '            AuthorityWire.ResponseKey.kind: .string(kind.rawValue),\n            AuthorityWire.ResponseKey.score: .double(0.5)'),
    # ㉞ search 不按 lexical 档位排（等于只按路径）：宽口径检索不再「名字优先」。
    ('search 不按档位排序', FILES['LocateExecution'],
     '            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }',
     '            // 档位不参与排序'),
    # ㉟ #26 判权用完整宇宙：用户关掉的「搜索这台 Mac」被 AI 授权重新打开。
    ('本机全局关闭被授权重新打开', FILES['MCPAuthority'],
     '                    return model.aiAccessUsableCandidates.map { candidate in',
     '                    return model.aiAccessCandidates.map { candidate in'),
    # ---- Phase 6.4b-0：映射表的三列与三条硬要求 ----
    # ㊱ 写前不校验：不安全路径与「借来的 id」都能进表——`get_metadata` 之后
    #    会拿一条这个 id **从未指向过**的路径去问 Provider。
    ('映射表写前不校验路径与身份', FILES['FileReferenceStore'],
     '        try Self.validate(reference)\n        guard let statement = insertStatement',
     '        guard let statement = insertStatement'),
    # ㊲ 读回不校验：库被改坏（旧版本 / 手工 UPDATE）以后，坏路径原样交出去。
    ('映射表读回不校验坏行', FILES['FileReferenceStore'],
     '        do {\n            try Self.validate(reference)\n        } catch {\n'
     '            throw FileReferenceStoreError.corruptRow\n        }\n',
     '        _ = reference\n'),
    # ㊳ 查不到被判成错误：Agent 会收到 `internal_error` 而不是 `file_not_found`，
    #    于是「这个 id 过期了」被说成「闪寻内部出错了」。
    ('查不到的 id 被判成错误', FILES['FileReferenceStore'],
     '        if rc == SQLITE_DONE { return nil }',
     '        if rc == SQLITE_DONE { throw FileReferenceStoreError.storage("missing") }'),
    # ㊴ 批量不是原子：一条坏，前面几条已经落盘 → 有的 id 能查、有的不能，
    #    而调用方从返回值上分不出是哪一半。
    ('批量注册逐条提交', FILES['FileReferenceStore'],
     '            for reference in references { try insert(reference) }',
     '            for reference in references {\n'
     '                try insert(reference)\n'
     '                try exec("COMMIT")\n'
     '                try exec("BEGIN IMMEDIATE")\n'
     '            }'),
    # ㊵ 「以后也许会用」的一列：metadata 缓存 / History 就是这样长出来的。
    ('映射表预留 metadata 列', FILES['FileReferenceStore'],
     '            source_id TEXT NOT NULL,',
     "            source_id TEXT NOT NULL,\n            kind TEXT NOT NULL DEFAULT '',"),

    # ---- Phase 6.4b-1（2026-10-21）：get_metadata 的四步链 ----
    # ㊶ 去掉登记：搜索照常成功、file_id 照常发出去，只是以后查不出来。
    #
    # ★ 三条**分开**登记，不是一条打三处：三个 Tool 的三处落盘代码是三份，
    #   合成一条的话 `replace(old, new, 1)` 只删掉第一处，另两个 Tool 的用例
    #   在逐条里**根本不会红**——那是一次真实的假 MISS（2026-10-21 实测：
    #   `locate_many` / `search` 两条被记成「已证红」，其实从没被打到）。
    #   分开之后每条都有自己那一份锚点与那一条用例。
    ('locate 不登记就返回结果', FILES['LocateExecution'],
     '        // ★ 落盘**先于**成功响应：写不进去就不许把这一批 id 发出去。\n'
     '        if let failure = registerSelected(response.results.map(\\.reference)) {\n'
     '            return Run(outcome: failure, report: report)\n'
     '        }\n',
     ''),
    ('search 不登记就返回结果', FILES['LocateExecution'],
     '        // ★ 与 `locate` 同一条纪律：写不进去就不许把这一批 id 发出去。\n'
     '        if let failure = registerSelected(response.results.map(\\.reference)) {\n'
     '            return Run(outcome: failure, report: report)\n'
     '        }\n',
     ''),
    ('locate_many 不登记就返回结果', FILES['LocateExecution'],
     '        if let failure = registerSelected(groups.flatMap { $0.response.results.map(\\.reference) }) {\n'
     '            return Run(outcome: failure, report: report)\n'
     '        }\n',
     ''),
    # ㊷ 落盘失败被吞掉：照样回成功，等于发出一个不能兑现的引用。
    ('登记失败照样回成功', FILES['LocateExecution'],
     '            try store.registerAll(references)',
     '            try? store.registerAll(references)'),
    # ㊸ 冲突改成覆盖：同一个 id 在两次调用之间悄悄换了所指。
    ('映射冲突被静默覆盖', FILES['FileReferenceStore'],
     '                INSERT INTO file_reference(file_id, source_id, canonical_relative_path)',
     '                INSERT OR REPLACE INTO file_reference(file_id, source_id, canonical_relative_path)'),
    # ㊹ 撞了就当没发生：既不抛错也不改旧行，调用方以为写进去了。
    ('冲突被当成幂等', FILES['FileReferenceStore'],
     '        guard sameSource, samePath else {\n'
     '            throw FileReferenceStoreError.conflictingMapping\n'
     '        }',
     '        guard sameSource, samePath else {\n'
     '            return\n'
     '        }'),
    # ㊺ 不查本次 scope：撤销来源之后仍然把元数据交出去。
    ('get_metadata 不查本次 scope', FILES['MetadataExecutor'],
     '        guard snapshot.contains(reference.sourceID) else {',
     '        guard true || snapshot.contains(reference.sourceID) else {'),
    # ㊻ 绕过冻结句柄：拿快照里第一个可用句柄，掉线的来源借了别人的眼睛。
    ('metadata 绕过冻结句柄', FILES['MetadataExecutor'],
     '        guard let handle = snapshot.execution(for: reference.sourceID) else {',
     '        guard let handle = snapshot.ids.compactMap({ snapshot.execution(for: $0) }).first else {'),
    # ㊼ get_metadata 还停在「未实现」。
    # ★ 2026-10-21 重锚：6.4b-1 曾把 `get_metadata` 从「未实现」改成真执行，
    #      那条旧变异（整行 `return await MetadataExecutor(...)`）随之失效。
    #      现在的写法是「把这次调用的结果换成未实现错误」，语义不变。
    ('get_metadata 停在未实现', FILES['RoutingAuthorityService'],
     '            let run = await MetadataExecutor(store: store)\n'
     '                .run(fileID: fileID, snapshot: snapshot, history: history, now: timing.now())\n'
     '            return run.outcome',
     '            return .failure(code: NotImplementedAuthorityService.code,\n'
     '                             message: NotImplementedAuthorityService.message)'),
    # ㊽ 未知大小折成 0：Agent 会把它读成「这是个空文件」。
    ('未知大小折成 0', FILES['MetadataResponse'],
     '        guard let sizeBytes else { return .null }',
     '        guard let sizeBytes else { return .int(0) }'),
    # ㊾ 未知时间折成 1970。
    ('未知时间折成 1970', FILES['MetadataResponse'],
     '        guard let modified else { return .null }',
     '        guard let modified else { return .string("1970-01-01T00:00:00Z") }'),
    # ㊿ 目录也报一个「大小」。
    ('目录也报大小', FILES['ProviderMetadata'],
     '            sizeBytes: isDirectory ? nil : size,',
     '            sizeBytes: size,'),
    # 五十之后用汉字：跟业务语义走，别让编号变成又一份要维护的表。
    # ㊿₁ 匹配只要包含就算命中：`预算.xlsx` 会被 `预算.xlsx.bak` 顶掉。
    ('直查只要包含就算命中', FILES['ProviderMetadata'],
     '            guard rowName.precomposedStringWithCanonicalMapping == wanted else { continue }',
     '            guard rowName.precomposedStringWithCanonicalMapping.contains(wanted) else { continue }'),
    # ㊿₂ 匹配忽略大小写：`Report.pdf` 与 `report.pdf` 变成同一个文件。
    ('直查忽略大小写', FILES['ProviderMetadata'],
     '            guard rowName.precomposedStringWithCanonicalMapping == wanted else { continue }',
     '            guard rowName.precomposedStringWithCanonicalMapping.lowercased() == wanted.lowercased() else { continue }'),
    # ㊿₃ 不列父目录，直接列目标自己（没有任何来源支持这种问法）。
    ('直查不列父目录', FILES['ProviderMetadata'],
     '            ? "/" + segments.dropLast().joined(separator: "/")\n'
     '            : "/"',
     '            ? "/" + segments.joined(separator: "/")\n'
     '            : "/"'),
    # ㊿₄ 没连上也照样去问设备（于是得到「文件不在了」）。
    ('没连上也照样问设备', FILES['ProviderMetadata'],
     '        guard ready else { return .unavailable }',
     '        guard ready || true else { return .unavailable }'),
    # ---- build 29（2026-10-23）：本机读范围闸门（代码审核 BUG-112-01）。
    #
    # 这六条的锚点分散在两个文件里：闸门本身在 `LocalReadScope`，
    # 「有没有接上去」在 `ProviderMetadata`。只测纯函数不够 —— 判定写得再对，
    # 调用点没接就是原样漏出去。
    # ㊿₉₉ 忘了把闸门接到 metadata 上：收窄范围之后旧 file_id 照样能问出元数据。
    ('本机 metadata 不判范围', FILES['ProviderMetadata'],
     '        guard LocalReadScope.allows(absolutePath: absolutePath,\n'
     '                                    mode: mode,\n'
     '                                    folders: folders) else {\n'
     '            return .notFound\n'
     '        }\n',
     ''),
    # ㊿₁₀₀ 「整台 Mac」也去比文件夹：用户明明选了全盘，却只查得到挑过的那几个目录。
    ('整台 Mac 也按文件夹拦', FILES['LocalReadScope'],
     '        guard mode == .selectedFolders else { return true }',
     '        guard mode == .selectedFolders else { return false }'),
    # ㊿₁₀₁ 判定反向：范围内的被拒、范围外的放行 —— 比漏判更难发现，因为
    #      「搜得到但查不出元数据」看起来像设备的问题。
    ('范围判定反向', FILES['LocalReadScope'],
     '        return folders.contains { folder in',
     '        return !folders.contains { folder in'),
    # ㊿₁₀₂ 前缀不带分隔符：选中 `工作` 就把 `工作备份` 一起放进来。
    ('范围前缀不带分隔符', FILES['LocalReadScope'],
     '            return target.hasPrefix(root.hasSuffix("/") ? root : root + "/")',
     '            return target.hasPrefix(root)'),
    # ㊿₁₀₃ 空列表当成「全部」：用户清空文件夹列表那一刻，AI 的范围变成全盘。
    ('空文件夹列表当成全部', FILES['LocalReadScope'],
     '        guard !folders.isEmpty else { return false }',
     '        guard !folders.isEmpty else { return true }'),
    # ㊿₁₀₄ 不归一也不解软链：`工作/../客户资料` 与文件夹里的软链都能绕过去。
    #    ★★ 只能单跑：批跑里 ㊿₁₀₁（判定反向）会把它的后果**抵消掉**
    #      （2026-10-23 批跑实测两条 MISS）。两个错误叠在一起恰好是对的：
    #      「不归一」让 `工作/../客户资料/a.pdf` 因为字面前缀而命中原根，
    #      「判定反向」再把它翻成「拒绝」——用例要的正好是拒绝，于是全绿。
    #      这类互相抵消属于红证假象⑥，必须挪进 `SINGLE_ONLY`。
    ('读范围不归一也不解软链', FILES['LocalReadScope'],
     '        URL(fileURLWithPath: path)\n'
     '            .standardizedFileURL\n'
     '            .resolvingSymlinksInPath()\n'
     '            .path',
     '        path'),
    # ---- 下面四条是 6.4b-1 「把用例登记进 EXPECTED 之后才发现没有变异能打红它」
    #      的产物。登记用例却不给它能被打破的变异，等于造 9 条永久 MISS
    #      （2026-10-21 实测：批跑 330/339，9 条里 6 条是这一类的）。
    #      ★「用例进了 EXPECTED」与「有变异能打红它」必须成对登记。
    # ㊿₅ Swift 侧把「设备没给大小」折成 0（§4.11.6 在 Swift 侧的落点）。
    ('直查把没给大小折成 0', FILES['ProviderMetadata'],
     '                sizeBytes: (row["size"] as? NSNumber)?.int64Value,',
     '                sizeBytes: (row["size"] as? NSNumber)?.int64Value ?? 0,'),
    # ㊿₆ 反过来：0 字节被当成「设备没给大小」。null ≠ 0 的另一半，
    #      少了它只有「不会折成 0」被守住，「不会把 0 当成不知道」没人守。
    ('0 字节当成没给大小', FILES['MetadataResponse'],
     '        return .int(Int(sizeBytes))',
     '        return sizeBytes == 0 ? .null : .int(Int(sizeBytes))'),
    # ㊿₇ 某个入口忘了走队列：这条在单线程下毫无症状，
    #      只有源码级断言抓得到（§15.3.7）。
    ('有入口不走队列', FILES['FileReferenceStore'],
     '    public func register(_ reference: FileReference) throws {\n'
     '        try queue.sync { try insert(reference) }\n'
     '    }',
     '    public func register(_ reference: FileReference) throws {\n'
     '        try insert(reference)\n'
     '    }'),
    # ㊿₈ 又把 synthetic absolute_path 加回来（§4.12 刚推翻的旧冻结项）。
    ('get_metadata 又给回绝对路径', FILES['MetadataResponse'],
     '            AuthorityWire.ResponseKey.modified: modifiedPayload\n'
     '        ])',
     '            AuthorityWire.ResponseKey.modified: modifiedPayload,\n'
     '            "absolute_path": .string("/Volumes/" + relativePath)\n'
     '        ])'),

    # ==================== Phase 7：History + recent ====================
    #
    # ★ 两条纪律在这一轮同时生效，别只记住前一条：
    #   ① 一变异一锚点（`replace(…,1)` 只改第一处）；
    #   ② 「用例进了 EXPECTED」与「有变异能打红它」必须成对登记。

    # ㊿₉ 拿 request id 顶替 session id（§7a 明令禁止）。
    #      后果正是 §6.2.2 当场失效：每次 locate 都算「首见」。
    ('session 退化成 request id', FILES['HistoryContext'],
     '    public init(sessionID: String = UUID().uuidString, launchedAt: Date = Date()) {',
     '    public init(sessionID: String = "request", launchedAt: Date = Date()) {'),
    # ㊿₁₀ 标签不设长度上限：任何同 UID 进程都能往用户磁盘里塞任意长字符串。
    ('标签不设长度上限', FILES['HistoryContext'],
     '    public static let maxLabelLength = 256',
     '    public static let maxLabelLength = Int.max'),
    # ㊿₁₁ 畸形标签（换行 / NUL）不清洗，直接进 jsonl 诊断行。
    ('畸形标签不清洗', FILES['HistoryContext'],
     '            flattened.append(CharacterSet.controlCharacters.contains(scalar) ? " " : Character(scalar))',
     '            flattened.append(Character(scalar))'),
    # ㊿₁₂ located 的去重扩到所有动作：Phase 8 的 `metadata-access`
    #      会被掐死在 n=1（§6.2.2 / §7.1.2）。
    ('located 去重扩到 metadata', FILES['HistoryStore'],
     "            ON access_event(session_id, file_id) WHERE action='located';",
     '            ON access_event(session_id, file_id);'),
    # ㊿₁₃ 不再拒绝绝对路径：History 里一旦有根，§6.3 的承诺就破了。
    ('绝对路径也入库', FILES['HistoryStore'],
     '        guard RelativePath.isSafe(event.lastKnownRelativePath) else {',
     '        guard true else {'),
    # ㊿₁₄ 保留窗口形同虚设：90 天边界没人守。
    ('保留窗口放宽到 900 天', FILES['HistoryStore'],
     '    public static let retentionDays = 90',
     '    public static let retentionDays = 900'),
    # ㊿₁₅ 条数上限形同虚设：20 000 条边界没人守。
    ('条数上限放宽到 200 000', FILES['HistoryStore'],
     '    public static let maxEvents = 20_000',
     '    public static let maxEvents = 200_000'),
    # ㊿₅₄ 修剪的窗口取成 `now` 而不是 `cutoff`：窗口内的行也一起被删 ⇒
    #      第二次 `prune` 还在删东西，幂等性破掉（`testPruneIsIdempotent`）。
    #      ★ 改 `retentionDays`（㊿₁₄）动不到这条用例：它记录的时间戳就是 `base`，
    #        不是「90 天前」，所以把窗口放宽到 900 天对它毫无影响。
    ('修剪窗口用 now 当 cutoff', FILES['HistoryStore'],
     '            try exec("DELETE FROM access_event WHERE timestamp < \\(cutoff.timeIntervalSince1970)")',
     '            try exec("DELETE FROM access_event WHERE timestamp <= \\(now.timeIntervalSince1970)")'),
    # ㊿₁₆ 写失败不记录：故障被静默吞掉，日志里查不到。
    ('写入故障不记录诊断', FILES['HistorySink'],
     '    private func note(_ error: Error) {\n'
     '        let text = String(describing: error)\n'
     '        lock.withLock { lastFailure = text }\n'
     '    }',
     '    private func note(_ error: Error) {\n'
     '    }'),

    # ---- 三个写入点是**三份代码**，必须三条变异分别打（6.4b-1 的坑）----
    # ㊿₁₇ `locate` 不记 located。
    ('locate 不记 located', FILES['LocateExecution'],
     '        // ★ 只有**窗口内**那几条才算「被看到过」：被 limit 截掉的候选不记。\n'
     '        if let history {\n'
     '            history.located(Self.locatedEvents(response.results, context: history.context, at: now))\n'
     '        }',
     ''),
    # ㊿₁₈ `search` 不记 located。
    ('search 不记 located', FILES['LocateExecution'],
     '        // ★ 与 `locate` 同一条纪律：只有窗口内那几条算「被看到过」。\n'
     '        if let history {\n'
     '            history.located(Self.locatedEvents(response.results, context: history.context, at: now))\n'
     '        }',
     ''),
    # ㊿₁₉ `locate_many` 不记 located。
    ('locate_many 不记 located', FILES['LocateExecution'],
     '        if let history {\n'
     '            history.located(groups.flatMap {\n'
     '                Self.locatedEvents($0.response.results, context: history.context, at: now)\n'
     '            })\n'
     '        }',
     ''),
    # ㊿₂₀ `get_metadata` 不记 metadata。
    ('get_metadata 不记 metadata', FILES['MetadataExecutor'],
     '            if let history {\n'
     '                history.metadata(AccessEvent(sessionID: history.context.sessionID,\n'
     '                                             agentID: history.context.agentID,\n'
     '                                             fileID: fileID,\n'
     '                                             sourceID: reference.sourceID,\n'
     '                                             action: .metadata,\n'
     '                                             timestamp: now,\n'
     '                                             lastKnownRelativePath: reference.canonicalRelativePath))\n'
     '            }',
     ''),
    # ㊿₂₁ `get_metadata` 把 metadata 记成 located：撞上 located 的唯一索引，
    #      第二次查询就被幂等吞掉（§7c 明确要求 metadata 不去重）。
    #      ★★ 锚点必须在**库这一侧**，不能改 `MetadataExecutor` 里那个
    #        `action: .metadata` —— `recordMetadata` 用的是**自己的** action，
    #        `AccessEvent.action` 根本不参与落库。2026-10-21 实测：改调用侧那条，
    #        `RecentExecutionTests` 的 19 条用例全绿——那是**空转变异**，
    #        红证上它一直「已登记」，其实什么也没守。
    ('metadata 记成 located', FILES['HistoryStore'],
     '    public func recordMetadata(_ event: AccessEvent) throws {\n'
     '        try queue.sync { try insert(event, action: .metadata) }',
     '    public func recordMetadata(_ event: AccessEvent) throws {\n'
     '        try queue.sync { try insert(event, action: .located) }'),

    # ==================== Phase 7d / 7e / wire：recent 执行、生命周期、context ====================
    #
    # ★ 三条纪律在这一轮同时生效：
    #   ① 一变异一锚点（`replace(…,1)` 只改第一处，同一行不允许两条变异抢）；
    #   ② 「用例进了 EXPECTED」与「有变异能打红它」必须成对登记；
    #   ③ **互相掩盖的变异只留一条在批跑**，另一条进 `SINGLE_ONLY`
    #      并在 `mutate_each_mapped.py` 登记（如「去重形同虚设」与「去重键去掉 session」）。

    # ---- 7d：`recent` 真执行 ----
    # ㊿₂₂ 不把本次授权集合交给 History：撤销的来源照样从 `recent` 里冒出来。
    ('recent 不看本次 scope', FILES['RecentExecution'],
     '                events = try history.recentDistinct(limit: need,\n'
     '                                                    sourceIDs: snapshot.ids,\n',
     '                events = try history.recentDistinct(limit: need,\n'),
    # ㊿₂₃ 一条 stale 就毁掉整个列表——列表型 Tool 最典型的退化方式：
    #      Agent 会把它读成「用户最近没看过任何文件」，而我们并不知道这件事。
    ('recent 不跳过 stale', FILES['RecentExecution'],
     '                let resolved = references.flatMap { try? $0.lookup(event.fileID) }\n'
     '                guard let resolved, resolved.sourceID == event.sourceID else {\n'
     '                    report.skipped.append("stale_file_id:\\(event.fileID.value)")\n'
     '                    continue\n'
     '                }\n',
     '                let resolved = FileReference(fileID: event.fileID,\n'
     '                                             sourceID: event.sourceID,\n'
     '                                             canonicalRelativePath: event.lastKnownRelativePath)\n'),
    # ㊿₂₄ 退化成空列表 —— §14.3 明令禁止的假实现。
    ('recent 退化成空列表', FILES['RecentExecution'],
     '        let response = RecentResponse(selecting: hits,\n',
     '        let response = RecentResponse(selecting: [],\n'),
    # ✗ ㊿₂₅「recent 不去重」（删掉 `guard seen.insert(…)`）**build 29 起已删除**：
    #   BUG-112-03 的修法让「同一文件只出一条」有**三道独立防线** ——
    #   SQL 的 `GROUP BY file_id`、这里的 `seen` 集合、以及翻页（页内不会重复）。
    #   任何单点变异都会被另外两道兜住 ⇒ 零效应（2026-10-23 逐条实测：
    #   `MISS recent 不去重 … 实际变红 []`）。零效应变异不留在登记表里，
    #   否则它就是一条永久 MISS。
    #   `testRecentCollapsesRepeatedSightingsOfOneFile` 仍留在 `EXPECTED`：
    #   批跑里 ㊿₂₄（退化成空列表）能打红它。
    # ㊿₂₆ `recent` 又给回 synthetic absolute_path（§4.12 / §4.13 五字段闭集）。
    ('recent 多给字段', FILES['RecentExecution'],
     '                 AuthorityWire.ResponseKey.lastSeen:\n'
     '                     .string(MetadataResponse.utcFormatter.string(from: lastSeen))])',
     '                 AuthorityWire.ResponseKey.lastSeen:\n'
     '                     .string(MetadataResponse.utcFormatter.string(from: lastSeen)),\n'
     '                 "absolute_path": .string("/Volumes/" + relativePath)])'),
    # ㊿₂₇ 库读不出来时退化成空列表：等于替 Agent 下了「最近没看过」这个结论。
    ('recent 库坏了也返回空', FILES['RecentExecution'],
     '            } catch {\n'
     '                // 历史库坏了：整次失败，因为「最近看过什么」本身就是这次请求要的答案。\n'
     '                return Run(outcome: Self.failure, report: report)\n'
     '            }',
     '            } catch {\n'
     '                break\n'
     '            }'),
    # ㊿₂₈ 没装 History 库时报错：那是「功能没开」，不是故障。
    #      ★ 与 ㊿₂₉ 是**相反**的两条：一个谎称可用、一个谎称不可用。
    ('recent 没库时报错', FILES['RecentExecution'],
     '        guard let history else {\n'
     '            report.historyUnavailable = true\n',
     '        guard let history else {\n'
     '            report.historyUnavailable = true\n'
     '            return Run(outcome: Self.failure, report: report)\n'),
    # ㊿₂₉ 库明明装上了却谎称不可用：Agent 会以为 App 关掉了历史功能。
    ('recent 谎称不可用', FILES['RecentExecution'],
     '        var report = Report()\n',
     '        var report = Report()\n'
     '        report.historyUnavailable = true\n'),

    # ---- 7b：History 库 ----
    # ㊿₃₀ located 的去重形同虚设 → 「被看过」会被次数放大（§6.2.2）。
    ('located 去重形同虚设', FILES['HistoryStore'],
     "            ON access_event(session_id, file_id) WHERE action='located';",
     "            ON access_event(session_id, file_id) WHERE action='__none__';"),
    # ㊿₃₁ 把 v0.1 草案里的 size / mtime / 绝对路径快照列加回来。
    #      这三列没有任何消费者，却会让 History 变成「元数据的第二份说法」（§6.1 / §6.3）。
    ('加回快照列与绝对路径列', FILES['HistoryStore'],
     '            last_known_relative_path TEXT NOT NULL\n        );',
     '            last_known_relative_path TEXT NOT NULL,\n'
     '            mtime_at_access REAL,\n'
     '            size_at_access INTEGER,\n'
     '            absolute_path TEXT\n        );'),
    # ㊿₃₂ `source_ids` 筛选器失效（§7d：recent 只能读本次授权集合）。
    ('recent 的 source 过滤失效', FILES['HistoryStore'],
     '            conditions.append("source_id IN (\\(Self.placeholders(sourceIDs.count)))")',
     '            conditions.append("source_id NOT IN (\\(Self.placeholders(sourceIDs.count)))")'),
    # ㊿₃₃ `within_days` 的方向反了：老的留下、新的删掉。
    ('recent 的时间窗反了', FILES['HistoryStore'],
     '        if withinDays != nil { conditions.append("timestamp >= ?") }',
     '        if withinDays != nil { conditions.append("timestamp <= ?") }'),
    # ㊿₃₄ `limit` 只作用在候选上；失效后一次 `recent` 会把整张表读出来。
    ('recent 的 limit 失效', FILES['HistoryStore'],
     '            sqlite3_bind_int64(statement, index, Int64(limit))\n'
     '\n'
     '            var events: [AccessEvent] = []',
     '            sqlite3_bind_int64(statement, index, Int64(limit * 8))\n'
     '\n'
     '            var events: [AccessEvent] = []'),
    # ㊿₃₅ 排序反了：最老的在最前（§7d「最近被看到的时刻倒序」）。
    ('recent 的排序反了', FILES['HistoryStore'],
     '            sql += " ORDER BY timestamp DESC, id DESC LIMIT ?"',
     '            sql += " ORDER BY timestamp ASC, id ASC LIMIT ?"'),
    # ㊿₃₆ 清空历史不真删：用户点了「清空」之后 `recent` 照样有内容。
    ('clear 不真删', FILES['HistoryStore'],
     '        try queue.sync { try exec("DELETE FROM access_event") }',
     '        try queue.sync { try exec("DELETE FROM access_event WHERE 0") }'),
    # ㊿₃₇ HistoryStore 某个入口绕开串行队列（源码级断言会数出少了一处）。
    ('HistoryStore 有入口不走队列', FILES['HistoryStore'],
     '    public func recordLocated(_ event: AccessEvent) throws {\n'
     '        try queue.sync { try insert(event, action: .located) }\n'
     '    }',
     '    public func recordLocated(_ event: AccessEvent) throws {\n'
     '        try insert(event, action: .located)\n'
     '    }'),

    # ---- 7e：生命周期闸门 ----
    # ㊿₃₈ 闸门记不住上次跑过 → 每次调用都扫一遍 20 000 行的表。
    ('每日闸门记不住', FILES['HistorySink'],
     '        lastRun = stamp\n',
     ''),
    # ㊿₃₉ 闸门永不放行 → 90 天保留窗口变成一句空话，磁盘只涨不降。
    #      ★ 锚点含上面那段注释，保证与 ㊿₄₀ 不抢同一行。
    ('每日闸门永不放行', FILES['HistorySink'],
     '        // ★ 锁外执行：修剪可能扫 20 000 行，不该占着这把锁。\n'
     '        _ = try? store?.prune(now: now)\n'
     '        return true',
     '        _ = try? store?.prune(now: now)\n'
     '        return false'),
    # ㊿₄₀ 没装 History 库也算失败：那是「功能没开」，不该让维护报错。
    #      ★ 与上一条锚在同一段 ⇒ 上一条留批跑，这条走逐条。
    ('没库也算失败', FILES['HistorySink'],
     '        _ = try? store?.prune(now: now)\n'
     '        return true',
     '        guard store != nil else { return false }\n'
     '        _ = try? store?.prune(now: now)\n'
     '        return true'),

    # ---- 7a：标签 ----
    # ㊿₄₁ 每次 `current()` 现造一个 session：§6.2.2 当场失效。
    ('每次调用换 session', FILES['HistoryContext'],
     '        self.sessionID = sessionID\n',
     '        self.sessionID = UUID().uuidString\n'),
    # ㊿₄₂ 空标签不降级成 `unknown`：诊断里分不清「没取到」与「取到了空」。
    ('空标签不降级', FILES['HistoryContext'],
     '        return words.isEmpty ? Self.unknownAgent : String(words.joined(separator: " ").prefix(maxLabelLength))',
     '        return words.joined(separator: " ")'),
    # ㊿₄₃ 版本为空也拼斜杠 → `cursor/`。
    ('版本为空也拼斜杠', FILES['HistoryContext'],
     '        return cleanVersion.isEmpty ? cleanName : "\\(cleanName)/\\(cleanVersion)"',
     '        return "\\(cleanName)/\\(cleanVersion)"'),
    # ㊿₄₄ 客户端名不 trim → 全空白的名字被当成真名字。
    ('客户端名不 trim', FILES['HistoryContext'],
     '        let cleanName = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""',
     '        let cleanName = name ?? ""'),
    # ㊿₄₅ 名字与版本写反 → `1.0.31/claude-code`。
    #      ★ 锚点取 `noteClient` 而不是 `agentLabel` 的 return：后者已被 ㊿₄₃
    #        占住（`replace(…,1)` 只认第一处，同一行上排第二的会报「标记没找到」）。
    #        ★ 代价是它与 `客户端名不 trim`（㊿₄₄）互相抵消，所以 ㊿₄₄ 只单跑。
    ('名字与版本写反', FILES['HistoryContext'],
     '            agentName = name\n'
     '            agentVersion = version\n',
     '            agentName = version\n'
     '            agentVersion = name\n'),
    # ㊿₅₃ wire 键名写错成 `query`：不只是「解不出标签」——它把**查询词**这个
    #      概念带进了标签类型，下一步就有人真往里塞关键词（§6.3 明令禁止）。
    #      ★ 只能改 `case` 的**原始值**：多加一个 `case` 而没有对应存储属性，
    #        `Codable` 合成会直接编译失败——那不是变异，是把仓库改坏。
    ('context 的键名写成 query', FILES['HistoryContext'],
     '        case agentID = "agent_id"',
     '        case agentID = "query"'),
    # ---- wire：context 的形状 ----
    # ㊿₄₆ `context` 混进 `args`：Router 会把它当未声明参数拒掉，
    #      表现为**助手每次调用都失败**，而开发机上没人手往 socket 里写 context。
    #      ★ 锚点含两段注释，保证与 ㊿₄₇ 不抢同一行；且 **先于** ㊿₄₇ 登记，
    #      因为 ㊿₄₇ 会在同一行前面插入语句。
    ('context 混进 args', FILES['AuthorityWire'],
     '        self.args = try container.decodeIfPresent([String: AuthorityWire.Value].self, forKey: .args) ?? [:]\n'
     '        // ★ 解码即降级（不抛错）：标签来自不可信进程，畸形是常态。\n'
     '        //   在这里抛错会让任何同 UID 进程有能力用一条畸形标签把 MCP 搜索打挂（§5.2.2）。\n'
     '        self.context = try container.decodeIfPresent(HistoryContext.self, forKey: .context)?.clamped',
     '        var merged = try container.decodeIfPresent([String: AuthorityWire.Value].self, forKey: .args) ?? [:]\n'
     '        if let leaked = try container.decodeIfPresent(HistoryContext.self, forKey: .context) {\n'
     '            merged["session_id"] = .string(leaked.sessionID)\n'
     '        }\n'
     '        self.args = merged\n'
     '        self.context = try container.decodeIfPresent(HistoryContext.self, forKey: .context)?.clamped'),
    # ㊿₄₇ 缺 `context` 就报错：老客户端 / 直接写 socket 的脚本都不带它（§7a）。
    ('缺 context 就报错', FILES['AuthorityWire'],
     '        self.context = try container.decodeIfPresent(HistoryContext.self, forKey: .context)?.clamped',
     '        guard container.contains(.context) else {\n'
     '            throw DecodingError.dataCorruptedError(forKey: .context, in: container,\n'
     '                                                   debugDescription: "context is required")\n'
     '        }\n'
     '        self.context = try container.decodeIfPresent(HistoryContext.self, forKey: .context)?.clamped'),

    # ---- 只单跑：与批跑里某条互相掩盖（见 SINGLE_ONLY 注释）----
    # ㊿₄₈ 去重键里去掉 `session_id`：两个助手进程从此互相污染。
    #      ★ 这种 bug **只在开两个客户端时才出现** —— 单会话下无论怎么实现都表现正常。
    ('去重键去掉 session', FILES['HistoryStore'],
     "            ON access_event(session_id, file_id) WHERE action='located';",
     "            ON access_event(file_id) WHERE action='located';"),

    # ---- 7a 标签的形状（结构级禁令，只能靠源码断言抓）----
    # ㊿₄₉ `context` 的 wire 键名写错（少 `_id`）：老客户端按 `session_id` 发，
    #      这边按 `session` 解 ⇒ 标签静默丢失，History 拿不到 session 维度。
    #      ★ 不写成「多带一个 `case query`」：那会让 `HistoryContext` 编译失败
    #        （`CodingKey case 不匹配任何存储属性`）——变异得是能编过的错实现。
    ('context 键名写错', FILES['HistoryContext'],
     '        case sessionID = "session_id"',
     '        case sessionID = "session"'),
    # ㊿₅₀ 让 `HistoryContext` 认识 owner / scope / job 那套概念：
    #      一旦它认识，下一步就是「拿标签参与判定」，而它是可伪造的（§7a）。
    ('HistoryContext 引用判定概念', FILES['HistoryContext'],
     '    public static let unknownAgent = "unknown"',
     '    public static let ownerHint = "MCPOwner"\n'
     '    public static let unknownAgent = "unknown"'),
    # ㊿₅₁ 动作集合多一个：预留一个永远不会被写入的动作值，
    #      等于在库里放一列假数据（§6.2 / §15 #30）。
    ('动作集合多一个', FILES['HistoryStore'],
     '    case located\n    case metadata\n}',
     '    case located\n    case metadata\n    case selected\n}'),
    # ㊿₅₂ 编码时丢掉 `context`：往返之后标签没了，History 拿不到 session 维度。
    ('编码时丢掉 context', FILES['AuthorityWire'],
     '        Request(id: id, op: tool, args: self.arguments(from: arguments), context: context)',
     '        Request(id: id, op: tool, args: self.arguments(from: arguments))'),

    # ---- 7c 旁路：历史写失败也让 Tool Call 失败（与 §6.6 相反）----
    # ㊿₅₃ `locate`：历史写不进去也让搜索失败。
    #      ★ 与 ㊿₁₇（把整个写入块删掉）锚在同一段 ⇒ 只能一条进批跑。
    #        ㊿₁₇ 在**前面**已注册，整块删掉后这条就找不到标记了；
    #        留 ㊿₁₇ 在批跑（它同时是「只有窗口内才记」那条用例的抓手），
    #        这条走逐条。
    ('历史写失败也让 locate 失败', FILES['LocateExecution'],
     '        // ★ 只有**窗口内**那几条才算「被看到过」：被 limit 截掉的候选不记。\n'
     '        if let history {\n'
     '            history.located(Self.locatedEvents(response.results, context: history.context, at: now))\n'
     '        }',
     '        // ★ 只有**窗口内**那几条才算「被看到过」：被 limit 截掉的候选不记。\n'
     '        if let history {\n'
     '            history.located(Self.locatedEvents(response.results, context: history.context, at: now))\n'
     '            if history.lastFailure != nil {\n'
     '                return Run(outcome: .failure(code: LocateFailureCode.internalError.rawValue,\n'
     '                                             message: LocateFailureCode.internalError.message),\n'
     '                           report: report)\n'
     '            }\n'
     '        }'),

    # ---- 9-lite：AI 设置页（2026-10-22）----
    #
    # ㊿₅₅ AI 页改名。页面集合与顺序都由 `SettingsPane.allCases` 驱动，
    #      改 rawValue 就是界面上段名变了——「AI 必须是独立一级页」得被抓住。
    ('AI 页改名', FILES['SettingsPane'],
     '    case ai = "AI"',
     '    case ai = "智能"'),
    # ㊿₅₆ 把 AI 排到「高级」后面：页还在，但降级成了「又一个高级设置」。
    #      ★ 与 ㊿₅₅ 锚在同一行 ⇒ 只能单跑（进批跑会报「标记没找到」）。
    ('AI 页排到高级后面', FILES['SettingsPane'],
     '    case ai = "AI"\n    case advanced = "高级"',
     '    case advanced = "高级"\n    case ai = "AI"'),
    # ㊿₅₇ 被占用也点绿灯：用户以为这一份在服务，实际生效的是另一份。
    ('被占用也点绿灯', FILES['AISettingsStatus'],
     '    public var isHealthy: Bool { self == .running }',
     '    public var isHealthy: Bool { true }'),
    # ㊿₅₈ 没走到启动那一步也说「正常」。
    ('没启动也说正常', FILES['AISettingsStatus'],
     '        case nil: self = .notStarted',
     '        case nil: self = .running'),
    # ㊿₅₉ 失败原因吞掉：用户只知道坏了，不知道该修什么。
    ('失败原因被吞', FILES['AISettingsStatus'],
     '            return "监听没有起来：\\(reason)"',
     '            return "监听没有起来。"'),
    # ㊿₆₀ 占用态不说是「另一份」：用户会以为设置里改的授权已经生效。
    ('占用态不说是另一份', FILES['AISettingsStatus'],
     '            return "这个服务由另一份闪寻提供。同一台 Mac 上只运行一份，设置里的授权才对得上。"',
     '            return "这个服务正在提供。"'),
    # ㊿₆₁ 库打不开说成「已开启」：故障态被说成正常态，用户不会去修。
    ('打不开说成已开启', FILES['AISettingsStatus'],
     '        guard !isUnavailable else { return "不可用" }',
     '        guard !isUnavailable else { return "已开启" }'),
    # ㊿₆₂ 打不开也给出「清空」按钮，空库也给：点了什么都不会发生。
    ('打不开也可清空', FILES['AISettingsStatus'],
     '    public var canClear: Bool { (eventCount ?? 0) > 0 }',
     '    public var canClear: Bool { (eventCount ?? 0) >= 0 }'),
    # ㊿₆₃ 关闭态不说旧记录还留着：用户会以为关开关等于删了历史。
    ('关闭态不提旧记录', FILES['AISettingsStatus'],
     '        return "AI 访问关着，不再记录；已有的 \\(count) 条仍保留。"',
     '        return "AI 访问关着，不再记录。"'),
    # ㊿₆₄ 二次确认不承诺「文件编号仍有效」：用户会以为清历史等于让 AI 失忆。
    ('确认框不提文件编号', FILES['AISettingsStatus'],
     '清空后不可恢复。AI 已经拿到的文件编号仍然有效，不影响它继续查同一个文件。',
     '清空后不可恢复。'),
    # ㊿₆₅ 清空结果不报条数：删了 0 条还是 2000 条，用户看不出来。
    ('清空不说条数', FILES['AISettingsStatus'],
     '        "已清空 \\(count) 条历史。"',
     '        "已清空历史。"'),
    # ㊿₇₁ 两种状态同一个名字：标题一样了，用户分不出该修哪个。
    ('两种状态同一个名字', FILES['AISettingsStatus'],
     '        case .notStarted: return "未启动"',
     '        case .notStarted: return "正常运行"'),
    # ㊿₆₆ 设置页绕过草稿直接读已保存值：「改一半能撤销」那一套就白做了。
    ('设置页绕过草稿读已保存值', FILES['SettingsView'],
     '        let history = model.aiHistorySummary',
     '        let history = AIHistorySummary(isRecording: model.aiAccess.saved.isEnabled, eventCount: 0)'),
    # ㊿₆₇ 清空不做二次确认，直接删。
    ('清空不做二次确认', FILES['SettingsView'],
     'Button(AIHistoryText.clearButton) { confirmingHistoryClear = true }',
     'Button(AIHistoryText.clearButton) { clearHistory() }'),
    # ㊿₆₈ 注入排到启动之后：监听其实在跑，设置页却一直显示「未启动」。
    ('先启动再注入', FILES['FlashFind2App'],
     '        model.mcpAuthority = mcpAuthority\n        mcpAuthority.start(model: model)',
     '        mcpAuthority.start(model: model)\n        model.mcpAuthority = mcpAuthority'),
    # ㊿₆₉ 历史条数写死 0：`canClear` 跟着错，按钮点了没用。
    ('历史条数写死 0', FILES['AppModelAIAccess'],
     'eventCount: mcpAuthority?.historyEventCount() ?? nil)',
     'eventCount: 0)'),
    # ㊿₇₀ 历史行读草稿：改一半没保存，界面已经在说「记录中」。
    ('历史行读草稿', FILES['AppModelAIAccess'],
     'AIHistorySummary(isRecording: aiAccess.saved.isEnabled,',
     'AIHistorySummary(isRecording: aiAccess.draft.isEnabled,'),

    # ---- 接入提示词（Phase 9-lite 追加）----
    #
    # 这一段会被用户**原样复制**给 AI。写错的后果不在本机：别人照着错误的路径去启动
    # 一个不存在的程序，然后判定「闪寻这功能是坏的」。所以每条都守一个具体后果。
    #
    # ㊿₇₂ Helper 路径写死成 /Applications：App 被改名或拖到 ~/Applications 之后，
    #     提示词里的路径就是错的（而界面上一切正常）。
     ('Helper 路径写死', FILES['MCPIntegrationPrompt'],
      '        bundleURL.appendingPathComponent("Contents/Helpers/flashfind-mcp").path',
      '        URL(fileURLWithPath: "/Applications/闪寻.app/Contents/Helpers/flashfind-mcp").path'),
    # ㊿₇₃ 给 `appendingPathComponent` 多传一个前导斜杠：拼出 `闪寻.app//Contents/…`。
    #     ★ 这条**只单跑**：与 ㊿₇₂ 锚在同一行（`helperPath(forAppAt:)` 只有一行），
    #     批跑里后上的一条会报 `FAIL 变异标记没找到`。
    #     ★ 注意别拿「字符串拼 `含 /Contents/…`」当变异——`URL.path` 会吃掉尾部斜杠，
    #     实测两种写法结果一样，那是零效应变异。
     ('路径拼出双斜杠', FILES['MCPIntegrationPrompt'],
      '        bundleURL.appendingPathComponent("Contents/Helpers/flashfind-mcp").path',
      '        bundleURL.appendingPathComponent("/Contents/Helpers/flashfind-mcp").path'),
    # ㊿₇₄ 命令写死成别的绝对路径：提示词里出现「不是这个包」的路径，
    #     而且顺带把本机目录结构泄进了这段要外发的话。
     ('命令写死成别的绝对路径', FILES['MCPIntegrationPrompt'],
      '        命令：\\(helperPath)',
      '        命令：/Users/shared/Applications/闪寻.app/Contents/Helpers/flashfind-mcp'),
    # ㊿₇₅ 工具列表少一个：AI 会以为没有 recent，第三步验证直接做不下去。
     ('工具列表少一个', FILES['MCPIntegrationPrompt'],
      '''    public static let toolNames = ["list_sources", "locate", "locate_many",
                                   "search", "get_metadata", "recent"]''',
      '''    public static let toolNames = ["list_sources", "locate", "locate_many",
                                   "search", "get_metadata"]'''),
    # ㊿₇₆ 句子里不写数量：多一个工具或改坏数组，用户读不出「是不是全的」。
     ('句中不写工具数量', FILES['MCPIntegrationPrompt'],
      '        工具就是这六个，没有别的：',
      '        工具都在下面：'),
    # ㊿₇₇ 参数不写「无」：客户端会以为要传点什么，或者干脆自己编一个。
     ('参数不写留空', FILES['MCPIntegrationPrompt'],
      '        参数：无',
      '        参数：见客户端文档'),
    # ㊿₇₈ 第一步换成 search：`search` 是模糊搜，验证不了「授权范围对不对」，
    #     这一条同时是「配置通了」与「范围对」的双重校验，换掉就只剩一半。
    ('第一步换成 search', FILES['MCPIntegrationPrompt'],
     '        1. 调 list_sources，列出你现在能看到哪些来源。',
     '        1. 调 search，随便搜点什么。'),
    # ㊿₇₈b 第 2 步诱导传目录参数：locate/search 只收关键词，范围由勾选的来源决定。
    #     旧文案「在我提到的目录里找一个文件」实测会让 AI 传 root=…，必然撞
    #     Unknown argument，AI 就误判工具坏了（2026-10-23）。
    ('第 2 步诱导传路径参数', FILES['MCPIntegrationPrompt'],
     '        2. 调 locate，用一个关键词找一个文件（查找范围由勾选的来源决定，不接受路径参数）。',
     '        2. 调 locate，在我提到的目录里找一个文件。'),
    # ㊿₇₉ 改成「允许猜路径」：AI 会自己拼绝对路径去读文件，而闪寻从不给绝对路径。
     ('允许猜路径', FILES['MCPIntegrationPrompt'],
      '        找不到就说找不到，不要猜路径。',
      '        找不到就自己推断一下路径。'),
    # ㊿₈₀ 去掉「不上传」：这半句是隐私承诺的一部分，少一句就成了「不读内容但会上传」。
     ('去掉不上传', FILES['MCPIntegrationPrompt'],
      '        闪寻只在用户勾选过的来源里找，不读文件内容，也不上传任何东西。',
      '        闪寻只在用户勾选过的来源里找，不读文件内容。'),
    # ㊿₈₁ 折叠说明里写死客户端语法：没在真机上验过，用户照着抄必然报错。
     ('折叠说明写了客户端语法', FILES['MCPIntegrationPrompt'],
      '    具体怎么填以各自文档里讲 MCP 的那一节为准。你不需要在这里选客户端——填进去的永远是同一个路径。',
      '    写进它的 config.toml 就行。'),
    # ㊿₈₂ 提示词挂到草稿上：拨开开关还没保存，下面就摆出一段可复制的话，
    #     复制过去必然连不上——权威端那边 AI 访问还是关的。
     ('提示词挂到草稿上', FILES['SettingsView'],
      '            if model.isAIAccessGranted {',
      '            if model.aiAccess.draft.isEnabled {'),
    # ㊿₈₃ 复制时重新拼一遍：屏幕上是一句、剪贴板里是另一句，只有逐字比对才发现得了。
     ('复制时重新拼一遍', FILES['SettingsView'],
      'Button(MCPIntegrationText.copyButton) { copyPrompt(integration.text) }',
      'Button(MCPIntegrationText.copyButton) { copyPrompt(model.aiIntegrationPrompt.text) }'),
    # ㊿₈₄ 闸自己读草稿：名字还叫 Granted，看源码看不出来，等于这道闸不存在。
     ('闸读草稿', FILES['AppModelAIAccess'],
      '    var isAIAccessGranted: Bool { aiAccess.saved.isEnabled }',
      '    var isAIAccessGranted: Bool { aiAccess.draft.isEnabled }'),
    # ── Phase 10（2026-10-22）：Helper 身份 + 打包签名顺序 ──
    # ㊿₈₅ 派生副本落后一格：主 plist 升了版本、HelperInfo.plist 忘了跟。
    #     编译照过、链接照成，只有客户端握手时那行 serverInfo.version 是旧的。
    #     ★ 两端都现读现算，不写死版本号（见文件头 HELPER_SHORT_VERSION 的说明）。
     ('Helper 版本落后一格', FILES['HelperInfo'],
      '<string>%s</string>' % HELPER_SHORT_VERSION,
      '<string>%s</string>' % HELPER_PREVIOUS_VERSION),
    # ㊿₈₆ 构建号留空：`serverInfo.version` 只读短版本，构建号空了在协议上看不出来，
    #     但打包脚本会拿它当身份的一部分（归档名、证据目录）。
     ('Helper 构建号留空', FILES['HelperInfo'],
      '\t<key>CFBundleVersion</key>\n\t<string>%s</string>' % HELPER_BUILD,
      '\t<key>CFBundleVersion</key>\n\t<string></string>'),
    # ㊿₈₇ 标识符自己写死一份：不再从主 App 派生，改主标识符时两边就分叉了。
     ('Helper 标识符写死', FILES['HelperInfo'],
      '<string>com.flashfind.v2.mcp</string>',
      '<string>com.flashfind.mcp</string>'),
    # ㊿₈₈ 可执行名对不上：plist 说自己是 flashfind-mcp-cli，实际文件名不是，
    #     `Bundle.main.executablePath` 会指到不存在的文件，而 infoDictionary 照样读得到。
     ('Helper 可执行名对不上', FILES['HelperInfo'],
      '\t<key>CFBundleExecutable</key>\n\t<string>flashfind-mcp</string>',
      '\t<key>CFBundleExecutable</key>\n\t<string>flashfind-mcp-cli</string>'),
    # ㊿₈₉ 把主 plist 整个拷了一份过来：混进只对 App 生效的键。
     ('Helper plist 混进 App 键', FILES['HelperInfo'],
      '\t<key>CFBundlePackageType</key>',
      '\t<key>LSUIElement</key>\n\t<true/>\n\t<key>CFBundlePackageType</key>'),
    # ㊿₉₀ 先签 App 再签 Helper：App 的封存把 Helper 当时的内容记下了，之后再动 Helper，
    #     封存就失效。本机 verify 靠 `--strict` 未必当场炸，装到别人机器上才拒。
     ('先签 App 再签 Helper', FILES['BuildTrial'],
      "run(sign_arguments(helpers / HELPER_NAME), 'sign-helper')\nrun(sign_arguments(app), 'sign')",
      "run(sign_arguments(app), 'sign')\nrun(sign_arguments(helpers / HELPER_NAME), 'sign-helper')"),
    # ── Phase 11-lite（2026-10-22）：客户端 capability 兼容清洗 ──
    # ㊿₉₁ 清洗层空转（`sanitize` 直接返回原样）：整套规则还在，但一个字节都不洗。
    #     只能单跑：它一旦在批跑里生效，下面五条清洗变异全成了打死代码，
    #     对应用例反而变绿 → 六条一起假 MISS（掩蔽型假绿，见「红证里的假象」⑥）。
     ('清洗层空转', FILES['ClientSanitizer'],
      '    public static func sanitize(_ raw: Data) -> Data {',
      '    public static func sanitize(_ raw: Data) -> Data {\n        return raw'),
    # ㊿₉₂ 保留非字符串值（把过滤条件反过来）：Codex 的 `{"codex/auth-change":{}}` 又进得去，
    #     于是 SDK 照样解不开、握手照样 -32603。这是「修了但修反了」。
     ('只留非字符串值', FILES['ClientSanitizer'],
      '$0.value is String',
      '!($0.value is String)'),
    # ㊿₉₃ 合规客户端也被重编码：`return raw` 的早退没了，一个字节都不改的承诺破功。
    #     危害不是性能，是「字节是谁改的」再也说不清。
     ('合规报文也重编码', FILES['ClientSanitizer'],
      '            if kept.count == map.count { return raw }\n',
      ''),
    # ㊿₉₄ `experimental` 是字符串/数组/null 时不再整键删：这几种同样塞不进
    #     `[String: String]`，留着就是「只修了一半的畸形形态」。
     ('非对象 experimental 不删', FILES['ClientSanitizer'],
      '        } else {\n            capabilities.removeValue(forKey: "experimental")\n        }',
      '        }'),
    # ㊿₉₅ 重编码后丢掉行尾换行：传输层按行分帧，帧边界被吃掉在真实客户端上
    #     表现为「后面那条报文永远等不到」。
     ('清洗后丢换行', FILES['ClientSanitizer'],
      '        if raw.last == UInt8(ascii: "\\n") {',
      '        if false {'),
    # ㊿₉₆ main.swift 忘了换成包装层：清洗器还在、单测全绿，而 Codex 依旧连不上。
    #     只有跑真二进制的那条 E2E 抓得到——这正是它存在的理由。
     ('忘了换 SanitizingTransport', FILES['MCPMain'],
      'let transport = SanitizingTransport(wrapping: StdioTransport())',
      'let transport = StdioTransport()'),
    # ★ 撤掉过一条「出站也清洗」（`send(sanitize(data))`）：**零效应变异**。
    #   `sanitize` 只改 `initialize` 报文，出站的 `result` 帧进去什么样出来什么样，
    #   于是 `testSanitizingTransportForwardsOutboundVerbatim` 永远打不红——批跑里
    #   直接记成 MISS（2026-10-22 实测）。这类变异必须撤，否则「已证红」是假的。
]

# ★ 只能单跑、不能进批跑的变异。
#
# 批跑是把所有变异一次性打上去、只跑一遍测试；因此**锚在同一行**的两条变异互相冲突：
# 前一条改掉了那行，后一条就永远找不到标记（报 `FAIL 变异标记没找到`）。
#
# `truncated` 的语义只有一处赋值，而它恰好是四条边界的唯一判定点，所以三条
# 「把这一行改坏」的变异必须留给 `tools/mutate_each_mapped.py` 一条一条证红。
# 它们**不在** `EXPECTED` 里：`EXPECTED` 只列批跑能抓到的用例。
SINGLE_ONLY = {
    'truncated 写死 false',
    'truncated 退回「参数被钳位」',
    'truncated 恒 true',
    # ★ 这两条的性质与前三条不同：不是「锚在同一行」，而是**变异体会打死测试进程**。
    #
    # 两种都是真的 SIGPIPE（也正是生产里的症状：App 一声不响消失，没有 crash log），
    # 但作为批跑成员，`swift test` 会在那一处收到 signal 13 并**终止整轮**，
    # 后面所有用例都不再执行——2026-10-21 实测过一次：249 条假 MISS。
    #
    # 单跑时用 `--filter` 精确到单条用例（`mutate_each_mapped.py` 里登记），
    # 让它在「还没走到会自杀的那一步」就断言失败，于是拿到**具名**的红：
    #   · socket 不关 SIGPIPE        → AuthoritySocketTests/testSocketsAreCreatedWithSIGPIPESuppressed
    #   · accepted 连接不关 SIGPIPE  → MCPBoundaryTests/testTheAcceptedSocketSuppressesSIGPIPEToo
    'socket 不关 SIGPIPE',
    'accepted 连接不关 SIGPIPE',
    # ★ 两条装配变异：不是会自杀，而是**只有产品级跨进程 E2E 抓得到**。
    #
    # 批跑只跑一遍 `swift test`，而这两条要观察的是「真 App 进程 + 真 Helper 走
    # stdio」；把它们混进批跑并不能归因（一次性打上两百多条变异时产品 E2E 会因为
    # 别的原因红，红的不是这两条）。单跑用 `--filter ProductAssemblyE2ETests`
    # 精确到那一条用例，红的理由才唯一：
    #   · MCP 执行侧不套本机搜索范围 → 产品 E2E 的 locate 拿到 hits=0
    #   · MCP 来源不传执行句柄       → 产品 E2E 的 locate 拿到 source_unavailable
    'MCP 执行侧不套本机搜索范围',
    'MCP 来源不传执行句柄',
    # ★ 锚在同一行的第二条：NAS 直查的「精确匹配」只有一行
    #   （`rowName.precomposed… == wanted`），而它同时是「不许 contains」与
    #   「不许 case-fold」两条禁令的判定点。批跑只改一行，两条里必有一条落空。
    #   留 `直查只要包含就算命中`（前缀含糊更常犯）在批跑，
    #   case-fold 这条留给逐条，用例 `testCaseIsSignificantSoThereIsNoFuzzyMatch`
    #   因此**不在** `EXPECTED` 里（批跑里它该是绿的）。
    '直查忽略大小写',
    # ★ build 29：三条「首帧 vs 中途」的变异锚在 `readLine` 里同一行 `let wait = …`。
    #   批跑留了 `首帧也等读空闲超时`（审核报告里的原始故障），另外两条只能单跑：
    #     · 中途停顿改用整段预算 → AuthoritySocketTests/testAStallAfterTheFirstChunkStillUsesTheIdleTimeout
    #     · 每块都续命不受总预算 → AuthoritySocketTests/testDribbledChunksCannotExtendTheTotalBudget
    #   这两条用例因此**不在** `EXPECTED` 里（批跑里它们该是绿的）。
    '中途停顿改用整段预算',
    '每块都续命不受总预算',
    # ★ build 29：㊿₁₀₈ `recent 先限量再去重` 的锚点从循环头包到调用点
    #   （BUG-112-03 必须「按事件限量」+「不翻页」同时成立才复现），
    #   与批跑里的 ㊿₂₂ `recent 不看本次 scope` 抢同一段代码 ⇒ 只能单跑。
    #   对应用例 `testOneFileFloodingHistoryDoesNotEvictAnother` 因此
    #   **不在** `EXPECTED` 里（批跑里它该是绿的）。
    'recent 先限量再去重',
    # ★ ㊿₁₀₄ `读范围不归一也不解软链` 与批跑的 ㊿₁₀₁（判定反向）**互相抵消**：
    #   叠在一起时两条用例要的结论恰好都对，于是批跑里它们是绿的。
    #   ⇒ 只能单跑，两条用例 `testDotDotIsNormalisedBeforeComparison`、
    #   `testSymbolicLinkEscapingTheFolderIsRejected` 因此**不在** `EXPECTED` 里。
    '读范围不归一也不解软链',
    # ★ 这条与批跑里的 `located 去重形同虚设` **互相掩盖**：去重一旦整体失效，
    #   依赖「碰撞」的用例就都变绿了（testTwoHelperSessionsDoNotShareTheLocatedDedup
    #   在两条变异同时生效时反而是绿的）⇒ 它只能单跑，且对应用例不进 `EXPECTED`。
    '去重键去掉 session',
    # ★ 与上一条同源：两条都在改 `located` 的唯一索引，而批跑里已经有一条
    #   `located 去重扩到 metadata`（㊿₁₂）占住了那一行 —— 同一行上第 2、3 条
    #   变异会报「标记没找到」。所以「去重整体失效」也只能单跑。
    'located 去重形同虚设',
    # ★ 同理：它改的是 `locate` 那个写入块，而 ㊿₁₇ 已经把它整块删掉了。
    '历史写失败也让 locate 失败',
    # ★ ㊿₂₁ `metadata 记成 located` **不再只单跑**：它的锚点已移到库这一侧
    #   （`HistoryStore.recordMetadata`），不再与 ㊿₂₀（删掉 `MetadataExecutor`
    #   那整块写入）抢同一段代码，因此回到批跑。
    # ★ 同理：`runIfNeeded` 结尾被 ㊿₃₉ 改掉了。
    '没库也算失败',
    # ★ 同理，但方向是「互相抵消」而不是「锚在同一行」：
    #   `客户端名不 trim`（㊿₄₄）的后果是「全空白的名字被当成真名字」；
    #   `名字与版本写反`（㊿₄₅）把 `name` 换成 `version`——本例里 version 是 nil，
    #   于是那条空白名字根本走不到判断，两条变异同时生效时用例反而是绿的。
    #   ⇒ ㊿₄₄ 只单跑，对应用例 `testAClientWithoutANameIsUnknownWithALaunchStamp`
    #   因此**不进** `EXPECTED`（批跑里它该是绿的）。
    '客户端名不 trim',
    # ★ 锚在同一行：`helperPath(forAppAt:)` 只有一行，㊿₇₂（写死安装位置）与
    #   ㊿₇₃（拼出双斜杠）只能一条进批跑。留 ㊿₇₂ 在批跑（「忘了跟着包走」更常犯），
    #   双斜杠这条走逐条 ⇒ 对应用例 `testTheHelperPathNeverDoublesASlash`
    #   **不进** `EXPECTED`（批跑里它该是绿的）。
    '路径拼出双斜杠',
    # ★ 与 ㊿₅₅ 锚在同一行（`case ai = "AI"`）：批跑只改一处，
    #   于是「页名写错」与「页序被挪后」只能一条进批跑。
    #   留在批跑的是 ㊿₅₅（页名/页集合更常被改坏），顺序这条走逐条：
    #   单跑它时 `testAIIsItsOwnPaneAndSitsBeforeAdvanced` 才会红得有名有姓。
    'AI 页排到高级后面',
    # ★ ㊿₉₁ `sanitize` 直接 `return raw`：规则代码还在，但后面五条清洗变异全成了
    #   打死代码 —— 批跑里它们与这条同时生效时，对应用例反而全绿（掩蔽型假绿）。
    #   所以它只能单跑；单跑时 `ClientCapabilitySanitizerTests` 与
    #   `MCPStdioTests/testCodexShapeInitializeIsAccepted` 才会红得有名有姓。
    '清洗层空转',
}

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
    # 2026-10-22 用户报障「OTP 账号在详情界面不弹输入框」，随后又要求
    # 「全部改成登录时弹 OTP 弹窗的形式」：折叠区已撤，改由弹窗承载。
    # 指路只能指界面上确定还在的控件（「连接」按钮）——指到一个不存在的位置等于没说。
    'testTheOTPRetryHintPointsAtAButtonThatStillExists',
    'testTheOTPRetryHintSaysWhatToTypeAndHowToComeBack',
    'testWizardPromptsForOTPAndContinuesOnItsOwn',
    'testWizardFailurePromptsWhenTheDeviceNeedsOTP',
    # ★ 'testTheWizardFormHasNoInlineOTPField' **不进 EXPECTED**（护栏，不是回归）：
    #   它守「别把内联动态码框加回来」——三个断言都是 XCTAssertFalse（不存在型），
    #   而任何变异只会让「乱动」发生，且红证的变异形态（替换/删除现有 token）
    #   根本不会往 NASSourceWizardView.swift 里**添加** `nas-otp`/`nativeNASOTP`/
    #   `DisclosureGroup`。强行登记就是永久 MISS（2026-10-22 批跑实测）。留作护栏。
    # 2026-10-22 真机报障：OTP 账号点登录后「闪退」。
    # 不是崩溃（退出码 0、无崩溃报告），是关掉最后一个窗口后进程自己退了。
    # 两条变异各自打红：判定取反打红前两条，理由写空打红第三条。
    'testRestoresTheSearchPanelWhenNoOtherWindowIsVisible',
    'testDoesNotStealFocusWhenAnotherWindowIsStillOpen',
    'testAutomaticTerminationIsDisabledWithANonEmptyReason',
    'testOpenFileHidesPanelAndDoesNotStealFocus',
    # 2026-10-19 真机报障：提示条被压成窄边 + 查询清空后还挂在面板上。
    'testOpenFailureBannerOwnsItsHeightAndLeavesWithTheQuery',
    # 2026-10-19 真机报障：证书确认路径漏装挂载服务 / 只认 smbfs 导致 AFP 挂载不认。
    'testWizardBuildsEveryProviderThroughOneFactory',
    'testAFPMountCountsAsConnectedShare',
    # 2026-10-19 界面只体现版本号：关于面板显式清空的 `.version` 不能被填回去。
    'testAboutPanelAndSettingsShareOneVersionSource',
    # 2026-10-19 CI 首红复盘：取消之后的迟到批次必须被丢掉（原用例靠 sleep 赌顺序）。
    'testCancelRejectsDelayedBatches',
    # 2026-10-19 设置-高级：检查更新（版本比较 / 请求合规 / 失败说法 / 视图接线）。
    'testNumericComparisonIsNotLexicographic',
    'testMissingSegmentsCountAsZero',
    'testPrereleaseIsOlderThanTheSameStableVersion',
    'testDevBuildIsReportedAsIncomparableWithoutTouchingTheNetwork',
    'testRateLimitIsExplainedInsteadOfSwallowed',
    'testRequestLooksLikeAnAppAndSkipsTheCache',
    'testMessagesExplainEachOutcome',
    'testAdvancedPaneChecksForUpdatesThroughCore',
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
    # ★ 这里原来还写着一个 `testBuildScriptRefusesToProduceMissingNASRuntime`，
    #   但它**在整个代码库里不存在**（只有这一行提到它），所以永远不可能变红。
    #   它守的东西由下面这条真测试覆盖（`scripts/build.sh` 缺 MyNAS 运行时必须
    #   非零退出并指路）。死期望必须删掉：留着的后果是「MISS 一条」被当成噪音，
    #   久而久之所有人都不再看 MISS 列表——那红证就白做了。
    'testBuildScriptRefusesToProduceAppWithoutNASRuntime',
    # ---- 2026-10-20 Phase 3：搜索会话隔离（方案 §1.6.4）----
    # 「MCP 也自动取代」会让同 session 的 5 条 locate_many 子查询互相取消。
    'testSameMCPSessionQueuesInsteadOfSuperseding',
    'testFiveQueriesFromSameOwnerRunSerially',
    # 「GUI 插队退化成分段排队尾」只改排队位置，不影响「不抢占」。
    'testGUITakesNextSlotWithoutPreemptingActive',
    # 「排队项永不超时」：deadline 不再清队列，调用方拿不到终态。
    'testQueuedQueryIsRemovedAtDeadlineAndReportsTimeout',
    'testContinuousGUITrafficDoesNotLeakQueue',
    # 「owner 入口退回静态派发」：provider 收到的 owner 退化成默认 .ui。
    'testOwnerReachesProviderImplementation',
    # ---- 2026-10-20 Phase 3 第二轮：状态机补洞（v0.7）----
    # 每条新变异至少对应一条下面的用例；这 6 条都是「组合」，不是 happy path。
    #
    # 「取代时直接丢弃槽位」→ 来源卡死：新 GUI 与排队的 MCP 都永远不跑。
    'testUISupersedeWhileMCPQueuedDoesNotStallSource',
    # 「被取代的排队项静默消失」→ 调用方永远收不到终态。
    'testSupersededQueuedQueryReceivesCancelledTerminal',
    # 「cancelAll 先 drain 再清队列」→ 刚要求全取消，反而启动了排队那条。
    'testCancelAllNeverStartsTheOwnersQueuedWork',
    # 「取消时立刻释放槽位」→ 同来源出现两个活跃请求。
    'testNewQueryWaitsForCancellingSearchToActuallyReturn',
    # 「跨 owner 不校验」→ owner 隔离退化成注释。
    'testCrossOwnerCancelIsRejected',
    # 「复活 lastQuery」→ 已完成（甚至从未发出）的查询被再取消一遍。
    'testSupersedeDoesNotCancelAlreadyCompletedQuery',
    # ---- 2026-10-20 第三轮：Provider 终态契约（v0.8）----
    # 「终态只认 completed」→ 取消类终态不再是终态，排队取消那条也一样。
    'testCancelOwnQueuedQueryEmitsTerminalWithoutTouchingProvider',
    # 「取消不补发终态」→ 本机 / NAS 两条取消路径各一条用例，都是「恰好一个终态」。
    'testLocalCancelStillEmitsExactlyOneTerminal',
    'testNASCancelEmitsExactlyOneTerminalAndNeverTwice',
    # 「终态丢弃不完整信息」→ 结果不全必须落在 resultsIncomplete 上，不能与终态混用。
    'testNASCompletedEmitsOneTerminalAndKeepsIncompletenessSeparate',
    # ---- 2026-10-20 Phase 4：权限判定与设置状态 ----
    # 「总开关关着也放行」→ 关着时必须一律 mcp_disabled（按组合遍历，不只看一个典型输入）。
    'testMasterSwitchOffDeniesEveryCombination',
    # 「未点名时当成搜全部来源」→ 结果里会出现存在但未授权的来源。
    'testMissingRequestSearchesAllowlistNotEverything',
    # 「存在的来源一律放行」→ 同上，且不变量那条也会红。
    'testAllowResultIsAlwaysSubsetOfAllowlistAndExisting',
    # 「已删除的来源照样返回」→ 用户删了 NAS，list_sources 里还挂着它。
    'testDeletedAllowlistedSourceIsNotReturned',
    # 「空数组退化成没传」→ 参数错误变成一次范围更大的搜索。
    'testEmptyRequestedArrayFailsClosed',
    # 「warnings 用错码」→ 没授权被说成连不上，Agent 会让用户去查 NAS。
    'testExplicitRequestMixingDeniedSourceDegradesToWarning',
    # 「拒绝信息泄露来源 id」→ 未授权与不存在变得可区分，可据此枚举来源。
    'testDenyMessageDoesNotDistinguishUnknownFromUnauthorized',
    'testExplicitRequestEntirelyDeniedIsSourceDenied',
    # 「判定自己去读偏好」→ 撤销授权不再在下次请求生效。
    'testPolicyKnowsNothingAboutStorageOrMCP',
    # 「开着零来源也能保存」→ 首次开启不预勾任何来源这条契约随之失效。
    'testTurningOnPreselectsNothing',
    'testDeselectingLastSourceBlocksSaving',
    # 「存储层不校验就落盘」/「损坏状态照原样读出」/「保存不剔除已删除来源」。
    'testStoreRefusesToPersistEnabledWithNoSources',
    'testCorruptStoredStateLoadsAsDisabled',
    'testPruneDropsSourcesThatNoLongerExist',
    # 「剔空来源后仍保持开启」→ 删掉最后一个授权来源后仍留「开着但零来源」。
    # 这一条是 Phase 4 收尾补的状态不变量：删空即关、一次落盘、读出也是关。
    'testDeletingLastAuthorizedSourceTurnsAIOffAndPersistsOnce',
    'testEnabledWithZeroSourcesCannotReachDiskByAnyRoute',
    # ---- 2026-10-20 Phase 5.2：Tool 定义 ----
    # 「search 上限退化」→ 宽口径工具失去意义，两个工具无法区分。
    'testEachToolClampsToItsOwnMaximum',
    'testSearchIsWiderThanLocate',
    # 「非正 limit 静默用默认值」→ 参数错误被掩盖成「顺利返回 N 条」。
    'testNonPositiveLimitIsInvalidNotDefaulted',
    # 「超上限不报截断」→ Agent 以为拿到的就是全部。
    'testLimitClampsAndReportsTruncation',
    # 「kind 多出未实现取值」→ Agent 会传一个我们不处理的过滤条件。
    'testLocateParameterShape',
    # 「get_metadata 接受路径」→ 身份不再统一走 file_id。
    'testGetMetadataTakesFileIDOnly',
    'testNoToolAcceptsAPathAsInput',

    # ---- 2026-10-20 Phase 5.3：ToolRouter ----
    'testUnknownToolIsReportedAsUnknownTool',
    'testUnknownToolIsCheckedBeforeArguments',
    'testBlankQueryIsInvalidArgument',
    'testNonPositiveLimitIsInvalidArgument',
    'testLimitClampsAtSchemaMaximumAndReportsTruncation',
    'testOmittedSourceIDsSearchesEveryAuthorizedSource',
    'testEmptySourceIDsIsDeniedRatherThanOmitted',
    'testNullSourceIDsIsInvalidArgumentNotOmitted',
    'testUnknownArgumentIsRejected',
    'testLimitParameterNameComesFromSchema',
    'testKindRejectsValuesOutsideTheClosedSet',
    'testFileIDShapeIsEnforced',
    'testMasterSwitchOffDeniesEvenWithPerfectArguments',
    'testPermissionIsRecomputedOnEveryCall',
    'testWithinDaysMustBeAPositiveInteger',
    'testModifiedAfterRejectsGarbageAndDateOnly',
    # ---- Phase 6.1：Unix Socket 传输层（2026-10-20）----
    'testDirectoryIsOwnerOnly',
    'testSocketIsOwnerOnly',
    'testSecondInstanceDoesNotStealTheSocket',
    'testAConnectedButSilentSocketCountsAsStale',
    'testOversizedRequestIsRejected',
    'testIdleConnectionIsClosed',
    'testOversizedResponseBecomesAnError',
    'testSlowAuthorityTimesOut',
    'testResponseEchoesTheRequestID',
    'testIntegersStayIntegers',
    'testMissingResultIsNotASuccess',

    # ---- 2026-10-20 Phase 5.5：SDK 装配层（十处变异对应的红）----
    # 「启动日志写进 stdout」→ 结构测试 + 真实二进制两条端到端用例（管道 + 正常退出会 flush）。
    'testTheHelperWritesNothingButProtocolToStdout',
    'testStdoutCarriesOnlyProtocolFrames',
    'testStartupWritesNothingButTheResponse',
    # 「SDK 渗进 Router / tools/list 少一个」→ 两处「同一事实写两遍」的开端。
    'testTheSDKIsImportedInExactlyThreeFiles',
    'testBusinessLayersDoNotKnowTheSDK',
    'testToolsListIsExactlyTheCatalog',
    'testEveryCatalogParameterIsCarriedIntoTheSchema',
    # 「错误码被抹平 / Router 说 JSON-RPC」→ Agent 分不清该改参数还是该找用户。
    'testFailureIsNotAProtocolError',
    'testLinkFailureCodeIsForwardedUnchanged',
    'testUnsupportedJSONTypesSurviveAsUnsupported',
    'testTheRouterNeverSpeaksJSONRPC',
    # 「权限事实被写死为关闭 / 设置不现读」→ 开启与撤销都不生效。
    'testListSourcesReturnsOnlyAllowedSources',
    'testRevokingASourceTakesEffectOnTheNextRequest',
    # 「协议版本被手写」→ SDK 升级后新客户端连不上，报错指不到我们。
    'testProtocolVersionIsNeverHardcoded',
    # 「占位执行端假装成功」→ Agent 以为搜过了。
    'testUnreachableLinkNeverPretendsToSucceed',
    # 「入参不翻译（全丢）」→ 请求还在，内容没了。
    'testCallToolForwardsTheToolNameAndRawArguments',
    'testSuccessPayloadIsReturnedVerbatim',
    'testToolCallOverTheWireReachesTheLink',

    # ---- 2026-10-20 Phase 6.2：权限判定收回 App authority（v0.18）----
    # 每一个请求都要现读设置与来源：写死、缓存、相信报文都会让下面某一条变红。
    'testUnauthorizedSourceNeverAppearsInListSources',
    'testListSourcesIsSortedBySourceID',
    'testForgedSourceIDsFromAnotherProcessAreStillDenied',
    'testRoutingHappensExactlyOncePerRequest',
    'testUnknownOperationIsRejectedAsUnknownTool',
    # 参数过一趟线不许变形（B 方案的两份映射由往返属性测试拴住）。
    'testArgumentMappingSurvivesTheWireRoundTrip',
    'testNullSourceIDsIsInvalidArgumentNotOmitted',
    # 结构闸：层次错误只能靠源码扫描抓。
    'testHelperSourcesDoNotReferencePermissionOrRouting',
    'testWireCarriesNoAuthorizationScope',
    'testAuthoritySmokeIsNotAProduct',
    'testPackagingScriptDoesNotCopyDevTools',

    # ---- 2026-10-20 Phase 6.3a：FileID / owner / locate 返回结构 ----
    # FileID：前像少了来源、分隔符换了、大小写翻上去、不做 NFC、路径放宽，各有一条。
    'testMakeProducesPrefixAndThirtyTwoLowercaseHex',
    'testParseAcceptsWhatMakeProduces',
    'testTheSourceIsPartOfTheIdentity',
    'testComposedAndDecomposedFormsProduceTheSameID',
    'testUnsafePathsAreRejected',
    'testGoldenIDsPinTheHashRule',
    'testPreimageIsTheDocumentedByteSequence',
    'testTheSeparatorIsUnitSeparator',
    # 「格式只有一个出处」只能扫源码；Router 兜默认值那条由行为用例抓。
    'testTheFormatLiteralLivesInExactlyOneSourceFile',
    'testTheRouterDoesNotCarryASecondShapeRule',
    'testFileIDShapeIsEnforced',
    # owner：固定 sessionID / 落成 .ui / 报文 id 不过河。
    'testEachWireRequestBecomesItsOwnOwner',
    'testTheMCPOwnerIsNeverTheUIOwner',
    'testTwoDifferentHostileIDsStayDistinct',
    # ★ `testAnOverlongOrHostileIDIsBounded` **故意不在**这里：「owner 变成固定 sessionID」
    #   与「不可信 id 不夹长度」是同一个小函数里的两条变异，前者把所有 id 折成同一个短串，
    #   于是后者永远轮不到失败——变异互相遮住（6.1 的 inode 那条踩过同一个坑）。
    #   它由 `tools/mutate_each_mapped.py` **单独**证红。
    # 报文 id 过河（socket 层，跨进程）。
    'testTheRequestIDReachesTheService',
    # locate 返回结构：字段名、warnings、reasons、分数越界、绝对路径、顺序、truncated。
    'testEveryHitCarriesExactlyTheFrozenKeys',
    'testRetiredFieldsDoNotComeBack',
    'testTheHitValuesAreCarriedVerbatim',
    'testWarningsAreCarriedVerbatim',
    'testAScoreOutsideZeroToOneCannotBecomeAResult',
    'testAnAbsolutePathCannotBecomeAResult',
    'testTheResultOrderIsPreserved',

    # ---- 2026-10-20 Phase 6.3b-0：四个 preflight ----
    # ① 路径规范化：越界不许钳、NFC 必做、空段/尾随斜杠必消。
    'testTheSevenEscapingFormsAreRejected',
    'testAnEscapingPathNeverCollidesWithARealFileAtTheRoot',
    'testTheNineLegalSpellingsConvergeToOnePath',
    'testATrailingSlashIsNormalisedRatherThanRejected',
    'testEveryCanonicalPathIsSafeForFileID',
    # ② truncated 的边界。★ 四条里只有 `testExactlyTheLimitIsNotTruncated` 在批跑里：
    #    另外三条要「把同一行改成 false / wasClamped / true」才红，而那三条与批跑里
    #    的 `>=` 锚在同一行（见 `SINGLE_ONLY`），只能单跑证红——
    #    `tools/mutate_each_mapped.py` 里逐条登记了它们各自的期望用例。
    'testExactlyTheLimitIsNotTruncated',
    # ③ owner 摘要必须是完整 SHA-256。
    'testTheDigestIsTheFullSHA256',
    # ④ 授权快照：只含授权来源、排序、名字不许编、执行侧不许再读注册表。
    'testOnlyAuthorizedSourcesAreInTheSnapshot',
    'testIDsAreSortedAndDeduplicated',
    'testAnIDWithoutANameIsExecutableButNotListed',
    'testTheExecutorUsesTheSnapshotThatWasAuthorized',

    # ---- 2026-10-21 Phase 6.3b-1：locate 真执行 ----
    # limit+1 必须真的观察到第 N+1 条（走生产路径）。
    'testOneMoreCandidateThanTheLimitIsTruncatedOnTheProductionPath',
    # 部分失败：结果 + typed warning，超时不许伪装成连不上。
    'testOneSourceFailingYieldsResultsAndAWarning',
    'testATimedOutSourceIsReportedAsTimeoutNotUnavailable',
    # 全部失败：typed error 不降级、优先级只处理它该处理的那几个。
    'testASingleTimedOutSourceKeepsItsOwnCode',
    'testAuthRequiredWinsOverUnavailable',
    'testTimeoutOutranksUnavailableWhenEverythingFails',
    'testABlockedSourceIsAnArgumentProblemNotAnOutage',
    # ★ `testACancelledSearchIsNeverAnEmptySuccess` **不在这里**：批跑里它被
    # 「空结果被当成失败」遮住（cancelled→nil 之后走 else，`sawUsableSource`
    # 又被改成 false，两条叠加仍然回 internal_error，它反而绿了）。
    # 批跑的抓手换成下面这条部分失败形态；单来源那条由 mutate_each_mapped 单独证红。
    'testACancelledSourceIsReportedEvenWhenAnotherSourceSucceeded',
    'testAnEmptyButCompletedSearchIsASuccess',
    # owner：一次 wire 请求一个 owner，同会话并发也不许互相取代。
    'testTwoConcurrentRequestsFromOneSessionDoNotCancelEachOther',
    'testEachWireRequestReachesTheProviderAsItsOwnOwner',
    # 快照：执行句柄必须按 id 取（★ 用确定性单测——老抓手
    # `testTheExecutorUsesOnlyTheProvidersInTheSnapshot` 依赖字典序，是碰运气）。
    'testTheExecutionHandleIsFetchedBySourceIDNotByWhicheverComesFirst',
    # 去重、确定性、排序主导权。
    'testDuplicateRowsForOnePathAreMerged',
    'testTiesAreBrokenByPathSoTheOrderIsReproducible',
    'testASharperNameMatchOutranksAFresherFile',
    # reasons 不许编、时间过滤不许形同虚设、身份不许来自数据、越界不许修。
    'testAnOldFileDoesNotClaimToBeRecentlyModified',
    'testModifiedAfterDropsUndatedRows',
    'testTheSourceIDComesFromTheSnapshotNotFromTheRow',
    'testEscapingPathsAreDroppedNotRepaired',
    # 超预算要停掉。
    'testAnOverBudgetSourceIsCancelled',
    # ★ 传输层的两条 SIGPIPE 断言**不在这里**：它们的变异会打死测试进程（见
    # `SINGLE_ONLY`），只能由 `mutate_each_mapped.py` 单跑证红。
    # `testSocketsAreCreatedWithSIGPIPESuppressed` 与
    # `testTheAcceptedSocketSuppressesSIGPIPEToo` 都在那份登记里。

    # ---- Phase 6.3b-3（2026-10-21）：NAS 共享名 / 来源根（六条契约）----
    # ① ② 由 ㉑ 抓；④ 由 ㉒ 抓；⑤ 由 ㉔ 抓；⑥ 由 ㉓ 抓。
    # ③（同路径不同 source_id 必须是不同身份）没有新变异：它抓的是
    # `FileID` 前像里必须带 sourceID，那条变异（`file_id 前像里没有来源`）
    # 已在 `FileIDTests` 上逐条证红，这里只是把同一条语义在 NAS 全链路上再钉一次。
    'testASharePathKeepsItsShareSegmentThroughTheWholeChain',
    'testTwoSharesUnderTheSameSourceKeepDistinctFileIDs',
    'testTheSameSharePathUnderDifferentSourceIDsKeepsDistinctFileIDs',
    'testTheShareRootItselfIsAValidRelativePath',
    'testADotDotRowCrossingSharesIsRejectedNotRepaired',
    'testAPathOutsideTheAuthorizedScopesIsDropped',

    # ---- Phase 6.4a（2026-10-21）：locate_many / search ----
    # 顺序、预算、取代、每组独立窗口、空组。㉗ ㉘ ㉙（并入 ⑨）㉚ ㉛ 逐条对应。
    'testGroupsFollowTheInputOrderNotTheCompletionOrder',
    'testTheSubQueriesShareOneBudgetInsteadOfOneEach',
    # ㉘b 券本身的算术：`remaining()` 永不消耗时上一条抓不到，靠这一条。
    'testTheBudgetCouponShrinksWithTheClockInsteadOfStayingFull',
    'testFiveSubQueriesOnOneSourceAllComeBack',
    'testEveryGroupHasItsOwnTruncatedWindow',
    'testAQueryWithoutHitsStillGetsAnEmptyGroup',
    # search：不按 kind 过滤、字段只有五个、按 lexical 档位排。
    'testFoldersAreReturnedWithKindFolder',
    'testEachHitHasExactlyFiveFields',
    'testHitsAreOrderedByLexicalRankThenPath',
    # #26：全局关闭压过 AI 授权（㉟）。
    'testTheLocalSwitchGatesJudgementWithoutPruningTheAuthorization',

    # ---- Phase 6.4b-0（2026-10-21）：映射表 `FileReferenceStore` ----
    # ㊱ 写前不校验 → 不安全路径 / 借来的 id 都进表。
    'testAnUnsafePathIsRejectedInsteadOfRepaired',
    'testAnIDThatDoesNotBelongToThePathIsRejected',
    # ㊲ 读回不校验 → 坏行被当成好行交出去。
    'testALookupRefusesACorruptRowInsteadOfHandingOutThePath',
    'testACorruptRowThatNoLongerMatchesItsIDIsAlsoRefused',
    # ㊳ 查不到被判成错误 → 过期 id 被说成「闪寻内部出错」。
    'testAnUnknownIDIsNilInsteadOfAnError',
    # ㊴ 批量逐条提交 → 写一半。
    'testOneBadEntryRollsBackTheWholeBatch',
    # ㊵ 预留 metadata 列 → 列名闭集与「不许偷带」两条一起红。
    'testTheTableHasExactlyTheThreeFrozenColumns',
    'testTheTableDoesNotSmuggleInMetadataOrHistoryColumns',

    # ---- Phase 6.4b-1（2026-10-21）：`get_metadata` ----
    # ㊶ 去掉 registerAll：三个搜索 Tool 都得有一份「id 能查到」的抓手，
    #    否则「只有 locate 接线、search 没接线」不会红。
    'testLocateRegistersTheIdsItReturns',
    'testSearchRegistersTheIdsItReturns',
    'testLocateManyRegistersEveryGroup',
    'testLocateManyRegistersEveryGroupInOneTransaction',
    # ★ 下面这条**不在**这里。它单跑时是红的（逐条里挂在 `locate 不登记就返回结果`
    #   与 `登记失败照样回成功` 两条上），但批跑里会被**别**的变异掩盖：
    #   另有若干变异会让 `run` 走到 `response.json()` 失败那条路，一样吐
    #   `internal_error`，于是这条用例在 294 条变异一起上时反而是绿的。
    #   （2026-10-21 实测。教训：进了 EXPECTED 的用例必须真的有变异能打红它。）
    #   'testAStoreThatCannotWriteFailsTheWholeCall',
    # ㊸/㊹ 冲突改成覆盖 / 当成幂等：既有引用绝不能被改写。
    #   ㊸ 同时是下面「先写的那串字节不该被改写」的抓手。
    'testAnExistingMappingIsNeverOverwritten',
    'testOneConflictRollsBackTheWholeBatch',
    'testThereIsNoUpsertAnywhereInTheStore',
    # ㊺ 不查本次 scope：撤销来源之后照样把元数据交出去。
    #   ★ 'testRevocationDoesNotEraseTheMapping' **不在**这里：没有任何批跑变异
    #   能打红它（「撤销时顺手删映射」那条变异要调一个不存在的 `delete` API，
    #   只会让编译挂掉——那不是变异，那是把仓库改坏）。它是回归用例，
    #   只接受「有它比没它好」，不进红证账。
    'testRevokingTheSourceDeniesTheNextCall',
    # ㊻ 绕过冻结句柄：掉线的来源借别人的眼睛。
    'testAnUnavailableSourceDoesNotBorrowAnotherSourcesHandle',
    # ㊼ 还停在「未实现」。
    'testGetMetadataIsNoLongerNotImplemented',
    # ㊽ 未知大小折成 0 / ㊾ 未知时间折成 1970。
    'testAnUnknownSizeIsNullNotZero',
    'testAZeroByteFileReportsZeroNotNull',
    'testAnUnknownTimeIsNullNotEpoch',
    'testADeviceThatGivesNoSizeYieldsNil',
    # ㊿ 目录也报大小 / 直查含糊匹配 / 不列父目录 / 没连上也问。
    'testALocalFolderHasNoSize',
    'testAFolderHasNoSize',
    # ★ 这条**不在**这里：它的变异（直查忽略大小写）是只单跑的，
    #   批跑里它必须保持绿（`直查只要包含就算命中` 抓不到它）。
    #   'testCaseIsSignificantSoThereIsNoFuzzyMatch',
    'testAPrefixIsNotAMatch',
    'testNasMetadataPicksTheExactEntry',
    'testADisconnectedSourceIsUnavailableNotNotFound',
    # ㊿₈ synthetic absolute_path 加回来 → 七字段闭集破。
    'testTheResponseCarriesExactlySevenFields',
    # ★ 下面两条**不在**这里，都是「没有批跑变异能打红它」的：
    #   · 'testTheMappingSurvivesAReopen'：库的重开/落库路径上没有单点可改——
    #     删掉 `COMMIT` 只影响 `registerAll`（事务），这条用例走的是单条 `register`；
    #     改建库路径又只能让整个套件编译失败。
    #   · 'testConcurrentReadersAndWritersDoNotLockEachOtherOut'：去掉串行队列后
    #     WAL + busy_timeout 仍会让 8 个任务全部成功——它守的是「真实锁竞争下
    #     不许失败」，不是「有没有那条队列」（后者由源码级断言守）。
    #     'testTheMappingSurvivesAReopen',
    #     'testConcurrentReadersAndWritersDoNotLockEachOtherOut',
    # ㊿₇ 有入口不走队列 → 源码级断言数出 `queue.sync` 少了一处。
    'testEveryEntryPointGoesThroughOneSerialQueue',
    'testTheFirstByteFormWinsAndTheSecondIsNotAnError',
    'testMcpDisabledBeatsEverything',

    # ---- Phase 7（2026-10-21）：History + recent ----
    # ★ 下面每一条都在上面有**唯一**的对应变异；进不了 EXPECTED 的（只能单跑）
    #   都在 `mutate_each_mapped.py` 里登记，并在下面注明原因。
    #
    # 7c 三个写者 + 一个 metadata 写者：
    'testLocatedCoversOnlyTheReturnedWindow',            # ㊿₁₇ locate 不记 located
    'testRepeatedLocateInOneSessionRecordsLocatedOnce',   # ㊿₁₇（写入点整体消失 ⇒ 计数 0 ≠ 1）
    'testSearchRecordsLocatedForTheHitsItReturns',       # ㊿₁₈ search 不记 located
    'testLocateManyRecordsLocatedForEveryGroup',         # ㊿₁₉ locate_many 不记 located
    'testGetMetadataRecordsEverySuccessfulCall',         # ㊿₂₀ get_metadata 不记 metadata
    # 旁路：历史写失败不许影响搜索（与映射表那条规则正相反）：
    'testLocateStillSucceedsWhenHistoryCannotBeWritten',         # ㊿₁₆
    'testGetMetadataStillSucceedsWhenHistoryCannotBeWritten',    # ㊿₁₆
    # 7d recent 真执行：
    'testRecentReturnsWhatLocateJustReturned',            # ㊿₂₄ 退化成空列表
    'testRecentCollapsesRepeatedSightingsOfOneFile',      # ㊿₂₄（原 ㊿₂₅「不去重」已删，见变异处的说明）
    'testTheRecentHitCarriesExactlyFiveFields',          # ㊿₂₆ 多给字段
    'testRecentDropsSourcesThatAreNoLongerAuthorized', # ㊿₂₂ 不看本次 scope
    'testSourceIDsTightenRecentAndNeverWiden',            # ㊿₂₂
    'testRecentSkipsStaleReferencesAndWarns',             # ㊿₂₃ 不跳过 stale
    'testRecentIsEmptyNotAnErrorWhenHistoryIsNotAttached', # ㊿₂₈ 没库时报错
    'testRecentFailsWhenTheHistoryStoreIsBroken',           # ㊿₂₇ 库坏了也返回空
    'testRecentReturnsAnEmptyListWhenNothingHasBeenSeen',   # ㊿₂₉ 谎称不可用
    # 7b 库：
    'testMetadataIsRecordedEveryTime',              # ㊿₁₂ 去重扩到 metadata
    'testLocatedAndMetadataCoexist',                 # ㊿₁₂
    'testRecentIsNewestFirst',                       # ㊿₃₅ 排序反了
    'testRecentHonoursTheSourceFilter',              # ㊿₃₂ source 过滤失效
    'testRecentHonoursWithinDays',                   # ㊿₃₃ 时间窗反了
    'testRecentLimitBoundsTheCandidateSet',          # ㊿₃₄ limit 失效
    'testPruneDropsEventsOlderThanNinetyDays',      # ㊿₁₄
    'testPruneKeepsAtMostTwentyThousand',            # ㊿₁₅
    'testPruneIsIdempotent',                         # ㊿₅₄ 修剪窗口用 now 当 cutoff
    'testTheRowCarriesExactlyEightColumns',          # ㊿₃₁ 加回快照列
    'testTheRowCarriesNoSizeOrTimeSnapshot',         # ㊿₃₁
    'testAnAbsolutePathIsRejected',                     # ㊿₁₃
    'testATraversalIsRejected',                          # ㊿₁₃
    'testClearEmptiesEveryEvent',                         # ㊿₃₇ clear 不真删
    'testTheActionSetIsExactlyLocatedAndMetadata',    # ㊿₅₁ 动作集合多一个
    # 7e 生命周期闸门：
    'testTheFirstRunPrunesForReal',                    # ㊿₃₉ 每日闸门永不放行
    'testTheSecondRunOnTheSameDayTouchesNothing',         # ㊿₃₈ 每日闸门记不住
    'testANewDayOpensTheGateAgain',                    # ㊿₃₈
    'testNoHistoryStoreIsNotAFailure',                 # ㊿₄₀ 没库也算失败
    # 7a 标签：
    'testTheSessionIdIsStableWithinOneHelperProcess',   # ㊿₄₁
    'testRestartingTheHelperYieldsADifferentSessionId', # ㊿₉
    'testTheSessionIdIsNeverTheRequestId',              # ㊿₅₀ 引用判定概念
    'testTheAgentIdComesFromTheClientInfo',              # ㊿₄₅ 名字与版本写反
    'testAClientWithoutAVersionKeepsTheBareName',       # ㊿₄₃ 版本为空也拼斜杠
    'testLongLabelsAreClampedBeforeTheyReachTheStore',  # ㊿₁₀
    'testLabelsNeverCarryControlCharacters',             # ㊿₁₁
    'testALabelOfOnlyNoiseFallsBackToUnknown',           # ㊿₄₂ 空标签不降级
    'testTheContextCarriesExactlyTwoKeys',                # ㊿₄₉ context 键名写错
    'testTheContextTypeMentionsNoPathQueryOrCredential',   # ㊿₅₃ context 键名写成 query
    'testBothLabelsSurviveTheRoundTrip',                   # ㊿₅₂ 编码时丢掉 context
    'testARequestWithoutContextIsNotAnError',              # ㊿₄₇ 缺 context 就报错
    'testTheRidesNextToArgsNotInsideThem',                # ㊿₄₆ context 混进 args

    # ---- Phase 9-lite（2026-10-22）：AI 设置页成为独立一级页 ----
    'testSettingsPaneHasAtMostFourPages',                 # ㊿₅₅ AI 页改名
    'testAIIsItsOwnPaneAndSitsBeforeAdvanced',             # ㊿₅₅（顺序那条 ㊿₅₆ 走逐条）
    'testListeningIsTheOnlyHealthyState',                  # ㊿₅₇ 被占用也点绿灯
    'testNoStartResultIsNotStarted',                       # ㊿₅₈ 没启动也说正常
    'testAFailedStartCarriesTheReasonVerbatim',            # ㊿₅₉ 失败原因被吞
    'testTheOccupiedStateSaysAnotherInstanceOwnsIt',        # ㊿₆₀ 占用态不说是另一份
    'testEveryStartResultHasItsOwnWords',                   # ㊿₇₁ 两种状态同一个名字
    'testAMissingStoreIsUnavailableNotZero',                # ㊿₆₁ 打不开说成已开启
    'testEmptyHistoryCannotBeCleared',                      # ㊿₆₂ 空库也给清空按钮
    'testRecordingAndStoppedSayDifferentThings',            # ㊿₆₃ 关闭态不提旧记录
    'testTheConfirmationPromisesTheFileIDsSurvive',          # ㊿₆₄ 不提文件编号 / ㊿₆₅ 不报条数
    'testTheAISectionMovedOutOfTheAdvancedPane',             # ㊿₆₇ 清空不做二次确认
    'testTheAuthorityIsInjectedBeforeItStarts',              # ㊿₆₈ 先启动再注入
    'testTheHistoryRowReadsTheSavedSwitchAndTheRealCount',    # ㊿₆₆ / ㊿₆₉ / ㊿₇₀

    # ---- Phase 9-lite 追加：接入提示词 ----
    'testTheHelperPathFollowsTheBundle',                      # ㊿₇₂ 写死 /Applications
    'testThePromptCarriesThePathItWasGivenAndNoOther',        # ㊿₇₄ 命令写死成别的路径
    'testThePromptListsEveryWireOperation',                   # ㊿₇₅ 工具列表少一个
    'testTheSpelledOutCountMatchesTheToolList',               # ㊿₇₅ / ㊿₇₆ 不写数量
    'testThePromptPinsStdioAndEmptyArguments',                # ㊿₇₇ 参数不写留空
    'testTheThreeVerificationStepsStartWithListSources',      # ㊿₇₈ 第一步换成 search
    'testTheLocateStepRejectsPathArguments',                  # ㊿₇₈b 第 2 步诱导传路径
    'testThePromptForbidsGuessingPaths',                      # ㊿₇₉ 允许猜路径
    'testThePromptCarriesThePrivacyPromise',                  # ㊿₈₀ 去掉「不上传」
    'testThePromptCarriesNoMachineIdentifiers',               # ㊿₇₄ 混进 /Users/…
    'testTheOtherClientsNoteNamesNoClientSyntax',             # ㊿₈₁ 写了 config.toml
    'testThePromptWaitsForTheSavedGrant',                     # ㊿₈₂ 提示词挂到草稿上
    'testCopyTakesTheTextThatIsOnScreen',                     # ㊿₈₃ 复制时重新拼
    'testTheGrantGateReadsTheSavedValue',                     # ㊿₈₄ 闸自己读草稿
    # ── build 29：代码审核三项隐藏 Bug（㊿₉₉–）──
    # 本机读范围闸门（BUG-112-01）：判定本体 + 有没有接到 metadata 上，两段都要守。
    'testWholeMacAllowsAnything',                             # ㊿₁₀₀ 整台 Mac 也按文件夹拦
    'testPathInsideSelectedFolderIsAllowed',                  # ㊿₁₀₁ 范围判定反向
    'testSelectedFolderItselfIsAllowed',                      # ㊿₁₀₁ 范围判定反向
    'testPathOutsideSelectedFoldersIsRejected',               # ㊿₁₀₁ 范围判定反向
    'testSiblingSharingThePrefixIsRejected',                  # ㊿₁₀₂ 范围前缀不带分隔符
    'testEmptyFolderListRejectsEverything',                   # ㊿₁₀₃ 空文件夹列表当成全部
    # ★ ㊿₁₀₄ 的两条用例不在上面：那条变异只能单跑（与 ㊿₁₀₁ 互相抵消，
    #   见 `SINGLE_ONLY` 里的说明），逐条登记在 `mutate_each_mapped.py`。
    'testProviderHidesMetadataOfFileOutsideCurrentFolders',   # ㊿₉₉ 本机 metadata 不判范围
    'testProviderStillAnswersInsideCurrentFolders',           # ㊿₁₀₁ 范围判定反向
    'testProviderAnswersAnythingUnderWholeMacMode',           # ㊿₁₀₀ 整台 Mac 也按文件夹拦
    # 首帧预算（BUG-112-02）。另两条相关用例（中途停顿、每块续命）的变异在
    # `SINGLE_ONLY` 里，批跑里它们该是绿的，所以不登记。
    'testSlowButWithinBudgetResponseIsNotCutByTheIdleTimeout', # ㊿₁₀₅ 首帧也等读空闲超时
    # recent 去重顺序（BUG-112-03）：一个文件刷满近期访问不能挤掉别的文件。
    # ★ 唯一能打红它的变异 ㊿₁₀₈ 在 `SINGLE_ONLY` 里（必须同时改循环头与调用点，
    #   与 ㊿₂₂ 抢同一段代码），逐条登记在 `mutate_each_mapped.py`
    #   ⇒ `testOneFileFloodingHistoryDoesNotEvictAnother` **不进** `EXPECTED`。
    #   它在批跑里本来就该是绿的：批跑同时打上了按文件收敛与翻页两道防线。
    # ── Phase 10：Helper 身份 + 打包签名顺序（㊿₈₅–㊿₉₀）──
    # 这六条守的都是「编译得过、跑起来也对，只有发出去才错」的东西：
    # 版本号落后、标识符分叉、可执行名对不上、plist 混进 App 键、签名顺序反了。
    'testHelperVersionMatchesTheApp',                         # ㊿₈₅ 派生副本落后
    'testBothVersionKeysAreActuallyFilled',                   # ㊿₈₆ 构建号留空
    'testHelperIdentifierIsDerivedFromTheApp',                # ㊿₈₇ 标识符写死
    'testHelperExecutableNameMatchesThePackagedFileName',     # ㊿₈₈ 可执行名对不上
    'testHelperPlistCarriesOnlyBundleIdentityKeys',           # ㊿₈₉ 混进 App 键
    'testPackagingScriptSignsHelperBeforeTheApp',             # ㊿₉₀ 签名顺序反了
    # ── build 30：阻塞往返不许占用协作线程池（㊿₁₀₉ / ㊿₁₁₀）──
    # 公开仓 CI 首跑在 3 核 runner 上暴露的**真实并发缺陷**：`Task.detached` 跑在
    # Swift 并发的协作池上，池宽≈核心数且不允许阻塞，8 个并发就把池占满，
    # 服务端的业务 Task 抢不到线程 → 6 个请求卡满 10 秒预算。
    # 本机 10 核恒绿，所以这条只能靠**结构断言**守（跑行为是测不出来的）。
    'testTheBlockingRoundTripIsNotParkedOnACooperativeThread', # ㊿₁₀₉ 占协作池 / ㊿₁₁₀ 队列改串行
    # ── Phase 11-lite：客户端 capability 兼容清洗（㊿₉₁–㊿₉₆）──
    # ★ 「进 EXPECTED」与「有变异能打红它」必须成对：下面每一条都点了名。
    # ★ 不进 EXPECTED 的是这组里的**护栏用例**（非 initialize 原样、缺 capabilities
    #   原样、畸形 JSON 原样）。它们守的是「别乱动」，而任何变异都只会让「乱动」
    #   发生——恰是它们该绿的情形，强行登记就是永久 MISS。
    'testCodexInitializeDecodesAfterSanitizing',              # ㊿₉₁ 空转 / ㊿₉₂ 反过滤
    'testMixedExperimentalKeepsStringEntriesOnly',            # ㊿₉₂ 反过滤
    'testStringValuedExperimentalIsLeftByteIdentical',         # ㊿₉₃ 合规也重编码
    'testNonObjectExperimentalIsDroppedEntirely',             # ㊿₉₁ 空转 / ㊿₉₄ 不删
    'testTrailingNewlineIsPreserved',                         # ㊿₉₅ 丢换行
    'testSanitizingTransportRewritesIncomingInitialize',      # ㊿₉₁ 空转
    # ★ `testSanitizingTransportForwardsOutboundVerbatim` **不进 EXPECTED**：
    #   「出站原样转发」的正确实现就是「什么也不做」，没有哪个一行变异能把它改坏
    #   又保持零效应之外的可观察差异（试过 `sanitize(data)`，见上）。它留作护栏。
    'testCodexShapeInitializeIsAccepted',                     # ㊿₉₆ 忘了换包装

    # ── 2026-10-22 槽位释放（㊿₉₈）──
    # 现场：GUI 与 MCP 互相把对方挡在门外，报「这个来源正在被另一个调用方搜索」。
    # 这两条是**同一个 bug 的两个方向**（GUI→MCP、MCP→GUI），同一个变异打红：
    # 只置终态不摘槽位。必须一起进 EXPECTED —— 只登记一条，另一个方向就会在
    # 「回归了但没人知道」的状态下漂着。
    'testAnotherOwnerCanSearchAfterTheQueryCompleted',        # ㊿₉₈ 搜索结束不摘槽位
    'testTheUICanSearchAfterAnMCPQueryCompleted',             # ㊿₉₈ 同上（反方向）
    # ★ 不进 EXPECTED 的三条（护栏，不是回归）：
    #   · 'testAnotherOwnerIsStillRejectedWhileTheQueryIsReallyRunning'
    #       —— 它守的是「别把互斥一起拆掉」。㊿₉₈ 只是不摘槽位，互斥反而更强，
    #          它必然绿；也没有一行变异能让它红而编译器还过得去。
    #   · 'testLateMetadataIsStillAcceptedForTheQueryThatJustFinished' /
    #     'testTheLateMetadataWindowClosesWhenANewQueryStarts'
    #       —— 它们守「迟到补发窗口」的边界。㊿₉₈ 的锚点不在这个窗口里；
    #          单独变异窗口判据只会打红「刚结束也要放行」，而那正是修法本身。

    # ★★  deliberately 不在 EXPECTED 的用例（回归，只接受「有它比没它好」）：
    #   · 'testTheHelperPathNeverDoublesASlash'（Phase 9-lite 接入提示词）
    #       —— 它唯一的变异 `路径拼出双斜杠` 与 ㊿₇₂（写死 /Applications）锚在同一行，
    #          批跑里只能上一条 ⇒ 这条留给逐条。
    #          ★ 顺带记一笔：不能拿「字符串拼 `/Contents/…`」当变异——`URL.path`
    #          会吃掉尾部斜杠，两种写法结果一样，那是零效应变异（已实测）。
    #   · 'testTwoHelperSessionsDoNotShareTheLocatedDedup'
    #       —— 它的变异 `去重键去掉 session` 与批跑里的 `located 去重扩到 metadata`（㊿₁₂）
    #          锚在同一行，只能一条进批跑 ⇒ 这条留给逐条。
    #   · 'testLocatedIsRecordedOncePerSessionPerFile'
    #       —— 唯一能打红它的变异是「删掉 located 唯一索引」，同样锚在同一行。
    #          库级去重的行为后果已由 `testRepeatedLocateInOneSessionRecordsLocatedOnce`
    #          在批跑里守住（写入点整体消失 ⇒ 计数 0 ≠ 1）。
    #   · 'testDifferentFilesAreRecordedSeparately'
    #       —— 列闭集/去重里没有能单独打红它的单点。
    #   · 'testTheHistorySurvivesAReopen'
    #       —— 落库路径上没有单点可改（改 `COMMIT` 只会让批事务一起挂）。
    #   · 'testConcurrentWritersDoNotLockEachOtherOut'
    #       —— 它守的是「真实锁竞争下不许失败」；去掉串行队列后 WAL +
    #          busy_timeout 仍会让 8 个任务全部成功。「有没有那条队列」
    #          由源码级断言 `testEveryEntryPointGoesThroughOneSerialQueue` 守。
    #   · 'testRecentIsDisabledWhenTheMasterSwitchIsOff'
    #       —— 总开关那条规则由 `testMcpDisabledBeatsEverything` 守；
    #          这条只是把同一个结论钉在 recent 上。
    #   · 'testDifferentLabelsDoNotChangeTheAnswer'
    #       —— 「标签不参与判定」的机器执行版本是结构断言
    #          `testNoPermissionOrRoutingFileMentionsTheHistoryContext`；
    #          这条是它的行为补充，批跑里没有能单独打红它的变异。
    #   · 'testAClientWithoutANameIsUnknownWithALaunchStamp'
    #       —— 唯一能打红它的变异是 `客户端名不 trim`，而它在批跑里被
    #          `名字与版本写反` 抵消（后者把 name 换成 version ⇒ nil，
    #          那条空白名字进不了判断）⇒ 这条留给逐条。
    #   · 'testClearOutcomeKeepsSuccessApartFromFailure'（9-lite）
    #       —— 它守的是 `AIHistoryClearOutcome` 的三个 case 各自独立。
    #          删 case 或改签名都会让视图里的穷举 switch 编译不过，
    #          也就是说**没有能编译通过的变异**能打红它；
    #          「删失败不许说成已清空」这条行为由 `MCPAuthority.clearHistory`
    #          返回 `.failed` 与视图三种文案的接线断言守（源码级）。
}

# Dart 侧的期望：这些套件在对应变异下必须失败。
EXPECTED_DART = {'test_search_readiness'}


def sha(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require_swift_61() -> bool:
    """本包依赖的 MCP SDK 0.12.1 声明 `swift-tools-version:6.1`，工具链更旧时一条测试都编不起来。

    不守这一道，输出会伪装成别的问题：`red_proof` 报一长串 MISS（看着像用例太弱），
    `mutate_each` 报一长串「编译失败」（看着像变异写坏了）。两者都会把人引向
    错误的方向——这正是 v0.7 那次「红证从未真正跑通」的同一类事故。
    """
    try:
        out = subprocess.run(['swift', '--version'], capture_output=True, text=True).stdout
    except OSError:
        out = ''
    m = re.search(r'Swift version ([\d.]+)', out)
    if not m:
        print('FAIL 无法识别 swift 版本（swift 命令不可用？）')
        return False
    full = m.group(1)
    parts = [int(x) for x in full.split('.')[:2]]
    major, minor = (parts + [0, 0])[:2]
    if (major, minor) >= (6, 1):
        return True
    print(f'FAIL 本包需要 Swift 6.1+（MCP SDK 0.12.1 的 swift-tools-version 是 6.1），'
          f'当前 {full}')
    print('     硬跑的后果不是「红证变红」，而是整批测试根本没编译起来。')
    print('     用 TOOLCHAINS=<6.1+ 工具链的 CFBundleIdentifier> 再跑本脚本。')
    return False


def main() -> int:
    if not require_swift_61():
        return 1
    # ── SINGLE_ONLY 审计（复审 6.3b-2 要求）：豁免区必须显式、固定、可审计。
    # 每条 SINGLE_ONLY 变异都必须在 mutate_each_mapped.py 里有一条确定的证红路径，
    # 否则它就是一条永远没人跑的隐形豁免 —— 启动时直接拒。
    mapped_text = (CLIENT / 'tools' / 'mutate_each_mapped.py').read_text(encoding='utf-8')
    unregistered = sorted(n for n in SINGLE_ONLY if f"'{n}'" not in mapped_text)
    if unregistered:
        print('FAIL SINGLE_ONLY 里有变异没有在 mutate_each_mapped.py 登记（隐形豁免区）：')
        for name in unregistered:
            print('  ', name)
        return 1
    batch = [m for m in MUTATIONS if m[0] not in SINGLE_ONLY]
    print(f'batch mutations: {len(batch)}')
    print(f'single-only mutations: {len(SINGLE_ONLY)}')
    print(f'total registered: {len(batch) + len(SINGLE_ONLY)}')
    before = {k: sha(p) for k, p in FILES.items()}
    backup = Path(tempfile.mkdtemp(prefix='ff-red-proof-'))
    try:
        for k, p in FILES.items():
            shutil.copy2(p, backup / k)

        batch = [m for m in MUTATIONS if m[0] not in SINGLE_ONLY]
        for _, path, old, new in batch:
            text = path.read_text(encoding='utf-8')
            if old not in text:
                print(f'FAIL 变异标记没找到：{path.name}: {old[:50]}')
                return 1
            path.write_text(text.replace(old, new, 1), encoding='utf-8')
        print(f'{len(batch)} 处变异已应用'
              f'（另有 {len(SINGLE_ONLY)} 条只单跑：{", ".join(sorted(SINGLE_ONLY))}）')

        # ★ 必须钉 `--only-use-versions-from-resolved-file`：不钉的话 SwiftPM 会按当前
        #   manifest 重新解析，把 `Package.resolved` 里冻结的版本**改掉**
        #   （2026-10-21 实测：swift-log 1.15.1 → 1.11.0，六条 pin 一起漂）。
        #   红证是「同一份依赖下的红」，依赖漂了，跑出来的红就不属于这次变异。
        result = subprocess.run(['swift', 'test', '--only-use-versions-from-resolved-file'],
                                cwd=CLIENT, capture_output=True, text=True)
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
        # 注：批跑是**叠加环境**（一次应用全部变异），failed 里必然还有大量
        # EXPECTED 之外的测试红——「只有 EXPECTED 红」不是批跑的契约。
        # 「这一个变异确实能被某条具名用例抓住」由 mutate_each_mapped.py 逐条保证。

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

