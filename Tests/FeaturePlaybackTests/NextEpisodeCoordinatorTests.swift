#if canImport(AVFoundation)
import CoreModels
import Foundation
import XCTest

@testable import FeaturePlayback

@MainActor
final class NextEpisodeCoordinatorTests: XCTestCase {

    private var retainedHosts: [SpyNextEpisodeHost] = []

    override func tearDown() {
        retainedHosts.removeAll()
        super.tearDown()
    }

    private func makeSUT(
        providerKind: ProviderKind = .plex,
        next: MediaItem? = MediaItem(id: "next-1", title: "Next", kind: .episode, runtime: 1_400),
        showUpNextCard: Bool = true
    ) -> (NextEpisodeCoordinator, SpyNextEpisodeHost, UpNextSpyEngine, UpNextRecordingProvider) {
        let engine = UpNextSpyEngine()
        let provider = UpNextRecordingProvider(kind: providerKind)
        let host = SpyNextEpisodeHost(engine: engine, provider: provider)
        host.nextEpisodeCandidate = next
        retainedHosts.append(host)
        var settings = PlaybackSettings.default
        settings.showUpNextCard = showUpNextCard
        let controls = PlayerControlsModel()
        let sut = NextEpisodeCoordinator(
            host: host,
            controls: controls,
            playbackSettings: settings,
            spoilerSettings: .default
        )
        return (sut, host, engine, provider)
    }

