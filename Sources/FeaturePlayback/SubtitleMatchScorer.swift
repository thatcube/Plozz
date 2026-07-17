import Foundation
import CoreModels

/// Pure scorer that maps a provider-picked subtitle track onto the engine's own
/// subtitle track list across the two disjoint id-spaces (provider stream index
/// vs Plozzigen FFmpeg AVStream index). Extracted from
/// `PlayerViewModel.bestEngineSubtitleMatch` so the correspondence rules — a
/// required language match, tie-breaks on forced / hearing-impaired / image-based
/// agreement, and the "decline on an ambiguous tie" guard — are unit-testable.
///
/// Provider-agnostic and engine-agnostic: it compares `MediaTrack` facts only,
/// so it behaves identically whether the engine list came from AVPlayer or
/// Plozzigen and whether the source is Plex or Jellyfin.
enum SubtitleMatchScorer {
    /// Finds the engine subtitle track that best corresponds to `provider`.
    ///
    /// Requires a language match when the provider track declares a language (so a
    /// mismatch never silently swaps in the wrong subtitle). Among the language
    /// candidates it prefers agreement on forced (weight 2), hearing-impaired
    /// (weight 1), and image-based (weight 1) flags. Returns `nil` when nothing
    /// matches, or when two or more candidates tie on the top score (ambiguous —
    /// decline rather than pick arbitrarily).
    static func bestMatch(
        for provider: MediaTrack,
        in engineTracks: [MediaTrack]
    ) -> MediaTrack? {
        let candidates: [MediaTrack]
        if provider.language != nil {
            candidates = engineTracks.filter { LanguageMatch.matches($0.language, provider.language) }
        } else {
            candidates = engineTracks
        }
        guard !candidates.isEmpty else { return nil }
        func score(_ track: MediaTrack) -> Int {
            var s = 0
            if track.isForced == provider.isForced { s += 2 }
            if track.isHearingImpaired == provider.isHearingImpaired { s += 1 }
            if track.isBitmapSubtitle == provider.isBitmapSubtitle { s += 1 }
            return s
        }
        guard let best = candidates.max(by: { score($0) < score($1) }) else { return nil }
        // Require an unambiguous winner: if two or more candidates tie on the top
        // score we can't tell which subtitle the viewer meant, so decline rather
        // than swap in an arbitrary one.
        let topScore = score(best)
        guard candidates.filter({ score($0) == topScore }).count == 1 else { return nil }
        return best
    }
}
