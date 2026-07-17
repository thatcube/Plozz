#if canImport(AVFoundation)
import CoreModels
import XCTest

@testable import FeaturePlayback

/// Pins the fragile subtitle/audio **track selection** semantics extracted from
/// `PlayerViewModel` into ``SubtitleTrackController``: subtitle on/off routing,
/// the text-sidecar → overlay vs embedded-text → AVPlayer-draw split, the
/// image-based native→Plozzigen swap, the Plozzigen live-feed route, the
/// once-per-load default guard, the optimistic pending-audio indicator, the
/// cross-server audio import retry, hot-loaded id assignment, and dual-line
/// eligibility. These are the routes that break silently on device.
@MainActor
final class SubtitleTrackControllerTests: XCTestCase {

    /// The controller holds a *weak* host, so retain spies for the test's life.
    private var retainedHosts: [SpyTrackHost] = []

    override func tearDown() {
        retainedHosts.removeAll()
        super.tearDown()
    }

    // MARK: Harness

    private func makeSUT(
        engineKind: PlaybackEngineKind = .native,
        capabilities: PlayerEngineCapabilities = [],
        plozzigenAvailable: Bool = true
    ) -> (SubtitleTrackController, SpyTrackHost, SpyTrackEngine) {
        let engine = SpyTrackEngine()
        engine.capabilities = capabilities
        let host = SpyTrackHost(engine: engine, engineKind: engineKind)
        host.plozzigenAvailable = plozzigenAvailable
        retainedHosts.append(host)
        let sut = SubtitleTrackController(host: host)
        host.controller = sut
        return (sut, host, engine)
    }

