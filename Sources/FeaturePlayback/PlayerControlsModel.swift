#if canImport(UIKit)
import Foundation
import CoreGraphics
import Observation
import CoreModels

/// A selectable audio or subtitle option for the in-player track menu.
///
/// `id` is the option's index within its `AVMediaSelectionGroup`; the special
/// id `PlayerTrackOption.offID` represents "Off" (subtitles only).
public struct PlayerTrackOption: Identifiable, Hashable, Sendable {
    public static let offID = -1
    public var id: Int
    public var title: String
    public var isSelected: Bool

    public init(id: Int, title: String, isSelected: Bool) {
        self.id = id
        self.title = title
        self.isSelected = isSelected
    }
}

/// Shared, observable state for the custom player's transport overlay.
///
/// `PlayerViewModel` writes live playback facts (position, duration, buffered,
/// paused); the UIKit input controller writes scrub state and the resolved
/// preview thumbnail; the SwiftUI overlay only reads. Keeping it UI-framework
/// free (CoreGraphics only) lets the overlay stay a thin presentation layer.
@MainActor
@Observable
public final class PlayerControlsModel {
    // MARK: Live playback (written by the view model)
    public var duration: TimeInterval = 0
    public var currentSeconds: TimeInterval = 0
    public var bufferedSeconds: TimeInterval = 0
    public var isPaused: Bool = false
    /// True while a committed seek is resolving, so the overlay can show a spinner.
    public var isSeeking: Bool = false

    /// The latest *committed* seek destination that hasn't yet been reached by
    /// the engine. While non-nil, the engine-poll refresh loop must NOT
    /// overwrite `currentSeconds` with the live engine time — that's what
    /// caused the "press right → snaps back" feel: a 300ms poll arrived
    /// between the optimistic position update and the engine actually arriving,
    /// and snapped the bar back to the *old* position. With this in place, the
    /// scrub head holds at the optimistic target until the engine catches up
    /// (within a small tolerance), then we release.
    public var pendingSeekTarget: TimeInterval?

    // MARK: Presentation
    public var title: String = ""
    public var subtitle: String = ""
    public var hasTrickplay: Bool = false

    // MARK: Track menus
    public var audioOptions: [PlayerTrackOption] = []
    public var subtitleOptions: [PlayerTrackOption] = []

    // MARK: Live tunables (mirrors of engine state)
    /// What the active engine supports — drives which rows the options menu
    /// renders so AVPlayer doesn't show fake delay sliders, etc.
    public var engineCapabilities: PlayerEngineCapabilities = []
    /// Current playback speed (1.0 == normal).
    public var playbackSpeed: Double = 1.0
    /// Audio offset in seconds (positive = audio later than video).
    public var audioDelaySeconds: TimeInterval = 0
    /// Subtitle offset in seconds (positive = subs later than video).
    public var subtitleDelaySeconds: TimeInterval = 0
    /// Whether the dialog-enhance audio filter is engaged (when supported).
    public var dialogEnhanceEnabled: Bool = false

    // MARK: Transport UI state (written by the input controller)
    public var controlsVisible: Bool = false
    public var isScrubbing: Bool = false
    public var scrubSeconds: TimeInterval = 0
    /// The trickplay frame for `scrubSeconds`, shown above the scrub head.
    public var previewImage: CGImage?
    /// Whether a real scrub-preview frame is available for display.
    public var hasPreviewFrame: Bool { previewImage != nil }
    /// True while the focusable bottom control bar owns Siri-Remote focus. The
    /// input controller reads this to suppress scrub gestures and the control bar
    /// reads it to take/relinquish focus.
    public var controlBarVisible: Bool = false

    // MARK: Skip hint (transient ±10s indicator)
    /// Whether the last skip was forward; drives which glyph the hint shows.
    public var skipHintForward: Bool = true
    /// True while the transient skip indicator is on screen.
    public var skipHintVisible: Bool = false
    /// Bumped on every skip so the indicator's pop-in transition replays even
    /// when it's already visible (rapid repeated skips).
    public var skipHintToken: Int = 0
    /// Which side of the thumb the loading spinner sits on while a seek resolves:
    /// the left of the current time after a backward skip, otherwise the right
    /// (forward skip or a plain scrub). Mirrors where the ±10s glyph appeared.
    public var seekIndicatorOnLeft: Bool = false

    /// Whether the live playback-diagnostics overlay is shown. Toggleable from
    /// the in-player control bar; seeded from the caller's initial preference.
    public var diagnosticsEnabled: Bool = false

    public init() {}

    /// Where the transport playhead should render: the scrub target while
    /// scrubbing, otherwise the live position.
    public var displaySeconds: TimeInterval { isScrubbing ? scrubSeconds : currentSeconds }

    public var progressFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, displaySeconds / duration))
    }

    public var bufferedFraction: Double {
        guard duration > 0 else { return 0 }
        return min(1, max(0, bufferedSeconds / duration))
    }

    public var hasSelectableAudio: Bool { audioOptions.count > 1 }
    public var hasSelectableSubtitles: Bool { !subtitleOptions.isEmpty }
}
#endif
