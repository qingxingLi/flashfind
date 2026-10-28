import Foundation

/// 搜索框**下方那一条文件类型选择器**（仿聚焦搜索 / Finder 的分段条）。
///
/// 用户 2026-10-27 的要求：「仿照聚焦搜索 闪寻搜索框下方可以选择文件类型
/// 默认是全部 分别从全部 word ppt 等依次排布 **此功能为搜索框模块的功能**」。
///
/// ## 与 `/` 命令面板是同一个清单，两种呈现
///
/// 类型清单只有一份（`SearchFileTypeCatalog.all`）：面板是「输入指令」，
/// 这里是「常驻的一排选项卡」。清单如果各写一份，迟早出现
/// 「面板里有压缩包、条上没有」这种分叉——而两边指向的是同一件事。
///
/// ## 为什么「全部」自成一条
///
/// 「不限定类型」不是一个类型，它必须能**显式**被选中：用户切到 ppt 之后
/// 要能一眼看到「怎么回到全部」，而不是靠猜「再点一次 ppt 会不会取消」。
/// 所以它是一个真实的分段，排在最前，默认选中。
public enum SearchTypeBar {

    /// 「全部」那一段的 id。
    public static let allID = "type:all"

    /// 条上的一段。
    public struct Entry: Hashable, Sendable, Identifiable {
        public let id: String
        /// 段上显示的字（「全部」「word」「ppt」…）。
        public let title: String
        /// `nil` = 不限定类型（「全部」那一段）。
        public let fileType: SearchFileTypeCatalog.FileType?

        public init(id: String, title: String, fileType: SearchFileTypeCatalog.FileType?) {
            self.id = id
            self.title = title
            self.fileType = fileType
        }

        /// 是不是「全部」。
        public var isAll: Bool { fileType == nil }
    }

    /// 从「全部」开始，其余按类型清单的自然顺序（pdf / word / excel / ppt …）。
    ///
    /// ★ 顺序就是清单顺序，不另排：用户说的「依次排布」指的是清单原有的次序。
    /// 于是「设置 ▸ 搜索」里改过的候选顺序也天然一致（面板那侧读的是同一份）。
    public static let entries: [Entry] =
        [Entry(id: allID, title: "全部", fileType: nil)]
        + SearchFileTypeCatalog.all.map { type in
            Entry(id: type.id, title: type.title, fileType: type)
        }

    /// 当前应该选中哪一段。
    ///
    /// - 没限定类型 ⇒ `allID`。
    /// - 限定的类型**不在清单里**（比如偏好被手改过）⇒ 也回落到 `allID`：
    ///   宁可显示「全部」，也不画一排一段都没选中的条——那看起来像坏了。
    public static func selectedID(for fileType: SearchFileTypeCatalog.FileType?) -> String {
        guard let fileType else { return allID }
        return entries.contains(where: { $0.fileType == fileType }) ? fileType.id : allID
    }

    /// 某一段对应的类型限定（「全部」⇒ nil）。
    ///
    /// ★ 界面只认 id、把换算交给这里：点一下要「清掉类型限定」还是
    /// 「设成 pdf」，由这一处说了算，视图里不许出现 `if id == "type:all"`。
    public static func fileType(for id: String) -> SearchFileTypeCatalog.FileType? {
        entries.first { $0.id == id }?.fileType
    }
}
