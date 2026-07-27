import Foundation
import CoreModels

/// A titled group of search results (e.g. "Movies", "TV Shows", "Episodes"),
/// rendered as one section of the results grid.
public struct SearchSection: Identifiable, Equatable, Sendable {
    /// What a section *is*, independent of what it is called.
    ///
    /// Identity deliberately does NOT come from the displayed title. The title is
    /// localized, so keying `id` off it would change a section's SwiftUI identity
    /// the moment the user switches language — tearing down and rebuilding the
    /// grid, and dropping tvOS focus in the process. `Kind` is also what lets the
    /// view model rebuild a section (watched-state flips, availability
    /// enrichment) without round-tripping through display text.
    public enum Kind: String, Hashable, Sendable, CaseIterable {
        case movies
        case tvShows
        case episodes
        case other
        case notInLibrary

        /// The section header shown to the user.
        ///
        /// These carry semantic keys rather than natural-language ones because
        /// "Movies"/"Episodes" are short nouns that recur elsewhere in the app
        /// with different senses (a library type, a filter, a media kind), and a
        /// section header is exactly the kind of string a translator needs
        /// disambiguated. Everything here is a static literal, so the compiler
        /// still extracts key, default value and comment automatically.
        public var title: LocalizedStringResource {
            switch self {
            case .movies:
                return LocalizedStringResource(
                    "search.section.movies",
                    defaultValue: "Movies",
                    comment: "Header for the search-results section listing movies."
                )
            case .tvShows:
                return LocalizedStringResource(
                    "search.section.tvShows",
                    defaultValue: "TV Shows",
                    comment: "Header for the search-results section listing TV series."
                )
            case .episodes:
                return LocalizedStringResource(
                    "search.section.episodes",
                    defaultValue: "Episodes",
                    comment: "Header for the search-results section listing individual episodes."
                )
            case .other:
                return LocalizedStringResource(
                    "search.section.other",
                    defaultValue: "Other",
                    comment: "Header for the search-results section collecting result types with no section of their own: seasons, videos, folders, collections."
                )
            case .notInLibrary:
                return LocalizedStringResource(
                    "search.section.notInLibrary",
                    defaultValue: "Not in Your Library",
                    comment: "Header for the search-results section listing titles the user does not have, which can be requested via Seerr."
                )
            }
        }
    }

    public var id: Kind { kind }
    public let kind: Kind
    public let items: [MediaItem]

    /// The localized section header. Derived from `kind`, never stored, so it can
    /// never disagree with identity or go stale after a language change.
    public var title: LocalizedStringResource { kind.title }

    public init(kind: Kind, items: [MediaItem]) {
        self.kind = kind
        self.items = items
    }

    /// Groups a flat result list into stably-ordered sections by kind, dropping
    /// empty groups. Order mirrors the search query's `IncludeItemTypes`
    /// (movies, then series, then episodes), with any other kinds last.
    public static func sections(from items: [MediaItem]) -> [SearchSection] {
        let groups: [(kind: Kind, mediaKinds: Set<MediaItemKind>)] = [
            (.movies, [.movie]),
            (.tvShows, [.series]),
            (.episodes, [.episode]),
            (.other, [.season, .video, .folder, .collection, .unknown])
        ]
        return groups.compactMap { group in
            let matching = items.filter { group.mediaKinds.contains($0.kind) }
            return matching.isEmpty ? nil : SearchSection(kind: group.kind, items: matching)
        }
    }

    /// Compact Search-only cue for a playable series whose Seerr match says only
    /// part of the show is available. Ordinary library cards have no availability,
    /// and fully absent discovery cards remain in "Not in Your Library".
    public static func availabilityCue(for item: MediaItem) -> LocalizedStringResource? {
        guard item.kind == .series, item.availability == .partiallyAvailable else { return nil }
        return LocalizedStringResource(
            "search.cue.moreSeasons",
            defaultValue: "More Seasons",
            comment: "Badge on a search result for a show only partly in the user's library, meaning more seasons can be requested."
        )
    }

    /// Transfers Seerr's partial-series state onto the matching playable library
    /// item without changing its provider id, sources, ordering, or navigation.
    /// The discovery duplicate is still filtered from "Not in Your Library".
    public static func mergingDiscoveryAvailability(
        into libraryResults: [MediaItem],
        discoveryResults: [MediaItem],
        requestableSeriesTmdbIDs: Set<String>
    ) -> [MediaItem] {
        let partialSeriesTmdbIDs = Set(discoveryResults.compactMap { item -> String? in
            guard item.kind == .series, item.availability == .partiallyAvailable else { return nil }
            guard let tmdbID = item.providerIDs["Tmdb"],
                  requestableSeriesTmdbIDs.contains(tmdbID) else { return nil }
            return tmdbID
        })
        guard !partialSeriesTmdbIDs.isEmpty else { return libraryResults }
        return libraryResults.map { item in
            guard item.kind == .series,
                  let tmdbID = item.providerIDs["Tmdb"],
                  partialSeriesTmdbIDs.contains(tmdbID)
            else { return item }
            var updated = item
            updated.availability = .partiallyAvailable
            return updated
        }
    }

    /// Builds the "Not in Your Library" section from Seerr discovery results,
    /// filtering out anything that is really in the user's library:
    ///
    /// - titles Seerr reports as already `available`/`partiallyAvailable`, and
    /// - titles whose TMDB id matches one already returned by the library search
    ///   (so a movie found on Jellyfin/Plex is never also listed as "not in your
    ///   library" just because Seerr surfaced it too).
    ///
    /// Preserves Seerr's relevance order and caps to `limit` (0 = uncapped).
    /// Returns `nil` when nothing requestable remains, so the caller simply omits
    /// the section.
    public static func notInLibrarySection(
        discoveryResults: [MediaItem],
        libraryResults: [MediaItem],
        limit: Int = 0
    ) -> SearchSection? {
        let libraryTmdbIDs = Set(libraryResults.compactMap { $0.providerIDs["Tmdb"] })
        let filtered = discoveryResults.filter { item in
            switch item.availability {
            case .available, .partiallyAvailable:
                return false // already fully/partly in the library
            default:
                break
            }
            if let tmdb = item.providerIDs["Tmdb"], libraryTmdbIDs.contains(tmdb) {
                return false // the library search already surfaced this title
            }
            return true
        }
        let capped = limit > 0 ? Array(filtered.prefix(limit)) : filtered
        return capped.isEmpty ? nil : SearchSection(kind: .notInLibrary, items: capped)
    }
}
