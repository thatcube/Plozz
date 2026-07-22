import Foundation

/// The locally-derived state of one known episode, combining a provider schedule
/// with what the user actually owns across every source (and, when Seerr is
/// configured, its request/availability status).
///
/// This is the output of the release-state machine (Step 8 Phase 2/3). It is derived
/// cache-first and recomputed after a server refresh or share scan — never by
/// querying every episode on render.
///
/// ## Derivation summary
/// - `upcoming` — a future episode absent from every source ("Airing soon").
/// - `airedGracePeriod` — the air date/time has just passed but the episode may not
///   have propagated yet; shown as "Aired today"/"Just aired" during a short grace
///   (exact timestamp: a few hours; date-only: until the following local day).
/// - `airedMissing` — the air date passed (grace elapsed) and the episode is absent
///   from every source ("Aired — not in your library").
/// - `present` — the episode exists in the library on some source; ordinary content,
///   no synthetic card. Once present, it never reverts to a schedule state.
/// - `requested` — Seerr (when configured) reports the season/episode as requested or
///   processing; shown as "Requested"/"Processing" instead of "Missing". Reflection
///   only — Plozz never auto-requests.
public enum EpisodeReleaseState: Sendable, Equatable, Hashable {
    /// A future episode not yet owned anywhere.
    case upcoming(UpcomingEpisode)
    /// Air time just passed; within the grace window before it's called missing.
    case airedGracePeriod(UpcomingEpisode)
    /// Air time passed and grace elapsed; still absent from every source.
    case airedMissing(UpcomingEpisode)
    /// The episode is present in the library on at least one source.
    case present(item: MediaItem)
    /// Seerr reflects the episode/season as requested or processing (not owned yet).
    case requested(UpcomingEpisode)

    /// The schedule backing this state, when the state is schedule-derived (every
    /// case except `.present`).
    public var upcomingEpisode: UpcomingEpisode? {
        switch self {
        case .upcoming(let e), .airedGracePeriod(let e), .airedMissing(let e), .requested(let e):
            return e
        case .present:
            return nil
        }
    }

    /// Whether this state represents an episode the user does not yet own on any
    /// source (everything but `.present`).
    public var isAbsent: Bool {
        if case .present = self { return false }
        return true
    }
}
