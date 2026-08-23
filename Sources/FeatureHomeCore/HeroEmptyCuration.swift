import CoreModels
import Foundation

/// Tells "the hero has run out of content" apart from "a fetch failed", which an
/// empty curation looks identical to.
///
/// The distinction decides whether an empty result clears the carousel or leaves
/// it alone (see ``HeroLiveMerge``), and getting it wrong is visible either way:
/// blanking a good hero on a momentary outage, or leaving a dead one after the
/// viewer hid every library.
///
/// The signal is the **candidate pool**, not the result. Home's own loader
/// already refuses to publish an empty aggregate over good content when a fetch
/// failed, so a still-populated pool means the world is fine and an empty
/// curation must have another explanation — a broken backdrop, a filter, a slow
/// source — none of which justify tearing the carousel down. An empty pool, on
/// the other hand, is the answer: there is nothing for the enabled sources to
/// draw from.
public enum HeroEmptyCuration {
    /// Whether an empty curation is the answer rather than a failure: no enabled
    /// source had anything left to offer.
    ///
    /// Takes the rows rather than `HomeViewModel.Content` so it stays free of the
    /// main actor and testable on its own, exactly like ``HeroCurator``.
    public static func isAuthoritative(
        settings: HeroSettings,
        continueWatching: [MediaItem],
        watchlist: [MediaItem],
        recentlyAdded: [MediaItem],
        randomLibraries: [HeroRandomLibrary],
        seerConnected: Bool
    ) -> Bool {
        guard settings.isActive else { return true }
        for source in settings.sources {
            switch source {
            case .continueWatching:
                if !continueWatching.isEmpty { return false }
            case .watchlist:
                if !watchlist.isEmpty { return false }
            case .recentlyAdded:
                if !recentlyAdded.isEmpty { return false }
            case .randomFromLibrary:
                if !randomLibraries.isEmpty { return false }
            case .featured:
                // A connected Seerr answering nothing is ambiguous — it may be
                // reachable and empty, or failing — so it blocks authority rather
                // than granting it. That distinction is load-bearing for a
                // Featured-only hero, where featured is the ONLY vote: treating it
                // as authoritative would let a Seerr outage blank the carousel.
                // With no Seerr configured there is genuinely no pool, so it
                // abstains and the other sources decide.
                if seerConnected { return false }
            }
        }
        return true
    }
}
