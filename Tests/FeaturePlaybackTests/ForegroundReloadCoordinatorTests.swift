#if canImport(AVFoundation)
import XCTest
import CoreModels
@testable import FeaturePlayback
#if canImport(UIKit)
import UIKit
#endif

@MainActor
final class ForegroundReloadCoordinatorTests: XCTestCase {

    // Weak host would drop mid-test; retain the spies here.
    private var retainedHosts: [ReloadSpyHost] = []

    private func makeSUT(
        phase: PlayerViewModel.Phase = .ready,
        didStop: Bool = false,
        isPlozzigen: Bool = false,
        intendsPlayback: Bool = true,
        playbackSpeed: Double = 1.0
    ) -> (ForegroundReloadCoordinator, ReloadSpyHost, ReloadSpyEngine) {
        let engine = ReloadSpyEngine()
        let host = ReloadSpyHost(
            engine: engine,
            phase: phase,
            didStop: didStop,
            isPlozzigen: isPlozzigen,
            intendsPlayback: intendsPlayback,
            playbackSpeed: playbackSpeed
        )
        retainedHosts.append(host)
        let sut = ForegroundReloadCoordinator(host: host)
        return (sut, host, engine)
    }

    // MARK: - Arming / no-op

    func testResumeWithoutBackgroundEntryIsNoOp() async {
        let (sut, host, engine) = makeSUT()
        await sut.resume()
        XCTAssertEqual(engine.reloadCount, 0)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(host.reconcilePausedCalled)
        XCTAssertFalse(sut.isRecovering)
    }

    // MARK: - Happy path

    func testHappyPathPlayingIntent() async {
        let (sut, host, engine) = makeSUT(intendsPlayback: true, playbackSpeed: 1.5)
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(engine.reloadCount, 1)
        XCTAssertEqual(engine.lastPlaybackSpeed, 1.5)
        XCTAssertEqual(engine.playCount, 1)
        XCTAssertEqual(engine.pauseCount, 0)
        XCTAssertEqual(host.reconcilePausedValue, false)     // !intendsPlayback
        XCTAssertTrue(host.loadTrackOptionsCalled)
        XCTAssertFalse(host.reapplyCalled)                   // not plozzigen
        XCTAssertFalse(sut.isRecovering)                     // cleared on exit
        XCTAssertNil(host.failedError)
    }

    func testHappyPathPausedIntent() async {
        let (sut, host, engine) = makeSUT(intendsPlayback: false)
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(engine.pauseCount, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(host.reconcilePausedValue, true)      // !intendsPlayback
    }

    func testPlozzigenReappliesTrackSelections() async {
        let (sut, host, engine) = makeSUT(isPlozzigen: true)
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertTrue(host.reapplyCalled)
        XCTAssertTrue(engine === (host.reapplyEngine as? ReloadSpyEngine))
    }

    func testNativeDoesNotReapplyTrackSelections() async {
        let (sut, host, _) = makeSUT(isPlozzigen: false)
        sut.markEnteredBackground()
        await sut.resume()
        XCTAssertFalse(host.reapplyCalled)
    }

    // MARK: - Generation guards

    func testStopBeforeReadyAborts() async {
        let (sut, host, engine) = makeSUT(phase: .ready, didStop: true)
        sut.markEnteredBackground()
        await sut.resume()
        XCTAssertEqual(engine.reloadCount, 0)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(host.loadTrackOptionsCalled)
    }

    func testSecondResumeConsumesNothing() async {
        // Exactly one recovery per background entry: a duplicate .active callback
        // must not rebuild the session twice.
        let (sut, host, engine) = makeSUT()
        sut.markEnteredBackground()
        await sut.resume()
        XCTAssertEqual(engine.reloadCount, 1)

        host.reset()
        await sut.resume()                                    // no new generation
        XCTAssertEqual(engine.reloadCount, 1)                 // unchanged
        XCTAssertFalse(host.loadTrackOptionsCalled)
    }

    // MARK: - Failure handling

    func testReloadFailureSurfacesTerminalPhase() async {
        let (sut, host, engine) = makeSUT()
        engine.reloadError = AppError.unknown("boom")
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(engine.playCount, 0)
        XCTAssertEqual(host.failedError, AppError.unknown("boom"))
        XCTAssertFalse(sut.isRecovering)
    }

    func testReloadFailureIgnoredWhenEngineSwappedMidFlight() async {
        // A retry/handoff swap during the async reload changes the token; the
        // stale recovery must bail without marking the *new* session failed.
        let (sut, host, engine) = makeSUT()
        engine.reloadError = AppError.unknown("boom")
        engine.onReload = { host.tokenValue = UUID() }        // swap mid-flight
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertNil(host.failedError)                        // not surfaced
    }

    // MARK: - Post-reload swap / stop guards

    func testTokenChangedAfterReloadBailsBeforePlay() async {
        let (sut, host, engine) = makeSUT(intendsPlayback: true)
        engine.onReload = { host.tokenValue = UUID() }        // swap mid-flight
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(engine.reloadCount, 1)
        XCTAssertEqual(engine.playCount, 0)                   // bailed at guard
        XCTAssertEqual(engine.lastPlaybackSpeed, nil)
        XCTAssertFalse(host.loadTrackOptionsCalled)
    }

    func testStopDuringReloadStopsEngineWithoutPlay() async {
        let (sut, host, engine) = makeSUT(intendsPlayback: true)
        engine.onReload = { host.didStopValue = true }        // dismissed mid-flight
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(engine.stopCount, 1)
        XCTAssertEqual(engine.playCount, 0)
        XCTAssertFalse(host.loadTrackOptionsCalled)
    }

    // MARK: - isRecovering flag

    func testIsRecoveringTrueDuringReloadFalseAfter() async {
        let (sut, _, engine) = makeSUT()
        var observedDuringReload: Bool?
        engine.onReload = { observedDuringReload = sut.isRecovering }
        sut.markEnteredBackground()
        await sut.resume()

        XCTAssertEqual(observedDuringReload, true)
        XCTAssertFalse(sut.isRecovering)
    }
}

// MARK: - Spies

@MainActor
private final class ReloadSpyHost: ForegroundReloadCoordinatorHost {
    private let engine: ReloadSpyEngine
    var phaseValue: PlayerViewModel.Phase
    var didStopValue: Bool
    var isPlozzigenValue: Bool
    var intendsPlaybackValue: Bool
    var playbackSpeedValue: Double
    var tokenValue = UUID()

