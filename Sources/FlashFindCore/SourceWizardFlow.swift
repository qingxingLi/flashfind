import Foundation

/// 「添加搜索来源」向导的一页。
///
/// ★ **三步，不是四步**（2026-10-28 用户报障）。
///
/// 原来「选来源」与「填连接信息」同屏，进度条却把选来源（第 1 步）、
/// 点设备/手填地址（第 2 步）、连接信息、选搜索位置算成四步 ——
/// 用户数出来只有三步：选来源 → 点连接 → 选位置。
/// 现在两者分成两页，页数就是三步，不多不少。
public enum SourceWizardPage: Int, CaseIterable, Sendable {
    /// 第 1 步：只列搜索来源，选中即翻页。
    case source = 1
    /// 第 2 步：连接信息（按来源不同而不同）。
    case connection = 2
    /// 第 3 步：搜索位置。
    case scope = 3
}

/// 向导分页的判定。
///
/// 全部是纯函数：页码、页数、翻页方向、能不能回退。
/// 视图只负责「问一句、照着画」——写进 App 层就再也测不了了。
public enum SourceWizardFlow {
    /// 总步数。**只此一处**：界面上那句「第 N 步，共 M 步」的 M 由它算出来。
    public static let stepCount = SourceWizardPage.allCases.count

    /// 标题下面那行进度。
    ///
    /// 已连接之后不再报步数：那时页面在讲「选位置」，报「第 3 步」只会
    /// 让人去找第 4 步。连接中与已连接的说法由视图另给。
    public static func subtitle(for page: SourceWizardPage) -> String {
        "第 \(page.rawValue) 步，共 \(stepCount) 步"
    }

    /// 打开向导时落在哪一页。
    ///
    /// - 已连接：直接给搜索位置。这时选来源与填账号都已经没有意义
    ///   （预览钩子造出来的草稿就是这一种，编辑一台在线来源也是）。
    /// - 编辑已有来源：跳过选来源（品牌不能改，改了等于换一台机器）。
    /// - 新建：从选来源开始。
    public static func enteringPage(isEditing: Bool, isConnected: Bool) -> SourceWizardPage {
        if isConnected { return .scope }
        return isEditing ? .connection : .source
    }

    /// 翻页方向：`+1` 前进、`-1` 后退、`0` 不动。
    ///
    /// 视图用它决定新页面从右边进来还是从左边进来（翻页的手感）。
    public static func direction(from current: SourceWizardPage,
                                 to target: SourceWizardPage) -> Int {
        let delta = target.rawValue - current.rawValue
        return delta == 0 ? 0 : (delta > 0 ? 1 : -1)
    }

    /// 这一页能不能往后退一步。
    ///
    /// 只有新建来源的第一、二页可以退：编辑模式没有「来源选择」那一页，
    /// 而搜索位置页退回去等于断开重连——那是底部的「断开」，不是翻页。
    public static func canGoBack(from page: SourceWizardPage, isEditing: Bool) -> Bool {
        guard !isEditing else { return false }
        return page == .connection
    }

    /// 断开连接之后该停在哪一页。
    ///
    /// 在第 3 步点「断开」时，位置列表会整块消失（它只在已连接时才有）。
    /// 若停在原地，用户看到的就是「一整页空白 + 灰掉的完成」——
    /// 必须退回连接信息，让他重新连或改地址。
    public static func page(afterDisconnectingFrom page: SourceWizardPage) -> SourceWizardPage {
        page == .scope ? .connection : page
    }

    /// 两页之间那一步是不是「点一下就走」的翻页（不需要按按钮）。
    ///
    /// 第 1 步是：点一张来源卡就翻过去。其余各页都要用户按下按钮
    /// （连接 / 完成），所以底部按钮的显隐看这个。
    public static func advancesByPickingOnly(_ page: SourceWizardPage) -> Bool {
        page == .source
    }
}

/// 连接信息页上那几个字段的名字。
///
/// ★ 各来源的字段**本来就不一样**：OpenList 要的是「站点地址」（带 `https://`
/// 的整条 URL），群晖要的是「IP / 域名」；端口的常见值也不同。
/// 原来这些字都写死在视图里，于是 OpenList 的用户看到的是群晖的 `5001`。
/// 现在按来源取，文案跟着能力走。
public struct SourceConnectionLabels: Equatable, Sendable {
    public let addressLabel: String
    public let addressPlaceholder: String
    public let portPlaceholder: String

    public static func forVendor(_ vendor: NASSourceConfig.Vendor) -> SourceConnectionLabels {
        switch vendor {
        case .openlist:
            // OpenList（含 Alist）默认跑在 5244，见发布说明 1.1.8。
            return SourceConnectionLabels(addressLabel: "站点地址",
                                          addressPlaceholder: "https://openlist.example.com",
                                          portPlaceholder: "5244")
        case .webdav:
            // 飞牛的 WebDAV 文件服务常见 5005（Core 的 `Vendor.supportMessage` 同口径）。
            return SourceConnectionLabels(addressLabel: "服务器地址",
                                          addressPlaceholder: "https://nas.example.com",
                                          portPlaceholder: "5005")
        case .smb:
            return SourceConnectionLabels(addressLabel: "服务器地址",
                                          addressPlaceholder: "192.0.2.96",
                                          portPlaceholder: "445")
        case .synology:
            return SourceConnectionLabels(addressLabel: "IP/域名",
                                          addressPlaceholder: "192.0.2.96",
                                          portPlaceholder: "5001")
        default:
            // 端口不给例子：猜一个数字上去，用户会当成「默认值」照抄。
            return SourceConnectionLabels(addressLabel: "IP/域名",
                                          addressPlaceholder: "192.0.2.96",
                                          portPlaceholder: "")
        }
    }
}
