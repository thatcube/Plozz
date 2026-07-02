import XCTest
@testable import CoreModels

final class OnboardingHighlightsTests: XCTestCase {
    func testDefaultHighlightsAreNonEmpty() {
        XCTAssertFalse(OnboardingHighlight.defaultHighlights.isEmpty)
    }

    func testDefaultHighlightIDsAreUnique() {
        let ids = OnboardingHighlight.defaultHighlights.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "highlight ids must be unique — they are the ordering/dedup key")
    }

    func testEveryDefaultHighlightIsFullyPopulated() {
        for highlight in OnboardingHighlight.defaultHighlights {
            XCTAssertFalse(highlight.id.isEmpty, "id must not be empty")
            XCTAssertFalse(highlight.symbol.isEmpty, "\(highlight.id) is missing an SF Symbol")
            XCTAssertFalse(highlight.title.isEmpty, "\(highlight.id) is missing a title")
            XCTAssertFalse(highlight.message.isEmpty, "\(highlight.id) is missing a message")
        }
    }

    /// The welcome must cover the headline capabilities a new user should learn
    /// about during setup. Guards against a future edit silently dropping one of
    /// the pillars (both providers, profiles, trackers).
    func testDefaultHighlightsCoverKeyFeatures() {
        let ids = Set(OnboardingHighlight.defaultHighlights.map(\.id))
        for expected in ["unified-servers", "profiles", "trackers", "playback", "captions", "privacy"] {
            XCTAssertTrue(ids.contains(expected), "expected a '\(expected)' highlight in the default set")
        }
    }

    /// Dual-provider mandate: the welcome copy must name both backends so it never
    /// reads as a Plex-only or Jellyfin-only app.
    func testDefaultHighlightsMentionBothProviders() {
        let corpus = OnboardingHighlight.defaultHighlights
            .map { "\($0.title) \($0.message)" }
            .joined(separator: " ")
        XCTAssertTrue(corpus.contains("Plex"), "welcome copy should mention Plex")
        XCTAssertTrue(corpus.contains("Jellyfin"), "welcome copy should mention Jellyfin")
    }

    func testWelcomeFlagDefaultsToUnseen() {
        XCTAssertEqual(OnboardingWelcome.storageKey, "hasSeenWelcome")
        XCTAssertFalse(OnboardingWelcome.defaultSeen)
    }

    func testHighlightEquatableByValue() {
        let a = OnboardingHighlight(id: "x", symbol: "star", title: "T", message: "M")
        let b = OnboardingHighlight(id: "x", symbol: "star", title: "T", message: "M")
        let c = OnboardingHighlight(id: "y", symbol: "star", title: "T", message: "M")
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(a, c)
    }
}
