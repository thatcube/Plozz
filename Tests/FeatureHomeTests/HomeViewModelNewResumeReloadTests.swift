import XCTest
import CoreModels
@testable import FeatureHome

/// Verifies that a brand-new *in-progress* resume for a title not already on the
/// Continue Watching row triggers a silent re-aggregation so the just-started card
/// appears — the "I played something new and it never showed in Continue Watching
/// until I relaunched" gap. Mark-watched / finish removes an existing card without
/// a reload; re-watch progress updates it in place.
@MainActor
final class HomeViewModelNewResumeReloadTests: XCTestCase {
    private func makeViewModel(provider: FakeMediaProvider) -> HomeViewModel {
        let server = MediaServer(id: "srv-a", name: "Local", baseURL: URL(string: "http://host")!, provider: .jellyfin)
        let account = Account(id: "a", server: server, userID: "u", userName: "Me", deviceID: "d")
        let resolved = ResolvedAccount(account: account, provider: provider)
        return HomeViewModel(
            accounts: [resolved],
            layoutStore: InMemoryHomeLayoutStore(),
            currentVisibility: { .default }
        )
    }

    /// Polls until `predicate` holds or a short budget elapses, letting the silent
    /// reload's detached `Task` run to completion.
    private func waitUntil(_ predicate: () -> Bool) async {
        for _ in 0..<200 {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 2_000_000)
        }
    }

    private func cw(_ vm: HomeViewModel) -> [MediaItem] {
        vm.state.value?.continueWatching ?? []
    }

    func testNewResumeTriggersSilentReloadThatSurfacesTheCard() async {
        let provider = FakeMediaProvider(allItems: [])
        // Home already has one unrelated title on Continue Watching, so it loads to
        // `.loaded` (an empty Home renders a different state entirely).
        provider.continueWatchingItems = [MediaItem(id: "m0", title: "Old", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(cw(vm).count, 1)
        XCTAssertFalse(cw(vm).contains { $0.id == "m1" })

        // The user plays a brand-new title; its provider now reports it as
        // resumable (a media share persists this to disk before the mutation posts).
        provider.continueWatchingItems = [
            MediaItem(id: "m1", title: "Movie", kind: .movie),
            MediaItem(id: "m0", title: "Old", kind: .movie)
        ]
        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: ["m1"],
                scopedItemIDs: ["a:m1"],
                resumePosition: 120,
                playedPercentage: 0.1
            )
        )

        // The silent reload re-aggregates and the new card slots in — no user-visible
        // reload was needed.
        await waitUntil { self.cw(vm).contains { $0.id == "m1" } }
        XCTAssertEqual(provider.librariesCallCount, 2, "a new resume should trigger exactly one silent re-aggregation")
        XCTAssertTrue(cw(vm).contains { $0.id == "m1" })
    }

    func testPendingHeroMutationsApplyInCaptureOrder() async {
        let target = WatchMutationTarget(accountID: "a", itemID: "m1")
        let older = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_000),
            canonicalMediaID: "tmdb:1",
            played: true,
            targets: [target]
        )
        let newer = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 2_000),
            canonicalMediaID: "tmdb:1",
            played: false,
            targets: [target]
        )
        let viewModel = HomeViewModel(
            accounts: [],
            pendingWatchMutations: { [newer, older] }
        )

        let projected = await viewModel.pendingHeroWatchMutations()

        XCTAssertEqual(projected.map(\.played), [true, false],
                       "Newest durable intent must be reduced last regardless of queue slot order")
    }

    func testReWatchOfExistingCardDoesNotReload() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m1", title: "Movie", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)
        XCTAssertEqual(cw(vm).count, 1)

        // Progress on a title already on the row updates in place — no reload.
        vm.applyWatchedState(
            MediaItemMutation(itemIDs: ["m1"], scopedItemIDs: ["a:m1"], resumePosition: 240, playedPercentage: 0.2)
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(provider.librariesCallCount, 1, "an in-place update must not re-aggregate")
    }

    func testFinishDoesNotReload() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [MediaItem(id: "m0", title: "Old", kind: .movie)]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(provider.librariesCallCount, 1)

        // A completed play (played=true, resume cleared) for a title not on the row
        // must never force a reload to "insert" a finished title.
        vm.applyWatchedState(
            MediaItemMutation(itemIDs: ["m1"], scopedItemIDs: ["a:m1"], played: true, resumePosition: 0, playedPercentage: 1)
        )
        await Task.yield()
        try? await Task.sleep(nanoseconds: 20_000_000)
        XCTAssertEqual(provider.librariesCallCount, 1, "a finish must not re-aggregate")
    }

    func testMarkWatchedRemovesExistingContinueWatchingCard() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.continueWatchingItems = [
            MediaItem(
                id: "episode",
                title: "Episode",
                kind: .episode,
                resumePosition: 420,
                playedPercentage: 0.2
            )
        ]
        let vm = makeViewModel(provider: provider)
        await vm.load()
        XCTAssertEqual(cw(vm).map(\.id), ["episode"])

        vm.applyWatchedState(
            MediaItemMutation(
                itemIDs: ["episode"],
                scopedItemIDs: ["a:episode"],
                played: true,
                resumePosition: 0,
                playedPercentage: 1
            )
        )

        XCTAssertTrue(cw(vm).isEmpty)
        XCTAssertEqual(
            provider.librariesCallCount,
            1,
            "marking watched should remove the card without reloading Home"
        )
    }
}
