#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

/// Pins the cross-engine failure fallback chain that historically broke silently
/// on a device: a once-only guard that fired twice (double-swap loop), a stale
/// callback that wasn't ignored (landed-but-frozen), or a network-file source
/// wrongly swapped to native (silent playback). The decision is pure, so the
/// whole chain is exercised here by feeding failures in sequence.
final class EngineFailurePolicyTests: XCTestCase {

    /// Convenience wrapper mirroring `handleEngineFailure`'s call, with sensible
    /// defaults so each test names only the facts it cares about.
    private func decide(
        tokenMatches: Bool = true,
        hasRequest: Bool = true,
        isNetworkFile: Bool = false,
        isTranscoding: Bool = false,
        hasExternalAudio: Bool = false,
        currentEngineKind: PlaybackEngineKind = .native,
        alternateEngineKind: PlaybackEngineKind? = .plozzigen,
        resume: TimeInterval = 0,
        state: inout EngineFallbackState
    ) -> EngineFailureAction {
        EngineFailurePolicy.decide(
            tokenMatches: tokenMatches,
            hasRequest: hasRequest,
            isNetworkFile: isNetworkFile,
            isTranscoding: isTranscoding,
            hasExternalAudio: hasExternalAudio,
            currentEngineKind: currentEngineKind,
            alternateEngineKind: alternateEngineKind,
            resume: resume,
            state: &state
        )
    }

    // MARK: Guard-rail short-circuits (evaluated before any fallback fires)

    func testStaleCallbackIsIgnoredWithoutTouchingGuards() {
        var state = EngineFallbackState()
        let action = decide(tokenMatches: false, state: &state)
        XCTAssertEqual(action, .ignoreStale)
        // A stale callback must not consume any once-only fallback.
        XCTAssertEqual(state, EngineFallbackState())
    }

    func testNoRequestFailsFast() {
        var state = EngineFallbackState()
        let action = decide(hasRequest: false, state: &state)
        XCTAssertEqual(action, .failNoRequest)
        XCTAssertEqual(state, EngineFallbackState())
    }

    // MARK: Network-file fresh-retry (Plozzigen only, once)

    func testNetworkFileOnPlozzigenRetriesFreshOnce() {
        var state = EngineFallbackState()
        let first = decide(
            isNetworkFile: true, currentEngineKind: .plozzigen,
            alternateEngineKind: .native, resume: 42, state: &state
        )
        XCTAssertEqual(first, .retryFreshNetworkFile(resume: 42))
        XCTAssertTrue(state.hasRetriedNetworkFileEngine)

        // Second failure on the same network file must NOT retry-fresh again.
        // With native as the only alternate and a network file, the native swap
        // is forbidden, and transcode is skipped for network files → exhausted.
        let second = decide(
            isNetworkFile: true, currentEngineKind: .plozzigen,
            alternateEngineKind: .native, resume: 42, state: &state
        )
        XCTAssertEqual(second, .exhausted)
    }

    func testNetworkFileNeverSwapsToNativeEngine() {
        var state = EngineFallbackState()
        // Even before the fresh-retry has fired, a network file must never route
        // to native (native URL loaders can't reinterpret a typed SMB/WebDAV
        // stream). Force past the fresh-retry by pre-setting its guard.
        state.hasRetriedNetworkFileEngine = true
        let action = decide(
            isNetworkFile: true, currentEngineKind: .plozzigen,
            alternateEngineKind: .native, resume: 10, state: &state
        )
        XCTAssertEqual(action, .exhausted)
        XCTAssertFalse(state.hasTriedAlternateEngine)
    }

    // MARK: Alternate-engine swap (once, native → Plozzigen)

    func testDirectPlayFailureSwapsToAlternateOnce() {
        var state = EngineFallbackState()
        let first = decide(currentEngineKind: .native, alternateEngineKind: .plozzigen, resume: 30, state: &state)
        XCTAssertEqual(first, .swapAlternate(kind: .plozzigen, resume: 30))
        XCTAssertTrue(state.hasTriedAlternateEngine)

        // The second failure must not swap again — it escalates to a transcode.
        let second = decide(currentEngineKind: .plozzigen, alternateEngineKind: .native, resume: 30, state: &state)
        XCTAssertEqual(second, .forceServerTranscode(resume: 30))
    }

