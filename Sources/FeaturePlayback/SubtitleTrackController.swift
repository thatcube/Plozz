#if canImport(AVFoundation)
import Foundation
import AVFoundation
import CoreModels
import CoreNetworking

/// Seam back to ``PlayerViewModel`` for the collaborators the track-selection
/// state machine drives. Held **weakly** so the controller never retains the
/// (SwiftUI-owned, `@Observable`) view model.
///
/// The engine is read through the host (not captured) on purpose: it is swapped
/// mid-session (native ⇆ Plozzigen handoff / retry / image-subtitle swap), and
/// every menu rebuild + selection must act on the *current* engine.
@MainActor
protocol SubtitleTrackControllerHost: AnyObject {
    var trackEngine: any VideoEngine { get }
    var trackEngineKind: PlaybackEngineKind { get }
    var trackRequest: PlaybackRequest? { get }
    var trackBehavior: SubtitleBehavior { get }
    var trackControls: PlayerControlsModel { get }
    var trackLiveSubtitles: LiveSubtitleModel { get }
    var trackSubtitleOverlay: SubtitleOverlayLoader { get }
    var trackStyle: SubtitleStyle { get }
    var trackPlozzigenAvailable: Bool { get }
    var trackAuthenticatedHTTPResolver: (any AuthenticatedHTTPResourceResolving)? { get }

    func trackApplySubtitleStyle(_ style: SubtitleStyle)
    func trackRememberedSubtitle(for item: MediaItem) -> RememberedSubtitleSelection?
    func trackEffectiveSubtitleRule(for item: MediaItem) -> SubtitlePolicy.Rule
    func trackRecordAudioSelection(language: String?)
    func trackRecordSubtitleSelection(_ selection: RememberedSubtitleSelection?)
    func trackRefreshSubtitleDelayAvailability()
    /// Re-route playback onto Plozzigen at the current position so a manually
    /// picked image-based subtitle can be decoded + drawn on-device. Forwards to
    /// the view model's `playResolved` (which owns engine bring-up).
    func trackPlayResolvedForImageSubtitleSwap(
        _ request: PlaybackRequest, startPosition: TimeInterval
    ) async
}

/// Owns the in-player **track selection** state extracted from
/// ``PlayerViewModel``: the audio / primary-subtitle / secondary-subtitle
/// selections, the menu the custom player draws, and the algorithms that route a
/// pick (or the load-time default) through the correct renderer across the
/// native and Plozzigen engines and the two disjoint id-spaces.
///
/// Fragile semantics that were inline and are now in one testable place:
/// - **subtitle on/off + track-switch routing**: text-with-sidecar → overlay,
///   embedded-text → AVPlayer draw, image-based → native⇄Plozzigen swap,
///   Plozzigen → live-feed overlay (``selectSubtitleOption``).
/// - the **load-time default** applied exactly once per load across the two
///   moments its tracks can arrive (``applyInitialSubtitleSelectionIfReady``).
/// - the **optimistic pending-audio** indicator that holds a pick until the
///   engine's reload confirms it (``loadTrackOptions`` / ``selectAudioOption``).
/// - the **cross-server audio import** retried until the engine's tracks are
///   known (``applyImportedAudioIfPossible``).
@MainActor
final class SubtitleTrackController {
    private weak var host: SubtitleTrackControllerHost?

    // MARK: Selection state

    /// Subtitles downloaded (Jellyfin/Plex) or otherwise sourced during *this*
    /// session and hot-loaded into the menu — kept separate from the engine's
    /// demuxed list (which can't be mutated). Rendered through the overlay.
    private var hotLoadedSubtitleTracks: [MediaTrack] = []
    /// Next synthetic id for a hot-loaded subtitle. Starts high so it can never
    /// collide with an engine/provider stream id.
    private var nextHotLoadedSubtitleID = 900_000

    /// Current in-player track-menu selection, so the menu can show a checkmark.
    /// `selectedSubtitleTrackID == nil` represents "Off".
    private(set) var selectedAudioTrackID: Int?
    private(set) var selectedSubtitleTrackID: Int?
    /// The track feeding the overlay's **second** (dual) subtitle line, or `nil`
    /// when off. Always renders through the overlay, so it must be a text track.
    private(set) var selectedSecondarySubtitleTrackID: Int?

    /// A just-requested audio track id whose engine switch is still in flight.
    /// Plozzigen reloads to change audio, so `currentAudioTrackID` lags the pick
    /// by a beat; the target is shown optimistically until the engine confirms.
    private var pendingAudioTrackID: Int?

