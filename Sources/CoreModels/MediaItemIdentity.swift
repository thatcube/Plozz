import Foundation

/// A stable, provider-agnostic identity for a media item, used to recognise when
/// the *same* title shows up on more than one server (e.g. a movie that lives on
/// both a Jellyfin and a Plex account).
///
/// Two flavours, in priority order:
/// - `.external` — a shared strong external id (IMDb, TMDb, TVDb). The most
///   reliable signal because both servers reference the same catalogue entry.
/// - `.title` — the normalized title + release year + media kind, the fallback
///   used only when no external id is present (and only for movies — see the
///   safety rules on ``MediaItemIdentity/identities(for:)``).
///
/// This was lifted out of `FeatureSearch.SearchDeduplicator` so that Home, Search
/// and any future surface share **one** well-tested identity definition instead
/// of duplicating the rules (and their subtle safety carve-outs).
public enum MediaIdentity: Hashable, Sendable, Codable {
    case external(source: String, value: String)
    case title(normalizedTitle: String, year: Int?, kind: MediaItemKind)
}

/// Pure, provider-agnostic identity resolution shared by every cross-server
/// surface (Home rows, aggregated Library browse, Search).
///
/// The rules here are deliberately conservative — collapsing two genuinely
/// different titles into one card is a far worse failure than missing a merge —
/// so the safety carve-outs are encoded once, here, and exhaustively tested.
public enum MediaItemIdentity {
    /// External id namespaces that uniquely identify a catalogue entry across
    /// providers, in match-priority order. Lower-cased for case-insensitive
    /// comparison against `MediaItem.providerIDs` keys.
    public static let strongExternalSources = ["imdb", "tmdb", "tvdb"]

    /// The candidate identities for an item, strongest first. Two items are the
    /// same title when *any* of their identities match.
    ///
    /// ## Safety rules (do not relax without new tests)
    /// 1. **External ids win and suppress the title key.** An item with a
    ///    TMDb/IMDb/TVDb id has a well-defined catalogue identity; adding a title
    ///    key on top risks bridging two completely different shows that merely
    ///    share a name/year via a false transitive merge (anime vs live-action
    ///    remake with bad year metadata).
    /// 2. **Title identity is movies-only.** Two films with the same title and
    ///    year are almost certainly the same release; two *series* with the same
    ///    name routinely are not (original vs reboot, anime vs live-action), and
    ///    a wrong year on one server would silently collapse them. Series must
    ///    rely on external ids alone.
    public static func identities(for item: MediaItem) -> [MediaIdentity] {
        var result: [MediaIdentity] = []

        let normalizedIDs = Dictionary(
            item.providerIDs.compactMap { key, value -> (String, String)? in
                let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : (key.lowercased(), trimmed.lowercased())
            },
            uniquingKeysWith: { first, _ in first }
        )
        for source in strongExternalSources {
            if let value = normalizedIDs[source] {
                result.append(.external(source: source, value: value))
            }
        }

        if result.isEmpty, let titleIdentity = titleIdentity(for: item) {
            result.append(titleIdentity)
        }
        return result
    }

    private static func titleIdentity(for item: MediaItem) -> MediaIdentity? {
        guard item.kind == .movie else { return nil }
        guard let year = item.productionYear else { return nil }
        let normalized = normalizedTitle(item.title)
        guard !normalized.isEmpty else { return nil }
        return .title(normalizedTitle: normalized, year: year, kind: item.kind)
    }

    /// Canonical title form: lower-cased, accent-folded, punctuation removed and
    /// internal whitespace collapsed so "Spider-Man" and "spider man" match.
    public static func normalizedTitle(_ raw: String) -> String {
        let folded = raw.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        let stripped = folded.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) ? Character(scalar) : " "
        }
        return String(stripped)
            .split(separator: " ", omittingEmptySubsequences: true)
            .joined(separator: " ")
    }
}
