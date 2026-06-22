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

    // MARK: Presentation
    public var title: String = ""
    public var subtitle: String = ""
    public var hasTrickplay: Bool = false

    // MARK: Track menus
    public var audioOptions: [PlayerTrackOption] = []
    public var subtitleOptions: [PlayerTrackOption] = []

    // MARK: Transport UI state (written by the input controller)
    public var controlsVisible: Bool = false
    public var isScrubbing: Bool = false
    public var scrubSeconds: TimeInterval = 0
    /// The trickplay frame for `scrubSeconds`, shown above the scrub head.
    public var previewImage: CGImage?

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
