import XCTest
import CoreModels
@testable import AppRuntime

/// Guards the cross-server watch fan-out contract.
///
/// `additionalSources` carries the eager identity index's known servers for a
/// title. Omitting it silently narrows the fan-out to the item's own `sources`,
/// which is invisible at the call site and produces no error — the other server
/// simply never gets marked played. iOS shipped without it while tvOS passed it,
/// so a MOVIE reached from a Home row that only one server populated never
/// converged.
///
/// Scope note: episodes deliberately ignore `additionalSources` for fan-out (see
/// `targets(for:...)`) because a stale snapshot can hold a different episode of
/// the same series; they converge via the authoritative episode-expansion path
/// instead. So this parameter matters for movies and other non-episode kinds.
/// These tests pin both halves of that contract.
final class WatchMutationFanoutTests: XCTestCase {
    private func makeItem() -> MediaItem {
        // A title reached from a Home row that only ONE server populated: it
        // carries no `sources` of its own, so the index is the only way to learn
        // about the other servers holding the same title.
        MediaItem(
            id: "jf-1",
            title: "Blade Runner",
            kind: .movie,
            sourceAccountID: "jellyfin-account"
        )
    }

    func testAdditionalSourcesExpandsFanoutBeyondTheOrigin() {
        let indexed = [
            MediaSourceRef(
                accountID: "plex-account",
                itemID: "46132",
                kind: .movie,
                providerKind: .plex
            )
        ]

        let withIndex = WatchMutationFactory.targets(
            for: makeItem(),
            primaryAccountID: nil,
            additionalSources: indexed
        )

        XCTAssertTrue(
            withIndex.contains { $0.accountID == "plex-account" && $0.itemID == "46132" },
            "the index's known Plex copy must be a fan-out target"
        )
        XCTAssertTrue(
            withIndex.contains { $0.accountID == "jellyfin-account" && $0.itemID == "jf-1" },
            "the origin must always remain a target"
        )
    }

    /// The regression itself: this is exactly what iOS was doing.
    func testOmittingAdditionalSourcesSilentlyLosesTheOtherServer() {
        let withoutIndex = WatchMutationFactory.targets(
            for: makeItem(),
            primaryAccountID: nil
        )

        XCTAssertFalse(
            withoutIndex.contains { $0.accountID == "plex-account" },
            "documents the failure mode: with no additionalSources the fan-out "
                + "cannot reach the other server, and does so without erroring"
        )
        XCTAssertEqual(
            withoutIndex.count,
            1,
            "origin only — the silent narrowing that lost cross-server sync"
        )
    }

    /// The deliberate exception, pinned so nobody "fixes" it by widening the
    /// episode path: a stale snapshot can hold a different episode of the same
    /// series, so episodes converge via episode-expansion, not pre-merged peers.
    func testEpisodesDeliberatelyIgnoreAdditionalSourcesForFanout() {
        let episode = MediaItem(
            id: "jf-ep",
            title: "Outside",
            kind: .episode,
            sourceAccountID: "jellyfin-account"
        )
        let indexed = [
            MediaSourceRef(
                accountID: "plex-account",
                itemID: "46132",
                kind: .episode,
                providerKind: .plex
            )
        ]

        let targets = WatchMutationFactory.targets(
            for: episode,
            primaryAccountID: nil,
            additionalSources: indexed
        )

        XCTAssertEqual(targets.map(\.accountID), ["jellyfin-account"])
    }
}
