import Foundation

/// Which entries in a provider's episode listing count as an upcoming *episode*.
public enum ScheduleEntryPolicy {

    /// Whether a listing entry is a regular episode rather than a special.
    ///
    /// Season 0 is the specials bucket on both TheTVDB and TVmaze, and it is a
    /// grab-bag: recaps, shorts, behind-the-scenes, convention panels — and
    /// theatrical films. "Avatar: The Last Airbender" ended in 2008, but its record
    /// carries S0E55 "Avatar: Aang, The Last Airbender" dated 2026-10-09: the
    /// upcoming animated *movie*. Announcing that as "New episode Oct 9" tells
    /// someone their favourite show is coming back when it isn't.
    ///
    /// A special also has no place to go: the rail lays entries out inside a
    /// numbered season, and season 0 isn't one the viewer is browsing.
    ///
    /// An entry with no season at all is kept — AniList numbers absolutely and
    /// reports no season, and that path has its own placement rules.
    public static func isRegularEpisode(seasonNumber: Int?) -> Bool {
        guard let seasonNumber else { return true }
        return seasonNumber > 0
    }
}
