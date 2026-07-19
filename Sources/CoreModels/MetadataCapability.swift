import Foundation

/// A coarse, open grouping of what an external metadata provider can supply.
///
/// Where ``MetadataField`` names an individual value (poster URL, overview text,
/// one provider id), a capability names the *class* of work a provider advertises.
/// The enrichment pipeline uses it as a cheap pre-filter: it only calls a provider
/// when the provider's declared ``MetadataEnrichmentProvider/capabilities`` overlap
/// the capabilities that could fill the fields still missing for an item. That keeps
/// a provider that has no chance of helping (e.g. a poster-only source asked for a
/// tagline) entirely off the request path.
///
/// A raw-string value (not an enum) so a newer build can introduce a capability
/// without breaking decoding in an older one — matching ``MetadataSource`` and
/// ``MetadataField``.
public struct MetadataCapability: RawRepresentable, Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    /// Strong external identifiers (IMDb / TVDB / TMDb / AniList / MAL …). Any
    /// dynamic `providerID.<namespace>` field maps here.
    public static let externalIDs = Self(rawValue: "externalIDs")
    /// Canonical descriptive text and facts: title, overview, genres, studios,
    /// runtime, air/premiere dates, season/episode numbers.
    public static let canonicalText = Self(rawValue: "canonicalText")
    /// A vertical key-art poster (~2:3).
    public static let poster = Self(rawValue: "poster")
    /// A wide backdrop (16:9 / banner) used behind the home and detail heroes.
    public static let backdrop = Self(rawValue: "backdrop")
    /// A transparent title / clear-logo PNG.
    public static let logo = Self(rawValue: "logo")
    /// A single 16:9 still for one episode.
    public static let episodeStill = Self(rawValue: "episodeStill")
    /// A short tagline / catchphrase.
    public static let tagline = Self(rawValue: "tagline")
    /// A numeric community/critic score (e.g. AniList mean score).
    public static let score = Self(rawValue: "score")
    /// A wide banner image (distinct from a hero backdrop; e.g. AniList banner).
    public static let banner = Self(rawValue: "banner")
    /// Structured external ratings (IMDb / RT / TMDb …).
    public static let ratings = Self(rawValue: "ratings")
    /// A series-level upcoming-episode schedule (next known air date + numbering).
    /// Supplied by the free schedule providers (AniList / TVmaze / TheTVDB) and used
    /// by the Step 8 "Airing Soon" / missing-episode features — not a per-item field
    /// written back onto a ``MediaItem``.
    public static let nextAiringEpisode = Self(rawValue: "nextAiringEpisode")
}

public extension MetadataCapability {
    /// The single capability able to supply `field`, or `nil` when no external
    /// provider capability covers it (e.g. a scan-owned field). Any dynamic
    /// `providerID.<namespace>` field resolves to ``externalIDs``.
    static func covering(_ field: MetadataField) -> MetadataCapability? {
        if let mapped = fieldCapabilities[field] { return mapped }
        if field.rawValue.hasPrefix("providerID.") { return .externalIDs }
        return nil
    }

    /// The fields a provider with this capability is allowed to fill. Used by the
    /// pipeline to expand a requested field set into the capabilities it needs, and
    /// by tests. `externalIDs` covers a dynamic namespace set, so it is not listed
    /// here (matched by prefix in ``covering(_:)``).
    var coveredFields: Set<MetadataField> {
        Set(Self.fieldCapabilities.compactMap { $0.value == self ? $0.key : nil })
    }

    /// The static field → capability table (dynamic `providerID.*` handled by
    /// prefix in ``covering(_:)``).
    private static let fieldCapabilities: [MetadataField: MetadataCapability] = [
        .title: .canonicalText,
        .originalTitle: .canonicalText,
        .sortTitle: .canonicalText,
        .overview: .canonicalText,
        .genres: .canonicalText,
        .studios: .canonicalText,
        .tags: .canonicalText,
        .runtime: .canonicalText,
        .productionYear: .canonicalText,
        .premiereDate: .canonicalText,
        .airDate: .canonicalText,
        .seasonNumber: .canonicalText,
        .episodeNumber: .canonicalText,
        .taglines: .tagline,
        .posterURL: .poster,
        .backdropURL: .backdrop,
        .homeHero: .backdrop,
        .detailBackdrop: .backdrop,
        .logoURL: .logo,
        .episodeThumbnail: .episodeStill,
        .ratings: .ratings,
        .nextAiringEpisode: .nextAiringEpisode,
    ]
}
