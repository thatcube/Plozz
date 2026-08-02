import XCTest
@testable import CoreModels

/// The outbox coalesces two writes for **one title** into one, but its
/// `coalesceKey` is derived from `canonicalMediaID`, which picks the first strong
/// namespace present on *that* payload. Two servers holding the same film routinely
/// expose different id sets, so marking it watched from a page backed by one server
/// and then the other produced two queued writes for one title that raced on the
/// wire.
///
/// `canonicalMediaID` is deliberately frozen — it roots the persisted stale-write
/// clock and the tracker idempotency keys — so the fix is additive, matching on the
/// identity evidence mutations already persist.
final class WatchOutboxEvidenceCoalescingTests: XCTestCase {
    private func mutation(
        canonicalMediaID: String,
        identities: [MediaIdentity],
        kind: MediaItemKind? = .movie,
        title: String? = "dune",
        year: Int? = 2021,
        capturedAt: Date,
        played: Bool = true,
        accountID: String = "acct",
        seasonNumber: Int? = nil,
        episodeNumber: Int? = nil
    ) -> WatchMutation {
        WatchMutation(
            capturedAt: capturedAt,
            canonicalMediaID: canonicalMediaID,
            seasonNumber: seasonNumber,
            episodeNumber: episodeNumber,
            played: played,
            targets: [WatchMutationTarget(accountID: accountID, itemID: "1")],
            identities: identities,
            kind: kind,
            anchorTitle: title,
            anchorYear: year
        )
    }

    /// The bug: one film, two servers, two different canonical ids.
    func testTwoServersWithDifferentIDSetsCoalesceIntoOneWrite() {
        let imdb = MediaIdentity.external(source: "imdb", value: "tt1160419")
        let tmdb = MediaIdentity.external(source: "tmdb", value: "438631")
        let now = Date()

        let first = mutation(
            canonicalMediaID: "imdb:tt1160419",
            identities: [imdb, tmdb],
            capturedAt: now,
            accountID: "plex"
        )
        let second = mutation(
            canonicalMediaID: "tmdb:438631",
            identities: [tmdb],
            capturedAt: now.addingTimeInterval(1),
            accountID: "jellyfin"
        )

        XCTAssertNotEqual(
            first.coalesceKey,
            second.coalesceKey,
            "the frozen canonical id genuinely differs — that is the bug"
        )
        XCTAssertEqual(
            WatchStateReconciler.evidenceMatchIndex(for: second, in: [first]),
            0
        )

        let merged = WatchStateReconciler.coalesce(existing: first, incoming: second)
        XCTAssertEqual(
            Set(merged.targets.map(\.accountID)),
            ["plex", "jellyfin"],
            "coalescing must union both servers' targets, not drop one"
        )
    }

    /// The split guard applies here too: a shared id can be a mis-tag, and merging
    /// two different works would mark the wrong title watched.
    func testContradictingTitlesDoNotCoalesce() {
        let shared = MediaIdentity.external(source: "tmdb", value: "5")
        let now = Date()

        let existing = mutation(
            canonicalMediaID: "imdb:tt1",
            identities: [shared],
            title: "scream 6",
            year: 2023,
            capturedAt: now
        )
        let incoming = mutation(
            canonicalMediaID: "tmdb:5",
            identities: [shared],
            title: "scream 7",
            year: 2025,
            capturedAt: now.addingTimeInterval(1)
        )

        XCTAssertNil(
            WatchStateReconciler.evidenceMatchIndex(for: incoming, in: [existing])
        )
    }

    /// TMDb and TVDb reuse one integer space across movies and series.
    func testCrossKindEvidenceDoesNotCoalesce() {
        let shared = MediaIdentity.external(source: "tmdb", value: "550")
        let now = Date()

        let existing = mutation(
            canonicalMediaID: "imdb:tt1",
            identities: [shared],
            kind: .movie,
            title: "fight club",
            year: 1999,
            capturedAt: now
        )
        let incoming = mutation(
            canonicalMediaID: "tmdb:550",
            identities: [shared],
            kind: .series,
            title: "shogun",
            year: 2024,
            capturedAt: now.addingTimeInterval(1)
        )

        XCTAssertNil(
            WatchStateReconciler.evidenceMatchIndex(for: incoming, in: [existing])
        )
    }

    /// Two different episodes of one series share the series' identities; they are
    /// separate writes.
    func testDifferentEpisodesDoNotCoalesce() {
        let series = MediaIdentity.external(source: "series-tmdb:s1e1", value: "99")
        let now = Date()

        let existing = mutation(
            canonicalMediaID: "a",
            identities: [series],
            kind: .episode,
            title: nil,
            year: nil,
            capturedAt: now,
            seasonNumber: 1,
            episodeNumber: 1
        )
        let incoming = mutation(
            canonicalMediaID: "b",
            identities: [series],
            kind: .episode,
            title: nil,
            year: nil,
            capturedAt: now.addingTimeInterval(1),
            seasonNumber: 1,
            episodeNumber: 2
        )

        XCTAssertNil(
            WatchStateReconciler.evidenceMatchIndex(for: incoming, in: [existing])
        )
    }

    /// Mutations enqueued before the identity fields existed carry none, and must
    /// keep exactly their old behavior rather than coalescing by accident.
    func testLegacyMutationsWithoutIdentitiesKeepTodaysBehavior() {
        let now = Date()
        let existing = mutation(
            canonicalMediaID: "imdb:tt1",
            identities: [],
            capturedAt: now
        )
        let incoming = mutation(
            canonicalMediaID: "tmdb:2",
            identities: [],
            capturedAt: now.addingTimeInterval(1)
        )

        XCTAssertNil(
            WatchStateReconciler.evidenceMatchIndex(for: incoming, in: [existing])
        )
    }
}