    /// Whether the load-time *default* subtitle has been routed through the
    /// overlay yet for the current load. Native tracks are known synchronously;
    /// Plozzigen demuxes asynchronously — this guards the auto-selection to run
    /// exactly once per load, on whichever moment has the tracks.
    private var initialSubtitleApplied = false

    /// A provider subtitle track the viewer manually picked that turned out to be
    /// image-based, triggering a native→Plozzigen swap. The provider id-space
    /// doesn't line up with Plozzigen's, so this holds the picked track until
    /// Plozzigen's list arrives and it can be attribute-matched.
    private var pendingImageSubtitleMatch: MediaTrack?

    /// True once the viewer manually changed the **audio** track this session.
    private(set) var viewerChangedAudioThisSession = false
    /// True once the viewer manually changed the **subtitle** track this session.
    private(set) var viewerChangedSubtitleThisSession = false

    /// A cross-server-imported audio language awaiting application — set when
    /// reconcile finds a remembered choice from another server but the engine's
    /// audio tracks aren't known yet. Applied on the next tracks arrival.
    private var crossServerAudioImportLanguage: String?

    /// Content-detected subtitle languages, keyed by track id. Filled when a text
    /// subtitle with no provider language tag is parsed for the overlay, so the
    /// menu can label an otherwise-anonymous "Track 8".
    private var detectedSubtitleLanguages: [Int: String] = [:]

    init(host: SubtitleTrackControllerHost) {
        self.host = host
    }

    // MARK: Detected-language cache (overlay hooks)

    func detectedLanguage(for id: Int) -> String? {
        detectedSubtitleLanguages[id]
    }

    func recordDetectedLanguage(_ language: String, for id: Int) {
        detectedSubtitleLanguages[id] = language
    }

    // MARK: Menu building

    /// Publishes the engine's audio/subtitle track lists into `controls` for the
    /// in-player track menu. Switching is routed back through the engine so the
    /// menu behaves identically across engines.
    func loadTrackOptions() {
        guard let host else { return }
        let engine = host.trackEngine
        // Enrich the engine's demuxed tracks with the provider's probe of the
        // same file (matched by stream id), filling in any language/codec/title
        // the demuxer dropped. For the native engine the two lists are identical,
        // so this is a no-op there; it only adds data on the advanced engine.
        let providerAudio = host.trackRequest?.audioTracks ?? []
        let providerSubs = host.trackRequest?.subtitleTracks ?? []

        let audio = engine.audioTracks.map { track in
            track.enriched(withProvider: providerAudio.first { $0.id == track.id })
        }
        // Resolve which audio row shows as selected: an in-flight pick
        // (optimistic) → the engine's resolved active track (ground truth) → the
        // default-flag heuristic only before either is known.
        let audioResolution = TrackMenuBuilder.resolveSelectedAudioTrackID(
            current: selectedAudioTrackID,
            pending: pendingAudioTrackID,
            engineActive: engine.currentAudioTrackID,
            tracks: audio
        )
        selectedAudioTrackID = audioResolution.selected
        if audioResolution.clearPending { pendingAudioTrackID = nil }

        // Preferred languages, highest priority first: the viewer's explicit
        // choice (or device language) leads, the device language backs it up.
        let preferred: [String?] = [
            host.trackBehavior.resolvedPreferredLanguage,
            LanguageMatch.deviceLanguageCode
        ]
        host.trackControls.audioOptions = TrackMenuBuilder.audioOptions(
            tracks: audio,
            selectedID: selectedAudioTrackID,
            preferred: preferred
        )

        let subtitles = engine.subtitleTracks.map { track in
            track.enriched(withProvider: providerSubs.first { $0.id == track.id })
        } + hotLoadedSubtitleTracks
        #if DEBUG
        // One-line ground truth for untagged-track triage.
        let unresolved = subtitles.filter { $0.language == nil }.count
        let providerWithLang = providerSubs.filter { $0.language != nil }.count
        PlozzLog.playback.debug(
            "Track labels: \(subtitles.count) subs, \(unresolved) still no language; provider probe had \(providerSubs.count) subs (\(providerWithLang) with a language)"
        )
        #endif
        host.trackControls.subtitleOptions = TrackMenuBuilder.subtitleOptions(
            tracks: subtitles,
            selectedID: selectedSubtitleTrackID,
            preferred: preferred,
            detectedLanguages: detectedSubtitleLanguages
        )

        // Dual/second-line picker. If the current secondary is no longer eligible
        // (e.g. it just became the primary, or the media changed), reconcile by
        // dropping it — clearing both its cues and its styling.
        let secondaryEligible = eligibleSecondarySubtitleTracks()
        host.trackControls.secondarySubtitleImagePrimaryFormat = TrackMenuBuilder.imagePrimaryFormat(
            selectedPrimaryID: selectedSubtitleTrackID,
            engineTracks: engine.subtitleTracks,
            providerTracks: providerSubs
        )
        if let sec = selectedSecondarySubtitleTrackID,
           !secondaryEligible.contains(where: { $0.id == sec }) {
            selectedSecondarySubtitleTrackID = nil
            host.trackSubtitleOverlay.cancelSecondary()
            if engine.capabilities.contains(.dualSubtitleDecode) {
                engine.selectSecondarySubtitleTrack(nil)
            }
            host.trackLiveSubtitles.loadSecondary(nil)
            host.trackControls.secondarySubtitleStatus = .idle
            if host.trackStyle.secondary != nil {
                var cleared = host.trackStyle
                cleared.secondary = nil
                host.trackApplySubtitleStyle(cleared)
            }
        }
        host.trackControls.secondarySubtitleOptions = TrackMenuBuilder.secondaryOptions(
            eligible: secondaryEligible,
            selectedID: selectedSecondarySubtitleTrackID,
            preferred: preferred,
            detectedLanguages: detectedSubtitleLanguages
        )
    }

