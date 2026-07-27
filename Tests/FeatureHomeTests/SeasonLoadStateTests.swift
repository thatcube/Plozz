import XCTest
import CoreModels
import FeatureHomeCore
@testable import FeatureHome

/// A failed season fetch and a genuinely empty season both cache `[]` —
/// deliberately, so neither re-requests on every focus change. But only one of
/// them is an answer.
///
/// Anything deciding from that emptiness — which episode to resume, whether a
/// show has been started — must not act on a dropped request as though the season
/// were really empty, or one bad moment on the network pins the wrong answer for
/// as long as the page stays open.
@MainActor
final class SeasonLoadStateTests: XCTestCase {
    private func series(_ id: String) -> MediaItem {
        MediaItem(id: id, title: "Show", kind: .series)
    }

    private func season(_ id: String) -> MediaItem {
        MediaItem(id: id, title: "Season 1", kind: .season, parentTitle: "Show", seasonNumber: 1)
    }

    private func episode(_ id: String, number: Int) -> MediaItem {
        MediaItem(id: id, title: "Episode \(number)", kind: .episode, episodeNumber: number)
    }

    private func makeViewModel(_ provider: FakeMediaProvider) async -> ItemDetailViewModel {
        provider.allItems = [series("show")]
        let vm = ItemDetailViewModel(provider: provider, itemID: "show")
        await vm.load()
        return vm
    }

    func testLoadedSeasonIsAuthoritative() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = [
            "show": [season("s1")],
            "s1": [episode("e1", number: 1), episode("e2", number: 2)]
        ]
        let vm = await makeViewModel(provider)

        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.seasonLoadState(for: "s1"), .loaded([episode("e1", number: 1), episode("e2", number: 2)]))
        XCTAssertEqual(vm.seasonLoadState(for: "s1").authoritativeEpisodes?.count, 2)
    }

    /// A season the server says is empty really is empty — that is an answer, and
    /// callers may act on it.
    func testGenuinelyEmptySeasonIsAuthoritative() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["show": [season("s1")], "s1": []]
        let vm = await makeViewModel(provider)

        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.seasonLoadState(for: "s1"), .loaded([]))
        XCTAssertEqual(vm.seasonLoadState(for: "s1").authoritativeEpisodes, [])
    }

    /// The case that used to be indistinguishable: the fetch failed, so the empty
    /// list is a placeholder and must not be read as "no episodes".
    func testFailedSeasonIsNotAuthoritative() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["show": [season("s1")], "s1": [episode("e1", number: 1)]]
        provider.childrenFailuresByParent = ["s1": [1]]
        let vm = await makeViewModel(provider)

        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.seasonLoadState(for: "s1"), .failed)
        XCTAssertNil(
            vm.seasonLoadState(for: "s1").authoritativeEpisodes,
            "a dropped request must not read as an empty season"
        )
        // Rendering still gets the cached list, which is right — an empty rail is
        // an empty rail. Only *decisions* need the distinction.
        XCTAssertEqual(vm.episodes(for: "s1"), [])
    }

    /// Without this a single dropped request left the season empty for as long as
    /// the page stayed open.
    func testFailedSeasonRetriesAndRecovers() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["show": [season("s1")], "s1": [episode("e1", number: 1)]]
        provider.childrenFailuresByParent = ["s1": [1]]
        let vm = await makeViewModel(provider)

        await vm.loadEpisodes(for: "s1")
        XCTAssertEqual(vm.seasonLoadState(for: "s1"), .failed)

        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(vm.seasonLoadState(for: "s1").authoritativeEpisodes?.map(\.id), ["e1"])
        XCTAssertEqual(provider.childrenCallCount["s1"], 2, "the failed season is retried exactly once more")
    }

    /// A season that loaded successfully must NOT re-request — that is the whole
    /// reason the empty result is cached.
    func testSuccessfullyLoadedSeasonDoesNotRefetch() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["show": [season("s1")], "s1": [episode("e1", number: 1)]]
        let vm = await makeViewModel(provider)

        await vm.loadEpisodes(for: "s1")
        await vm.loadEpisodes(for: "s1")
        await vm.loadEpisodes(for: "s1")

        XCTAssertEqual(provider.childrenCallCount["s1"], 1)
    }

    func testNeverRequestedSeasonIsNotLoaded() async {
        let provider = FakeMediaProvider(allItems: [])
        provider.childrenByParent = ["show": [season("s1")]]
        let vm = await makeViewModel(provider)

        XCTAssertEqual(vm.seasonLoadState(for: "s1"), .notLoaded)
        XCTAssertNil(vm.seasonLoadState(for: "s1").authoritativeEpisodes)
    }
}
