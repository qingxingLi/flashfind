import XCTest
@testable import FlashFindCore

/// 设备名称（来源名）的规则。
///
/// 名字是唯一一个「用户随时想改、而改它不该有任何副作用」的配置字段。
/// 这一组用例钉住两件事：
/// 1. 输入什么能存下来（换行、空格、清空）；
/// 2. 改名与「换了台设备」在判定上必须分得开 —— 后者会踢掉登录态。
@MainActor final class NASSourceRenameTests: XCTestCase {

    // MARK: - 输入 → 落盘

    /// 换行与制表折成**一个**空格：名字处处单行展示，带换行会当场错行。
    func testNormalizedFlattensLineBreaksIntoSingleSpace() {
        XCTAssertEqual(NASSourceRename.normalized("客厅\nNAS"), "客厅 NAS")
        XCTAssertEqual(NASSourceRename.normalized("客厅\r\nNAS"), "客厅 NAS",
                       "\\r\\n 是一个换行，折成两个空格会在名字里平白多一格")
        XCTAssertEqual(NASSourceRename.normalized("客厅\n\nNAS"), "客厅 NAS")
        XCTAssertEqual(NASSourceRename.normalized("客厅\tNAS"), "客厅 NAS")
        // 粘贴一整段说明当名字：不能出现换行，其余原样保留。
        XCTAssertEqual(NASSourceRename.normalized("书房\nNAS\r\n备用"), "书房 NAS 备用")
    }

    /// ★ 首尾空格**不许**被吃掉。
    ///
    /// 界面是逐键落盘的：若这里 trim，用户输 `NAS ` 时存成 `NAS`、输入框跟着变回 `NAS`，
    /// 接着输 `01` 就得到 `NAS01` —— 「名字里打不出空格」正是这么来的。
    func testNormalizedKeepsSpacesSoUsersCanTypeThem() {
        XCTAssertEqual(NASSourceRename.normalized("NAS "), "NAS ")
        XCTAssertEqual(NASSourceRename.normalized(" 客厅 NAS"), " 客厅 NAS")
        XCTAssertEqual(NASSourceRename.normalized("客厅  NAS"), "客厅  NAS",
                       "中间连续两个空格是用户自己的排版，不做折叠")
    }

    /// 空串是合法状态：展示层（`displayName`）会回落成品牌名。
    func testEmptyNameMeansDefault() {
        XCTAssertEqual(NASSourceRename.normalized(""), "")
        var config = NASSourceConfig(id: "A", name: "", host: "nas.example", port: 5001,
                                     username: "u", scopes: ["/share"])
        XCTAssertEqual(config.displayName, config.vendor.title)
        config.name = "   "
        XCTAssertEqual(config.displayName, config.vendor.title, "整串空白也算「用默认名」")
    }

    // MARK: - 是否算一次改名

    /// 真的改了才写盘。
    func testIsRenameComparesStoredText() {
        XCTAssertTrue(NASSourceRename.isRename(stored: "NAS", to: "客厅 NAS"))
        XCTAssertFalse(NASSourceRename.isRename(stored: "NAS", to: "NAS"))
        XCTAssertFalse(NASSourceRename.isRename(stored: "", to: ""))
        // 换行折叠之后与已存内容相同（粘贴了带换行的同名），不该写盘。
        XCTAssertFalse(NASSourceRename.isRename(stored: "客厅 NAS", to: "客厅\nNAS"))
    }

    /// ★ 逐键落盘的关键一步：**尾空格算改动**。
    ///
    /// 若这里返回 false，`set` 不写盘、而输入框的 `get` 仍是旧值，刚敲的空格当场被抹掉。
    func testIsRenameKeepsTrailingSpaceTyping() {
        XCTAssertTrue(NASSourceRename.isRename(stored: "NAS", to: "NAS "))
        XCTAssertTrue(NASSourceRename.isRename(stored: "NAS ", to: "NAS 01"))
        XCTAssertTrue(NASSourceRename.isRename(stored: "NAS ", to: "NAS"))
    }

    // MARK: - 改名 ≠ 换设备

    /// 只改名字，连接参数一模一样。
    func testRenameIsNotAConnectionChange() {
        let base = NASSourceConfig(id: "A", name: "NAS", host: "nas.example", port: 5001,
                                   username: "u", scopes: ["/share", "/photo"])
        var renamed = base
        renamed.name = "客厅 NAS"
        XCTAssertTrue(base.hasSameConnection(as: renamed),
                      "只改名字不该被当成换设备——那会 disconnect 已登录的会话")
        XCTAssertFalse(base == renamed, "整体相等仍应判为不同（名字确实是配置的一部分）")
    }

    /// 任何一项连接参数变了，都必须算换设备。
    func testConnectionFieldChangesAreDetected() {
        let base = NASSourceConfig(id: "A", name: "NAS", host: "nas.example", port: 5001,
                                   username: "u", scopes: ["/share"])
        var variants: [(String, NASSourceConfig)] = []
        var v = base; v.host = "other.example";      variants.append(("地址", v))
        v = base; v.port = 5002;                     variants.append(("端口", v))
        v = base; v.username = "other";              variants.append(("账号", v))
        v = base; v.scopes = ["/share", "/photo"];   variants.append(("搜索位置", v))
        v = base; v.vendor = .qnap;                  variants.append(("类型", v))
        v = base; v.usePlainHTTP = true;             variants.append(("协议", v))
        v = base; v.enabled = false;                 variants.append(("开关", v))
        v = base; v.id = "B";                        variants.append(("ID", v))
        for (label, changed) in variants {
            XCTAssertFalse(base.hasSameConnection(as: changed),
                           "\(label) 变了却仍被当成同一条连接：会继续拿旧会话去用新参数")
        }
    }
}