    // MARK: Audio selection

    /// Selects an audio track from the menu, routed through the engine.
    func selectAudioOption(id: Int) {
        guard let host else { return }
        let engine = host.trackEngine
        guard let track = engine.audioTracks.first(where: { $0.id == id }) else { return }
        viewerChangedAudioThisSession = true
        engine.selectAudioTrack(track)
        // Remember this language for the series so later episodes start here.
        host.trackRecordAudioSelection(language: track.language)
        // Show the target immediately; the engine's reload-to-switch lags, so we
        // hold this optimistic pick until `currentAudioTrackID` confirms it.
        pendingAudioTrackID = id
        selectedAudioTrackID = id
        loadTrackOptions()
    }

    /// Applies a pending cross-server audio import once the engine's audio tracks
    /// are known. Retried from the tracks-changed callback (Plozzigen's async
    /// arrival) and at the end of `playResolved` (native). No-ops when the
    /// matching track is already active or no pending import is set.
    func applyImportedAudioIfPossible() {
        guard let host, let language = crossServerAudioImportLanguage else { return }
        let engine = host.trackEngine
        guard let track = engine.audioTracks.first(where: {
            LanguageMatch.matches($0.language, language)
        }) else { return }
        crossServerAudioImportLanguage = nil
        guard track.id != engine.currentAudioTrackID, track.id != pendingAudioTrackID else { return }
        engine.selectAudioTrack(track)
        pendingAudioTrackID = track.id
        selectedAudioTrackID = track.id
        loadTrackOptions()
    }

    /// Queue a cross-server audio import (from series-memory reconcile) and try
    /// to apply it immediately.
    func queueImportedAudio(language: String) {
        crossServerAudioImportLanguage = language
        applyImportedAudioIfPossible()
    }

    // MARK: Load-time default subtitle

    /// Routes the load-time **default** subtitle through the owned overlay so it
    /// renders identically to a manual pick. Runs once per load:
    /// - **native** — provider tracks are known synchronously.
    /// - **Plozzigen** — waits for the demuxed list, then applies (or
    ///   attribute-matches a manually-picked image subtitle).
    func applyInitialSubtitleSelectionIfReady(for request: PlaybackRequest) {
        guard let host, !initialSubtitleApplied else { return }
        switch host.trackEngineKind {
        case .native:
            initialSubtitleApplied = true
            applyDefaultSubtitleThroughOverlay(from: request.subtitleTracks)
        case .plozzigen:
            let tracks = host.trackEngine.subtitleTracks
            guard !tracks.isEmpty else { return }
            initialSubtitleApplied = true
            if let picked = pendingImageSubtitleMatch {
                pendingImageSubtitleMatch = nil
                if let match = SubtitleMatchScorer.bestMatch(for: picked, in: tracks) {
                    selectSubtitleOption(id: match.id, userInitiated: false)
                    return
                }
                // No confident match — fall through to the default rule rather
                // than selecting a wrong-language track.
            }
            applyDefaultSubtitleThroughOverlay(from: tracks)
        default:
            initialSubtitleApplied = true
        }
    }

