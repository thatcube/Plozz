import Foundation
import CoreModels

/// A titled group of search results (e.g. "Movies", "TV Shows", "Episodes"),
/// rendered as one section of the results grid.
public struct SearchSection: Identifiable, Equatable, Sendable {
    public var id: String { title }
    public let title: String
    public let items: [MediaItem]

    public init(title: String, items: [MediaItem]) {
        self.title = title
        self.items = items
    }

    /// Groups a flat result list into stably-ordered sections by kind, dropping
    /// empty groups. Order mirrors the search query's `IncludeItemTypes`
    /// (movies, then series, then episodes), with any other kinds last.
    public static func sections(from items: [MediaItem]) -> [SearchSection] {
        let groups: [(title: String, kinds: Set<MediaItemKind>)] = [
            ("Movies", [.movie]),
            ("TV Shows", [.series]),
            ("Episodes", [.episode]),
            ("Other", [.season, .video, .folder, .collection, .unknown])
        ]
        return groups.compactMap { group in
            let matching = items.filter { group.kinds.contains($0.kind) }
            return matching.isEmpty ? nil : SearchSection(title: group.title, items: matching)
        }
    }

    /// The title of the discovery ("not in your library") section, appended after
    /// the library sections when Seerr is connected and returns requestable hits.
    public static let notInLibraryTitle = "Not in Your Library"

    /// Compact Search-only cue for a playable series whose Seerr match says only
    /// part of the show is available. Ordinary library cards have no availability,
    /// and fully absent discovery cards remain in "Not in Your Library".
    public static func availabilityCue(for item: MediaItem) -> String? {
        guard item.kind == .series, item.availability == .partiallyAvailable else { return nil }
        return "More Seasons"
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
        return capped.isEmpty ? nil : SearchSection(title: notInLibraryTitle, items: capped)
    }
}
