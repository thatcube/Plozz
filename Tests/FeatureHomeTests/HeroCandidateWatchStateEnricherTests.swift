import XCTest
import CoreModels
@testable import FeatureHome

/// Locks the pure hero candidate watch-state enrichment domain logic: folding live
/// historical watch state onto discovery-only items, skipping work when no library
/// copy exists or the candidate is already known watched, bounded concurrency, and
/// the oversampling `HeroCandidatePool` request math.
final class HeroCandidateWatchStateEnricherTests: XCTestCase {
    private actor FetchProbe {
        private(set) var active = 0
        private(set) var maximum = 0
        private(set) var calls = 0

        func begin() {
            active += 1
            calls += 1
            maximum = max(maximum, active)
        }

        func end() {
            active -= 1
        }
    }

    func testEnrichesDiscoveryItemsWithLiveHistoricalWatchState() async {
        let items = [
            MediaItem(id: "tmdb-1", title: "Seen", kind: .movie),
            MediaItem(id: "tmdb-2", title: "New", kind: .series)
        ]

        let enriched = await HeroCandidateWatchStateEnricher.enrich(
            items,
            sourceRefs: { item in
                [MediaSourceRef(accountID: "account", itemID: "library-\(item.id)")]
            },
            fetch: { source in
                MediaItem(
                    id: source.itemID,
                    title: source.itemID,
                    kind: .movie,
                    hasBeenPlayed: source.itemID == "library-tmdb-1"
                )
            }
        )

        XCTAssertTrue(enriched[0].hasBeenPlayed)
        XCTAssertFalse(enriched[1].hasBeenPlayed)
        XCTAssertEqual(enriched[0].sources.map(\.id), ["account:library-tmdb-1"])
        XCTAssertTrue(enriched[0].sources[0].hasBeenPlayed)
    }

    func testSkipsProviderWorkWhenIdentityIndexHasNoLibraryCopy() async {
        let probe = FetchProbe()
        let items = [MediaItem(id: "tmdb-1", title: "Not Owned", kind: .movie)]

        let enriched = await HeroCandidateWatchStateEnricher.enrich(
            items,
            sourceRefs: { _ in [] },
            fetch: { _ in
                await probe.begin()
                await probe.end()
                return nil
            }
        )

        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(enriched, items)
    }

    func testAlternateSourceHistoryIsFoldedOntoRandomCandidate() async {
        let item = MediaItem(
            id: "origin",
            title: "Movie",
            kind: .movie,
            sourceAccountID: "origin-account"
        )

        let enriched = await HeroCandidateWatchStateEnricher.enrich(
            [item],
            sourceRefs: { _ in
                [MediaSourceRef(accountID: "alternate-account", itemID: "alternate")]
            },
            fetch: { source in
                MediaItem(
                    id: source.itemID,
                    title: "Movie",
                    kind: .movie,
                    hasBeenPlayed: true,
                    sourceAccountID: source.accountID
                )
            }
        )

        XCTAssertTrue(enriched[0].hasBeenPlayed)
        XCTAssertEqual(enriched[0].sources.map(\.id), ["alternate-account:alternate"])
    }

    func testDisabledEnrichmentSkipsIdentityAndProviderWork() async {
        let probe = FetchProbe()
        let items = [MediaItem(id: "tmdb-1", title: "Owned", kind: .movie)]

        let enriched = await HeroCandidateWatchStateEnricher.enrich(
            items,
            enabled: false,
            sourceRefs: { _ in
                XCTFail("Identity lookup should be skipped")
                return [MediaSourceRef(accountID: "account", itemID: "library")]
            },
            fetch: { _ in
                await probe.begin()
                await probe.end()
                return nil
            }
        )

        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(enriched, items)
    }

    func testLiveLookupsUseBoundedConcurrency() async {
        let items = (0..<8).map {
            MediaItem(id: "tmdb-\($0)", title: "\($0)", kind: .movie)
        }
        let probe = FetchProbe()

        _ = await HeroCandidateWatchStateEnricher.enrich(
            items,
            sourceRefs: { item in
                [MediaSourceRef(accountID: "account", itemID: item.id)]
            },
            fetch: { source in
                await probe.begin()
                try? await Task.sleep(nanoseconds: 30_000_000)
                await probe.end()
                return MediaItem(id: source.itemID, title: source.itemID, kind: .movie)
            }
        )

        let calls = await probe.calls
        let maximum = await probe.maximum
        XCTAssertEqual(calls, items.count)
        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 4)
    }

    func testKnownWatchedCandidatesSkipAlternateProviderWork() async {
        let probe = FetchProbe()
        let watched = MediaItem(
            id: "watched",
            title: "Watched",
            kind: .movie,
            hasBeenPlayed: true
        )

        let enriched = await HeroCandidateWatchStateEnricher.enrich(
            [watched],
            sourceRefs: { _ in
                [MediaSourceRef(accountID: "alternate", itemID: "copy")]
            },
            fetch: { _ in
                await probe.begin()
                await probe.end()
                return nil
            }
        )

        let calls = await probe.calls
        XCTAssertEqual(calls, 0)
        XCTAssertEqual(enriched, [watched])
    }

    func testCandidatePoolOversamplesOnlyForWatchedFiltering() {
        XCTAssertEqual(HeroCandidatePool.requestLimit(finalLimit: 8, hideWatched: false), 8)
        XCTAssertEqual(HeroCandidatePool.requestLimit(finalLimit: 8, hideWatched: true), 16)
        XCTAssertEqual(HeroCandidatePool.requestLimit(finalLimit: 30, hideWatched: true), 48)
        XCTAssertEqual(HeroCandidatePool.requestLimit(finalLimit: 0, hideWatched: true), 0)
    }
}