    /// Reset the once-per-load guard and re-run the default selection — used on a
    /// fresh load and when series-memory reconcile resolves a remembered value.
    func applyInitialSubtitleForNewLoad(for request: PlaybackRequest) {
        initialSubtitleApplied = false
        applyInitialSubtitleSelectionIfReady(for: request)
    }

    /// Picks the default subtitle for the user's mode + preferred language and
    /// routes it through the overlay, or clears subtitles when there is no
    /// default text track. Image-based defaults are skipped here.
    private func applyDefaultSubtitleThroughOverlay(from tracks: [MediaTrack]) {
        guard let host else { return }
        let engine = host.trackEngine
        // A remembered per-series subtitle decision overrides the default rule.
        if let remembered = host.trackRequest.map({ host.trackRememberedSubtitle(for: $0.item) }) ?? nil {
            switch remembered {
            case .off:
                engine.selectSubtitleTrack(nil)
                host.trackSubtitleOverlay.clearPrimary()
                selectedSubtitleTrackID = nil
                loadTrackOptions()
                return
            case .language(let language):
                // Honor the remembered language explicitly, but only when a
                // matching, renderable text track exists; else fall through.
                if tracks.hasSuitableSubtitle(forLanguage: language),
                   let chosen = tracks.defaultSubtitleSelection(mode: .all, preferredLanguage: language),
                   !chosen.isImageBasedSubtitle {
                    selectSubtitleOption(id: chosen.id, userInitiated: false)
                    return
                }
            }
        }

        let rule = host.trackRequest.map { host.trackEffectiveSubtitleRule(for: $0.item) }
        let chosen = tracks.defaultSubtitleSelection(
            mode: rule?.mode ?? host.trackBehavior.subtitleMode,
            preferredLanguage: rule?.preferredLanguage ?? host.trackBehavior.resolvedPreferredLanguage
        )
        guard let chosen, !chosen.isImageBasedSubtitle else {
            engine.selectSubtitleTrack(nil)
            host.trackSubtitleOverlay.clearPrimary()
            selectedSubtitleTrackID = nil
            loadTrackOptions()
            return
        }
        selectSubtitleOption(id: chosen.id, userInitiated: false)
    }

    #if DEBUG
    /// Composes the DEBUG primary-subtitle route readout shown at the bottom of
    /// the Subtitles list: active engine, the routing path taken, and (when known)
    /// the cue count.
    func setPrimarySubtitleDiagnostic(route: String, cues: Int? = nil) {
        guard let host else { return }
        var text = "eng \(host.trackEngineKind) · \(route)"
        if let cues { text += " · \(cues) cues" }
        host.trackControls.primarySubtitleDiagnostic = text
    }
    #endif

    // MARK: Primary subtitle selection

