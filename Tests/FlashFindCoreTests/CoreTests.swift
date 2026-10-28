import XCTest
@testable import FlashFindCore

final class CoreTests: XCTestCase {
    func testAccountProfilesDoNotShareCaches() throws {
        let root = try directory()
        XCTAssertNotEqual(AccountProfile.directory(root: root, address: "https://nas:9443", username: "alice"), AccountProfile.directory(root: root, address: "https://nas:9443", username: "bob"))
        XCTAssertNotEqual(AccountProfile.key(address: "https://nas:9443", username: "alice"), AccountProfile.key(address: "https://other:9443", username: "alice"))
        XCTAssertEqual(AccountProfile.key(address: "https://nas:9443/", username: "alice"), AccountProfile.key(address: "https://nas:9443", username: "alice"))
        XCTAssertNotEqual(AccountProfile.key(address: "https://nas:9443", username: "Alice"), AccountProfile.key(address: "https://nas:9443", username: "alice"))
    }
    func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }; return url
    }
    @MainActor
    func testSpotlightSingleTermCompletes() async throws {
        let provider = SpotlightProvider()
        _ = try await provider.search("flashfind2-unlikely-regression-token")
        _ = try await provider.search("flashfind2 unlikely regression token")
    }
}
