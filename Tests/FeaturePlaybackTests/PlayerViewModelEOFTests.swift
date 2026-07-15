#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerViewModelEOFTests: XCTestCase {
    func testStopAfterNaturalEndStillWritesFinalFurthestPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )

        await viewModel.load()
        engine.duration = 120
        engine.furthestObservedPosition = 120
        engine.currentTime = 0
        engine.onEnded?()

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "stop"])
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
        XCTAssertEqual(reports.last?.progress.durationSeconds, 120)
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 100)
    }

    func testForcedCheckpointCapturesPausedPosition() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let checkpoints = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackCheckpoint: { position, percent in
                checkpoints.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 120
        engine.currentTime = 30
        engine.furthestObservedPosition = 30
        engine.isPaused = true

        viewModel.checkpointNow()

        XCTAssertEqual(checkpoints.onlyCall?.position, 30)
        XCTAssertEqual(checkpoints.onlyCall?.percent, 25)
    }

    func testInactiveOnlyPauseDoesNotReloadEngine() async {
        let (viewModel, engine, _) = makeViewModel()
        await viewModel.load()

        viewModel.suspendForBackground()
        await viewModel.resumeAfterBackground()

        XCTAssertEqual(engine.reloadAfterForegroundCount, 0)
        XCTAssertTrue(engine.isPaused)
    }

    func testForegroundReturnReloadsOnceAndRemainsPaused() async {
        let (viewModel, engine, provider) = makeViewModel()
        await viewModel.load()
        engine.currentTime = 30

        viewModel.didEnterBackground()
        await viewModel.resumeAfterBackground()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(viewModel.controls.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start", "pause"])
    }

    func testBackgroundDuringBringUpReportsPausedStartBeforeRecovery() async {
        let (viewModel, engine, provider) = makeViewModel()

        viewModel.didEnterBackground()
        await viewModel.load()
        await viewModel.resumeAfterBackground()
        for _ in 0..<10 { await Task.yield() }

        XCTAssertEqual(engine.reloadAfterForegroundCount, 1)
        XCTAssertTrue(engine.isPaused)
        let reports = await provider.reports
        XCTAssertEqual(reports.map(\.event.rawValue), ["start"])
        XCTAssertEqual(reports.first?.progress.isPaused, true)
    }

    func testStopAfterRewindUsesCurrentPositionInsteadOfFurthest() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 600)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let stopped = PlaybackStoppedRecorder()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine }),
            onPlaybackStopped: { position, percent in
                stopped.record(position: position, percent: percent)
            }
        )
        await viewModel.load()
        engine.duration = 600
        engine.furthestObservedPosition = 427
        engine.currentTime = 120

        await viewModel.stop()

        let reports = await provider.reports
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 20)
        XCTAssertEqual(reports.last?.progress.positionSeconds, 120)
    }

    func testNetworkFileFailureReplacesPlozzigenOnceAndIgnoresOldCallback() async throws {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let identity = try RemoteFileIdentity(
            kind: .strongETag,
            value: "\"movie-v1\""
        )
        let representation = try RemoteFileRepresentation(
            size: 1_024,
            identity: identity,
            consistency: .stronglyBound
        )
        let locator = try NetworkFileLocator(
            accountID: "account",
            sourceID: "source",
            credentialRevision: CredentialRevision(),
            relativePath: "Movies/Movie.mkv",
            representation: representation,
            formatHint: MediaFormatHint(
                container: "mkv",
                mimeType: "video/x-matroska"
            )
        )
        let request = PlaybackRequest(
            item: item,
            playbackSource: .networkFile(locator)
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        var plozzigenEngines: [SpyVideoEngine] = []
        let factory = EngineFactory(
            makeNative: { _ in native },
            makePlozzigen: {
                let engine = SpyVideoEngine()
                plozzigenEngines.append(engine)
                return engine
            }
        )
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: factory
        )

        await viewModel.load()
        XCTAssertEqual(plozzigenEngines.count, 1)
        let staleFailure = try XCTUnwrap(plozzigenEngines[0].onFailure)

        staleFailure(.invalidResponse)
        for _ in 0..<50
        where plozzigenEngines.count < 2 || plozzigenEngines[1].loadCount < 1 {
            await Task.yield()
        }

        XCTAssertEqual(plozzigenEngines.count, 2)
        XCTAssertEqual(plozzigenEngines[0].stopCount, 1)
        XCTAssertEqual(plozzigenEngines[1].loadCount, 1)

        staleFailure(.unknown("late old-engine failure"))
        await Task.yield()
        XCTAssertEqual(plozzigenEngines.count, 2)

        plozzigenEngines[1].onFailure?(.invalidResponse)
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(plozzigenEngines.count, 2)

        await viewModel.stop()
    }

    private func makeViewModel() -> (
        PlayerViewModel,
        SpyVideoEngine,
        RecordingPlaybackProvider
    ) {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine })
        )
        return (viewModel, engine, provider)
    }
}