    /// Selects a subtitle track, or turns subtitles off (`PlayerTrackOption.offID`).
    /// `userInitiated` is `true` for a real menu pick (remembered for the series)
    /// and `false` for the programmatic load-time default.
    func selectSubtitleOption(id: Int, userInitiated: Bool = true) {
        guard let host else { return }
        let engine = host.trackEngine
        if userInitiated { viewerChangedSubtitleThisSession = true }
        if id == PlayerTrackOption.offID {
            if userInitiated { host.trackRecordSubtitleSelection(.off) }
            engine.selectSubtitleTrack(nil)
            host.trackSubtitleOverlay.clearPrimary()
            selectedSubtitleTrackID = nil
            #if DEBUG
            host.trackControls.primarySubtitleDiagnostic = ""
            #endif
            loadTrackOptions()
            return
        }
        guard let track = engine.subtitleTracks.first(where: { $0.id == id }) else {
            // Not an engine-demuxed track: it may be a subtitle we downloaded and
            // hot-loaded this session. Those are always text sidecars, so render
            // them through the overlay regardless of engine.
            if let hot = hotLoadedSubtitleTracks.first(where: { $0.id == id }) {
                if userInitiated { host.trackRecordSubtitleSelection(hot.language.map(RememberedSubtitleSelection.language)) }
                selectedSubtitleTrackID = id
                engine.selectSubtitleTrack(nil)
                #if DEBUG
                setPrimarySubtitleDiagnostic(route: "overlay · hot-loaded")
                #endif
                host.trackSubtitleOverlay.loadPrimary(hot)
                loadTrackOptions()
            }
            return
        }
        if userInitiated { host.trackRecordSubtitleSelection(track.language.map(RememberedSubtitleSelection.language)) }

        // Image-based subtitles (PGS/DVB/DVD/VOBSUB) can't be rendered by
        // AVPlayer. If the user picks one on the native engine, swap to Plozzigen
        // at the current position: it decodes the bitmap packets into image cues
        // the overlay draws at their authored position — no server burn-in.
        if track.isImageBasedSubtitle, host.trackEngineKind == .native,
           let request = host.trackRequest, !request.isTranscoding, host.trackPlozzigenAvailable {
            host.trackSubtitleOverlay.clearPrimary()
            selectedSubtitleTrackID = id
            Task { await swapEngineForImageSubtitle(track) }
            return
        }

        // Text subtitle on the native engine. With a sidecar URL we render it
        // through the overlay (styling, HDR luminance, live offset all apply),
        // suppressing AVPlayer's draw. WITHOUT a sidecar (embedded text) the
        // overlay has no cue source, so let AVPlayer draw the track natively.
        if !track.isImageBasedSubtitle, host.trackEngineKind == .native {
            selectedSubtitleTrackID = id
            if track.deliverySource != nil {
                engine.selectSubtitleTrack(nil)
                #if DEBUG
                setPrimarySubtitleDiagnostic(route: "overlay")
                #endif
                host.trackSubtitleOverlay.loadPrimary(track)
            } else {
                host.trackSubtitleOverlay.clearPrimary()
                engine.selectSubtitleTrack(track)
                #if DEBUG
                setPrimarySubtitleDiagnostic(route: "avplayer-draw")
                #endif
            }
            loadTrackOptions()
            return
        }

        // Plozzigen decodes the selected subtitle and publishes its active cues;
        // route them through the owned overlay (live-feed mode) so text *and*
        // bitmap subs draw on the same SDR renderer as native.
        host.trackSubtitleOverlay.cancelPrimary()
        host.trackLiveSubtitles.beginLiveFeed()
        host.trackRefreshSubtitleDelayAvailability()
        engine.selectSubtitleTrack(track)
        selectedSubtitleTrackID = id
        #if DEBUG
        setPrimarySubtitleDiagnostic(route: "live-feed")
        #endif
        loadTrackOptions()
    }

    func resolveSubtitleDeliveryURL(_ track: MediaTrack) async throws -> URL? {
        guard let source = track.deliverySource else { return nil }
        switch source {
        case .localFile(let url):
            return url
        case .authenticatedHTTP(let locator):
            return try await host?.trackAuthenticatedHTTPResolver?.resolve(locator)
        }
    }

    // MARK: Dual (secondary) subtitle

    /// The tracks a second subtitle line can show. Sourced from the PROVIDER's
    /// subtitle probe (not the engine's demuxed tracks) because only the provider
    /// reliably carries a text sub's delivery source. Bitmap tracks are never
    /// eligible; when the primary is bitmap, dual is disabled entirely.
    private func eligibleSecondarySubtitleTracks() -> [MediaTrack] {
        guard let host else { return [] }
        return TrackMenuBuilder.eligibleSecondaryTracks(
            selectedPrimaryID: selectedSubtitleTrackID,
            engineTracks: host.trackEngine.subtitleTracks,
            providerTracks: host.trackRequest?.subtitleTracks ?? [],
            engineSupportsDualDecode: host.trackEngine.capabilities.contains(.dualSubtitleDecode)
        )
    }

    /// Selects the second (dual) subtitle track, or turns the second line off.
    /// The secondary always renders through the overlay. Picking a track also
    /// enables the secondary *styling* so the overlay actually draws the line;
    /// turning it off clears both.
    func selectSecondarySubtitleOption(id: Int) {
        guard let host else { return }
        let engine = host.trackEngine
        let engineDual = engine.capabilities.contains(.dualSubtitleDecode)
        if id == PlayerTrackOption.offID {
            host.trackSubtitleOverlay.cancelSecondary()
            selectedSecondarySubtitleTrackID = nil
            if engineDual {
                engine.selectSecondarySubtitleTrack(nil)
            }
            host.trackLiveSubtitles.loadSecondary(nil)
            host.trackControls.secondarySubtitleStatus = .idle
            if host.trackStyle.secondary != nil {
                var cleared = host.trackStyle
                cleared.secondary = nil
                host.trackApplySubtitleStyle(cleared)
            }
            loadTrackOptions()
            return
        }
        guard let track = eligibleSecondarySubtitleTracks().first(where: { $0.id == id }) else { return }
        selectedSecondarySubtitleTrackID = id
        host.trackControls.secondarySubtitleStatus = .loading
        // The overlay only draws the second line when `style.secondary` exists;
        // seed a default (which inherits the primary look) if unset.
        if host.trackStyle.secondary == nil {
            var enabled = host.trackStyle
            enabled.secondary = SubtitleStyle.Secondary()
            host.trackApplySubtitleStyle(enabled)
        }
        if engineDual {
            // Engine decodes the embedded second track itself and publishes cues
            // via the secondary-cues callback, which the model draws through
            // secondary-live mode. Status flips to `.loaded` when cues land.
            host.trackSubtitleOverlay.cancelSecondary()
            host.trackLiveSubtitles.beginSecondaryLiveFeed()
            engine.selectSecondarySubtitleTrack(track)
        } else {
            host.trackSubtitleOverlay.loadSecondary(track)
        }
        loadTrackOptions()
    }