    private func waitUntil(
        _ predicate: @escaping () -> Bool,
        timeout: TimeInterval = 2.0
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return }
            await Task.yield()
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
    }

    private func prefetched(itemID: String, engineKind: PlaybackEngineKind = .native,
                            metadata: MediaSourceMetadata? = nil) -> PlayerViewModel.PrefetchedPlayback {
        let item = MediaItem(id: itemID, title: "N", kind: .episode)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/\(itemID).m3u8")!,
            playSessionID: "session-\(itemID)",
            sourceMetadata: metadata
        )
        return PlayerViewModel.PrefetchedPlayback(itemID: itemID, request: request, engineKind: engineKind)
    }

    // MARK: - prefetch (one-shot, eager vs windowed)

    func testEagerPrefetchFiresOnceAndCaches() async {
        let (sut, host, _, _) = makeSUT(providerKind: .plex)
        host.resolveResult = prefetched(itemID: "next-1")
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { sut.prefetchedNext != nil }
        XCTAssertEqual(sut.prefetchedNext?.itemID, "next-1")
        XCTAssertEqual(host.resolveCallCount, 1)

        // One-shot: a second call must NOT re-resolve.
        sut.startNextEpisodePrefetch(trigger: "eager")
        await Task.yield()
        XCTAssertEqual(host.resolveCallCount, 1, "prefetch is one-shot per player")
    }

    func testFailedPrefetchDoesNotReArm() async {
        let (sut, host, _, _) = makeSUT(providerKind: .jellyfin)
        host.resolveError = TestError.boom
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { host.resolveCallCount == 1 }
        XCTAssertNil(sut.prefetchedNext)
        // A failed prefetch must not re-arm (would re-POST + orphan a Jellyfin session).
        sut.startNextEpisodePrefetch(trigger: "eager")
        await Task.yield()
        XCTAssertEqual(host.resolveCallCount, 1, "a failed prefetch must not re-arm")
    }

    func testWindowedPrefetchNoOpForIdempotentProvider() async {
        let (sut, host, engine, _) = makeSUT(providerKind: .plex)
        engine.duration = 100
        engine._currentTime = 50 // near end
        sut.maybeStartWindowedNextPrefetch()
        await Task.yield()
        XCTAssertEqual(host.resolveCallCount, 0, "idempotent providers use the eager path, never windowed")
    }

    func testWindowedPrefetchFiresWhenNearEndForJellyfin() async {
        let (sut, host, engine, _) = makeSUT(providerKind: .jellyfin)
        engine.duration = 100
        engine._currentTime = 50 // remaining 50 <= 90 lead
        host.resolveResult = prefetched(itemID: "next-1")
        sut.maybeStartWindowedNextPrefetch()
        await waitUntil { host.resolveCallCount == 1 }
        XCTAssertEqual(host.resolveCallCount, 1)
    }

    func testWindowedPrefetchNoOpWhenNotNearEnd() async {
        let (sut, host, engine, _) = makeSUT(providerKind: .jellyfin)
        engine.duration = 1_000
        engine._currentTime = 0 // remaining 1000 > 90, window closed
        sut.maybeStartWindowedNextPrefetch()
        await Task.yield()
        XCTAssertEqual(host.resolveCallCount, 0, "window closed → no prefetch")
    }

    // MARK: - consume / release

    func testConsumePrefetchHitClearsAndReturns() async {
        let (sut, host, _, _) = makeSUT(providerKind: .plex)
        host.resolveResult = prefetched(itemID: "next-1")
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { sut.prefetchedNext != nil }

        let consumed = sut.consumePrefetchedNext(matching: "next-1")
        XCTAssertEqual(consumed?.itemID, "next-1")
        XCTAssertNil(sut.prefetchedNext, "a consumed prefetch is cleared so teardown can't release it")
        XCTAssertNil(sut.consumePrefetchedNext(matching: "next-1"), "second consume is a miss")
    }

    func testConsumePrefetchMissKeeps() async {
        let (sut, host, _, _) = makeSUT(providerKind: .plex)
        host.resolveResult = prefetched(itemID: "next-1")
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { sut.prefetchedNext != nil }

        XCTAssertNil(sut.consumePrefetchedNext(matching: "other"), "mismatched id → miss")
        XCTAssertNotNil(sut.prefetchedNext, "a miss must not clear the cached prefetch")
    }

    func testReleaseOrphanedPrefetchReportsStopForJellyfin() async {
        let (sut, host, _, provider) = makeSUT(providerKind: .jellyfin)
        host.resolveResult = prefetched(itemID: "next-1")
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { sut.prefetchedNext != nil }

        await sut.releaseOrphanedPrefetchIfNeeded()
        let reports = await provider.stopReports
        XCTAssertEqual(reports.count, 1, "a non-idempotent orphan is released with a .stop")
        XCTAssertNil(sut.prefetchedNext)
    }

    func testReleaseOrphanedPrefetchNoOpForIdempotentProvider() async {
        let (sut, host, _, provider) = makeSUT(providerKind: .plex)
        host.resolveResult = prefetched(itemID: "next-1")
        sut.startNextEpisodePrefetch(trigger: "eager")
        await waitUntil { sut.prefetchedNext != nil }

        await sut.releaseOrphanedPrefetchIfNeeded()
        let reports = await provider.stopReports
        XCTAssertEqual(reports.count, 0, "idempotent providers create no server session to release")
    }

    // MARK: - display-mode preservation

    func testPreserveDisplayModeBothPlozzigenSameHDR() {
        let (sut, host, _, _) = makeSUT()
        host.contentDisplayMode = .dolbyVision
        host.currentEngineKind = .plozzigen
        let next = prefetched(itemID: "n", engineKind: .plozzigen,
                              metadata: MediaSourceMetadata(video: .init(videoRangeType: "DOVI")))
        XCTAssertTrue(sut.shouldPreserveDisplayMode(forNext: next))
    }

    func testPreserveDisplayModeFalseOnNativeSide() {
        let (sut, host, _, _) = makeSUT()
        host.contentDisplayMode = .dolbyVision
        host.currentEngineKind = .native // outgoing native → always full reset
        let next = prefetched(itemID: "n", engineKind: .plozzigen,
                              metadata: MediaSourceMetadata(video: .init(videoRangeType: "DOVI")))
        XCTAssertFalse(sut.shouldPreserveDisplayMode(forNext: next))
    }

    func testPreserveDisplayModeFalseOnModeMismatch() {
        let (sut, host, _, _) = makeSUT()
        host.contentDisplayMode = .hdr10
        host.currentEngineKind = .plozzigen
        let next = prefetched(itemID: "n", engineKind: .plozzigen,
                              metadata: MediaSourceMetadata(video: .init(videoRangeType: "DOVI")))
        XCTAssertFalse(sut.shouldPreserveDisplayMode(forNext: next), "a genuine mode change keeps the full reset")
    }

    // MARK: - first-frame gate

    func testFirstFrameClearsImmediatelyWhenAlreadyPresenting() {
        let (sut, _, engine, _) = makeSUT()
        engine.preventsDisplaySleep = true
        sut.beginAwaitingFirstFrame()
        XCTAssertFalse(sut.awaitingFirstFrame, "an already-presenting engine never holds the spinner")
    }

    func testFirstFrameHoldsThenClearsWhenPictureArrives() async {
        let (sut, _, engine, _) = makeSUT()
        engine.preventsDisplaySleep = false
        sut.beginAwaitingFirstFrame()
        XCTAssertTrue(sut.awaitingFirstFrame, "the spinner holds until the picture is up")
        engine.preventsDisplaySleep = true // picture arrives
        await waitUntil { sut.awaitingFirstFrame == false }
        XCTAssertFalse(sut.awaitingFirstFrame)
    }

    func testClearFirstFrameWaitStopsHolding() {
        let (sut, _, engine, _) = makeSUT()
        engine.preventsDisplaySleep = false
        sut.beginAwaitingFirstFrame()
        XCTAssertTrue(sut.awaitingFirstFrame)
        sut.clearFirstFrameWait()
        XCTAssertFalse(sut.awaitingFirstFrame)
    }

    // MARK: - Up Next card

    func testUpdateUpNextCardBuildsWhenEnabled() {
        let controls = PlayerControlsModel()
        let engine = UpNextSpyEngine()
        let provider = UpNextRecordingProvider(kind: .plex)
        let host = SpyNextEpisodeHost(engine: engine, provider: provider)
        host.nextEpisodeCandidate = MediaItem(id: "n", title: "Next", kind: .episode,
                                              parentTitle: "Show", seasonNumber: 1, episodeNumber: 2)
        retainedHosts.append(host)
        var settings = PlaybackSettings.default
        settings.showUpNextCard = true
        let coord = NextEpisodeCoordinator(
            host: host, controls: controls, playbackSettings: settings, spoilerSettings: .default)
        coord.updateUpNextCard()
        XCTAssertNotNil(controls.upNext, "an enabled card with a next episode publishes an UpNextInfo")
    }

    func testUpdateUpNextCardClearsWhenDisabled() {
        let controls = PlayerControlsModel()
        let engine = UpNextSpyEngine()
        let provider = UpNextRecordingProvider(kind: .plex)
        let host = SpyNextEpisodeHost(engine: engine, provider: provider)
        host.nextEpisodeCandidate = MediaItem(id: "n", title: "N", kind: .episode)
        retainedHosts.append(host)
        var settings = PlaybackSettings.default
        settings.showUpNextCard = false
        let coord = NextEpisodeCoordinator(
            host: host, controls: controls, playbackSettings: settings, spoilerSettings: .default)
        controls.upNext = UpNextInfo(episode: host.nextEpisodeCandidate!, showName: "x",
                                     metaLine: nil, thumbnailURLs: [], blurThumbnail: false)
        coord.updateUpNextCard()
        XCTAssertNil(controls.upNext, "a disabled card is cleared")
    }

    // MARK: - pure meta formatting

    func testUpNextMetaSeasonEpisodeAndRuntime() {
        let item = MediaItem(id: "e", title: "E", kind: .episode,
                             seasonNumber: 2, episodeNumber: 3, runtime: 48 * 60)
        XCTAssertEqual(NextEpisodeCoordinator.upNextMeta(for: item), "S2 · E3 · 48m")
    }

    func testUpNextRuntimeLabelHoursAndMinutes() {
        XCTAssertEqual(NextEpisodeCoordinator.upNextRuntimeLabel(48 * 60), "48m")
        XCTAssertEqual(NextEpisodeCoordinator.upNextRuntimeLabel(62 * 60), "1h 2m")
        XCTAssertEqual(NextEpisodeCoordinator.upNextRuntimeLabel(60 * 60), "1h")
    }
}

