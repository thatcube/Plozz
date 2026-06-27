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

    // MARK: Local remux debug / comparison harness
    /// Whether the current title is eligible for the shared local-remux seam.
    public var localRemuxEligible: Bool = false
    /// Whether playback is currently flowing through an active local-remux
    /// strategy (as opposed to plain native/hybrid/server routing).
    public var localRemuxActive: Bool = false
    /// Available runtime-selectable local-remux strategies, persisted through the
    /// playback preferences store.
    public var localRemuxStrategies: [LocalRemuxStrategyChoice] = LocalRemuxStrategyChoice.builtInChoices
    /// Persisted strategy selection for the next playback bring-up.
    public var selectedLocalRemuxStrategyID: String = LocalRemuxStrategyChoice.disabledID
    /// Human-readable name of the strategy actually active for *this* playback
    /// session. A mid-play change to `selectedLocalRemuxStrategyID` does not rewrite
    /// the active stream until the title is reloaded.
    public var activeLocalRemuxStrategyName: String?
    /// Human-readable reason why this title didn't enter the local-remux seam.
    public var localRemuxEligibilityMessage: String = ""
    /// Whether the scripted seek torture-test is currently running.
    public var remuxHarnessRunning: Bool = false
    /// Live status / last result for the scripted seek torture-test.
    public var remuxHarnessStatus: String = ""
    /// True when the selected remux mode is not what is currently playing, so the
    /// player can offer an explicit reload instead of making the user guess.
    public var localRemuxReloadAvailable: Bool = false

    // MARK: Skip intros/credits
    /// Server-detected skippable segments (intros/credits) for the playing item.
    /// Populated by the view model only when the per-profile Skip Intros setting
    /// is on; empty otherwise, so no skip button is ever offered.
    public var skippableSegments: [MediaSegment] = []
    /// True while the user has dismissed the skip button for the *current*
    /// segment, so it doesn't keep re-grabbing focus for the rest of that window.
    public var dismissedSegmentID: String?

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

    /// The skippable segment whose window currently contains the live position,
    /// unless the user already dismissed that segment's button. Drives whether
    /// the in-player Skip Intro/Credits button is shown and focusable.
    public var activeSkipSegment: MediaSegment? {
        guard let segment = skippableSegments.activeSkippable(at: currentSeconds) else { return nil }
        return segment.id == dismissedSegmentID ? nil : segment
    }

    /// How intros/credits are handled (Off / On / Auto (delay) / Auto (instant)).
    /// Mirrors the per-profile setting; set when markers load. Drives whether the
    /// Skip button is surfaced, auto-skipped after a delay, or skipped instantly.
    public var skipMode: SkipIntrosMode = .off

    /// In `.autoDelay`, the playback position (seconds) at which the active
    /// segment auto-skips. Set while the button counts down; `nil` otherwise.
    /// The button's ring depletes toward this so the wait is visible.
    public var autoSkipAtSeconds: TimeInterval?

    /// A transient, non-interactive confirmation shown briefly after a segment is
    /// auto-skipped instantly (e.g. "Skipping Intro"). Set by the view model and
    /// cleared on a short timer; `nil` the rest of the time.
    public var autoSkipNotice: AutoSkipNotice?
}

/// A brief on-screen confirmation that an intro/credits segment was skipped
/// automatically. A fresh `id` per occurrence re-triggers the reveal animation
/// even when consecutive notices share the same `label`.
public struct AutoSkipNotice: Equatable, Identifiable, Sendable {
    public let id: UUID
    public let label: String

    public init(label: String) {
        self.id = UUID()
        self.label = label
    }
}
#endif
