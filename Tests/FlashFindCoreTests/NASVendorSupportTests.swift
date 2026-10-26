import XCTest
@testable import FlashFindCore

/// 品牌接入状态与「怎么说给用户听」。
///
/// 结构就绪 ≠ 真机验证过 ≠ 曾被证伪，这三档必须分开表达：
/// 说成「支持」是在对没验过的设备打包票，说成「不支持」又把已经接进来的
/// 适配器抹掉。下面锁的是每一档的判定和措辞。
final class NASVendorSupportTests: XCTestCase {

    /// 接入状态分四档：**结构就绪 ≠ 真机验证过 ≠ 曾被证伪**。
    ///
    /// 「适配器已移植」和「能用」必须分开说：既不能说成「支持」，
    /// 也不能说成「不支持」。已下线那一档与「从未接入」的区别也要留住——
    /// 后者给人的预期是「等等就有了」，前者是一次已经做完的结论。
    func testAdapterStatusKeepsRetiredSeparateFromNeverPorted() {
        // 已验证：群晖（原生路径）+ WebDAV（真机跑通）。
        for vendor in [NASSourceConfig.Vendor.synology, .webdav] {
            XCTAssertEqual(vendor.adapterStatus, .deviceVerified, "\(vendor.title) 应已真机验证")
        }
        // 已接入但无真机证据。
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen] {
            XCTAssertEqual(vendor.adapterStatus, .portedUnverified, "\(vendor.title) 应为「已接入未验证」")
        }
        // 接入过、已证伪并下线：不能与「未接入」混为一谈。
        XCTAssertEqual(NASSourceConfig.Vendor.fnos.adapterStatus, .retired,
                       "飞牛已从核心下线，不再是「未验证」那一档")
        for vendor in [NASSourceConfig.Vendor.smb, .generic] {
            XCTAssertEqual(vendor.adapterStatus, .notPorted, "\(vendor.title) 应为「未接入」")
        }
    }

    /// 已下线的品牌，说明必须说清是**试过、证伪了**，而不是「还没做」。
    func testRetiredVendorMessageDoesNotSoundLikeWorkInProgress() {
        let message = NASSourceConfig.Vendor.fnos.supportMessage
        XCTAssertTrue(message.contains("下线"), "必须明说适配器已下线：\(message)")
        XCTAssertFalse(message.contains("还没接进闪寻"),
                       "已下线 ≠ 没接入，说成后者会让人以为等一等就有：\(message)")
        // 指一条真能走通的路，别只把门关上。
        XCTAssertTrue(message.contains("WebDAV"), "必须给出可替代的协议：\(message)")
    }

    /// 「已接入未验证」的说明必须同时讲清两件事：
    /// 适配器在、且**没在真机上验证过**。少讲任何一件都会误导用户。
    func testPortedUnverifiedMessageIsHonest() {
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen] {
            let message = vendor.supportMessage
            XCTAssertTrue(message.contains("已经接进闪寻"), "\(vendor.title) 应说明适配器已接入：\(message)")
            XCTAssertTrue(message.contains("没在真机上验证过"),
                          "\(vendor.title) 必须说清未真机验证：\(message)")
        }
    }

    /// WebDAV 已真机验证，但它**没有服务端搜索** —— 这两件事必须分开表达。
    ///
    /// 最容易做错的地方就是把「已验证」直接等同于「原生搜索可用」，
    /// 那样界面对 WebDAV 就是在说假话。
    func testWebDAVVerifiedButHasNoServerSearch() {
        let vendor = NASSourceConfig.Vendor.webdav
        XCTAssertEqual(vendor.adapterStatus, .deviceVerified)
        XCTAssertTrue(vendor.hasAdapter)
        XCTAssertFalse(vendor.hasNativeSearch, "WebDAV 没有服务端搜索")
        XCTAssertFalse(vendor.nativelySupported, "已验证 ≠ 原生搜索可用")
        XCTAssertTrue(vendor.supportMessage.contains("不提供服务端搜索"),
                      "必须说明搜索受限：\(vendor.supportMessage)")
    }

    /// 已验证的品牌里，**原生搜索可用**的恰好是群晖与 OpenList。
    ///
    /// 2026-10-24 起 OpenList 也进了这一档：它在真实实例（v4.1.10）上
    /// 验过 `/api/fs/search` 的限定目录检索与分页，属「已验证 + 有原生搜索」。
    /// 断言从「只有群晖」改成「恰好这两个」——成员仍然逐个锁死，
    /// 不是放宽成「至少一个」，否则将来误加第三个品牌也测不出来。
    func testNativeSearchVerifiedVendorsAreExactlySynologyAndOpenList() {
        let actual = Set(NASSourceConfig.Vendor.allCases
            .filter { $0.adapterStatus == .deviceVerified && $0.hasNativeSearch }
            .map(\.rawValue))
        XCTAssertEqual(actual, ["synology", "openlist"],
                       "已验证且有原生搜索的品牌集合变了，需同步核对证据：\(actual.sorted())")
    }

    /// 是否能连接由 `hasAdapter` 决定，而不是 `nativelySupported`。
    /// 否则已接入的品牌会被挡在连接按钮外。
    func testConnectGateUsesHasAdapterNotNativeSupport() {
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen, .webdav] {
            XCTAssertTrue(vendor.hasAdapter, "\(vendor.title) 已接适配器，应允许连接")
            XCTAssertFalse(vendor.nativelySupported, "\(vendor.title) 尚未真机验证，不是 native")
        }
        XCTAssertFalse(NASSourceConfig.Vendor.generic.hasAdapter)
        XCTAssertFalse(NASSourceConfig.Vendor.smb.hasAdapter)
        // 已下线 = 没有可用适配器：核心已经不认它，界面放行只会拿到一句失败。
        XCTAssertFalse(NASSourceConfig.Vendor.fnos.hasAdapter,
                       "飞牛适配器已下线，不该再算「有适配器」")
        XCTAssertFalse(ExperimentalSources.vendors(includingExperimental: true).contains(.fnos),
                       "核心已不认飞牛，打开实验性开关也不该把它摆出来")
    }

    /// 「已接入 + 已验证 + 有原生搜索」的集合恰好是群晖与 OpenList。
    ///
    /// 其余一律不得出现在这里：WebDAV 已验证但无服务端搜索，
    /// qnap / ugreen 未真机验证，fnos 已下线，smb / generic 未接入。
    func testNativelySupportedVendorsAreExactlySynologyAndOpenList() {
        XCTAssertEqual(NASSourceConfig.Vendor.allCases.filter(\.nativelySupported),
                       [.synology, .openlist])
    }

    func testOnlySynologyIsNativelySupported() {
        XCTAssertTrue(NASSourceConfig.Vendor.synology.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.qnap.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.ugreen.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.generic.nativelySupported)
    }

    /// 选型开放「群晖 + OpenList」。其余品牌**撤下选型不等于删除** ——
    /// 枚举仍完整，旧配置仍能解码，以后要再开放也不用重建模型。
    func testWizardOffersSynologyAndOpenList() {
        XCTAssertEqual(NASSourceConfig.Vendor.selectableVendors, [.synology, .openlist])
        XCTAssertEqual(NASSourceConfig.Vendor.allCases.count, 8,
                       "撤下选型不该删枚举项，否则已保存的旧配置会解不出来")
    }

    /// 群晖在界面上显示的两段文案里，不能再出现「真机 / 已接入 / 上游 / 移植 / 校准」
    /// 这类只有开发与验收阶段才用的措辞 —— 用户看到的是产品，不是验收报告。
    func testSynologyUserFacingCopyHasNoQALanguage() {
        let vendor = NASSourceConfig.Vendor.synology
        for text in [vendor.supportMessage, vendor.serviceHint] {
            for banned in ["真机", "已接入", "接进闪寻", "上游", "移植", "校准"] {
                XCTAssertFalse(text.contains(banned),
                               "群晖文案不该出现「\(banned)」：\(text)")
            }
        }
    }

    /// 撤下 WebDAV 选型后，群晖的选型指引不能再让用户「改选 WebDAV」——
    /// 那会指向一个界面上已经不存在的选项。
    func testSynologyHintNoLongerPointsAtRemovedWebDAVOption() {
        let hint = NASSourceConfig.Vendor.synology.serviceHint
        XCTAssertFalse(hint.contains("WebDAV"),
                       "群晖指引不该再提已撤下的 WebDAV 选项：\(hint)")
    }

    /// 待接入的说明必须点名上游适配器。
    ///
    /// 用户听到「上游已经有 FnOSAdapter，移植过来就能用」与听到「暂不支持」，
    /// 是完全不同的感受——前者是进度，后者像产品限制。
    ///
    /// 范围只到 `notPorted`：已接入的品牌说的是「已接入但未真机验证」，
    /// 不再走「还没接进闪寻」那套话，所以本条对它们不适用。
    func testPendingVendorMessageNamesUpstreamAdapter() {
        for vendor in NASSourceConfig.Vendor.allCases {
            let message = vendor.supportMessage
            XCTAssertFalse(message.isEmpty, "\(vendor.title) 缺少接入状态说明")
            // 不允许出现把「还没移植」说成能力边界的措辞。
            XCTAssertFalse(message.contains("走群晖 DSM 接口"), "\(vendor.title)：\(message)")
            XCTAssertFalse(message.contains("只支持群晖"), "\(vendor.title)：\(message)")
            guard vendor.adapterStatus == .notPorted else { continue }
            if let adapter = vendor.upstreamAdapter {
                XCTAssertTrue(message.contains("还没接进闪寻"), "\(vendor.title)：\(message)")
                XCTAssertTrue(message.contains(adapter),
                              "\(vendor.title) 的说明里应点名上游适配器 \(adapter)：\(message)")
            } else {
                // 「其他 NAS」这类没有具体上游适配器的，也要给一句可行动的说明。
                XCTAssertTrue(message.contains("保存"), "\(vendor.title)：\(message)")
            }
        }
    }

    /// endpoint 的协议：群晖/WebDAV 走 https，国产三家的管理口默认明文 http。
    func testDefaultSchemePerVendor() {
        for vendor in [NASSourceConfig.Vendor.qnap, .fnos, .ugreen] {
            XCTAssertTrue(vendor.defaultInsecureHTTP, "\(vendor.title) 管理口出厂即明文")
        }
        for vendor in [NASSourceConfig.Vendor.synology, .webdav] {
            XCTAssertFalse(vendor.defaultInsecureHTTP, "\(vendor.title) 默认走 https")
        }
    }

    /// 品牌列表要覆盖上游 MyNAS 已有的存储类适配器，否则用户根本选不到。
    func testVendorListCoversUpstreamStorageSources() {
        let raws = Set(NASSourceConfig.Vendor.allCases.map(\.rawValue))
        for expected in ["synology", "qnap", "ugreen", "fnos", "webdav", "smb"] {
            XCTAssertTrue(raws.contains(expected), "缺少上游已有适配器的类型：\(expected)")
        }
    }
}