private enum TestError: Error { case boom }

@MainActor
private final class SpyNextEpisodeHost: NextEpisodeCoordinatorHost {
    var nextEpisodeCandidate: MediaItem?
    let engine: UpNextSpyEngine
    let provider: UpNextRecordingProvider
    var contentDisplayMode: HDRDisplayMode = .sdr
    var currentEngineKind: PlaybackEngineKind = .native
    var bringUpStartedAt: Date?

    var resolveResult: PlayerViewModel.PrefetchedPlayback?
    var resolveError: Error?
    private(set) var resolveCallCount = 0

    init(engine: UpNextSpyEngine, provider: UpNextRecordingProvider) {
        self.engine = engine
        self.provider = provider
    }

    var upNextEngine: any VideoEngine { engine }
    var upNextProvider: any MediaProvider { provider }
    var upNextContentDisplayMode: HDRDisplayMode { contentDisplayMode }
    var upNextCurrentEngineKind: PlaybackEngineKind { currentEngineKind }
    var upNextBringUpStartedAt: Date? { bringUpStartedAt }

    func upNextResolveAndRoute(
        itemID: String, mediaSourceID: String?, forceTranscode: Bool
    ) async throws -> PlayerViewModel.PrefetchedPlayback {
        resolveCallCount += 1
        if let resolveError { throw resolveError }
        guard let resolveResult else { throw TestError.boom }
        return resolveResult
    }
}

private actor UpNextRecordingProvider: MediaProvider {
    nonisolated let kind: ProviderKind
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server", name: "Server",
            baseURL: URL(string: "https://example.test")!, provider: .jellyfin),
        userID: "user", userName: "User", deviceID: "device", accessToken: "token")

    private(set) var stopReports: [PlaybackProgress] = []

    init(kind: ProviderKind) { self.kind = kind }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { MediaItem(id: id, title: "x", kind: .episode) }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest {
        PlaybackRequest(item: MediaItem(id: itemID, title: "x", kind: .episode),
                        streamURL: URL(string: "https://example.test/a.m3u8")!)
    }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        try await playbackInfo(for: itemID)
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        if event == .stop { stopReports.append(progress) }
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class UpNextSpyEngine: VideoEngine {
    let displayName = "upnext-spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var duration: TimeInterval = 1_000
    var _currentTime: TimeInterval = 0
    var currentTime: TimeInterval { _currentTime }
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async { status = .ready }
    func play() { isPaused = false }
    func pause() { isPaused = true }
    func reloadAfterForeground() async throws {}
    func seek(to seconds: TimeInterval) async { _currentTime = seconds }
    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async { _currentTime = seconds }
    func stop() { status = .idle }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
