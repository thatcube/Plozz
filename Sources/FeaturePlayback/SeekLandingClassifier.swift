import Foundation
import CoreModels

/// Pure classifier that decides whether a *committed seek* landing inside a
/// skippable segment should still offer a manual Skip affordance, or be taken as
/// a deliberate jump into the segment (affordance suppressed — the seek is
/// respected). Extracted from `PlayerViewModel.updateSeekLanding` so the
/// grace-window rule (design "Option B") is unit-testable without a player.
///
/// Provider-agnostic: it works on the already-normalised `[MediaSegment]` array
/// the model holds, so intro/credits handling is identical for Plex and Jellyfin.
enum SeekLandingClassifier {
    /// Classifies where a committed seek to `target` (seconds) lands relative to
    /// the skippable segments.
    ///
    /// - Returns: a ``SkipSeekLanding`` when the seek lands inside a skippable
    ///   segment — `isWithinGrace == true` if within `MediaSegment.seekGraceWindow`
    ///   of the segment start (still offer a manual Skip button), `false` when
    ///   deeper (suppress the affordance). `nil` when the seek lands outside every
    ///   skippable segment.
    static func landing(
        forTarget target: TimeInterval,
        in segments: [MediaSegment]
    ) -> SkipSeekLanding? {
        guard let segment = segments.activeSkippable(at: target) else { return nil }
        let offset = target - segment.start
        return SkipSeekLanding(
            segmentID: segment.id,
            isWithinGrace: offset <= MediaSegment.seekGraceWindow
        )
    }
}
