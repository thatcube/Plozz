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

    func testSettingSeerrUserSetsAndClears() {
        let base = Profile(id: "p1", name: "Dad")
        XCTAssertNil(base.seerrUserID)

        let mapped = base.settingSeerrUser(id: 7, name: "Dad (Seerr)", avatarURL: "https://x/y.png")
        XCTAssertEqual(mapped.seerrUserID, 7)
        XCTAssertEqual(mapped.seerrUserName, "Dad (Seerr)")
        XCTAssertEqual(mapped.seerrUserAvatarURL, "https://x/y.png")

        let cleared = mapped.settingSeerrUser(id: nil)
        XCTAssertNil(cleared.seerrUserID)
        XCTAssertNil(cleared.seerrUserName, "Clearing the id drops the cached name")
        XCTAssertNil(cleared.seerrUserAvatarURL)
    }

    func testSeerrUserMappingSurvivesCodableRoundTrip() throws {
        let p = Profile(id: "p2", name: "Mom").settingSeerrUser(id: 42, name: "Mom", avatarURL: nil)
        let data = try JSONEncoder().encode(p)
        let decoded = try JSONDecoder().decode(Profile.self, from: data)
        XCTAssertEqual(decoded.seerrUserID, 42)
        XCTAssertEqual(decoded, p)
    }

    func testLegacyProfileJSONWithoutSeerrFieldsDecodesToNil() throws {
        // A profile encoded before seerrUserID existed must decode cleanly.
        let legacyJSON = #"{"id":"p3","name":"Kid","avatarSymbol":"star.circle.fill","colorIndex":0,"createdAt":0}"#
        let decoded = try JSONDecoder().decode(Profile.self, from: Data(legacyJSON.utf8))
        XCTAssertEqual(decoded.id, "p3")
        XCTAssertNil(decoded.seerrUserID)
        XCTAssertNil(decoded.seerrUserName)
    }
}
