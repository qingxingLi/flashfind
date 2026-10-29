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
        // 已验证：群晖（原生路径）+ WebDAV（真机跑通）+ 飞牛（2026-10-29 转正）。
        for vendor in [NASSourceConfig.Vendor.synology, .webdav, .fnos] {
            XCTAssertEqual(vendor.adapterStatus, .deviceVerified, "\(vendor.title) 应已真机验证")
        }
        // 已接入但无真机证据。
        //
        // 只剩 qnap / ugreen：有适配器，但真机上没跑过。
        //
        // ★ 飞牛 2026-10-29 离开这一档：它在用户真实设备上跑通
        // 浏览器授权码登录 → 列共享 → 原生搜索 → 打开结果（1.1.32–1.1.44 连发版
        // 全部以它为验证对象），同一轮用户把它从实验性移进正式来源。
        // 状态与 `selectableVendors` 必须同步 —— 只改一处会得到
        // 「向导里能选、说明却说没验过」的自相矛盾。
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen] {
            XCTAssertEqual(vendor.adapterStatus, .portedUnverified, "\(vendor.title) 应为「已接入未验证」")
        }
        for vendor in [NASSourceConfig.Vendor.smb, .generic] {
            XCTAssertEqual(vendor.adapterStatus, .notPorted, "\(vendor.title) 应为「未接入」")
        }
        // 「接入过、已证伪并下线」这一档现在**没有成员**，但枚举项不能删 ——
        // 它是三态区分的一半，下一个被真机证伪的品牌要有地方落。
        // 这里锁的是「此刻没人在这一档」：将来谁被塞进来会红，逼着连文案一起改，
        // 而不是被人悄悄降级成「未验证」蒙过去。
        for vendor in NASSourceConfig.Vendor.allCases {
            XCTAssertNotEqual(vendor.adapterStatus, .retired,
                              "\(vendor.title) 被标成已下线，supportMessage 与选型文案必须同步改回「试过、证伪」口径")
        }
    }

    /// 飞牛不再是「已下线」，但也不能被说成「支持」——
    /// 它现在是**正式来源**，文案必须是产品口径（讲能力），而不是验收口径（讲验证过程）。
    ///
    /// 这条替换了原先的 `testFnOSIsPortedAgainAndSaysItIsNotPasswordLogin`
    /// 与更早的 `testRetiredVendorMessageDoesNotSoundLikeWorkInProgress`。
    /// 那两版分别锁「已下线」与「已接入未验证」的正确措辞；飞牛转正后，
    /// 如果还留着旧断言，就会把一条正式功能重新说成半成品。
    func testFnOSIsFullySupportedAndSaysItIsNotPasswordLogin() {
        let vendor = NASSourceConfig.Vendor.fnos
        let message = vendor.supportMessage
        XCTAssertFalse(message.contains("下线"),
                       "飞牛已接入并验证，不能再告诉用户适配器下线了：\(message)")
        XCTAssertFalse(message.contains("没在真机上验证过"),
                       "飞牛已是正式来源，不该再说未验证：\(message)")
        XCTAssertTrue(message.contains("原生搜索"),
                      "飞牛有服务端文件名索引，说明里应讲这项能力：\(message)")

        // 飞牛官方协议里没有账号密码换 token 这条路（OAuth 授权码 + PKCE，
        // 授权页不回跳，code 要用户手动交出）。指引里必须提前讲明，
        // 否则用户会照着「用 NAS 账号登录」的惯性去填密码然后连不上。
        XCTAssertTrue(vendor.serviceHint.contains("浏览器"),
                      "必须说明要开浏览器授权：\(vendor.serviceHint)")
        XCTAssertTrue(vendor.serviceHint.contains("没有账号密码"),
                      "必须明说没有密码直连这条路：\(vendor.serviceHint)")
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

    /// 已验证的品牌里，**原生搜索可用**的恰好是群晖、OpenList、飞牛。
    ///
    /// 2026-10-24 起 OpenList 也进了这一档：它在真实实例（v4.1.10）上
    /// 验过 `/api/fs/search` 的限定目录检索与分页，属「已验证 + 有原生搜索」。
    /// 2026-10-29 飞牛转正：真机跑通 `appcgi.finder.fileSearch` 的整条链路。
    /// 断言逐项锁死 —— 不是放宽成「至少一个」，否则将来误加第四个品牌也测不出来。
    func testNativeSearchVerifiedVendorsAreExactlyTheThreeFormalOnes() {
        let actual = Set(NASSourceConfig.Vendor.allCases
            .filter { $0.adapterStatus == .deviceVerified && $0.hasNativeSearch }
            .map(\.rawValue))
        XCTAssertEqual(actual, ["synology", "fnos", "openlist"],
                       "已验证且有原生搜索的品牌集合变了，需同步核对证据：\(actual.sorted())")
    }

    /// 是否能连接由 `hasAdapter` 决定，而不是 `nativelySupported`。
    /// 否则已接入的品牌会被挡在连接按钮外。
    func testConnectGateUsesHasAdapterNotNativeSupport() {
        // 未真机验证的两家：能连（有适配器），但不是 native。
        for vendor in [NASSourceConfig.Vendor.qnap, .ugreen] {
            XCTAssertTrue(vendor.hasAdapter, "\(vendor.title) 已接适配器，应允许连接")
            XCTAssertFalse(vendor.nativelySupported, "\(vendor.title) 尚未真机验证，不是 native")
        }
        // WebDAV 另一回事：真机验证过，但协议没有服务端搜索。
        XCTAssertTrue(NASSourceConfig.Vendor.webdav.hasAdapter)
        XCTAssertFalse(NASSourceConfig.Vendor.webdav.nativelySupported,
                       "已验证 ≠ 有原生搜索")
        XCTAssertFalse(NASSourceConfig.Vendor.generic.hasAdapter)
        XCTAssertFalse(NASSourceConfig.Vendor.smb.hasAdapter)
        // ★ 飞牛现在是正式来源：适配器在、真机验证过、有原生搜索。
        // 这三条一起锁，防止有人把状态改回「未验证」却没动选型列表
        // （那会让向导里能选、说明却说没验过）。
        XCTAssertTrue(NASSourceConfig.Vendor.fnos.hasAdapter)
        XCTAssertTrue(NASSourceConfig.Vendor.fnos.nativelySupported,
                      "飞牛已真机验证且有服务端搜索，应算 native")
        // 正式来源**不依赖**实验性开关：关着、开着都在，而且只出现一次
        // （它已经在 `selectableVendors` 基线里，实验分支不该再追加一遍）。
        for including in [false, true] {
            let listed = ExperimentalSources.vendors(includingExperimental: including)
            XCTAssertTrue(listed.contains(.fnos),
                          "飞牛已转正，实验开关=\(including) 时都该在选型里")
            XCTAssertEqual(listed.filter { $0 == .fnos }.count, 1,
                           "实验开关打开后不该把飞牛重复追加一次")
        }
    }

    /// 「已接入 + 已验证 + 有原生搜索」的集合恰好是群晖、OpenList、飞牛。
    ///
    /// 其余一律不得出现在这里：WebDAV 已验证但无服务端搜索，
    /// qnap / ugreen 未真机验证，smb / generic 未接入。
    /// 这正是 `hasNativeSearch` 与 `adapterStatus` 必须分开的理由 ——
    /// 只看前者会把 WebDAV 说成原生搜索可用，只看后者又说不出它没有。
    func testNativelySupportedVendorsAreExactlyTheThreeFormalOnes() {
        XCTAssertEqual(NASSourceConfig.Vendor.allCases.filter(\.nativelySupported),
                       [.synology, .fnos, .openlist])
    }

    func testOnlySynologyIsNativelySupported() {
        XCTAssertTrue(NASSourceConfig.Vendor.synology.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.qnap.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.ugreen.nativelySupported)
        XCTAssertFalse(NASSourceConfig.Vendor.generic.nativelySupported)
    }

    /// 选型开放「群晖 + 飞牛 + OpenList」。其余品牌**撤下选型不等于删除** ——
    /// 枚举仍完整，旧配置仍能解码，以后要再开放也不用重建模型。
    ///
    /// 顺序即界面上卡片的顺序（群晖 / 飞牛 / OpenList / 附近的设备）：
    /// 用户 2026-10-29 要求把飞牛从实验性移进正式来源，顺带说明了它该排在
    /// 两个「原生支持」的老成员之间。
    func testWizardOffersTheThreeFormalVendors() {
        XCTAssertEqual(NASSourceConfig.Vendor.selectableVendors, [.synology, .fnos, .openlist])
        XCTAssertEqual(NASSourceConfig.Vendor.allCases.count, 8,
                       "撤下选型不该删枚举项，否则已保存的旧配置会解不出来")
    }

    /// 正式开放的三家各有一枚**自己的**品牌标记，其余品牌没有（界面回落 SF Symbol）。
    ///
    /// 「哪家该有专属标记」是产品判断，所以锁在 Core：漏配一枚时界面会静默显示
    /// 一个通用硬盘符号 —— 那种缺失没人会报告，只会觉得「图标没做」。
    /// 图形本身画在 App 层（`VendorMarkView`），只能靠截图验。
    func testFormalVendorsEachHaveTheirOwnMark() {
        XCTAssertEqual(NASSourceConfig.Vendor.selectableVendors.compactMap(\.mark),
                       [.synology, .fnos, .openlist],
                       "正式开放的三家必须有专属标记，顺序与卡片一致")

        // 反过来锁一遍：进了正式列表却没标记 = 卡片上会是个泛化符号。
        for vendor in NASSourceConfig.Vendor.selectableVendors {
            XCTAssertNotNil(vendor.mark, "\(vendor.title) 在正式列表里，却没有品牌标记")
        }
        // 标记不许两家共用一张图（共用等于没做区分）。
        let marks = NASSourceConfig.Vendor.allCases.compactMap(\.mark)
        XCTAssertEqual(Set(marks).count, marks.count, "两个品牌共用了同一个标记")
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
