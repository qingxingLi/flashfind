import XCTest
@testable import FlashFindCore

/// 搜索框下方的**文件类型条**（用户 2026-10-27：「仿照聚焦搜索……默认是全部」）。
///
/// 这里锁三件事：**「全部」是第一段且默认选中**、清单与类型目录一一对应、
/// 以及「选哪一段」这个换算只有一处（视图里不许出现 `if id == "type:all"`）。
final class SearchTypeBarTests: XCTestCase {

    /// ★ 默认（没限定类型）必须是「全部」，而且它就是第一段。
    ///
    /// 用户原话「默认是全部 分别从全部 word ppt 等依次排布」——两条都在这一条里。
    func testAllComesFirstAndIsTheDefault() {
        XCTAssertEqual(SearchTypeBar.entries.first?.title, "全部", "「全部」必须排在最前")
        XCTAssertTrue(SearchTypeBar.entries.first?.isAll == true)
        XCTAssertEqual(SearchTypeBar.selectedID(for: nil), SearchTypeBar.allID,
                       "没限定类型时选中的就是「全部」")
    }

    /// 类型条与 `/` 面板共用同一份清单，顺序也一致。
    ///
    /// ★ 各写一份的后果是「面板里有压缩包、条上没有」——而两边指的是同一件事。
    func testEntriesMirrorTheTypeCatalogInOrder() {
        let catalog = SearchFileTypeCatalog.all
        XCTAssertEqual(SearchTypeBar.entries.count, catalog.count + 1, "「全部」+ 类型目录的每一条")
        for (index, type) in catalog.enumerated() {
            let entry = SearchTypeBar.entries[index + 1]
            XCTAssertEqual(entry.id, type.id, "第 \(index + 2) 段必须对应目录里的 \(type.title)")
            XCTAssertEqual(entry.title, type.title)
            XCTAssertEqual(entry.fileType, type)
        }
    }

    /// 每段的 id 必须唯一：`ForEach` 认 id，重复会让选中胶囊跳错段。
    func testSegmentIDsAreUnique() {
        let ids = SearchTypeBar.entries.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "类型条上有重复 id：\(ids)")
    }

    func testSelectedIDFollowsTheLimitedType() {
        XCTAssertEqual(SearchTypeBar.selectedID(for: SearchFileTypeCatalog.all[0]), "type:pdf")
        XCTAssertEqual(SearchTypeBar.selectedID(for: SearchFileTypeCatalog.all[3]), "type:ppt")
        XCTAssertEqual(SearchTypeBar.selectedID(for: nil), SearchTypeBar.allID)
    }

    /// 清单里没有的类型 ⇒ 回落到「全部」，不是「一段都不选」。
    ///
    /// 偏好被手改过、或以后删掉了某个类型时，界面上不能出现一排全灰的段。
    func testUnknownTypeFallsBackToAll() {
        let stranger = SearchFileTypeCatalog.FileType(id: "type:unknown", title: "未知", formatWord: "unknown")
        XCTAssertEqual(SearchTypeBar.selectedID(for: stranger), SearchTypeBar.allID)
    }

    /// 「点这一段要设成什么」也只有一处答案。
    func testFileTypeForSegmentID() {
        XCTAssertNil(SearchTypeBar.fileType(for: SearchTypeBar.allID), "「全部」= 清掉类型限定")
        XCTAssertEqual(SearchTypeBar.fileType(for: "type:word")?.formatWord, "doc",
                       "★ 显示名是 word，交给解析器的格式词是 doc——这层换算不许在视图里再写一遍")
        XCTAssertNil(SearchTypeBar.fileType(for: "type:nope"))
    }
}
