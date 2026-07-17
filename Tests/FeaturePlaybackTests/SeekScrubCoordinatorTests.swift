#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

@MainActor
final class SeekScrubCoordinatorTests: XCTestCase {

    /// Keeps spy hosts alive for the test's duration — the coordinator holds a
    /// *weak* host, so without this the seam would drop mid-test.
    private var retainedHosts: [SeekSpyHost] = []

    override func tearDown() {
        retainedHosts.removeAll()
        super.tearDown()
    }

    // MARK: Harness

    private func makeSUT(
        intendsPlayback: Bool = true,
        didStop: Bool = false,
        autoAdvance: Bool = false,
        commitDebounce: UInt64 = 1_000_000 // 1ms — keep tests fast
    ) -> (SeekScrubCoordinator, SeekSpyHost, SeekSpyEngine, PlayerControlsModel) {
        let engine = SeekSpyEngine()
        engine.autoAdvance = autoAdvance
        let controls = PlayerControlsModel()
        let host = SeekSpyHost(engine: engine, intendsPlayback: intendsPlayback, didStop: didStop)
        retainedHosts.append(host)
        let sut = SeekScrubCoordinator(host: host, controls: controls, commitDebounce: commitDebounce)
        host.onApplyPaused = { [weak controls] paused in
            // Mirror the real VM's setPaused funnel enough for the give-up path.
            controls?.isPaused = paused
            controls?.intendsPause = paused
            controls?.isResumeConfirming = false
        }
        return (sut, host, engine, controls)
    }

    private func waitUntil(
        timeout: TimeInterval = 3,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }

    // MARK: End-guard clamp (network-file EOF-fault guard)

    func testCommittedSeekPastEndClampsBelowDuration() {
        // Scrubbing to the very end must not drop the engine exactly on EOF: a
        // network-file source faults its demuxer there. The committed target lands
        // one endGuard shy of duration so the stream plays out to a clean onEnded.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        engine.duration = 1_000
        sut.requestSeek(to: 1_000)
        XCTAssertEqual(controls.pendingSeekTarget ?? -1, 999, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(1_000), 999, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(5_000), 999, accuracy: 0.0001,
                       "a target past the end still clamps to just below duration")
    }

    func testCommittedSeekWithinRangeIsUnchanged() {
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 1_000
        XCTAssertEqual(sut.clampedSeekTarget(500), 500, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(0), 0, accuracy: 0.0001)
        XCTAssertEqual(sut.clampedSeekTarget(-42), 0, accuracy: 0.0001,
                       "still floored at zero")
    }

    func testUnknownDurationOnlyFloorsAtZero() {
        // Early bring-up: duration not yet known → only the lower bound applies,
        // preserving prior behaviour (no upper clamp against a bogus 0 duration).
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 0
        XCTAssertEqual(sut.clampedSeekTarget(12_345), 12_345, accuracy: 0.0001)
        engine.duration = .infinity
        XCTAssertEqual(sut.clampedSeekTarget(12_345), 12_345, accuracy: 0.0001)
    }

    func testVeryShortDurationDoesNotProduceNegativeTarget() {
        let (sut, _, engine, _) = makeSUT(intendsPlayback: false)
        engine.duration = 0.5 // shorter than endGuard
        XCTAssertEqual(sut.clampedSeekTarget(0.4), 0.4, accuracy: 0.0001,
                       "sub-endGuard durations skip the upper clamp rather than go negative")
    }

    // MARK: isSeeking clear-on-return (forever-spinner guard)

    func testIsSeekingClearsAfterDrainReturns() async {
        // Pause-to-seek so we skip the (slow) resume-confirm loop; the drain still
        // must clear isSeeking exactly once it returns.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: 42)
        XCTAssertTrue(controls.isSeeking, "isSeeking is asserted synchronously on request")
        await waitUntil { !controls.isSeeking }
        XCTAssertFalse(controls.isSeeking, "isSeeking must clear when the drain returns")
        XCTAssertEqual(engine.lastSeekTarget, 42)
    }

    // MARK: duration-gate (DV·SMB "seek during load snaps to start" guard)

