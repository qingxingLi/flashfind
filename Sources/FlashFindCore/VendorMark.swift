import Foundation

/// 来源品牌的**标记**（单色剪影），与 `Vendor.symbol`（SF Symbol）分工不同。
///
/// ## 为什么不用 SF Symbol 代表品牌
///
/// 向导第 1 步原来三家都用系统符号：群晖是 `externaldrive.connected.to.line.below`、
/// OpenList 是 `cloud`、飞牛是 `externaldrive.badge.icloud`。这些是「设备类别」而不是
/// 「品牌」—— 三张卡并排时，用户看到的是「三个硬盘」，得读下面的字才知道哪台是哪台。
///
/// 2026-10-29 用户要求换成「黑白风格的他们自己的主题图标」，并提供了三家各自标志的截图
/// 作为形态依据（DSM 方块、飞牛牛头、OpenList 圆环 + 斜杠）。
///
/// ★ 最终形态**不是重画**，是**从用户给的原始截图里描出来的轮廓**（用户 2026-10-29
/// 提供 `VendorMarkView.swift` 定稿）：只把颜色改成黑白，形状一点都不重新设计。
/// 手绘过三版都不成立 —— 群晖的字母在 26pt 下糊成一团、飞牛的两只角角度怎么调都像鹿角、
/// OpenList 的缺口方向凭印象放反了。轮廓照抄才是唯一稳的做法。
///
/// ## 为什么标记的「判定」在这里、绘制在 App 层
///
/// 「哪家该有专属标记」是产品判断，必须能被测试钉住（新增一家没配标记时，
/// 界面上会默默退回一个泛化符号，没人会发现）。图形本身是排版，只能靠截图验，
/// 留在 App 层（`VendorMarkView`）。这与字体阶梯的做法一致：取值在 Core，画在视图。
public enum VendorMark: String, CaseIterable, Sendable {
    /// 群晖：DSM 的圆角方块，「DSM」三个字母是**镂空**的（负形）。
    case synology
    /// 飞牛 fnOS：牛头 —— 顶横 + 左侧竖笔 + 底脚 + 向右上两级阶梯，加两只角
    /// （右角长、近垂直，左角短且与主体**断开**）。
    case fnos
    /// OpenList：缺口在**左下**的圆环（下端向内收成钩），加一条嵌在缺口里的斜杠。
    case openlist

    /// 画布边长（绘制坐标用 24 网格，与 SF Symbol 的常见光学尺寸对齐）。
    ///
    /// 视图按这个数字把路径等比缩放到实际尺寸，所以调整图形时只改这里与路径数据。
    ///
    /// 这里**没有**「统一笔画宽度」这类常量了：轮廓是从原图描出来的闭合多边形，
    /// 「肉有多厚」已经写在各家的轮廓里（原标志本身粗细就不一致，硬统一反而是改形状）。
    public static let designSize: Double = 24
}

public extension NASSourceConfig.Vendor {
    /// 该品牌的专属标记；`nil` 表示没有，界面回落到 `symbol`（SF Symbol）。
    ///
    /// 只给**正式开放**的三家配了标记。实验性品牌（qnap / ugreen / webdav 等）
    /// 仍用系统符号 —— 它们连选型卡都不常出现，专门画一套图形没有收益。
    var mark: VendorMark? {
        switch self {
        case .synology: return .synology
        case .fnos: return .fnos
        case .openlist: return .openlist
        default: return nil
        }
    }
}