    private func textSidecar(_ id: Int, language: String? = "en") -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "Sub \(id)", language: language,
            deliverySource: .localFile(URL(fileURLWithPath: "/tmp/\(id).vtt"))
        )
    }

    private func embeddedText(_ id: Int, language: String? = "en") -> MediaTrack {
        MediaTrack(id: id, kind: .subtitle, displayTitle: "Emb \(id)", language: language)
    }

    private func imageSub(_ id: Int, language: String? = "en") -> MediaTrack {
        MediaTrack(
            id: id, kind: .subtitle, displayTitle: "PGS \(id)", language: language,
            isImageBasedSubtitle: true
        )
    }

    private func audio(_ id: Int, language: String?, isDefault: Bool = false) -> MediaTrack {
        MediaTrack(id: id, kind: .audio, displayTitle: "Aud \(id)", language: language, isDefault: isDefault)
    }

    // MARK: - Subtitle OFF

    func testSelectOffClearsSelectionAndRecordsMemory() {
        let (sut, host, engine) = makeSUT(engineKind: .native)
        engine.subtitleTracks = [embeddedText(1)]
        sut.selectSubtitleOption(id: 1)                 // land on a track first
        sut.selectSubtitleOption(id: PlayerTrackOption.offID)
        XCTAssertNil(sut.selectedSubtitleTrackID, "Off clears the primary selection")
        XCTAssertTrue(engine.lastSubtitleSelectionCleared, "Off tells the engine to draw nothing")
        XCTAssertEqual(host.recordedSubtitle.last ?? nil, .off)
        XCTAssertTrue(host.isPrimarySubtitleOffProxy)
    }

    // MARK: - Text-with-sidecar → overlay (engine draw suppressed)

    func testTextSidecarOnNativeRoutesThroughOverlay() {
        let (sut, host, engine) = makeSUT(engineKind: .native)
        engine.subtitleTracks = [textSidecar(3)]
        sut.selectSubtitleOption(id: 3)
        XCTAssertEqual(sut.selectedSubtitleTrackID, 3)
        // Overlay draws it → the engine is told to draw NOTHING (nil).
        XCTAssertTrue(engine.lastSubtitleSelectionCleared)
        XCTAssertFalse(host.liveSubtitles.rendersPrimary, "sidecar timeline, not a live feed")
    }

    // MARK: - Embedded text (no sidecar) → AVPlayer draw

    func testEmbeddedTextOnNativeLetsAVPlayerDraw() {
        let (sut, _, engine) = makeSUT(engineKind: .native)
        engine.subtitleTracks = [embeddedText(4)]
        sut.selectSubtitleOption(id: 4)
        XCTAssertEqual(sut.selectedSubtitleTrackID, 4)
        // No sidecar → the engine itself must draw the track (non-nil selection).
        XCTAssertEqual(engine.lastSelectedSubtitleID, 4)
    }

    // MARK: - Image-based on native → Plozzigen swap

    func testImageSubtitleOnNativeTriggersEngineSwap() async {
        let (sut, host, engine) = makeSUT(engineKind: .native, plozzigenAvailable: true)
        host.request = PlaybackRequest(
            item: MediaItem(id: "m1", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://example.test/m.m3u8")!,
            isTranscoding: false
        )
        engine.subtitleTracks = [imageSub(5)]
        sut.selectSubtitleOption(id: 5)
        XCTAssertEqual(sut.selectedSubtitleTrackID, 5, "selection is seeded optimistically before the swap")
        // The swap is dispatched on a Task; wait for the host callback.
        await waitUntil { host.swapCalls == 1 }
        XCTAssertEqual(host.swapCalls, 1, "an image sub on native must swap to Plozzigen")
    }

    func testImageSubtitleWithoutPlozzigenDoesNotSwap() async {
        let (sut, host, engine) = makeSUT(engineKind: .native, plozzigenAvailable: false)
        host.request = PlaybackRequest(
            item: MediaItem(id: "m1", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://example.test/m.m3u8")!,
            isTranscoding: false
        )
        engine.subtitleTracks = [imageSub(6)]
        sut.selectSubtitleOption(id: 6)
        // Give any (erroneous) dispatched swap a chance to run.
        try? await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(host.swapCalls, 0, "no Plozzigen → never attempt the swap")
    }

    // MARK: - Plozzigen → live-feed overlay

    func testSubtitleOnPlozzigenUsesLiveFeed() {
        let (sut, host, engine) = makeSUT(engineKind: .plozzigen)
        engine.subtitleTracks = [embeddedText(7)]
        sut.selectSubtitleOption(id: 7)
        XCTAssertEqual(sut.selectedSubtitleTrackID, 7)
        XCTAssertEqual(engine.lastSelectedSubtitleID, 7, "Plozzigen decodes and emits cues itself")
        XCTAssertTrue(host.liveSubtitles.rendersPrimary, "the overlay draws Plozzigen's live-fed cues")
    }

    // MARK: - Load-time default: once-per-load guard

    func testInitialDefaultAppliesOncePerLoad() {
        let (sut, host, engine) = makeSUT(engineKind: .native)
        host.remembered = .off                       // deterministic default route → clear
        let request = PlaybackRequest(
            item: MediaItem(id: "e1", title: "Ep", kind: .episode),
            streamURL: URL(string: "https://example.test/e.m3u8")!,
            subtitleTracks: [textSidecar(1)]
        )
        host.request = request
        engine.subtitleTracks = [textSidecar(1)]

        sut.applyInitialSubtitleForNewLoad(for: request)
        let afterFirst = engine.subtitleSelections.count
        XCTAssertGreaterThanOrEqual(afterFirst, 1, "the default routes once")
        // A second readiness poll (e.g. a later onTracksChanged) must NOT re-route.
        sut.applyInitialSubtitleSelectionIfReady(for: request)
        XCTAssertEqual(engine.subtitleSelections.count, afterFirst, "guarded to once per load")
    }

    // MARK: - Optimistic pending audio

    func testSelectAudioShowsTargetOptimisticallyBeforeEngineConfirms() {
        let (sut, host, engine) = makeSUT(engineKind: .plozzigen)
        engine.audioTracks = [audio(1, language: "en", isDefault: true), audio(2, language: "ja")]
        engine.currentAudioTrackID = 1               // engine still on the old track
        sut.selectAudioOption(id: 2)
        XCTAssertEqual(sut.selectedAudioTrackID, 2)
        XCTAssertTrue(sut.viewerChangedAudioThisSession)
        XCTAssertEqual(engine.lastSelectedAudioID, 2, "the pick is routed through the engine")
        XCTAssertEqual(host.recordedAudioLanguage.last ?? nil, "ja", "the language is remembered for the series")
        // The menu shows the target NOW even though the engine still reports id 1.
        let selected = host.controls.audioOptions.first { $0.isSelected }
        XCTAssertEqual(selected?.id, 2, "optimistic indicator holds the target until the engine confirms")
    }

    // MARK: - Cross-server audio import

    func testQueuedAudioImportAppliesWhenMatchingTrackExists() {
        let (sut, host, engine) = makeSUT(engineKind: .plozzigen)
        engine.audioTracks = [audio(1, language: "en"), audio(2, language: "de")]
        engine.currentAudioTrackID = 1
        sut.queueImportedAudio(language: "de")
        XCTAssertEqual(sut.selectedAudioTrackID, 2)
        XCTAssertEqual(engine.lastSelectedAudioID, 2)
        _ = host  // silence unused in some configs
    }

    func testQueuedAudioImportStaysPendingUntilTrackArrives() {
        let (sut, _, engine) = makeSUT(engineKind: .plozzigen)
        engine.audioTracks = [audio(1, language: "en")]  // no German track yet
        engine.currentAudioTrackID = 1
        sut.queueImportedAudio(language: "de")
        XCTAssertNil(sut.selectedAudioTrackID, "no match → nothing applied")
        XCTAssertTrue(engine.audioSelections.isEmpty)
        // The German track demuxes in later; the retry now applies it.
        engine.audioTracks.append(audio(2, language: "de"))
        sut.applyImportedAudioIfPossible()
        XCTAssertEqual(sut.selectedAudioTrackID, 2, "retry applies the import once the track is known")
    }

    // MARK: - Hot-loaded downloaded subtitle

    func testHotLoadAssignsSyntheticIdAndBecomesSelectable() {
        let (sut, host, engine) = makeSUT(engineKind: .native)
        engine.subtitleTracks = []
        let assigned = sut.hotLoadSubtitleTrack(embeddedText(0, language: "fr"), preferredLanguage: "fr", forced: false)
        XCTAssertGreaterThanOrEqual(assigned, 900_000, "synthetic id can't collide with a stream id")
        let assigned2 = sut.hotLoadSubtitleTrack(embeddedText(0, language: "es"), preferredLanguage: "es", forced: false)
        XCTAssertEqual(assigned2, assigned + 1, "ids increment monotonically")
        XCTAssertTrue(host.controls.subtitleOptions.contains { $0.id == assigned }, "hot-loaded row is in the menu")
        // Selecting the hot-loaded row renders through the overlay (engine draws nothing).
        sut.selectSubtitleOption(id: assigned)
        XCTAssertEqual(sut.selectedSubtitleTrackID, assigned)
        XCTAssertTrue(engine.lastSubtitleSelectionCleared)
    }

    // MARK: - Dual (secondary) subtitle

    func testSelectSecondaryEnablesStylingAndLoadingStatus() {
        let (sut, host, engine) = makeSUT(engineKind: .native)   // non-dual engine → sidecar overlay
        let secondary = textSidecar(8, language: "ja")
        host.request = PlaybackRequest(
            item: MediaItem(id: "m1", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://example.test/m.m3u8")!,
            subtitleTracks: [secondary]
        )
        engine.subtitleTracks = [secondary]
        sut.selectSecondarySubtitleOption(id: 8)
        XCTAssertEqual(sut.selectedSecondarySubtitleTrackID, 8)
        XCTAssertNotNil(host.style.secondary, "picking a second line seeds the secondary style")
        XCTAssertEqual(host.controls.secondarySubtitleStatus, .loading)
    }

    func testTurnSecondaryOffClearsSelectionStyleAndStatus() {
        let (sut, host, engine) = makeSUT(engineKind: .native)
        let secondary = textSidecar(9, language: "ja")
        host.request = PlaybackRequest(
            item: MediaItem(id: "m1", title: "Movie", kind: .movie),
            streamURL: URL(string: "https://example.test/m.m3u8")!,
            subtitleTracks: [secondary]
        )
        engine.subtitleTracks = [secondary]
        sut.selectSecondarySubtitleOption(id: 9)
        sut.selectSecondarySubtitleOption(id: PlayerTrackOption.offID)
        XCTAssertNil(sut.selectedSecondarySubtitleTrackID)
        XCTAssertNil(host.style.secondary, "turning the second line off clears its styling")
        XCTAssertEqual(host.controls.secondarySubtitleStatus, .idle)
    }

    // MARK: helpers

    private func waitUntil(
        timeout: TimeInterval = 2,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

// MARK: - Spies

@MainActor
private final class SpyTrackHost: SubtitleTrackControllerHost {
    private let engine: SpyTrackEngine
    weak var controller: SubtitleTrackController?

    var engineKind: PlaybackEngineKind
    var request: PlaybackRequest?
    var behavior = SubtitleBehavior.default
    let controls = PlayerControlsModel()
    let liveSubtitles = LiveSubtitleModel()
    let overlay: SubtitleOverlayLoader
    var style = SubtitleStyle.default
    var plozzigenAvailable = true
    var remembered: RememberedSubtitleSelection?
    var rule = SubtitlePolicy.Rule()

    private(set) var recordedAudioLanguage: [String?] = []
    private(set) var recordedSubtitle: [RememberedSubtitleSelection?] = []
    private(set) var refreshDelayCalls = 0
    private(set) var swapCalls = 0

    var isPrimarySubtitleOffProxy: Bool { controller?.selectedSubtitleTrackID == nil }

    init(engine: SpyTrackEngine, engineKind: PlaybackEngineKind) {
        self.engine = engine
        self.engineKind = engineKind
        self.overlay = SubtitleOverlayLoader(host: StubOverlayHost(), fetch: { _ in Data() })
    }

    var trackEngine: any VideoEngine { engine }
    var trackEngineKind: PlaybackEngineKind { engineKind }
    var trackRequest: PlaybackRequest? { request }
    var trackBehavior: SubtitleBehavior { behavior }
    var trackControls: PlayerControlsModel { controls }
    var trackLiveSubtitles: LiveSubtitleModel { liveSubtitles }
    var trackSubtitleOverlay: SubtitleOverlayLoader { overlay }
    var trackStyle: SubtitleStyle { style }
    var trackPlozzigenAvailable: Bool { plozzigenAvailable }
    var trackAuthenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? { nil }

    func trackApplySubtitleStyle(_ style: SubtitleStyle) { self.style = style }
    func trackRememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection? { remembered }
    func trackEffectiveSubtitleRule(for item: MediaItem) -> SubtitlePolicy.Rule { rule }
    func trackRecordAudioSelection(language: String?) { recordedAudioLanguage.append(language) }
    func trackRecordSubtitleSelection(_ selection: RememberedSubtitleSelection?) { recordedSubtitle.append(selection) }
    func trackRefreshSubtitleDelayAvailability() { refreshDelayCalls += 1 }

    func trackPlayResolvedForImageSubtitleSwap(
        _ request: PlaybackRequest, startPosition: TimeInterval
    ) async {
        swapCalls += 1
        engineKind = .plozzigen   // mimic the real handoff so a follow-up applies against Plozzigen
    }
}

/// A minimal `SubtitleOverlayLoaderHost` so the controller's real overlay can be
/// built without a view model. The overlay effects themselves are covered by
/// `SubtitleOverlayLoaderTests`; here we only need it to exist and not crash.
@MainActor
private final class StubOverlayHost: SubtitleOverlayLoaderHost {
    var primarySubtitleSelectionID: Int?
    var secondarySubtitleSelectionID: Int?
    func overlayResolveDeliveryURL(_ track: MediaTrack) async throws -> URL? { nil }
    func overlayApplyPrimaryCues(_ stream: SubtitleCueStream?) {}
    func overlayApplySecondaryCues(_ stream: SubtitleCueStream?) {}
    func overlayDetectedLanguage(for id: Int) -> String? { nil }
    func overlayRecordDetectedLanguage(_ language: String, for id: Int) {}
    func overlayReloadTrackOptions() {}
    func overlaySetSecondaryStatus(_ status: SecondarySubtitleStatus) {}
    #if DEBUG
    func overlaySetPrimaryDiagnostic(route: String, cues: Int?) {}
    #endif
}

@MainActor
private final class SpyTrackEngine: VideoEngine {
    let displayName = "track-spy"
    var status: VideoEngineStatus = .ready
    var isPaused = false
    var preventsDisplaySleep = false
    var currentTime: TimeInterval = 0
    var duration: TimeInterval = 1_000
    var furthestObservedPosition: TimeInterval = 0
    var capabilities: PlayerEngineCapabilities = []
    var audioTracks: [MediaTrack] = []
    var subtitleTracks: [MediaTrack] = []
    var currentAudioTrackID: Int?

    var onProgress: (@MainActor () -> Void)?
    var onFailure: (@MainActor (AppError) -> Void)?
    var onEnded: (@MainActor () -> Void)?
    var onTracksChanged: (@MainActor () -> Void)?
    var onSubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?
    var onSecondarySubtitleCues: (@MainActor ([SubtitleCue]) -> Void)?

    private(set) var audioSelections: [MediaTrack?] = []
    private(set) var subtitleSelections: [MediaTrack?] = []
    private(set) var secondarySelections: [MediaTrack?] = []

    /// The id last routed to `selectAudioTrack` (nil if the last call cleared).
    var lastSelectedAudioID: Int? { audioSelections.last.flatMap { $0 }?.id }
    /// The id last routed to `selectSubtitleTrack` (nil if the last call cleared).
    var lastSelectedSubtitleID: Int? { subtitleSelections.last.flatMap { $0 }?.id }
    /// `true` when the most recent subtitle selection told the engine to draw
    /// nothing (an explicit `nil`), distinct from "never called".
    var lastSubtitleSelectionCleared: Bool { !subtitleSelections.isEmpty && subtitleSelections.last! == nil }

    func load(request: PlaybackRequest, startPosition: TimeInterval) async {}
    func play() {}
    func pause() {}
    func seek(to seconds: TimeInterval) async {}
    func seek(to seconds: TimeInterval, kind: VideoSeekKind) async {}
    func stop() {}
    func setPlaybackSpeed(_ rate: Double) {}
    func setAudioDelay(_ seconds: TimeInterval) {}
    func setSubtitleDelay(_ seconds: TimeInterval) {}
    func updateSubtitleStyle(_ style: SubtitleStyle) {}
    func setDialogEnhanceEnabled(_ enabled: Bool) {}
    func setScrubRefreshBoost(_ enabled: Bool) {}

    func selectAudioTrack(_ track: MediaTrack?) { audioSelections.append(track) }
    func selectSubtitleTrack(_ track: MediaTrack?) { subtitleSelections.append(track) }
    func selectSecondarySubtitleTrack(_ track: MediaTrack?) { secondarySelections.append(track) }

    #if canImport(UIKit)
    func makeVideoOutputView() -> UIView { UIView() }
    #endif
}
#endif
