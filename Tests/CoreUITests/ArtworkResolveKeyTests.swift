import XCTest
import CoreModels
@testable import CoreUI

final class ArtworkResolveKeyTests: XCTestCase {
    /// The regression: posterless cards have no direct references, but their
    /// async fallback closures resolve different titles. Those sessions must not
    /// share a memo key.
    func testPosterlessCardsUseTheirPinnedSubjectInTheKey() {
        let first = ArtworkResolveKey.make(
            references: [],
            variant: .posterCard,
            maxAspectRatio: 1,
            pinIdentity: "watchlist:a-series"
        )
        let second = ArtworkResolveKey.make(
            references: [],
            variant: .posterCard,
            maxAspectRatio: 1,
            pinIdentity: "watchlist:dota"
        )

        XCTAssertNotEqual(first, second)
    }

    /// Rebuilding the same card must still find the memo entry it wrote.
    func testSameSubjectAndInputsRemainStable() {
        let arguments = (
            references: [ArtworkReference.remote(URL(string: "https://art.example/poster.jpg")!)],
            variant: ArtworkImageVariant.posterCard,
            maxAspectRatio: CGFloat(1),
            pinIdentity: Optional("watchlist:one")
        )
        XCTAssertEqual(
            ArtworkResolveKey.make(
                references: arguments.references,
                variant: arguments.variant,
                maxAspectRatio: arguments.maxAspectRatio,
                pinIdentity: arguments.pinIdentity
            ),
            ArtworkResolveKey.make(
                references: arguments.references,
                variant: arguments.variant,
                maxAspectRatio: arguments.maxAspectRatio,
                pinIdentity: arguments.pinIdentity
            )
        )
    }

    /// Callers without a subject identity keep the old reference-based sharing.
    func testNilPinKeepsMatchingReferencesShareable() {
        let references = [
            ArtworkReference.remote(URL(string: "https://art.example/poster.jpg")!)
        ]
        let first = ArtworkResolveKey.make(
            references: references,
            variant: .posterCard,
            maxAspectRatio: 1,
            pinIdentity: nil
        )
        let second = ArtworkResolveKey.make(
            references: references,
            variant: .posterCard,
            maxAspectRatio: 1,
            pinIdentity: nil
        )
        XCTAssertEqual(first, second)
    }

    func testVariantAndAspectRatioStillParticipate() {
        let identity = "watchlist:one"
        let poster = ArtworkResolveKey.make(
            references: [],
            variant: .posterCard,
            maxAspectRatio: 1,
            pinIdentity: identity
        )
        let landscape = ArtworkResolveKey.make(
            references: [],
            variant: .landscapeCard,
            maxAspectRatio: 1,
            pinIdentity: identity
        )
        let stricterPoster = ArtworkResolveKey.make(
            references: [],
            variant: .posterCard,
            maxAspectRatio: 0.75,
            pinIdentity: identity
        )

        XCTAssertNotEqual(poster, landscape)
        XCTAssertNotEqual(poster, stricterPoster)
    }
}
