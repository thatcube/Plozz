import XCTest
import CoreModels
@testable import FeatureHome

/// Covers the rule that decides whether returning to Home asks the servers
/// anything.
///
/// Home cannot hear that a title was watched, finished or dismissed somewhere
/// else — there is no push, and every in-app signal it has describes something
/// the viewer did here. So without a staleness bound it keeps showing the row it
/// built at launch for as long as the app stays open, which is the reported
/// "Continue Watching isn't in sync": the row was right when it was built, and
/// nothing ever asked again.
///
/// The bound has to cut both ways, and both directions are pinned here. Too eager
/// and ordinary navigation — stepping into a title and back out — refetches and
/// reshuffles the row under the viewer for no new information.
@MainActor
final class HomeViewModelStalenessRefreshTests: XCTestCase {

    private func makeModel(
        provider: CountingResumeProvider,
        policy: ContinueWatchingPolicy
    ) -> HomeViewModel {
        let server = MediaServer(
            id: "srv", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
        )
        let account = Account(id: "acct", server: server, userID: "u", userName: "U", deviceID: "d")
        return HomeViewModel(
            accounts: [ResolvedAccount(account: account, provider: provider)],
            layoutStore: InMemoryHomeLayoutStore(),
            policy: policy
        )
    }

    private var visibility: HomeLibraryVisibility { HomeLibraryVisibility(mergeLibrariesOnHome: true) }

    /// The regression that let a removed title sit on the row all session: three
    /// returns to Home, and not one of them asked a server anything.
    func testAStaleRowIsRefreshedOnReturningToHome() async {
        let provider = CountingResumeProvider()
        // Everything is immediately stale, standing in for a long absence.
        let model = makeModel(provider: provider, policy: ContinueWatchingPolicy(refreshAfter: 0))

        await model.loadIfNeeded(for: visibility)
        let afterFirstLoad = provider.continueWatchingCalls
        XCTAssertGreaterThan(afterFirstLoad, 0, "The first appearance must load")

        await model.loadIfNeeded(for: visibility)

        XCTAssertGreaterThan(
            provider.continueWatchingCalls,
            afterFirstLoad,
            "Returning to a stale row must ask the servers again"
        )
    }

    /// The behaviour the staleness window must not break: back-navigation is
    /// navigation, not new information.
    func testAFreshRowIsLeftAloneOnReturningToHome() async {
        let provider = CountingResumeProvider()
        let model = makeModel(provider: provider, policy: ContinueWatchingPolicy(refreshAfter: 600))

        await model.loadIfNeeded(for: visibility)
        let afterFirstLoad = provider.continueWatchingCalls

        await model.loadIfNeeded(for: visibility)
        await model.loadIfNeeded(for: visibility)

        XCTAssertEqual(
            provider.continueWatchingCalls,
            afterFirstLoad,
            "Within the window a reappearance stays a no-op, so the row cannot reshuffle under the viewer"
        )
    }

    /// A stale refresh must be silent: the loaded rows stay on screen and swap in
    /// place. Dropping to `.loading` would flash the skeleton and reset focus —
    /// the exact thing the original guard existed to prevent.
    func testTheStaleRefreshNeverFlashesTheSkeleton() async {
        let provider = CountingResumeProvider()
        let model = makeModel(provider: provider, policy: ContinueWatchingPolicy(refreshAfter: 0))

        await model.loadIfNeeded(for: visibility)
        XCTAssertNotNil(model.state.value, "Precondition: content is loaded")

        await model.loadIfNeeded(for: visibility)

        XCTAssertNotNil(
            model.state.value,
            "The refresh must keep content loaded throughout rather than passing through a loading state"
        )
    }

    /// A genuine change to what the viewer asked for still reloads, staleness or
    /// not — that path predates this window and must be untouched by it.
    func testAVisibilityChangeStillReloadsWithinTheWindow() async {
        let provider = CountingResumeProvider()
        let model = makeModel(provider: provider, policy: ContinueWatchingPolicy(refreshAfter: 600))

        await model.loadIfNeeded(for: visibility)
        let afterFirstLoad = provider.continueWatchingCalls

        await model.loadIfNeeded(for: HomeLibraryVisibility(mergeLibrariesOnHome: false))

        XCTAssertGreaterThan(provider.continueWatchingCalls, afterFirstLoad)
    }
}

/// Counts resume fetches so a test can tell "Home asked the servers" apart from
/// "Home decided not to bother".
private final class CountingResumeProvider: MediaProvider, @unchecked Sendable {
    let kind: ProviderKind = .jellyfin
    let session = UserSession(
        server: MediaServer(
            id: "srv", name: "S", baseURL: URL(string: "http://host")!, provider: .jellyfin
        ),
        userID: "u",
        userName: "User",
        deviceID: "d",
        accessToken: "TOKEN"
    )

    private let lock = NSLock()
    private var calls = 0
    var continueWatchingCalls: Int {
        lock.lock(); defer { lock.unlock() }; return calls
    }

    func continueWatching(limit: Int) async throws -> [MediaItem] {
        lock.lock(); calls += 1; lock.unlock()
        var item = MediaItem(id: "resume-1", title: "Halfway", kind: .movie)
        item.resumePosition = 600
        item.lastPlayedAt = Date()
        return [item]
    }

    func libraries() async throws -> [MediaLibrary] {
        [MediaLibrary(id: "L1", title: "Movies", kind: .movie)]
    }

    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { throw AppError.notFound }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: 0, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { throw AppError.notFound }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {}
    func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}
