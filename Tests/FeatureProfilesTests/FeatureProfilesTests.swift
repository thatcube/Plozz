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

    func testLegibleForegroundContrastsWithTile() {
        // White tile (index of the white swatch) must take a dark glyph; the
        // black tile a white one. Find them by luminance extremes.
        let rgb = ProfileTileColor.paletteRGB
        let whiteIndex = rgb.firstIndex { $0.r > 0.98 && $0.g > 0.98 && $0.b > 0.98 }
        let blackIndex = rgb.firstIndex { $0.r < 0.15 && $0.g < 0.15 && $0.b < 0.15 }
        XCTAssertNotNil(whiteIndex, "palette should include a white")
        XCTAssertNotNil(blackIndex, "palette should include a black")
        if let w = whiteIndex {
            XCTAssertEqual(ProfileTileColor.legibleForeground(forIndex: w), .black)
        }
        if let b = blackIndex {
            XCTAssertEqual(ProfileTileColor.legibleForeground(forIndex: b), .white)
        }
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

final class ProfilePhotoCandidateTests: XCTestCase {
    private func url(_ s: String) -> URL { URL(string: s)! }

    func testGravatarDefaultsAreRecognized() {
        XCTAssertTrue(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://www.gravatar.com/avatar/abc123?s=200&d=mm")))
        XCTAssertTrue(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://gravatar.com/avatar/abc?d=404")))
        XCTAssertTrue(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://gravatar.com/avatar/abc?default=blank")))
    }

    func testPlexDefaultSilhouetteIsRecognized() {
        XCTAssertTrue(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://plex.tv/assets/images/avatar/default")))
    }

    func testRealPhotosAreNotFiltered() {
        // A custom gravatar (identicon fallback, or a real uploaded image) and a
        // Plex user thumb are genuine photos and must be kept.
        XCTAssertFalse(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://www.gravatar.com/avatar/abc123?s=200&d=identicon")))
        XCTAssertFalse(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://plex.tv/users/abcdef/avatar?c=1700000000")))
        XCTAssertFalse(ProfilePhotoCandidate.isLikelyDefaultAvatar(
            url("https://jelly.example.com/Users/1/Images/Primary")))
    }

    func testMakeDropsDefaultPlexHomeUserAvatars() {
        let account = Account(
            id: "plex-1",
            server: MediaServer(
                id: "srv",
                name: "Home",
                baseURL: URL(string: "https://plex.host:32400")!,
                provider: .plex
            ),
            userID: "u",
            userName: "Owner",
            deviceID: "dev"
        )
        let realUser = PlexHomeUser(
            id: "real",
            name: "Mom",
            requiresPIN: false,
            avatarURL: URL(string: "https://plex.tv/users/mom/avatar?c=1")
        )
        let defaultUser = PlexHomeUser(
            id: "default",
            name: "Kid",
            requiresPIN: false,
            avatarURL: URL(string: "https://www.gravatar.com/avatar/xyz?d=mm")
        )
        let candidates = ProfilePhotoCandidate.make(
            accounts: [account],
            plexHomeUsersByAccount: ["plex-1": [realUser, defaultUser]]
        )
        XCTAssertEqual(candidates.map(\.detailLabel), ["Mom on Home"])
    }
}
#endif
