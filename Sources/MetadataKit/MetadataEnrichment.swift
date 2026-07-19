import Foundation
import CoreModels

/// The accumulated, provenance-carrying result of running an item through the
/// ``MetadataEnrichmentPipeline``.
///
/// Every value is a ``SourcedValue`` so the exact provider that supplied it is
/// retained for the Step 2/3 provenance + sourced-field priority path — the pipeline
/// never launders attribution. Artwork the pipeline may need for two different
/// screens (home hero vs detail backdrop) is kept as an **ordered candidate set**
/// (``backdropCandidates``) so a single provider response serves both without a
/// second search.
public struct MetadataEnrichment: Sendable, Equatable {
    /// Strong external ids keyed by canonical namespace (`Imdb`, `Tvdb`, `Tmdb`,
    /// `AniList`, `Mal`, …), each with the source that resolved it.
    public var externalIDs: [String: SourcedValue<String>]
    public var title: SourcedValue<String>?
    public var overview: SourcedValue<String>?
    public var genres: SourcedValue<[String]>?
    public var tagline: SourcedValue<String>?
    public var posterURL: SourcedValue<URL>?
    public var logoURL: SourcedValue<URL>?
    public var episodeStillURL: SourcedValue<URL>?
    public var bannerURL: SourcedValue<URL>?
    public var score: SourcedValue<Double>?
    /// Ordered wide-backdrop candidates, best first. Retained as a set (not one URL)
    /// so both ``homeHero`` and ``detailBackdrop`` can be served from one response.
    public var backdropCandidates: [SourcedValue<URL>]

    public init(
        externalIDs: [String: SourcedValue<String>] = [:],
        title: SourcedValue<String>? = nil,
        overview: SourcedValue<String>? = nil,
        genres: SourcedValue<[String]>? = nil,
        tagline: SourcedValue<String>? = nil,
        posterURL: SourcedValue<URL>? = nil,
        logoURL: SourcedValue<URL>? = nil,
        episodeStillURL: SourcedValue<URL>? = nil,
        bannerURL: SourcedValue<URL>? = nil,
        score: SourcedValue<Double>? = nil,
        backdropCandidates: [SourcedValue<URL>] = []
    ) {
        self.externalIDs = externalIDs
        self.title = title
        self.overview = overview
        self.genres = genres
        self.tagline = tagline
        self.posterURL = posterURL
        self.logoURL = logoURL
        self.episodeStillURL = episodeStillURL
        self.bannerURL = bannerURL
        self.score = score
        self.backdropCandidates = backdropCandidates
    }

    public var isEmpty: Bool {
        externalIDs.isEmpty && title == nil && overview == nil && genres == nil
            && tagline == nil && posterURL == nil && logoURL == nil
            && episodeStillURL == nil && bannerURL == nil && score == nil
            && backdropCandidates.isEmpty
    }

    /// The best backdrop for the full-bleed home hero (the top-ranked candidate).
    public var homeHero: SourcedValue<URL>? { backdropCandidates.first }

    /// The backdrop for the detail page. Prefers a *second, distinct* candidate so
    /// the two screens don't show the identical image when more than one exists;
    /// falls back to the top candidate when only one is available.
    public var detailBackdrop: SourcedValue<URL>? {
        backdropCandidates.count >= 2 ? backdropCandidates[1] : backdropCandidates.first
    }

    /// Every ``MetadataField`` this enrichment currently supplies. Drives the
    /// pipeline's "stop once all requested fields are filled" decision.
    public var filledFields: Set<MetadataField> {
        var fields: Set<MetadataField> = []
        for key in externalIDs.keys { fields.insert(.providerID(key)) }
        if title != nil { fields.insert(.title) }
        if overview != nil { fields.insert(.overview) }
        if genres != nil { fields.insert(.genres) }
        if tagline != nil { fields.insert(.taglines) }
        if posterURL != nil { fields.insert(.posterURL) }
        if logoURL != nil { fields.insert(.logoURL) }
        if episodeStillURL != nil { fields.insert(.episodeThumbnail) }
        if !backdropCandidates.isEmpty {
            fields.formUnion([.backdropURL, .homeHero, .detailBackdrop])
        }
        return fields
    }

    /// Folds newly-resolved values from `other` into this accumulator, **filling
    /// only fields that are still empty** and are not in `present` (values the
    /// caller already knows from a higher-priority local/server source). Because the
    /// pipeline visits providers in configured priority order, the first provider to
    /// supply a field wins — so this is a monotonic, priority-respecting merge that
    /// never demotes an earlier, higher-priority value.
    public mutating func fillMissing(
        from other: MetadataEnrichment,
        skipping present: Set<MetadataField> = []
    ) {
        for (key, value) in other.externalIDs {
            let field = MetadataField.providerID(key)
            guard !present.contains(field), externalIDs[key] == nil else { continue }
            externalIDs[key] = value
        }
        fill(&title, from: other.title, field: .title, present: present)
        fill(&overview, from: other.overview, field: .overview, present: present)
        fill(&genres, from: other.genres, field: .genres, present: present)
        fill(&tagline, from: other.tagline, field: .taglines, present: present)
        fill(&posterURL, from: other.posterURL, field: .posterURL, present: present)
        fill(&logoURL, from: other.logoURL, field: .logoURL, present: present)
        fill(&episodeStillURL, from: other.episodeStillURL, field: .episodeThumbnail, present: present)
        // Banner and score have no dedicated MetadataField (bonus art/metadata);
        // still first-writer-wins, and never blocked by `present`.
        if bannerURL == nil { bannerURL = other.bannerURL }
        if score == nil { score = other.score }
        // Keep the first non-empty candidate set (one response serves both screens),
        // unless the caller already has a backdrop from a higher-priority source.
        if backdropCandidates.isEmpty,
           !present.contains(.backdropURL),
           !other.backdropCandidates.isEmpty {
            backdropCandidates = other.backdropCandidates
        }
    }

    private func fill<Value>(
        _ slot: inout SourcedValue<Value>?,
        from incoming: SourcedValue<Value>?,
        field: MetadataField,
        present: Set<MetadataField>
    ) {
        guard slot == nil, !present.contains(field), let incoming else { return }
        slot = incoming
    }
}