    private(set) var reapplyCalled = false
    private(set) var reapplyEngine: (any VideoEngine)?
    private(set) var loadTrackOptionsCalled = false
    private(set) var reconcilePausedCalled = false
    private(set) var reconcilePausedValue: Bool?
    private(set) var failedError: AppError?

    init(
        engine: ReloadSpyEngine,
        phase: PlayerViewModel.Phase,
        didStop: Bool,
        isPlozzigen: Bool,
        intendsPlayback: Bool,
        playbackSpeed: Double
    ) {
        self.engine = engine
        self.phaseValue = phase
        self.didStopValue = didStop
        self.isPlozzigenValue = isPlozzigen
        self.intendsPlaybackValue = intendsPlayback
        self.playbackSpeedValue = playbackSpeed
    }

    func reset() {
        reapplyCalled = false
        reapplyEngine = nil
        loadTrackOptionsCalled = false
        reconcilePausedCalled = false
        reconcilePausedValue = nil
        failedError = nil
    }

    var reloadPhase: PlayerViewModel.Phase { phaseValue }
    var reloadDidStop: Bool { didStopValue }
    var reloadEngine: any VideoEngine { engine }
    var reloadEngineToken: UUID { tokenValue }
    var reloadIsPlozzigenEngine: Bool { isPlozzigenValue }
    var reloadIntendsPlayback: Bool { intendsPlaybackValue }
    var reloadPlaybackSpeed: Double { playbackSpeedValue }

    func reloadReapplyTrackSelections(to engine: any VideoEngine) {
        reapplyCalled = true
        reapplyEngine = engine
    }

    func reloadLoadTrackOptions() {
        loadTrackOptionsCalled = true
    }

    func reloadReconcilePaused(_ paused: Bool) {
        reconcilePausedCalled = true
        reconcilePausedValue = paused
    }

    func reloadFail(_ error: AppError) {
        failedError = error
    }
}

@MainActor
private final class ReloadSpyEngine: VideoEngine {
    let displayName = "reload-spy"
    var status: VideoEngineStatus = .ready
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1_000
    var furthestObservedPosition: TimeInterval = 0
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onProbedSourceFactsChanged: (@MainActor (EngineProbedSourceFacts) -> Void)?

    var reloadCount = 0
    var playCount = 0
    var pauseCount = 0
    var stopCount = 0
    var lastPlaybackSpeed: Double?

    /// Thrown from `reloadAfterForeground` when set.
    var reloadError: Error?
    /// Runs *inside* `reloadAfterForeground` (before it may throw) so a test can
    /// mutate host state mid-flight (engine swap / dismissal).
    var onReload: (@MainActor () -> Void)?

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .ready
        currentTime = startPosition
    }

    func play() { playCount += 1; isPaused = false }
    func pause() { pauseCount += 1; isPaused = true }

    func reloadAfterForeground() async throws {
        reloadCount += 1
        onReload?()
        if let reloadError { throw reloadError }
    }

    func seek(to seconds: TimeInterval) async { currentTime = seconds }

    func stop() { stopCount += 1; status = .idle }

    func setPlaybackSpeed(_ rate: Double) { lastPlaybackSpeed = rate }

    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
