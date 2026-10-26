import XCTest
@testable import FlashFindCore

/// 共享/存储列表的两种真实形状。
///
/// 这不是「防御性编程」，是两个都在跑的契约：
/// 群晖原生路径回 `[String]`，品牌适配器回对象数组。
/// 只认前者时，品牌来源永远拿到空列表，界面会说
/// 「已登录，但这个账号确实没有任何共享目录。请检查账号权限」——
/// 把解码问题说成用户的权限问题，2026-10-24 在 App 内实测 OpenList 时正是如此。
@MainActor
final class ShareListDecodingTests: XCTestCase {

    func testPlainPathListFromSynologyIsKeptAsIs() {
        let raw: Any = ["/共享A", "/docker"]
        XCTAssertEqual(NASSearchProvider.decodeShares(raw), ["/共享A", "/docker"])
    }

    func testBrandObjectListUsesPathField() {
        let raw: Any = [
            ["name": "A0002", "path": "/A0002", "sourceID": "s1", "sourceName": "OpenList"],
            ["name": "B3603", "path": "/B3603", "sourceID": "s1", "sourceName": "OpenList"],
        ]
        XCTAssertEqual(NASSearchProvider.decodeShares(raw), ["/A0002", "/B3603"])
    }

    func testObjectWithoutPathFallsBackToName() {
        let raw: Any = [["name": "docker"]]
        XCTAssertEqual(NASSearchProvider.decodeShares(raw), ["docker"])
    }

    func testUnusableShapesYieldEmptyRatherThanGarbage() {
        XCTAssertEqual(NASSearchProvider.decodeShares(nil), [])
        XCTAssertEqual(NASSearchProvider.decodeShares("不是列表"), [])
        XCTAssertEqual(NASSearchProvider.decodeShares([["sourceID": "s1"]]), [])
    }
}
