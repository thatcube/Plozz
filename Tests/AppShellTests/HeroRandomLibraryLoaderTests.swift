import XCTest
import CoreModels
@testable import AppShell

final class HeroRandomLibraryLoaderTests: XCTestCase {
    private actor ConcurrencyProbe {
        private(set) var active = 0
        private(set) var maximum = 0
        private(set) var requested: [HeroRandomLibrary] = []

        func begin(_ library: HeroRandomLibrary) {
            active += 1
            maximum = max(maximum, active)
            requested.append(library)
        }

        func end() {
            active -= 1
        }
    }

    /// Waits until the probe reports `count` in-flight fetches, or the timeout
    /// elapses. Uses real (short) sleeps rather than a fixed `Task.yield()` budget:
    /// a yield only reschedules the caller and can burn through its whole budget in
    /// microseconds before the child tasks are ever scheduled (observed on loaded CI
    /// runners, where `active` stayed 0). Sleeping cedes actual wall-clock time so
    /// the concurrent fetches get to run.
    private func waitUntil(_ probe: ConcurrencyProbe,
                           active count: Int,
                           timeout: TimeInterval = 3) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if await probe.active == count { return }
            try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
        }
    }

    func testEligibleLibrariesFetchConcurrentlyWithinBound() async {
        let libraries = (0..<6).map {
            HeroRandomLibrary(
                accountID: "account",
                libraryID: "library-\($0)",
                kind: $0.isMultiple(of: 2) ? .movie : .series
            )
        }
        let probe = ConcurrencyProbe()

        let result = await HeroRandomLibraryLoader.load(
            libraries: libraries,
            limit: 6
        ) { library, _ in
            await probe.begin(library)
            try? await Task.sleep(nanoseconds: 40_000_000)
            await probe.end()
            return [MediaItem(id: library.libraryID, title: library.libraryID, kind: .movie)]
        }
        let maximum = await probe.maximum
        let requested = await probe.requested

        XCTAssertGreaterThan(maximum, 1)
        XCTAssertLessThanOrEqual(maximum, 4)
        XCTAssertEqual(Set(requested), Set(libraries))
        XCTAssertEqual(Set(result.map(\.id)), Set(libraries.map(\.libraryID)))
    }

    func testSkipsUnsupportedAndDuplicateLibraries() async {
        let movies = HeroRandomLibrary(
            accountID: "account",
            libraryID: "movies",
            kind: .movie
        )
        let music = HeroRandomLibrary(
            accountID: "account",
            libraryID: "music",
            kind: .folder
        )
        let probe = ConcurrencyProbe()

        _ = await HeroRandomLibraryLoader.load(
            libraries: [movies, movies, music],
            limit: 8
        ) { library, _ in
            await probe.begin(library)
            await probe.end()
            return []
        }
        let requested = await probe.requested

        XCTAssertEqual(requested, [movies])
    }

    func testRequestLimitDistributesOversamplingAcrossLibraries() {
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 1),
            20
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 2),
            15
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 20, libraryCount: 4),
            8
        )
        XCTAssertEqual(
            HeroRandomLibraryLoader.requestLimit(totalLimit: 8, libraryCount: 4),
            3
        )
    }

    func testCancellationDoesNotQueueAdditionalLibraries() async {
        let libraries = (0..<8).map {
            HeroRandomLibrary(
                accountID: "account",
                libraryID: "library-\($0)",
                kind: .movie
            )
        }
        let probe = ConcurrencyProbe()
        let task = Task {
            await HeroRandomLibraryLoader.load(libraries: libraries, limit: 8) { library, _ in
                await probe.begin(library)
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                await probe.end()
                return [MediaItem(id: library.libraryID, title: library.libraryID, kind: .movie)]
            }
        }

        await waitUntil(probe, active: 4)
        let activeBeforeCancellation = await probe.active
        XCTAssertEqual(activeBeforeCancellation, 4)

        task.cancel()
        let result = await task.value
        let requested = await probe.requested

        XCTAssertTrue(result.isEmpty)
        XCTAssertEqual(requested.count, 4)
    }
}

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
