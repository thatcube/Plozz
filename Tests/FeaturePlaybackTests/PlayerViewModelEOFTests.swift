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

        let playsBeforeResume = engine.playCallCount
        let pausesBeforeResume = engine.pauseCallCount
        viewModel.setPaused(false)
        XCTAssertTrue(viewModel.controls.isResumeConfirming)
        try? await Task.sleep(for: .milliseconds(700))
        XCTAssertEqual(engine.playCallCount, playsBeforeResume + 1)
        XCTAssertEqual(engine.pauseCallCount, pausesBeforeResume)
        viewModel.setPaused(true)
    }

    func testBackgroundRestoreSupersedesInFlightLoadWithoutStaleReadyTail() async {
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
        let restoreTask = Task { @MainActor in
            await viewModel.restoreAfterBackground()
        }
        await restoreTask.value
        XCTAssertEqual(engine.restoreAfterBackgroundCallCount, 1)

        engine.finishLoad()
        await viewModel.load()

        XCTAssertEqual(engine.restoreAfterBackgroundCallCount, 1)
        XCTAssertEqual(viewModel.phase, .ready)
        XCTAssertTrue(viewModel.controls.isPaused)

        let reports = await provider.reports
        let startReports = reports.filter { $0.event == .start }
        XCTAssertEqual(startReports.count, 1)
        XCTAssertEqual(startReports.first?.progress.isPaused, true)
    }

    func testDuplicateFailureCallbackStartsOnlyOneFallbackStage() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        let alternate = SpyVideoEngine()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: { alternate }
            )
        )

        await viewModel.load()
        XCTAssertEqual(native.loadCallCount, 1)

        native.onFailure?(.unknown("decoder failed"))
        native.onFailure?(.unknown("decoder failed"))
        await assertEventually { alternate.loadCallCount == 1 }

        XCTAssertEqual(alternate.loadCallCount, 1)
        let forceTranscodeRequestCount = await provider.forceTranscodeRequestCount
        XCTAssertEqual(forceTranscodeRequestCount, 0)
    }

    func testSuccessorEngineFailureQueuesBehindCurrentFallback() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        let alternate = SpyVideoEngine()
        alternate.failureOnLoad = .unknown("alternate decoder failed")
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: { alternate }
            )
        )

        await viewModel.load()
        native.onFailure?(.unknown("native decoder failed"))

        var forceTranscodeRequestCount = 0
        for _ in 0..<200 {
            forceTranscodeRequestCount = await provider.forceTranscodeRequestCount
            if forceTranscodeRequestCount == 1 { break }
            try? await Task.sleep(for: .milliseconds(5))
        }

        XCTAssertEqual(alternate.loadCallCount, 1)
        XCTAssertEqual(native.loadCallCount, 2)
        XCTAssertEqual(forceTranscodeRequestCount, 1)
    }

    func testForegroundRestoreDefersForFreshIdleFallbackEngine() async {
        let item = MediaItem(id: "movie", title: "Movie", kind: .movie, runtime: 120)
        let request = PlaybackRequest(
            item: item,
            streamURL: URL(string: "https://example.test/movie.m3u8")!
        )
        let provider = RecordingPlaybackProvider(request: request)
        let native = SpyVideoEngine()
        let alternate = SpyVideoEngine()
        alternate.blocksLoad = true
        alternate.marksLoadingOnLoad = false
        alternate.capabilities = [.playbackSpeed]
        let creationSignal = EngineCreationSignal()
        let viewModel = PlayerViewModel(
            provider: provider,
            itemID: item.id,
            engineFactory: EngineFactory(
                makeNative: { _ in native },
                makePlozzigen: {
                    creationSignal.signal()
                    return alternate
                }
            )
        )

        await viewModel.load()
        viewModel.suspendForBackground(requiresPipelineRestore: true)
        let restoreTask = Task { @MainActor in
            guard await creationSignal.wait() else { return false }
            await viewModel.restoreAfterBackground()
            return true
        }

        native.onFailure?(.unknown("native decoder failed"))
        let didCreateAlternate = await restoreTask.value
        XCTAssertTrue(didCreateAlternate)

        let reportsBeforeLoad = await provider.reports
        XCTAssertEqual(reportsBeforeLoad.filter { $0.event == .start }.count, 1)

        alternate.finishLoad()
        await assertEventually {
            alternate.restoreAfterBackgroundCallCount == 1
                && viewModel.controls.engineCapabilities.contains(.playbackSpeed)
        }

        XCTAssertTrue(viewModel.controls.isPaused)
        let reports = await provider.reports
        let startReports = reports.filter { $0.event == .start }
        XCTAssertEqual(startReports.count, 2)
        XCTAssertEqual(startReports.last?.progress.isPaused, true)
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

    private func assertEventually(
        _ predicate: () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<200 {
            if predicate() { return }
            try? await Task.sleep(for: .milliseconds(5))
        }
        XCTFail("Condition was not met before timeout", file: file, line: line)
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
    private(set) var forceTranscodeRequestCount = 0

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
        if forceTranscode {
            forceTranscodeRequestCount += 1
        }
        return request
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
    var playCallCount = 0
    var pauseCallCount = 0
    var loadCallCount = 0
    var capabilities: PlayerEngineCapabilities = []
    var blocksLoad = false
    var marksLoadingOnLoad = true
    var failureOnLoad: AppError?
    private(set) var loadStarted = false
    private var loadContinuation: CheckedContinuation<Void, Never>?
    private var lifecycleGeneration = 0
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        lifecycleGeneration += 1
        let generation = lifecycleGeneration
        loadCallCount += 1
        loadStarted = true
        if marksLoadingOnLoad {
            status = .loading
        }
        if blocksLoad {
            await withCheckedContinuation { continuation in
                loadContinuation = continuation
            }
        }
        guard generation == lifecycleGeneration else { return }
        if let failureOnLoad {
            status = .failed(failureOnLoad)
            onFailure?(failureOnLoad)
            return
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

    func play() {
        playCallCount += 1
        isPaused = false
    }
    func pause() {
        pauseCallCount += 1
        isPaused = true
    }
    func restoreAfterBackground() async {
        lifecycleGeneration += 1
        restoreAfterBackgroundCallCount += 1
        status = .ready
        isPaused = true
    }
    func seek(to seconds: TimeInterval) async {
        currentTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }
    func stop() {
        lifecycleGeneration += 1
        status = .idle
    }
    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}

@MainActor
private final class EngineCreationSignal {
    private var wasSignalled = false

    func wait() async -> Bool {
        for _ in 0..<200 {
            if wasSignalled { return true }
            try? await Task.sleep(for: .milliseconds(5))
        }
        return false
    }

    func signal() {
        wasSignalled = true
    }
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
