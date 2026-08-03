import XCTest
import CoreModels
@testable import FeatureHomeCore

/// A poster is the right shape for a portrait phone, but its whole job is to
/// carry its own title treatment — and no provider marks which of its posters
/// are textless. Leading with one under an overlaid logo drew the title twice.
final class HeroArtworkPlacementTests: XCTestCase {
    private func makeItem(hasLogo: Bool) -> MediaItem {
        var item = MediaItem(id: "1", title: "Futurama", kind: .series)
        item.posterURL = URL(string: "https://example.test/poster.jpg")
        item.backdropURL = URL(string: "https://example.test/backdrop.jpg")
        item.logoURL = hasLogo ? URL(string: "https://example.test/logo.png") : nil
        return item
    }

    private func firstReference(
        hasLogo: Bool,
        style: HeroArtworkStyle
    ) -> ArtworkReference? {
        HeroPresentation(
            item: makeItem(hasLogo: hasLogo),
            artworkStyle: style,
            surface: .home
        ).artworkReferences.first
    }

    func testPortraitHeroUsesThePosterWhenNoLogoWillBeDrawn() {
        XCTAssertEqual(
            firstReference(hasLogo: false, style: .compactPortrait),
            .remote(URL(string: "https://example.test/poster.jpg")!),
            "with no logo the poster's own title treatment is the point"
        )
    }

    func testPortraitHeroAvoidsThePosterWhenALogoWillBeDrawnOverIt() {
        XCTAssertEqual(
            firstReference(hasLogo: true, style: .compactPortrait),
            .remote(URL(string: "https://example.test/backdrop.jpg")!),
            "a logo over a poster shows the title twice"
        )
    }

    func testLandscapeHeroIsUnchanged() {
        for hasLogo in [true, false] {
            XCTAssertEqual(
                firstReference(hasLogo: hasLogo, style: .landscape),
                .remote(URL(string: "https://example.test/backdrop.jpg")!)
            )
        }
    }

    /// The poster must remain reachable as a fallback; this narrows preference,
    /// it does not discard artwork.
    func testPosterRemainsAvailableAsAFallback() {
        let references = HeroPresentation(
            item: makeItem(hasLogo: true),
            artworkStyle: .compactPortrait,
            surface: .home
        ).artworkReferences
        XCTAssertTrue(
            references.contains(.remote(URL(string: "https://example.test/poster.jpg")!))
        )
    }
}
