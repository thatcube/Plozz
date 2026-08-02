import Foundation

/// A title related to another — a recommendation, or a direct continuation like a
/// sequel or spin-off.
///
/// Carries external ids rather than a library item id, because a related title is
/// resolved from a metadata provider that knows nothing about anyone's library.
/// Binding it to something the viewer owns is a separate, id-verified step (see
/// `RelatedTitleMatcher`): a title match alone is how a 2022 documentary ends up on
/// a 2026 drama's page.
public struct RelatedTitle: Codable, Sendable, Equatable, Identifiable, Hashable {
    /// Why this title is related, which decides how it's presented and ordered.
    public enum Relation: String, Codable, Sendable, Equatable, Hashable {
        /// A direct continuation of the same story: sequel, prequel, or a season
        /// released as its own series (Avatar → Seven Havens).
        case continuation
        /// A side story, spin-off, or alternate telling of the same material.
        case sideStory
        /// "If you liked this…" — similar in tone or subject, unrelated in story.
        case recommendation
    }

    public let title: String
    public let year: Int?
    public let kind: MediaItemKind
    public let relation: Relation
    /// External ids (`Tmdb`, `Imdb`, `Tvdb`, `AniList`, `Mal`) in the app's usual
    /// namespace spellings, so they can be compared against a library item's own.
    public let providerIDs: [String: String]
    /// Provider-supplied poster, used only until a library match supplies the
    /// viewer's own artwork.
    public let posterURL: URL?
    public let source: MetadataSource

    public init(
        title: String,
        year: Int? = nil,
        kind: MediaItemKind,
        relation: Relation = .recommendation,
        providerIDs: [String: String] = [:],
        posterURL: URL? = nil,
        source: MetadataSource
    ) {
        self.title = title
        self.year = year
        self.kind = kind
        self.relation = relation
        self.providerIDs = providerIDs
        self.posterURL = posterURL
        self.source = source
    }

    /// Stable across providers where ids allow, so the same title resolved by two
    /// providers de-duplicates instead of appearing twice.
    public var id: String {
        for namespace in [ProviderIDNamespace.tmdb, .imdb, .tvdb, .aniList, .myAnimeList] {
            if let value = providerIDs.providerID(namespace) {
                return "\(kind.rawValue):\(namespace.canonicalKey.lowercased()):\(value)"
            }
        }
        return "\(kind.rawValue):title:\(title.lowercased()):\(year.map(String.init) ?? "?")"
    }

    /// Whether this is a continuation of the seed's own story rather than merely
    /// something similar. Continuations lead the row: someone looking at a show
    /// they love wants to know there's more of it before they want a lookalike.
    public var isContinuation: Bool {
        relation == .continuation || relation == .sideStory
    }
}

extension RelatedTitle: TitleDedupeSubject {
    public var dedupeKind: MediaItemKind { kind }
    public var dedupeTitle: String { title }
    public var dedupeYear: Int? { year }
    public var dedupeProviderIDs: [String: String] { providerIDs }
    public var dedupeFallbackID: String { id }

    /// Cross-provider results describe one work under disjoint id sets, so the fold
    /// keeps the union — that union is what later lets the row recognise a copy the
    /// viewer owns. The first member keeps title, kind and position; a year or
    /// poster it lacks comes from whichever sibling has one.
    public static func collapsingDedupeGroup(_ group: [RelatedTitle]) -> RelatedTitle {
        let first = group[0]
        var providerIDs = first.providerIDs
        for title in group.dropFirst() {
            for (key, value) in title.providerIDs where providerIDs[key] == nil {
                providerIDs[key] = value
            }
        }
        // The strongest claim in the group: a continuation outranks a side story,
        // which outranks a recommendation. Being described as "related" by one
        // source and "the sequel" by another means it is the sequel.
        let relation = group.map(\.relation).min {
            $0.relatedStrengthRank < $1.relatedStrengthRank
        } ?? first.relation
        return RelatedTitle(
            title: first.title,
            year: first.year ?? group.lazy.compactMap(\.year).first,
            kind: first.kind,
            relation: relation,
            providerIDs: providerIDs,
            posterURL: first.posterURL ?? group.lazy.compactMap(\.posterURL).first,
            source: first.source
        )
    }
}

public extension RelatedTitle.Relation {
    /// Lower is a stronger statement about how two titles relate.
    var relatedStrengthRank: Int {
        switch self {
        case .continuation: return 0
        case .sideStory: return 1
        case .recommendation: return 2
        }
    }
}