    func testCommittedSeekWaitsForDurationBeforeReachingEngine() async {
        // Engine has reported .ready (scrubber revealed) but hasn't published a
        // duration yet — AetherEngine would clamp min(target, 0) == 0 and snap
        // playback to the start. The coordinator must hold the engine seek until a
        // real duration is known, then issue it at the true target.
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        engine.duration = 0
        sut.requestSeek(to: 500)
        // Give the debounce + a few drain ticks time to run; no seek may reach the
        // engine while duration is unknown.
        try? await Task.sleep(nanoseconds: 60_000_000)
        XCTAssertTrue(engine.seekLog.isEmpty, "no committed seek may reach the engine while duration is 0")
        XCTAssertTrue(controls.isSeeking, "the seek is still in flight, pinned on screen")
        XCTAssertEqual(controls.currentSeconds, 500, "the optimistic position holds the requested target")
        // Duration lands → the held seek fires at the true target, not clamped to 0.
        engine.duration = 1_000
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.seekLog.count, 1, "exactly one committed seek once duration is known")
        XCTAssertEqual(engine.lastSeekTarget, 500, "the real target survives (never clamped to 0)")
    }

    // MARK: intendsPause phantom-.playing gate

    func testPauseToSeekReassertsPauseAndIntent() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: 30)
        await waitUntil { !controls.isSeeking }
        XCTAssertTrue(controls.isPaused, "a pause-to-seek must land paused")
        XCTAssertTrue(controls.intendsPause, "the intent gate must stay honest (intendsPause)")
        XCTAssertFalse(controls.isResumeConfirming, "no resume confirmation when not intending playback")
        XCTAssertTrue(engine.isPaused, "the engine must be re-paused on the landed frame")
    }

    // MARK: coalescing / latest-target-wins

    func testRapidPressesCollapseToSingleFinalExactSeek() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false, commitDebounce: 30_000_000)
        // A burst of presses inside the debounce window.
        sut.requestSeek(to: 10)
        sut.requestSeek(to: 20)
        sut.requestSeek(to: 90)
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.seekLog.count, 1, "the burst must collapse to ONE committed seek")
        XCTAssertEqual(engine.seekLog.first?.target, 90, "the final target wins")
        XCTAssertEqual(engine.seekLog.first?.kind, .exact, "the final settle is exact")
    }

    func testNegativeRequestClampsToZero() async {
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: false)
        sut.requestSeek(to: -50)
        await waitUntil { !controls.isSeeking }
        XCTAssertEqual(engine.lastSeekTarget, 0)
        XCTAssertEqual(controls.currentSeconds, 0)
    }

    // MARK: resume confirmation

    func testResumeConfirmClearsWhenClockAdvances() async {
        // An engine whose clock advances while playing should resolve the
        // resume-confirm loop and leave playback running (never re-paused).
        let (sut, _, engine, controls) = makeSUT(intendsPlayback: true, autoAdvance: true)
        sut.requestSeek(to: 15)
        await waitUntil(timeout: 5) { !controls.isResumeConfirming && !controls.isSeeking }
        XCTAssertFalse(controls.isResumeConfirming, "resume-confirm must clear once the clock advances")
        XCTAssertFalse(controls.isPaused, "a healthy resume stays playing")
        XCTAssertFalse(engine.isPaused)
    }

    // MARK: teardown

    func testCancelResumeConfirmClearsFlag() async {
        let (sut, _, _, controls) = makeSUT(intendsPlayback: true, autoAdvance: false)
        controls.isResumeConfirming = true
        sut.cancelResumeConfirm()
        XCTAssertFalse(controls.isResumeConfirming)
    }

    func testCancelAllStopsInFlightSeek() async {
        // With a stalled (non-advancing) engine and intendsPlayback, the drain
        // would enter the resume-confirm loop; cancelAll must tear it down and
        // clear the suppression flag.
        let (sut, _, _, controls) = makeSUT(intendsPlayback: true, autoAdvance: false)
        sut.requestSeek(to: 25)
        await waitUntil { !controls.isSeeking } // drain landed, resume-confirm running
        sut.cancelAll()
        await waitUntil { !controls.isResumeConfirming }
        XCTAssertFalse(controls.isResumeConfirming, "cancelAll clears the resume suppression")
    }

    // MARK: legacy direct seek

    func testLegacyDirectSeekTogglesIsSeeking() async {
        let (sut, _, engine, controls) = makeSUT()
        await sut.seek(to: 77)
        XCTAssertFalse(controls.isSeeking, "isSeeking must be cleared after the awaited seek returns")
        XCTAssertEqual(engine.lastSeekTarget, 77)
        XCTAssertEqual(controls.currentSeconds, 77)
        XCTAssertEqual(controls.pendingSeekTarget, 77)
    }
}

// MARK: - Spies

@MainActor
private final class SeekSpyHost: SeekScrubCoordinatorHost {
    private let engine: SeekSpyEngine
    var intendsPlaybackValue: Bool
    var didStopValue: Bool
    var onApplyPaused: (Bool) -> Void = { _ in }

    init(engine: SeekSpyEngine, intendsPlayback: Bool, didStop: Bool) {
        self.engine = engine
        self.intendsPlaybackValue = intendsPlayback
        self.didStopValue = didStop
    }

    var seekEngine: any VideoEngine { engine }
    var seekIntendsPlayback: Bool { intendsPlaybackValue }
    var seekDidStop: Bool { didStopValue }
    func seekApplyPaused(_ paused: Bool) { onApplyPaused(paused) }
}

@MainActor
private final class SeekSpyEngine: VideoEngine {
    struct SeekCall {
        let target: TimeInterval
        let kind: VideoSeekKind
    }

    let displayName = "seek-spy"
    var status: VideoEngineStatus = .idle
    var isPaused = false
    var preventsDisplaySleep = false
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

    var seekLog: [SeekCall] = []
    var lastSeekTarget: TimeInterval? { seekLog.last?.target }
    var playCount = 0
    var pauseCount = 0

    /// When true, `currentTime` advances with wall-clock while playing, so the
    /// resume-confirm loop observes forward motion and resolves.
    var autoAdvance = false
    private var baseTime: TimeInterval = 0
    private var playStartedAt: Date?

    var currentTime: TimeInterval {
        if autoAdvance, !isPaused, let started = playStartedAt {
            return baseTime + Date().timeIntervalSince(started)
        }
        return baseTime
    }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {
        status = .ready
        baseTime = startPosition
    }

    func play() {
        playCount += 1
        isPaused = false
        if autoAdvance { playStartedAt = Date() }
    }

    func pause() {
        pauseCount += 1
        baseTime = currentTime
        isPaused = true
        playStartedAt = nil
    }

    func reloadAfterForeground() async throws {}

    func seek(to seconds: TimeInterval) async {
        seekLog.append(SeekCall(target: seconds, kind: .exact))
        baseTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }

    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {
        seekLog.append(SeekCall(target: seconds, kind: kind))
        baseTime = seconds
        furthestObservedPosition = max(furthestObservedPosition, seconds)
    }

    func stop() {
        status = .idle
        duration = 0
    }

    func selectAudioTrack(_ track: MediaTrack?) {}
    func selectSubtitleTrack(_ track: MediaTrack?) {}

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
