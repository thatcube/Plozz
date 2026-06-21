import XCTest
@testable import FeatureProfiles
@testable import CoreModels

#if canImport(SwiftUI)
final class ProfileTileColorTests: XCTestCase {
    func testColorForProfileMatchesClampedIndex() {
        // Out-of-range indices wrap into the palette rather than crashing.
        let p = Profile(name: "A", colorIndex: Profile.tileColorCount + 2)
        XCTAssertEqual(ProfileTileColor.color(for: p),
                       ProfileTileColor.color(forIndex: p.clampedColorIndex))
    }

    func testColorForIndexWrapsNegatives() {
        XCTAssertEqual(ProfileTileColor.color(forIndex: -1),
                       ProfileTileColor.color(forIndex: ProfileTileColor.palette.count - 1))
    }

    func testPaletteCoversTileColorCount() {
        XCTAssertGreaterThanOrEqual(ProfileTileColor.palette.count, Profile.tileColorCount)
    }
}

final class ProfileDraftTests: XCTestCase {
    func testDraftCarriesEditedFields() {
        let draft = ProfileDraft(
            id: "p1",
            name: "Sister",
            avatarSymbol: "star.circle.fill",
            colorIndex: 2,
            linkedAccountID: "plex-1",
            activeAccountIDs: ["plex-1", "jelly-1"]
        )
        XCTAssertEqual(draft.id, "p1")
        XCTAssertEqual(draft.name, "Sister")
        XCTAssertEqual(draft.linkedAccountID, "plex-1")
        XCTAssertEqual(Set(draft.activeAccountIDs), ["plex-1", "jelly-1"])
    }
}
#endif