    func testAdaptiveSourceSkipsNativeSwap() {
        var state = EngineFallbackState()
        // External audio track → only the hybrid engine can mux it; a native swap
        // would play silent video, so the swap is skipped and we go to transcode.
        let action = decide(hasExternalAudio: true, currentEngineKind: .plozzigen,
                            alternateEngineKind: .native, resume: 5, state: &state)
        XCTAssertEqual(action, .forceServerTranscode(resume: 5))
        XCTAssertFalse(state.hasTriedAlternateEngine)
    }

    func testNoAlternateEngineFallsThroughToTranscode() {
        var state = EngineFallbackState()
        // Plozzigen not wired in → alternate is nil → direct swap skipped.
        let action = decide(currentEngineKind: .native, alternateEngineKind: nil, resume: 7, state: &state)
        XCTAssertEqual(action, .forceServerTranscode(resume: 7))
        XCTAssertFalse(state.hasTriedAlternateEngine)
    }

    // MARK: Server-transcode fallback (once; resume>1 → resume, else nil)

    func testTranscodeResumeCarriesPositionOnlyWhenPastOneSecond() {
        var past = EngineFallbackState()
        past.hasTriedAlternateEngine = true
        let withResume = decide(alternateEngineKind: nil, resume: 12, state: &past)
        XCTAssertEqual(withResume, .forceServerTranscode(resume: 12))

        var atStart = EngineFallbackState()
        atStart.hasTriedAlternateEngine = true
        // resume <= 1 → nil (start fresh) so a 0.x-second failure doesn't seek to 0.
        let noResume = decide(alternateEngineKind: nil, resume: 0.5, state: &atStart)
        XCTAssertEqual(noResume, .forceServerTranscode(resume: nil))
    }

    func testTranscodeFiresAtMostOnce() {
        var state = EngineFallbackState()
        state.hasTriedAlternateEngine = true
        let first = decide(alternateEngineKind: nil, resume: 20, state: &state)
        XCTAssertEqual(first, .forceServerTranscode(resume: 20))
        XCTAssertTrue(state.hasAttemptedTranscodeFallback)

        let second = decide(alternateEngineKind: nil, resume: 20, state: &state)
        XCTAssertEqual(second, .exhausted)
    }

    func testAlreadyTranscodingIsImmediatelyExhausted() {
        var state = EngineFallbackState()
        let action = decide(isTranscoding: true, alternateEngineKind: nil, resume: 5, state: &state)
        XCTAssertEqual(action, .exhausted)
        XCTAssertFalse(state.hasAttemptedTranscodeFallback)
    }

    // MARK: Full chain walked in sequence (native direct → swap → transcode → exhausted)

    func testFullFallbackChainWalksEachStepExactlyOnce() {
        var state = EngineFallbackState()

        // 1) native direct-play fails → swap to Plozzigen.
        let step1 = decide(currentEngineKind: .native, alternateEngineKind: .plozzigen, resume: 60, state: &state)
        XCTAssertEqual(step1, .swapAlternate(kind: .plozzigen, resume: 60))

        // 2) Plozzigen also fails (not a network file) → force server transcode.
        let step2 = decide(currentEngineKind: .plozzigen, alternateEngineKind: .native, resume: 60, state: &state)
        XCTAssertEqual(step2, .forceServerTranscode(resume: 60))

        // 3) transcode attempt fails too → exhausted, no further loops.
        let step3 = decide(isTranscoding: true, currentEngineKind: .native, alternateEngineKind: .plozzigen, resume: 60, state: &state)
        XCTAssertEqual(step3, .exhausted)

        XCTAssertEqual(
            state,
            EngineFallbackState(
                hasTriedAlternateEngine: true,
                hasRetriedNetworkFileEngine: false,
                hasAttemptedTranscodeFallback: true
            )
        )
    }
}
#endif
