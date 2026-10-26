import XCTest
@testable import FlashFindCore

final class SearchResultNavigationTests: XCTestCase {
    private func space(_ navigation: SearchResultNavigation, composing: Bool = false,
                       commandMode: Bool = false) -> SearchKeyRoute {
        SearchKeyRouter.route(SearchKeyContext(keyCode: 49, hasCommand: false, hasOtherModifier: false,
            inSearchField: !navigation.isActive, inResults: navigation.isActive, isComposing: composing,
            inCommandMode: commandMode))
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

    func testCompositionAndCommandsStillOwnTheirSpaces() {
        var navigation = SearchResultNavigation()
        navigation.record(.move(1), hasResult: true)
        XCTAssertEqual(space(navigation, composing: true), .passThrough)
        XCTAssertEqual(space(navigation, commandMode: true), .passThrough)
        navigation.record(.commandSubmit, hasResult: true)
        XCTAssertFalse(navigation.isActive)
    }
}
