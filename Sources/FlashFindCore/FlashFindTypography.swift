import CoreGraphics

/// 一处文字样式：字号 + 字重 + 字距。
///
/// 三者必须打包在一起，不能只存字号——用户 2026-10-28 要的「聚焦搜索那种
/// 加粗感」本质上不是字号变化，而是**同一层级里字重和字距的组合**。
/// 只把字号调大、字重留在 regular，出来的效果是「字变大了」而不是「字变结实了」。
public struct FlashFindTextStyle: Equatable, Sendable {
    public let size: CGFloat
    /// `NSFont.Weight` 的原始数值：0 = regular、0.4 = medium、0.6 = semibold。
    ///
    /// ★ 不存 SwiftUI 的 `Font.Weight`：Core 不能引 SwiftUI（那会把整个 UI 框架
    ///   拖进逻辑库，也拖慢测试）。App 层再用 `ffFont(_:)` 映射回 `Font.Weight`。
    public let weight: CGFloat
    /// SwiftUI `.tracking()` 的值，单位 pt。
    ///
    /// SF Pro 在大字号下自带一张字距表，但 SwiftUI 默认不套用全部——
    /// 所以 Spotlight 那种「字挨得紧、整行显得扎实」的感觉要手写负值才出得来。
    /// 中文（苹方）的字面比拉丁字母满，负值别超过 -0.4，再紧就并字了。
    public let tracking: CGFloat

    public init(size: CGFloat, weight: CGFloat = 0, tracking: CGFloat = 0) {
        self.size = size
        self.weight = weight
        self.tracking = tracking
    }
}

/// 闪寻的字体阶梯（2026-10-28 用户：「调整下整体的字体吧 我想要聚焦搜索的加粗字体效果」）。
///
/// ## 为什么不换字体
///
/// 界面一直用 `.font(.system(...))`，拿到的**就是** SF Pro（中文自动回退苹方），
/// 本来就是苹果字体，没有「换成苹果字体」这件事可做。
/// 而且不能改成 `.custom("SF Pro Display", size:)`：SF 不对第三方暴露可加载的
/// 字体名，`.custom` 多半静默回退；`Font.system` 还会按字号自动在 SF Text
/// （< 20pt）与 SF Display（≥ 20pt）之间切光学字号，`.custom` 没有这个能力，
/// 大字会显得粗笨。
///
/// 真正拉开与系统 Spotlight 观感差距的是三件事：**字重档次、字距、层级差**。
/// 这个文件只管这三样。
///
/// ## 中文的坑
///
/// SF Pro 没有中文字形，中文全部落到苹方。苹方的 semibold 视觉重量比 SF 的
/// semibold 更重，所以中文界面写 0.6 会比英文界面看起来更粗——
/// 力度是按**中文观感**定的，不是照抄 Spotlight 的英文数值。
///
/// ## 为什么放 Core
///
/// App 层是 executableTarget，字号字重写错了只能靠人眼发现。
/// 放这里就能用测试锁住「阶梯严格递减」「标题比正文重」这两条，
/// 而「层级不明显」正是用户会反复反馈的那类问题。
///
/// ## 为什么常量挂在 `FlashFindTextStyle` 上
///
/// 视图里的写法是 `.ffFont(.searchField)`，靠参数类型推断。如果常量装在另一个
/// enum 里，每个调用点都得写成 `.ffFont(FlashFindTypography.searchField)`。
/// `FlashFindTypography` 这个名字保留成别名——文档和测试里仍按「字体阶梯」称呼它。
public typealias FlashFindTypography = FlashFindTextStyle

public extension FlashFindTextStyle {

    // MARK: - 搜索主界面

    /// 搜索输入框。
    ///
    /// 22pt 落在 SF Display 光学区间（≥20pt），笔画更细更锐利；配合 medium 与
    /// -0.4 字距，就是「大而不肥、紧而不断」的那口气。
    static let searchField = FlashFindTextStyle(size: 22, weight: 0.4, tracking: -0.4)

    /// 搜索框下方的首屏键位提示。
    static let fieldHint = FlashFindTextStyle(size: 11)

    /// 结果行的**文件名**——全界面字重最高的一档。
    ///
    /// 13.5pt 而非 13：结果行固定 56pt 高，13.5 在 2x 屏落 27px 正好是整数像素；
    /// 比原来的 14pt 略小一档，是为了给 semibold 增加的笔画重量腾出视觉空间——
    /// 字号不变只加粗，整行会显得闷。
    static let resultName = FlashFindTextStyle(size: 13.5, weight: 0.6, tracking: -0.1)

