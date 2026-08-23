import CoreModels
import Foundation

/// Decides whether a fuzzy title-search hit is actually the title that was asked
/// for.
///
/// AniList and Kitsu are the two providers with no id to look a title up by: when
/// an item carries no AniList/MAL id, the only question they can be asked is a
/// free-text one, and **both of them always answer**. Kitsu's `filter[text]` is a
/// relevance search over its whole catalogue, so a title it has never heard of
/// still comes back with its closest guess — and taking that guess unverified put
/// *Dragon Goes House-Hunting*'s poster on House of the Dragon, under the correct
/// title and year, with nothing on screen saying it was a guess.
///
/// This is the rule the rest of the app already applies to search hits — see
/// ``RelatedTitleMatcher`` ("a title-only agreement is discarded, even when it
/// looks obviously right"), `TMDbMetadataProvider.bestMatch` and
/// `TVDBClient.titleResembles`. The anime providers were simply never given it.
///
/// Matching is deliberately generous about *which* title agrees, because anime is
/// catalogued under several at once: a library's English name has to be allowed to
/// meet a romaji canonical title, a native title, or a listed synonym. It is not
/// generous about *whether* one agrees — nothing matching means nothing is
/// returned, and the chain falls through to the next source.
enum AnimeTitleMatch {
    /// How well a candidate's names agree with the ones asked for.
    enum Confidence: Comparable {
        /// One side carries whole extra trailing words ("Attack on Titan Season 3"
        /// against "Attack on Titan"). Real, but beaten by an exact agreement.
        case compatible
        /// The normalized titles are the same string.
        case exact
    }

    /// Whether any of `candidateTitles` names the title `query` asked about.
    static func names(_ query: MetadataQuery, among candidateTitles: [String?]) -> Bool {
        confidence(query, among: candidateTitles) != nil
    }

    /// Whether any candidate title agrees with any of the titles we asked under.
    static func names(
        _ candidateTitles: [String?],  // l10n:content — provider-supplied media titles compared as lookup keys
        whenAskedFor wanted: [String]  // l10n:content — media titles used as external-provider lookup keys
    ) -> Bool {
        confidence(candidateTitles, whenAskedFor: wanted) != nil
    }

    static func confidence(
        _ query: MetadataQuery,
        among candidateTitles: [String?]
    ) -> Confidence? {
        confidence(candidateTitles, whenAskedFor: query.searchTitles)
    }

    /// The strongest agreement between anything the provider listed and anything
    /// we asked under, or `nil` when nothing agrees.
    ///
    /// Comparison runs through ``MediaItemIdentity/normalizedTitle(_:)`` (case,
    /// accents and punctuation folded) and then the app's existing
    /// ``MediaItemIdentity/normalizedTitlesCompatible(_:_:)`` rule, which lets one
    /// side carry whole extra trailing words. That tolerance is what a season or
    /// part suffix needs — a library's "Attack on Titan Season 3" is still the
    /// catalogue's "Attack on Titan" — while an unrelated work sharing a couple of
    /// words is rejected outright.
    static func confidence(
        _ candidateTitles: [String?],  // l10n:content — provider-supplied media titles compared as lookup keys
        whenAskedFor wanted: [String]  // l10n:content — media titles used as external-provider lookup keys
    ) -> Confidence? {
        let wanted = wanted.map(MediaItemIdentity.normalizedTitle).filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return nil }
        let candidates = candidateTitles
            .compactMap { $0 }
            .map(MediaItemIdentity.normalizedTitle)
            .filter { !$0.isEmpty }
        guard !candidates.isEmpty else { return nil }
        var best: Confidence?
        for candidate in candidates {
            for wanted in wanted {
                if candidate == wanted { return .exact }
                if MediaItemIdentity.normalizedTitlesCompatible(candidate, wanted) {
                    best = .compatible
                }
            }
        }
        return best
    }
}

extension MetadataQuery {
    /// Every title this query may legitimately be known by: the one being searched
    /// under, plus the alternates a caller offered precisely so a differently-named
    /// catalogue can still be matched.
    var searchTitles: [String] {  // l10n:content — media titles used as external-provider lookup keys
        ([title, alternateTitle].compactMap { $0 } + titleAlternates)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}
