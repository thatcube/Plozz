import XCTest
import CoreModels
@testable import FeatureHome

@MainActor
final class ItemDetailViewModelTests: XCTestCase {
    private func series(_ id: String) -> MediaItem {
        MediaItem(id: id, title: "Avatar", kind: .series)
    }

    private func season(_ id: String, _ title: String) -> MediaItem {
        MediaItem(id: id, title: title, kind: .season, parentTitle: "Avatar")
    }

    private func episode(_ id: String, number: Int, resume: TimeInterval? = nil) -> MediaItem {
        MediaItem(id: id, title: "Episode \(number)", kind: .episode, episodeNumber: number, resumePosition: resume)
    }

    func testLoadFetchesSeasonsAsChildren() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water"), season("s2", "Book Two: Earth")]
        ]
        provider.allItems = [series("show")]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")

        await vm.load()

        XCTAssertEqual(vm.state.value?.item.id, "show")
        XCTAssertEqual(vm.state.value?.children.map(\.id), ["s1", "s2"])
    }

    func testEnrichesAlternateSourcesAndUnifiesWatchState() async {
        let primary = MediaItem(id: "p1", title: "Dune", kind: .movie, productionYear: 2021,
                                sourceAccountID: "plex",
                                versions: [MediaVersion(id: "pv", height: 1080)])
        let alt = MediaItem(id: "j1", title: "Dune", kind: .movie, productionYear: 2021,
                            resumePosition: 300,
                            sourceAccountID: "jelly",
                            versions: [MediaVersion(id: "jv", height: 2160)],
                            lastPlayedAt: Date(timeIntervalSince1970: 1000))
        let provider = FakeMediaProvider(allItems: [primary, alt])
        let sources = [
            MediaSourceRef(accountID: "plex", itemID: "p1"),
            MediaSourceRef(accountID: "jelly", itemID: "j1")
        ]
        let vm = ItemDetailViewModel(
            provider: provider, itemID: "p1", sourceAccountID: "plex",
            initialSources: sources,
            alternateProviderResolver: { _ in provider }
        )

        await vm.load()

        XCTAssertEqual(vm.sources.count, 2)
        XCTAssertEqual(vm.sources.first { $0.accountID == "plex" }?.versions.map(\.id), ["pv"],
                       "Primary source seeded with the loaded detail's own versions")
        let jelly = vm.sources.first { $0.accountID == "jelly" }
        XCTAssertEqual(jelly?.versions.map(\.id), ["jv"], "Alternate server's versions fetched off the critical path")
        XCTAssertEqual(jelly?.resumePosition, 300)
        XCTAssertEqual(vm.state.value?.item.resumePosition, 300,
                       "Detail hero reflects unified (newest-wins) progress from the alternate server")
    }

    func testSingleSourceItemHasNoSourcePicker() async {
        let movie = MediaItem(id: "m1", title: "Arrival", kind: .movie, productionYear: 2016,
                              sourceAccountID: "plex")
        let provider = FakeMediaProvider(allItems: [movie])
        let vm = ItemDetailViewModel(provider: provider, itemID: "m1", sourceAccountID: "plex",
                                     initialSources: [MediaSourceRef(accountID: "plex", itemID: "m1")])
        await vm.load()
        XCTAssertTrue(vm.sources.isEmpty, "A single-server title carries no sources (no server picker)")
    }

    func testLoadEpisodesFetchesAndCachesPerSeason() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water")],
            "s1": [episode("e1", number: 1), episode("e2", number: 2)]
        ]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        XCTAssertNil(vm.episodes(for: "s1"))

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.episodes(for: "s1")?.map(\.id), ["e1", "e2"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)

        // Re-requesting a cached season does not hit the provider again.
        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
    }

    func testLoadEpisodesTagsChildrenWithSourceAccount() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = [
            "show": [season("s1", "Book One: Water")],
            "s1": [episode("e1", number: 1)]
        ]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show", sourceAccountID: "acct-7")
        await vm.load()
        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.episodes(for: "s1")?.first?.sourceAccountID, "acct-7")
    }

    func testLoadEpisodesCachesEmptyOnFailure() async {
        let provider = FakeMediaProvider(allItems: [series("show")])
        provider.childrenByParent = ["show": [season("s1", "Book One: Water")]]
        // "s1" intentionally absent from childrenByParent → resolves to [].
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.episodes(for: "s1"), [])
    }

    func testLoadFetchesTrailersTaggedWithSource() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem(id: "t1", title: "Trailer", kind: .video)]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            sourceAccountID: "acct-9",
            onlineTrailerResolver: { _ in [MediaItem.youTubeTrailer(videoID: "yt1", title: "online")] },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        // Local trailer is preferred over the online fallback, and stays tagged.
        XCTAssertEqual(vm.trailers.map(\.id), ["t1"])
        XCTAssertEqual(vm.trailers.first?.sourceAccountID, "acct-9")
        XCTAssertFalse(vm.trailers.first?.isYouTubeTrailer ?? true)
    }

    func testFallsBackToOnlineTrailerWhenNoLocal() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        // No local trailers configured → online fallback is used.
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            sourceAccountID: "acct-9",
            onlineTrailerResolver: { item in
                [MediaItem.youTubeTrailer(videoID: "yt1", title: "\(item.title) — Trailer")]
            },
            playableVideoIDResolver: { $0.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.youTubeTrailerVideoID), ["yt1"])
        // Online trailers are not tagged to an account — they route to YouTube.
        XCTAssertNil(vm.trailers.first?.sourceAccountID)
    }

    func testServerYouTubeTrailerIsStampedWithParentTitleAndYear() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        // A server RemoteTrailers entry: a YouTube trailer with a generic name and
        // no parent title/year of its own — and which verifies as playable.
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { $0.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        // Stamped so a later replacement search has a clean title and year.
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")
        XCTAssertEqual(vm.trailers.first?.parentTitle, "Mary Poppins Returns")
        XCTAssertEqual(vm.trailers.first?.productionYear, 2018)
        let subject = vm.trailers.first?.alternativeTrailerSearchSubject
        XCTAssertEqual(subject?.title, "Mary Poppins Returns")
        XCTAssertEqual(subject?.productionYear, 2018)
    }

    func testDeadServerTrailerFallsBackToVerifiedSearchResult() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        // Server points at a now-private video that fails verification.
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in
                [MediaItem.youTubeTrailer(videoID: "freshID", title: "Mary Poppins Returns — Trailer")]
            },
            // Dead server id doesn't verify; the searched replacement does.
            playableVideoIDResolver: { ids in ids.contains("deadID") ? nil : ids.first },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.youTubeTrailerVideoID), ["freshID"])
    }

    func testNoButtonWhenNothingVerifies() async {
        let provider = FakeMediaProvider(
            allItems: [MediaItem(id: "m1", title: "Mary Poppins Returns", kind: .movie, productionYear: 2018)]
        )
        provider.trailersByItem = ["m1": [
            MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")
        ]]
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            // A replacement is found but it also fails to verify → no button.
            onlineTrailerResolver: { _ in
                [MediaItem.youTubeTrailer(videoID: "alsoDead", title: "Mary Poppins Returns — Trailer")]
            },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
    }

    func testLocalTrailerSkipsVerificationAndSearch() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem(id: "t1", title: "Trailer", kind: .video)]]
        let searchCalled = LockedFlag()
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in searchCalled.set(); return [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.map(\.id), ["t1"])
        XCTAssertFalse(searchCalled.value, "Local trailer should not trigger an online search")
        XCTAssertFalse(verifyCalled.value, "Local trailer should not be verification-extracted")
    }

    func testLoadLeavesTrailersEmptyWhenNoLocalOrOnline() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: TrailerResolutionCache()
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
    }

    // MARK: - Fast button: optimistic surfacing + caching

    func testServerTrailerShowsButtonOptimisticallyBeforeVerification() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let gate = AsyncGate()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            // Verification blocks until released — modelling a slow network so the
            // button must appear before it finishes.
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { ids in await gate.wait(); return ids.first },
            trailerCache: TrailerResolutionCache()
        )

        let loadTask = Task { await vm.load() }
        // The button appears optimistically from the server id while the gated
        // verification is still suspended.
        await waitUntil { !vm.trailers.isEmpty }
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")

        gate.open()
        await loadTask.value
        // The verified id (here the same) remains after the pass completes.
        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "serverID")
    }

    func testCachedWorkingOutcomeShowsButtonWithoutReResolving() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        cache.record(.working("cachedID"), for: "m1")
        let searchCalled = LockedFlag()
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in searchCalled.set(); return [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertEqual(vm.trailers.first?.youTubeTrailerVideoID, "cachedID")
        XCTAssertFalse(verifyCalled.value, "A cached outcome should not re-verify")
        XCTAssertFalse(searchCalled.value, "A cached outcome should not re-search")
    }

    func testCachedNoneHidesButtonWithoutWork() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        cache.record(.none, for: "m1")
        let verifyCalled = LockedFlag()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
        XCTAssertFalse(verifyCalled.value, "A cached 'none' should not re-verify")
    }

    func testVerifiedOutcomeIsCachedForNextVisit() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "serverID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { $0.first },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertEqual(cache.outcome(for: "m1"), .working("serverID"))
    }

    func testNoPlayableTrailerIsCachedAsNone() async {
        let provider = FakeMediaProvider(allItems: [MediaItem(id: "m1", title: "Dune", kind: .movie)])
        provider.trailersByItem = ["m1": [MediaItem.youTubeTrailer(videoID: "deadID", title: "Trailer")]]
        let cache = TrailerResolutionCache()
        let vm = ItemDetailViewModel(
            provider: provider,
            itemID: "m1",
            onlineTrailerResolver: { _ in [] },
            playableVideoIDResolver: { _ in nil },
            trailerCache: cache
        )

        await vm.load()

        XCTAssertEqual(cache.outcome(for: "m1"), TrailerResolutionCache.Outcome.none)
        XCTAssertTrue(vm.trailers.isEmpty)
    }

    /// Spins the cooperative runtime until `condition` holds (or a bounded number
    /// of yields elapse), so a test can observe an optimistic state set before a
    /// later `await` resumes.
    private func waitUntil(_ condition: @MainActor () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Condition not met before timeout")
    }
}

/// A one-shot async gate: `wait()` suspends until `open()` is called (or returns
/// immediately if already open). Lets a test hold an injected async closure at a
/// known suspension point to observe intermediate view-model state.
private final class AsyncGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        lock.lock()
        opened = true
        let pending = waiters
        waiters = []
        lock.unlock()
        pending.forEach { $0.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            lock.lock()
            if opened {
                lock.unlock()
                continuation.resume()
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }
}

/// A tiny thread-safe boolean flag for asserting whether an injected async
/// closure was invoked.
private final class LockedFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    func set() { lock.lock(); flag = true; lock.unlock() }
    var value: Bool { lock.lock(); defer { lock.unlock() }; return flag }
}
