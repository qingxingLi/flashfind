import XCTest
@testable import FlashFindCore

/// 添加搜索来源向导的分页判定。
///
/// ★ 这一组守的是 2026-10-28 用户报的那条：界面标题写着「共 4 步」，
/// 而用户数出来只有三步 —— 选来源 → 点连接 → 选位置。
/// 步数与页码文案从此只在 Core 出，视图里再写死一遍就会被这里和结构断言抓到。
final class SourceWizardFlowTests: XCTestCase {

    func testTheWizardHasExactlyThreeSteps() {
        XCTAssertEqual(SourceWizardFlow.stepCount, 3,
                       "选来源 → 连接信息 → 搜索位置，写四步是错的")
        XCTAssertEqual(SourceWizardPage.allCases.map(\.rawValue), [1, 2, 3],
                       "页码必须从 1 连续排到 3")
    }

    func testSubtitleReadsStepOfTotal() {
        XCTAssertEqual(SourceWizardFlow.subtitle(for: .source), "第 1 步，共 3 步")
        XCTAssertEqual(SourceWizardFlow.subtitle(for: .connection), "第 2 步，共 3 步")
        XCTAssertEqual(SourceWizardFlow.subtitle(for: .scope), "第 3 步，共 3 步")
        // 步数只有一个来源：改 `stepCount` 时文案必须跟着变，不许各写各的。
        for page in SourceWizardPage.allCases {
            XCTAssertTrue(SourceWizardFlow.subtitle(for: page)
                .hasSuffix("共 \(SourceWizardFlow.stepCount) 步"))
        }
    }

    func testEnteringPageSkipsWhatIsAlreadyDone() {
        XCTAssertEqual(SourceWizardFlow.enteringPage(isEditing: false, isConnected: false), .source,
                       "新建来源从选来源开始")
        XCTAssertEqual(SourceWizardFlow.enteringPage(isEditing: true, isConnected: false), .connection,
                       "编辑已有来源：品牌不能改，直接给连接信息")
        XCTAssertEqual(SourceWizardFlow.enteringPage(isEditing: true, isConnected: true), .scope,
                       "编辑一台在线的来源：唯一还要做的事是选位置")
        XCTAssertEqual(SourceWizardFlow.enteringPage(isEditing: false, isConnected: true), .scope,
                       "已连接就去选位置——停在选来源页等于让用户重选一遍")
    }

    func testDirectionTellsWhichWayThePageTurns() {
        XCTAssertEqual(SourceWizardFlow.direction(from: .source, to: .connection), 1)
        XCTAssertEqual(SourceWizardFlow.direction(from: .scope, to: .source), -1)
        XCTAssertEqual(SourceWizardFlow.direction(from: .connection, to: .connection), 0)
    }

    func testBackIsOnlyOfferedOnTheSecondPageOfANewSource() {
        XCTAssertTrue(SourceWizardFlow.canGoBack(from: .connection, isEditing: false))
        XCTAssertFalse(SourceWizardFlow.canGoBack(from: .source, isEditing: false))
        XCTAssertFalse(SourceWizardFlow.canGoBack(from: .scope, isEditing: false),
                       "从搜索位置退回去等于断开重连，那是底部的「断开」，不是翻页")
        XCTAssertFalse(SourceWizardFlow.canGoBack(from: .connection, isEditing: true),
                       "编辑模式没有「来源选择」那一页，没有可退的地方")
    }

    func testOnlyTheFirstPageAdvancesByPicking() {
        XCTAssertTrue(SourceWizardFlow.advancesByPickingOnly(.source))
        XCTAssertFalse(SourceWizardFlow.advancesByPickingOnly(.connection),
                       "连接信息要用户按下「连接」，不能点一下就跳走")
        XCTAssertFalse(SourceWizardFlow.advancesByPickingOnly(.scope))
    }

    func testDisconnectingSendsTheUserBackToConnection() {
        XCTAssertEqual(SourceWizardFlow.page(afterDisconnectingFrom: .scope), .connection,
                       "断开之后位置列表没了，必须退回连接信息，不能停在空白页")
        XCTAssertEqual(SourceWizardFlow.page(afterDisconnectingFrom: .connection), .connection)
        XCTAssertEqual(SourceWizardFlow.page(afterDisconnectingFrom: .source), .source)
    }

    // MARK: 连接信息页的字段文案

    func testConnectionLabelsFollowTheVendor() {
        let synology = SourceConnectionLabels.forVendor(.synology)
        let openlist = SourceConnectionLabels.forVendor(.openlist)

        XCTAssertEqual(synology.addressLabel, "IP/域名")
        XCTAssertEqual(openlist.addressLabel, "站点地址",
                       "OpenList 要的是整条站点地址，说「IP/域名」会让人只填一段主机名")
        XCTAssertNotEqual(synology.addressLabel, openlist.addressLabel,
                          "各来源的字段本来就不一样，不许一套文案套所有品牌")
        XCTAssertTrue(openlist.addressPlaceholder.hasPrefix("https://"),
                      "OpenList 的地址是带协议的整条 URL")
        XCTAssertTrue(synology.addressPlaceholder.hasPrefix("192.0.2."),
                      "群晖给的是 IP 例子（192.0.2.0/24 是文档专用网段）")

        XCTAssertEqual(synology.portPlaceholder, "5001")
        XCTAssertEqual(openlist.portPlaceholder, "5244", "OpenList 默认 5244")
    }

    func testEveryVendorHasReadableLabels() {
        for vendor in NASSourceConfig.Vendor.allCases {
            let labels = SourceConnectionLabels.forVendor(vendor)
            XCTAssertFalse(labels.addressLabel.isEmpty, "\(vendor.rawValue) 的地址标签是空的")
            XCTAssertFalse(labels.addressPlaceholder.isEmpty, "\(vendor.rawValue) 的地址占位是空的")
        }
    }

    /// 没把握默认端口的品牌**不许编一个数字**。
    ///
    /// 占位符里的数字会被用户当成默认值照抄；猜错就是一个必然失败的连接。
    func testNoInventedPortWhereThereIsNoKnownDefault() {
        XCTAssertEqual(SourceConnectionLabels.forVendor(.generic).portPlaceholder, "")
        XCTAssertEqual(SourceConnectionLabels.forVendor(.ugreen).portPlaceholder, "")
    }
}