    /// Swaps from the native engine to Plozzigen (preserving position) so an
    /// image-based subtitle the user manually selected can be decoded and drawn
    /// on-device. Plozzigen demuxes asynchronously with its own id-space, so the
    /// actual selection is deferred: `pendingImageSubtitleMatch` carries the
    /// picked provider track and ``applyInitialSubtitleSelectionIfReady``
    /// attribute-matches it once the engine's list arrives.
    private func swapEngineForImageSubtitle(_ track: MediaTrack) async {
        guard let host, let request = host.trackRequest else { return }
        let engine = host.trackEngine
        let resume = max(engine.furthestObservedPosition, engine.currentTime)
        pendingImageSubtitleMatch = track
        await host.trackPlayResolvedForImageSubtitleSwap(request, startPosition: resume > 1 ? resume : 0)
        loadTrackOptions()
    }

    // MARK: Hot-loaded (downloaded) subtitle

    /// Registers a downloaded subtitle under a fresh synthetic id (never colliding
    /// with engine/provider stream ids) and rebuilds the menu so it becomes a
    /// first-class, reselectable row. Returns the assigned id.
    func hotLoadSubtitleTrack(_ track: MediaTrack, preferredLanguage: String?, forced: Bool) -> Int {
        var t = track
        t.id = nextHotLoadedSubtitleID
        nextHotLoadedSubtitleID += 1
        if t.language == nil { t.language = preferredLanguage }
        t.isForced = t.isForced || forced
        t.isImageBasedSubtitle = false
        t.isExternal = true
        hotLoadedSubtitleTracks.append(t)
        loadTrackOptions()
        return t.id
    }

    // MARK: Load / engine-change lifecycle

    /// Reset the controller-owned selection state that a fresh load drops: the
    /// dual selection and its status/diagnostic. (The primary id is intentionally
    /// NOT reset — the image-sub resolve path seeds it before `playResolved`.)
    func resetForNewLoad() {
        guard let host else { return }
        selectedSecondarySubtitleTrackID = nil
        host.trackControls.secondarySubtitleStatus = .idle
        #if DEBUG
        host.trackControls.primarySubtitleDiagnostic = ""
        #endif
    }

    /// Re-apply the remembered audio/subtitle/secondary selections onto an engine
    /// rebuilt by a foreground reload. Only the Plozzigen engine needs this
    /// (native restores its own selections); a no-op otherwise.
    func reapplyTrackSelections(to recoveringEngine: any VideoEngine) {
        guard let host, host.trackEngineKind == .plozzigen else { return }
        if let selectedAudioTrackID,
           selectedAudioTrackID != recoveringEngine.currentAudioTrackID,
           let track = recoveringEngine.audioTracks.first(where: { $0.id == selectedAudioTrackID }) {
            recoveringEngine.selectAudioTrack(track)
        }
        if let selectedSubtitleTrackID,
           let track = recoveringEngine.subtitleTracks.first(where: { $0.id == selectedSubtitleTrackID }) {
            recoveringEngine.selectSubtitleTrack(track)
        } else {
            recoveringEngine.selectSubtitleTrack(nil)
        }
        if let selectedSecondarySubtitleTrackID,
           let track = recoveringEngine.subtitleTracks.first(where: {
               $0.id == selectedSecondarySubtitleTrackID
           }) {
            recoveringEngine.selectSecondarySubtitleTrack(track)
        } else {
            recoveringEngine.selectSecondarySubtitleTrack(nil)
        }
    }
}
#endif
