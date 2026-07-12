#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class PlayerViewModelEOFTests: XCTestCase {
    func testBackgroundReturnRestoresPipelineOnceAndRemainsPaused() async {
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

        await viewModel.load()
        engine.currentTime = 42

        viewModel.suspendForBackground()
        viewModel.suspendForBackground(requiresPipelineRestore: true)
        await viewModel.restoreAfterBackground()
        await viewModel.restoreAfterBackground()

        XCTAssertEqual(engine.restoreAfterBackgroundCallCount, 1)
        XCTAssertTrue(engine.isPaused)
        XCTAssertTrue(viewModel.controls.isPaused)
        XCTAssertTrue(viewModel.controls.intendsPause)
        XCTAssertEqual(viewModel.controls.currentSeconds, 42)
        XCTAssertEqual(viewModel.phase, .ready)

        viewModel.setPaused(false)
        XCTAssertTrue(viewModel.controls.isResumeConfirming)
        viewModel.setPaused(true)
    }

    func testBackgroundDuringLoadingStillRestoresAfterLoadCompletes() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let engine = SpyVideoEngine()
        engine.blocksLoad = true
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(makeNative: { _ in engine })
        )

        for _ in 0..<100 where !engine.loadStarted {
            try? await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertTrue(engine.loadStarted)
        XCTAssertEqual(viewModel.phase, .loading)

        viewModel.suspendForBackground(requiresPipelineRestore: true)
        engine.finishLoad()
        await viewModel.load()
        await viewModel.restoreAfterBackground()

        XCTAssertEqual(engine.restoreAfterBackgroundCallCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
    }

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
        XCTAssertEqual(stopped.onlyCall?.position, 120)
        XCTAssertEqual(stopped.onlyCall?.percent, 100)
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
    var restoreAfterBackgroundCallCount = 0
    var blocksLoad = false
    private(set) var loadStarted = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        loadStarted = true
        if blocksLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        status = .ready
        currentTime = startPosition
        furthestObservedPosition = max(furthestObservedPosition, startPosition)
    }

    func finishLoad() {
        blocksLoad = false
        loadContinuation?.resume()
        loadContinuation = nil
    }

    func play() { isPaused = false }
    func pause() { isPaused = true }
    func restoreAfterBackground() async {
        restoreAfterBackgroundCallCount += 1
        status = .ready
        isPaused = true
    }
    func seek(to seconds: TimeInterval) async {
        currentTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }
    func stop() { status = .idle }
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
