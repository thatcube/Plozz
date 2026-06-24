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
            onlineTrailerResolver: { _ in [MediaItem.youTubeTrailer(videoID: "yt1", title: "online")] }
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
            playableVideoIDResolver: { $0.first }
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
            playableVideoIDResolver: { $0.first }
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
            playableVideoIDResolver: { ids in ids.contains("deadID") ? nil : ids.first }
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
            playableVideoIDResolver: { _ in nil }
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
            playableVideoIDResolver: { _ in verifyCalled.set(); return nil }
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
            playableVideoIDResolver: { _ in nil }
        )

        await vm.load()

        XCTAssertTrue(vm.trailers.isEmpty)
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
