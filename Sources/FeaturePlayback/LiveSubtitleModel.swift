#if canImport(SwiftUI)
import SwiftUI
import CoreGraphics
import CoreModels

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

    public init() {}

    /// `true` when a primary (or secondary) cue stream is loaded, so the host can
    /// decide whether the overlay needs to be driven at all.
    public var hasContent: Bool { primaryTimeline != nil || secondaryTimeline != nil }

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
        if let stream {
            primaryTimeline = SubtitleCueTimeline(stream: stream, offset: storedOffset)
        } else {
            primaryTimeline = nil
        }
        primary = []
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
        primaryTimeline = nil
        secondaryTimeline = nil
        primary = []
        secondary = []
    }

    /// Advance to playback `time` (seconds). Republishes the active cues for a
    /// track only when its on-screen set changes, so a 60 Hz call is cheap.
    public func tick(_ time: Double) {
        if let p = primaryTimeline, p.update(to: time) { primary = p.active }
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