    /// 结果行的路径（次级信息）。
    static let resultPath = FlashFindTextStyle(size: 11)

    /// 结果行右端的来源标签（「此 Mac」/ NAS 名）。
    static let sourceBadge = FlashFindTextStyle(size: 11)

    /// 类型条未选中段。
    static let segmentLabel = FlashFindTextStyle(size: 12)

    /// 类型条选中段：只加字重，不换字号——换字号会让整条宽度跳一下。
    static let segmentLabelSelected = FlashFindTextStyle(size: 12, weight: 0.4)

    /// 位置侧边栏未选中行。
    static let sidebarTitle = FlashFindTextStyle(size: 12)

    /// 位置侧边栏选中行。
    static let sidebarTitleSelected = FlashFindTextStyle(size: 12, weight: 0.4)

    /// 位置侧边栏的来源副标题。
    static let sidebarSubtitle = FlashFindTextStyle(size: 10)

    /// 空状态/加载态的标题。
    static let stateTitle = FlashFindTextStyle(size: 14, weight: 0.4, tracking: -0.1)

    /// 空状态/加载态/提示条的正文。
    static let stateDetail = FlashFindTextStyle(size: 13)

    /// 底部状态条（条数、键位说明）。
    static let statusBar = FlashFindTextStyle(size: 11)

    /// 分组标题（组件里的「标题」、弹层题头）。
    static let sectionHeader = FlashFindTextStyle(size: 13, weight: 0.6, tracking: -0.1)

    /// 页脚说明。
    static let footer = FlashFindTextStyle(size: 11)

    /// 失败提示条的标题（「无法打开文件」）。
    static let bannerTitle = FlashFindTextStyle(size: 13, weight: 0.6, tracking: -0.1)

    /// 钉住窗题头。
    static let pinnedTitle = FlashFindTextStyle(size: 13, weight: 0.6, tracking: -0.1)

    /// 钉住窗条数。
    static let pinnedCount = FlashFindTextStyle(size: 11)

    /// 钉住窗的空状态。
    static let pinnedEmpty = FlashFindTextStyle(size: 12)

    // MARK: - 设置页
    //
    // 字号仍由 `SettingsTypography` 给（17 / 16 / 13 / 11 四级阶梯是实测系统设置
    // 定下来的，2026-10 已锁在测试里），这里只补上字重与字距，
    // 避免两处各写一个 17 之后慢慢漂开。

    /// 设置页大标题。
    static let settingsPageTitle = FlashFindTextStyle(
        size: SettingsTypography.pageTitle, weight: 0.6, tracking: -0.3
    )

    /// 设置页分段标题。
    static let settingsSectionHeader = FlashFindTextStyle(
        size: SettingsTypography.sectionHeader, weight: 0.6, tracking: -0.2
    )

    /// 设置页正文。
    static let settingsBody = FlashFindTextStyle(size: SettingsTypography.body)

    /// 设置页正文里的**值 / 行标签**（比正文重半档，用来分「名字」与「值」）。
    static let settingsBodyEmphasis = FlashFindTextStyle(
        size: SettingsTypography.body, weight: 0.4
    )

    /// 设置页辅助说明。
    static let settingsCaption = FlashFindTextStyle(size: SettingsTypography.caption)

    /// 设置页里需要压过同排其他行的正文（左侧当前页）。
    ///
    /// 保持 semibold 而不是降到 medium：设置页左栏是**导航**，
    /// 当前页如果只比其他行重半档，扫一眼分不出自己在哪。
    static let settingsBodyStrong = FlashFindTextStyle(
        size: SettingsTypography.body, weight: 0.6
    )

    /// 阶梯校验用：从大到小、**互不相同**的字号序列（测试锁「严格递减」）。
    ///
    /// 同值样式（11pt 的路径 / 页脚 / 状态条）不进这个数组——
    /// 它们是同一档的不同用途，放进来会让「严格递减」这条断言失去意义。
    static let sizeLadder: [CGFloat] = [
        searchField.size,
        stateTitle.size,
        resultName.size,
        stateDetail.size,
        segmentLabel.size,
        resultPath.size,
    ]
}
