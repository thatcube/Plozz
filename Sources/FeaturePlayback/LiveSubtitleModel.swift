#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import CoreModels
import CoreNetworking

/// The live bridge between parsed subtitle cues and the owned
/// ``SubtitleOverlayView`` during real playback.
///
/// It holds the active ``SubtitleCueTimeline`` for the primary (and optional
/// secondary/dual) track plus the resolved ``SubtitleStyle``, and exposes the
/// currently-on-screen cues as observable state. A display-link in the player
/// container calls ``tick(_:)`` every frame with the engine clock; the timelines
/// recompute the active window cheaply (O(log n + k)) and this model only
/// publishes a new cue array when a cue boundary is actually crossed, so SwiftUI
/// re-renders the overlay only when the visible text changes — and the display
/// can idle while a line is held.
///
/// This is the runtime counterpart to the design's "engines emit cues, Plozz
/// draws them" inversion: the model is fed by whatever produced the cues (a
/// provider sidecar parsed by ``SubtitleCueParser`` today, an AetherEngine cue
/// stream later) and is completely independent of the playback engine.
@MainActor
@Observable
public final class LiveSubtitleModel {
    /// Cues on screen for the primary track right now (already time-filtered).
    public private(set) var primary: [SubtitleCue] = []
    /// Cues on screen for an optional secondary (dual-subtitle) track.
    public private(set) var secondary: [SubtitleCue] = []
    /// The resolved appearance the overlay renders with.
    public var style: SubtitleStyle = .default
    /// Whether the current video frame is HDR, so the overlay can clamp luminance.
    public var isHDR: Bool = false
    /// On-screen rect of the video image (for bitmap cues / precise placement);
    /// `nil` fills the container, which is correct for text dialogue.
    public var videoRect: CGRect?

    @ObservationIgnored private var primaryTimeline: SubtitleCueTimeline?
    @ObservationIgnored private var secondaryTimeline: SubtitleCueTimeline?
    @ObservationIgnored private var storedOffset: Double = 0
    /// `true` when an engine pushes its own already-windowed active cues
    /// (AetherEngine/Plozzigen) instead of us driving a sidecar timeline. In this
    /// mode there is no `SubtitleCueTimeline` and ``tick(_:)`` time-filters the
    /// pushed buffer — the engine emits the decoded *read-ahead* cue set (not just
    /// the on-screen line), so the model selects the cues active at the playhead.
    @ObservationIgnored private var isLiveFeed = false
    /// The full decoded cue buffer most recently pushed by a live engine feed.
    @ObservationIgnored private var liveCues: [SubtitleCue] = []
    /// IDs of the currently-seated live cues, so we only republish `primary` when
    /// the active set actually changes (not every 60 Hz tick).
    @ObservationIgnored private var liveActiveIDs: [Int] = []
    /// Last clock value seen by ``tick(_:)``, so a fresh ``updateLiveCues(_:)``
    /// push can re-seat against the current playhead between ticks.
    @ObservationIgnored private var lastTickTime: Double = 0

    public init() {}

    /// `true` when a primary (or secondary) cue stream is loaded, or an engine is
    /// live-feeding cues, so the host can decide whether the overlay needs driving.
    public var hasContent: Bool { primaryTimeline != nil || secondaryTimeline != nil || isLiveFeed }

    /// Global sync offset in seconds (positive = show subtitles later). Applied to
    /// both tracks and forces the next ``tick(_:)`` to recompute.
    public var offset: Double {
        get { storedOffset }
        set {
            storedOffset = newValue
            primaryTimeline?.offset = newValue
            secondaryTimeline?.offset = newValue
        }
    }

    /// Loads (or, with `nil`, clears) the primary cue stream. The on-screen set is
    /// reset to empty until the next ``tick(_:)`` seats the active cues.
    public func loadPrimary(_ stream: SubtitleCueStream?) {
        isLiveFeed = false
        if let stream {
            primaryTimeline = SubtitleCueTimeline(stream: stream, offset: storedOffset)
        } else {
            primaryTimeline = nil
        }
        primary = []
    }

    /// Switches the model into **live-feed** mode: drops any sidecar timeline and
    /// lets an engine push its decoded cue buffer via ``updateLiveCues(_:)``, which
    /// ``tick(_:)`` then time-filters against the playhead. Used by Plozzigen
    /// (AetherEngine), which decodes subtitles itself.
    public func beginLiveFeed() {
        isLiveFeed = true
        primaryTimeline = nil
        secondaryTimeline = nil
        liveCues = []
        liveActiveIDs = []
        primary = []
        secondary = []
    }

    /// Replaces the live cue buffer from an engine feed and re-seats the on-screen
    /// set against the current playhead. No-op unless ``beginLiveFeed()`` is
    /// active, so a stray late callback can't draw over a sidecar timeline or a
    /// cleared overlay.
    public func updateLiveCues(_ cues: [SubtitleCue]) {
        guard isLiveFeed else { return }
        liveCues = cues
        recomputeLiveActive(at: lastTickTime)
    }

    /// Seats the live cues visible at `time` (engine playhead), republishing
    /// `primary` only when the active set changes.
    private func recomputeLiveActive(at time: Double) {
        let active = liveCues.active(at: time, offset: storedOffset)
        let ids = active.map(\.id)
        if ids != liveActiveIDs {
            liveActiveIDs = ids
            primary = active
        }
    }

    /// Loads (or clears) the secondary/dual cue stream.
    public func loadSecondary(_ stream: SubtitleCueStream?) {
        if let stream {
            secondaryTimeline = SubtitleCueTimeline(stream: stream, offset: storedOffset)
        } else {
            secondaryTimeline = nil
        }
        secondary = []
    }

    /// Drops all cue streams and clears the screen.
    public func clear() {
        isLiveFeed = false
        primaryTimeline = nil
        secondaryTimeline = nil
        liveCues = []
        liveActiveIDs = []
        primary = []
        secondary = []
    }

    /// Advance to playback `time` (seconds). Republishes the active cues for a
    /// track only when its on-screen set changes, so a 60 Hz call is cheap.
    public func tick(_ time: Double) {
        lastTickTime = time
        if isLiveFeed {
            recomputeLiveActive(at: time)
            return
        }
        if let p = primaryTimeline, p.update(to: time) {
            primary = p.active
        }
        if let s = secondaryTimeline, s.update(to: time) { secondary = s.active }
    }
}

/// Thin SwiftUI wrapper that observes a ``LiveSubtitleModel`` and feeds the pure
/// ``SubtitleOverlayView``. Hosted above the engine's video surface (below the
/// transport controls) in the player container.
struct LiveSubtitleOverlay: View {
    let model: LiveSubtitleModel

    var body: some View {
        SubtitleOverlayView(
            primary: model.primary,
            secondary: model.secondary,
            style: model.style,
            isHDR: model.isHDR,
            videoRect: model.videoRect
        )
        .ignoresSafeArea()
    }
}
#endif
