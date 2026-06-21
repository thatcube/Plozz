import XCTest
@testable import CoreModels

final class ProfileModelTests: XCTestCase {
    func testDefaultProfileUsesNilNamespaceOnlyWhenDefault() {
        let p = Profile(id: "abc", name: "Mom")
        XCTAssertNil(p.settingsNamespace(isDefault: true))
        XCTAssertEqual(p.settingsNamespace(isDefault: false), "abc")
    }

    func testColorIndexIsClampedAndWraps() {
        XCTAssertEqual(Profile(name: "A", colorIndex: 0).clampedColorIndex, 0)
        XCTAssertEqual(Profile(name: "A", colorIndex: Profile.tileColorCount).clampedColorIndex, 0)
        XCTAssertEqual(Profile(name: "A", colorIndex: -1).clampedColorIndex,
                       Profile.tileColorCount - 1)
    }

    func testCodableRoundTrip() throws {
        let p = Profile(
            id: "p1",
            name: "Dad",
            avatarSymbol: "film.fill",
            colorIndex: 3,
            createdAt: Date(timeIntervalSince1970: 100),
            linkedAccountID: "acct-9"
        )
        let data = try JSONEncoder().encode(p)
        XCTAssertEqual(try JSONDecoder().decode(Profile.self, from: data), p)
    }
}