private actor RecordingPlaybackProvider: MediaProvider {
    struct Report: Sendable {
        let event: PlaybackEvent
        let progress: PlaybackProgress
    }

    nonisolated let kind: ProviderKind = .jellyfin
    nonisolated let session = UserSession(
        server: MediaServer(
            id: "server",
            name: "Server",
            baseURL: URL(string: "https://example.test")!,
            provider: .jellyfin
        ),
        userID: "user",
        userName: "User",
        deviceID: "device",
        accessToken: "token"
    )

    private let request: PlaybackRequest
    private(set) var reports: [Report] = []

    init(request: PlaybackRequest) {
        self.request = request
    }

    func libraries() async throws -> [MediaLibrary] { [] }
    func continueWatching(limit: Int) async throws -> [MediaItem] { [] }
    func latest(limit: Int) async throws -> [MediaItem] { [] }
    func item(id: String) async throws -> MediaItem { request.item }
    func children(of itemID: String) async throws -> [MediaItem] { [] }
    func items(in containerID: String, kind: MediaItemKind, page: PageRequest) async throws -> MediaPage {
        MediaPage(items: [], startIndex: page.startIndex, totalCount: 0)
    }
    func search(query: String, limit: Int) async throws -> [MediaItem] { [] }
    func playbackInfo(for itemID: String) async throws -> PlaybackRequest { request }
    func playbackInfo(for itemID: String, mediaSourceID: String?, forceTranscode: Bool) async throws -> PlaybackRequest {
        request
    }
    func reportPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async throws {
        reports.append(Report(event: event, progress: progress))
    }
    nonisolated func imageURL(itemID: String, kind: ImageKind, maxWidth: Int?) -> URL? { nil }
}

@MainActor
private final class SpyVideoEngine: VideoEngine {
    let displayName = "spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 0
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var loadCount = 0
    var stopCount = 0
    var reloadAfterForegroundCount = 0

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loadCount += 1
        status = .ready
        currentTime = startPosition
        furthestObservedPosition = max(furthestObservedPosition, startPosition)
    }

    func play() { isPaused = false }
    func pause() { isPaused = true }
    func reloadAfterForeground() async throws {
        reloadAfterForegroundCount += 1
    }
    func seek(to seconds: TimeInterval) async {
        currentTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }
    func stop() {
        stopCount += 1
        status = .idle
        duration = 0
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

private final class PlaybackStoppedRecorder: @unchecked Sendable {
    struct Call {
        let position: TimeInterval
        let percent: Double
    }

    private let lock = NSLock()
    private var calls: [Call] = []

    var onlyCall: Call? {
        lock.lock()
        defer { lock.unlock() }
        XCTAssertEqual(calls.count, 1)
        return calls.first
    }

    func record(position: TimeInterval, percent: Double) {
        lock.lock()
        calls.append(Call(position: position, percent: percent))
        lock.unlock()
    }
}
#endif
