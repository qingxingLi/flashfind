import XCTest
@testable import FlashFindCore

final class SearchResultNavigationTests: XCTestCase {
    private func space(_ navigation: SearchResultNavigation, composing: Bool = false) -> SearchKeyRoute {
        SearchKeyRouter.route(SearchKeyContext(keyCode: 49, hasCommand: false, hasOtherModifier: false,
            inSearchField: !navigation.isActive, inResults: navigation.isActive, isComposing: composing))
    }

    func testTypingSpacesThenNavigatingResultsPreviewsWithoutChangingQuery() {
        var navigation = SearchResultNavigation()
        XCTAssertEqual(space(navigation), .passThrough)
        navigation.record(.move(1), hasResult: true)
        XCTAssertEqual(space(navigation), .quickLook)
        navigation.record(.quickLook, hasResult: true)
        XCTAssertEqual(space(navigation), .quickLook)
        // 开始输入字符后，空格重新属于输入框。
        navigation.record(.passThrough, hasResult: true)
        XCTAssertEqual(space(navigation), .passThrough)
    }

    func testNoResultAndQueryChangeDoNotSwallowSpace() {
        var navigation = SearchResultNavigation()
        navigation.record(.move(1), hasResult: false)
        XCTAssertEqual(space(navigation), .passThrough)
        navigation.record(.move(1), hasResult: true)
        navigation.reset()
        XCTAssertEqual(space(navigation), .passThrough)
    }

    func testCompositionStillOwnsSpaceAndOtherRoutesResetNavigation() {
        var navigation = SearchResultNavigation()
        navigation.record(.move(1), hasResult: true)
        XCTAssertEqual(space(navigation, composing: true), .passThrough)
        // 不是「移动」的任何路由都要把导航状态清掉：否则下次按空格还是预览，
        // 而用户以为自己已经在打字了。
        navigation.record(.hide, hasResult: true)
        XCTAssertFalse(navigation.isActive)
    }
}
