import Foundation
import SQLite3
import CoreModels
import MetadataKit

/// Pure row/candidate → `MediaItem` mapping and metadata-overlay policy for the
/// share catalog read path. It holds NO SQLite handle, transport, network,
/// scheduler, or global state: the store owns the connection and executes the
/// queries, then hands typed rows/records here for projection. Keeping these
/// mappers pure means the winner-priority table (localNFO > filename > external >
/// legacy), rating projection, and display-title upgrade rules live in one
/// directly-testable place rather than being diffused across the store actor.
enum ShareCatalogReadProjection {
    /// A single persisted local (`localNFO`/`filename`) field candidate for an item.
    /// The store queries these rows; projection applies them.
    struct LocalFieldRow {
        var source: MetadataSource
        var valueJSON: String
    }

    /// Whether a persisted `metadata_values` row's JSON payload still equals the
    /// value the flat enrichment record projects for `field` — the flat row stays
    /// authoritative, so a stale/malformed normalized value is ignored and receives
    /// legacy attribution instead of overriding the projection.
    static func metadataValueMatches(
        field: MetadataField,
        valueJSON: String,
        record: EnrichmentRecord
    ) -> Bool {
        switch field {
        case .title:
            return CatalogJSON.decode(String.self, valueJSON) == record.title
        case .overview:
            return CatalogJSON.decode(String.self, valueJSON) == record.overview
        case .genres:
            return CatalogJSON.decode([String].self, valueJSON) == record.genres
        case .runtime:
            return CatalogJSON.decode(TimeInterval.self, valueJSON) == record.runtime
        case .posterURL:
            return CatalogJSON.decode(URL.self, valueJSON) == record.posterURL
        case .backdropURL:
            return CatalogJSON.decode(URL.self, valueJSON) == record.backdropURL
        case .logoURL:
            return CatalogJSON.decode(URL.self, valueJSON) == record.logoURL
        default:
            let prefix = "providerID."
            guard field.rawValue.hasPrefix(prefix) else { return false }
            let namespace = String(field.rawValue.dropFirst(prefix.count))
            guard let value = record.providerIDs.first(where: {
                $0.key.lowercased() == namespace
            })?.value else { return false }
            return CatalogJSON.decode(String.self, valueJSON) == value
        }
    }

    /// Decode the enrichment columns (provider_ids_json, overview, genres_json,
    /// runtime, poster_url, backdrop_url, logo_url, title) starting at `startingAt`
    /// into a record. Shared by the standalone `enrichmentRow` lookup and the JOINed
    /// grid queries (movies/series), so a page fetch reads enrichment in ONE query
    /// instead of N+1 per-row lookups. Returns nil when the core columns are all NULL
    /// (no enrichment row matched the LEFT JOIN); `title` is a supplementary 8th
    /// column not counted in that emptiness check.
    static func enrichmentRecord(fromColumns stmt: OpaquePointer?, startingAt base: Int32) -> EnrichmentRecord? {
        let allNull = (0..<7).allSatisfy { sqlite3_column_type(stmt, base + $0) == SQLITE_NULL }
        if allNull { return nil }
        var rec = EnrichmentRecord()
        rec.providerIDs = CatalogJSON.decode([String: String].self, CatalogConnection.columnText(stmt, base + 0)) ?? [:]
        rec.overview = CatalogConnection.columnText(stmt, base + 1)
        rec.genres = CatalogJSON.decode([String].self, CatalogConnection.columnText(stmt, base + 2)) ?? []
        if sqlite3_column_type(stmt, base + 3) != SQLITE_NULL { rec.runtime = sqlite3_column_double(stmt, base + 3) }
        rec.posterURL = CatalogConnection.columnText(stmt, base + 4).flatMap(URL.init(string:))
        rec.backdropURL = CatalogConnection.columnText(stmt, base + 5).flatMap(URL.init(string:))
        rec.logoURL = CatalogConnection.columnText(stmt, base + 6).flatMap(URL.init(string:))
        rec.title = CatalogConnection.columnText(stmt, base + 7)
        return rec
    }

    /// Recognized rating-source aliases mapped onto `RatingSource` for the
    /// `MediaItem.ratings` projection. Unrecognized sources stay losslessly in
    /// the persisted `metadata_values` payload but don't project here.
    static func recognizedRatingSource(_ raw: String) -> RatingSource? {
        switch raw.lowercased() {
        case "imdb": return .imdb
        case "tmdb", "themoviedb": return .tmdb
        default: return nil
        }
    }

    static func ratingScale(forMax max: Double) -> RatingScale {
        if abs(max - 100) < 0.001 { return .outOfHundred }
        if abs(max - 5) < 0.001 { return .outOfFive }
        return .outOfTen
    }

    /// Overlay persisted LOCAL (`localNFO`/`filename`) metadata onto an item —
    /// taking priority over any external/legacy value `applyEnrichment` already
    /// applied (NFO wins over a conflicting filename/folder tag, which in turn wins
    /// over external — the Step 3 source-priority table). `sourceURL` is always nil
    /// for these sources — the local-provenance-privacy invariant.
    static func applyLocalMetadata(_ item: MediaItem, _ fields: [MetadataField: LocalFieldRow]) -> MediaItem {
        var copy = item
        func attribution(for field: MetadataField) -> MetadataAttribution? {
            fields[field].map { MetadataAttribution(source: $0.source, sourceURL: nil) }
        }
        if let row = fields[.title], let value = CatalogJSON.decode(String.self, row.valueJSON), !value.isEmpty {
            copy.title = value
            copy.metadataProvenance[.title] = attribution(for: .title)
        }
        if let row = fields[.originalTitle], let value = CatalogJSON.decode(String.self, row.valueJSON), !value.isEmpty {
            copy.originalTitle = value
            copy.metadataProvenance[.originalTitle] = attribution(for: .originalTitle)
        }
        if let row = fields[.overview], let value = CatalogJSON.decode(String.self, row.valueJSON), !value.isEmpty {
            copy.overview = value
            copy.metadataProvenance[.overview] = attribution(for: .overview)
        }
        if let row = fields[.genres], let value = CatalogJSON.decode([String].self, row.valueJSON), !value.isEmpty {
            copy.genres = value
            copy.metadataProvenance[.genres] = attribution(for: .genres)
        }
        if let row = fields[.studios], let value = CatalogJSON.decode([String].self, row.valueJSON), !value.isEmpty {
            copy.studios = value
            copy.metadataProvenance[.studios] = attribution(for: .studios)
        }
        if let row = fields[.tags], let value = CatalogJSON.decode([String].self, row.valueJSON), !value.isEmpty {
            copy.tags = value
            copy.metadataProvenance[.tags] = attribution(for: .tags)
        }
        if let row = fields[.runtime], let value = CatalogJSON.decode(TimeInterval.self, row.valueJSON), value > 0 {
            copy.runtime = value
            copy.metadataProvenance[.runtime] = attribution(for: .runtime)
        }
        if let row = fields[.productionYear], let value = CatalogJSON.decode(Int.self, row.valueJSON) {
            copy.productionYear = value
            copy.metadataProvenance[.productionYear] = attribution(for: .productionYear)
        }
        // seasonNumber/episodeNumber are EPISODE-only (C1, final projection boundary):
        // even if a stray value reached persistence, never overlay it onto a
        // non-episode item.
        if item.kind == .episode {
            if let row = fields[.seasonNumber], let value = CatalogJSON.decode(Int.self, row.valueJSON) {
                copy.seasonNumber = value
                copy.metadataProvenance[.seasonNumber] = attribution(for: .seasonNumber)
            }
            if let row = fields[.episodeNumber], let value = CatalogJSON.decode(Int.self, row.valueJSON) {
                copy.episodeNumber = value
                copy.metadataProvenance[.episodeNumber] = attribution(for: .episodeNumber)
            }
        }
        if let row = fields[.ratings], let value = CatalogJSON.decode([ParsedNFORating].self, row.valueJSON), !value.isEmpty {
            let recognized: [ExternalRating] = value.compactMap { rating in
                guard let source = recognizedRatingSource(rating.source), rating.max > 0 else { return nil }
                return ExternalRating(source: source, value: rating.value, scale: ratingScale(forMax: rating.max))
            }
            if !recognized.isEmpty {
                copy.ratings = copy.ratings.mergedWithAuthoritative(recognized)
                copy.metadataProvenance[.ratings] = attribution(for: .ratings)
            }
        }
        // Provider ids: local wins per-namespace over whatever's already present.
        for (field, row) in fields where field.rawValue.hasPrefix("providerID.") {
            guard let value = CatalogJSON.decode(String.self, row.valueJSON), !value.isEmpty else { continue }
            let namespace = String(field.rawValue.dropFirst("providerID.".count))
            copy.providerIDs = copy.providerIDs.filter {
                ShareExplicitIDPolicy.canonicalNamespace($0.key) != namespace
            }
            copy.providerIDs[ShareExplicitIDPolicy.projectedKey(namespace: namespace)] = value
            copy.metadataProvenance[field] = attribution(for: field)
        }
        return copy
    }

    /// Local artwork references are credential-free payloads from the catalog. The
    /// attribution intentionally carries no URL: relative paths never escape into
    /// portable provenance.
    static func applyLocalArtwork(
        _ item: MediaItem,
        _ selections: [ArtworkSelection],
        metadataConfig: MetadataEnrichmentConfig = MetadataEnrichmentConfig()
    ) -> MediaItem {
        var copy = item
        guard !selections.isEmpty else { return copy }
        var byPlacement = Dictionary(uniqueKeysWithValues: copy.artworkSelections.map { ($0.placement, $0) })
        for selection in selections where !selection.references.isEmpty {
            if onlineArtworkOutranksLocal(
                for: selection.placement,
                in: copy,
                config: metadataConfig
            ) {
                byPlacement.removeValue(forKey: selection.placement)
                continue
            }
            byPlacement[selection.placement] = selection
            let field: MetadataField
            switch selection.placement {
            case .homeHero: field = .homeHero
            case .detailBackdrop: field = .detailBackdrop
            case .episodeThumbnail: field = .episodeThumbnail
            case .poster, .seriesPoster, .seasonPoster: field = .posterURL
            case .logo: field = .logoURL
            case .banner, .seasonBanner: continue
            default: continue
            }
            copy.metadataProvenance[field] = MetadataAttribution(source: .localArtwork, sourceURL: nil)
        }
        copy.artworkSelections = byPlacement.values.sorted { $0.placement.rawValue < $1.placement.rawValue }
        return copy
    }

    private static func onlineArtworkOutranksLocal(
        for placement: ArtworkPlacement,
        in item: MediaItem,
        config: MetadataEnrichmentConfig
    ) -> Bool {
        func outranks(
            precedenceField: MetadataField,
            provenanceField: MetadataField,
            hasValue: Bool
        ) -> Bool {
            guard hasValue,
                  let source = item.metadataProvenance[provenanceField]?.source,
                  ![.localNFO, .server, .localArtwork, .embedded, .filename, .generated]
                    .contains(source)
            else { return false }
            // Legacy enrichment rows predate exact provider provenance but are still
            // known to be online. Preserve the preference for those cached records.
            if source == .legacyUnknown { return config.preferOnlineArtwork }
            let precedence = config.precedenceSources(
                for: precedenceField,
                query: MetadataQuery(item)
            )
            guard let onlineIndex = precedence.firstIndex(of: source),
                  let localIndex = precedence.firstIndex(of: .localArtwork) else {
                return false
            }
            return onlineIndex < localIndex
        }

        switch placement {
        case .homeHero:
            return outranks(
                precedenceField: .homeHero,
                provenanceField: .backdropURL,
                hasValue: item.heroBackdropURL != nil || item.backdropURL != nil
            )
        case .detailBackdrop:
            return outranks(
                precedenceField: .detailBackdrop,
                provenanceField: .backdropURL,
                hasValue: item.heroBackdropURL != nil || item.backdropURL != nil
            )
        case .poster:
            return outranks(
                precedenceField: .posterURL,
                provenanceField: .posterURL,
                hasValue: item.posterURL != nil
            )
        case .seasonPoster:
            return outranks(
                precedenceField: .seasonPoster,
                provenanceField: .posterURL,
                hasValue: item.posterURL != nil
            )
        case .seriesPoster:
            return outranks(
                precedenceField: .posterURL,
                provenanceField: .posterURL,
                hasValue: item.seriesPosterURL != nil || item.posterURL != nil
            )
        case .logo:
            return outranks(
                precedenceField: .logoURL,
                provenanceField: .logoURL,
                hasValue: item.logoURL != nil
            )
        case .episodeThumbnail:
            return outranks(
                precedenceField: .episodeThumbnail,
                provenanceField: .posterURL,
                hasValue: item.posterURL != nil
            ) || outranks(
                precedenceField: .episodeThumbnail,
                provenanceField: .backdropURL,
                hasValue: item.backdropURL != nil
            )
        case .banner:
            return false
        case .seasonBanner:
            return false
        default:
            return false
        }
    }

    /// Merge an already-fetched enrichment record onto an item. Extracted from
    /// `withEnrichment` so the JOINed grid queries can reuse the exact same merge.
    static func applyEnrichment(_ item: MediaItem, _ rec: EnrichmentRecord) -> MediaItem {
        var copy = item
        if copy.metadataProvenance[.title] == nil {
            copy.metadataProvenance[.title] = MetadataAttribution(source: .filename)
        }
        func adopt(_ field: MetadataField) {
            if let attribution = rec.provenance[field] {
                copy.metadataProvenance[field] = attribution
            }
        }
        // Merge ids (don't clobber any already present).
        if !rec.providerIDs.isEmpty {
            var ids = copy.providerIDs
            for (k, v) in rec.providerIDs where ids[k] == nil {
                ids[k] = v
                adopt(.providerID(k))
            }
            copy.providerIDs = ids
        }
        if (copy.overview?.isEmpty ?? true), item.kind != .episode, let overview = rec.overview {
            copy.overview = overview
            adopt(.overview)
        }
        if copy.genres.isEmpty, !rec.genres.isEmpty {
            copy.genres = rec.genres
            adopt(.genres)
        }
        if copy.runtime == nil, let rt = rec.runtime, item.kind == .movie {
            copy.runtime = rt
            adopt(.runtime)
        }
        if copy.posterURL == nil, let poster = rec.posterURL {
            copy.posterURL = poster
            adopt(.posterURL)
        }
        if copy.backdropURL == nil, let backdrop = rec.backdropURL {
            copy.backdropURL = backdrop
            adopt(.backdropURL)
        }
        if copy.heroBackdropURL == nil, let backdrop = rec.backdropURL {
            copy.heroBackdropURL = backdrop
            adopt(.backdropURL)
        }
        if copy.logoURL == nil, let logo = rec.logoURL {
            copy.logoURL = logo
            adopt(.logoURL)
        }
        // Display-title upgrade (series/movies only, never episodes): overlay the
        // resolved canonical name when it's IDENTICAL, MORE SPECIFIC (current is a
        // word-prefix of resolved), or a NEAR-IDENTICAL typo/plural of the current
        // ("Peaky Blinder" → "Peaky Blinders") — so a generic or misspelled folder
        // shows the real name, but a spinoff that wrongly matched its parent is never
        // renamed DOWN. A more-specific upgrade must NOT add a non-canonical variant
        // word (abridged/recap/…): "Sword Art Online" must never become "Sword Art
        // Online: Abridged" even if a bad match slips through. Applied at READ time
        // so it's durable across re-scans.
        if item.kind == .series || item.kind == .movie,
           let resolved = rec.title, !resolved.isEmpty, resolved != copy.title {
            let a = MediaItemIdentity.normalizedTitle(copy.title)
            let b = MediaItemIdentity.normalizedTitle(resolved)
            let moreSpecific = b.hasPrefix(a + " ") && !ShareTitleSimilarity.addsVariantWord(base: a, extended: b)
            if b == a || moreSpecific || ShareTitleSimilarity.titlesNearlyIdentical(copy.title, resolved) {
                copy.title = resolved
                adopt(.title)
            }
        }
        // Episodes get the series art as a fallback, not as their own poster.
        if item.kind == .episode {
            if copy.seriesPosterURL == nil, let poster = rec.posterURL {
                copy.seriesPosterURL = poster
                adopt(.posterURL)
            }
            copy.posterURL = item.posterURL // keep episode's own (none yet) — series art via fallback field
        }
        return copy
    }

    /// Build a series item from already-decoded row values. Pure: the store
    /// composes the query and supplies the columns; this only shapes a `MediaItem`.
    static func seriesItem(key: String, title: String, library: CatalogLibrary, year: Int?) -> MediaItem {
        MediaItem(
            id: ShareCatalogID.series(key),
            title: title,
            kind: .series,
            productionYear: year,
            seriesID: ShareCatalogID.series(key),
            libraryID: ShareCatalogID.library(library)
        )
    }

    /// Build an episode item from a row selecting
    /// `rel_path, title, [kind|series_title], ...` — the two episode query shapes
    /// share column *names*, so read episode fields by a fixed layout:
    /// col0 rel_path, col1 title, col2 series_title, col3 season, col4 episode,
    /// col5 library, col6 year (used by `episodes(...)`), OR the `item(id:)` layout.
    static func episodeItem(from stmt: OpaquePointer?, seriesKey: String) -> MediaItem {
        // Read by name-agnostic positions used by the two callers. To stay robust,
        // pull values via helper that tolerates either layout is overkill; instead
        // both callers pass compatible column orders. `episodes(...)`:
        //   0 rel_path,1 title,2 series_title,3 season,4 episode,5 library,6 year
        // `item(id:)`:
        //   0 rel_path,1 title,2 kind,3 library,4 year,5 series_title,6 series_key,7 season,8 episode
        let colCount = sqlite3_column_count(stmt)
        let relPath = CatalogConnection.columnText(stmt, 0) ?? ""
        let title = CatalogConnection.columnText(stmt, 1) ?? relPath
        var seriesTitle: String?
        var season: Int?
        var episode: Int?
        var library: CatalogLibrary = .tv
        if colCount <= 7 {
            seriesTitle = CatalogConnection.columnText(stmt, 2)
            season = CatalogConnection.columnOptInt(stmt, 3)
            episode = CatalogConnection.columnOptInt(stmt, 4)
            library = CatalogLibrary(rawValue: CatalogConnection.columnText(stmt, 5) ?? "tv") ?? .tv
        } else {
            library = CatalogLibrary(rawValue: CatalogConnection.columnText(stmt, 3) ?? "tv") ?? .tv
            seriesTitle = CatalogConnection.columnText(stmt, 5)
            season = CatalogConnection.columnOptInt(stmt, 7)
            episode = CatalogConnection.columnOptInt(stmt, 8)
        }
        return MediaItem(
            id: ShareCatalogID.file(relPath),
            title: title,
            kind: .episode,
            parentTitle: seriesTitle,
            seasonNumber: season,
            episodeNumber: episode,
            seriesID: ShareCatalogID.series(seriesKey),
            // Give the episode its season id (the provider's own `season:key:N`
            // scheme that `children(of:)` decodes) so the player's neighbour
            // resolver — gated on `kind == .episode && seasonID != nil` — engages
            // for SMB shares too, enabling auto-advance, the Up Next card, and the
            // next-episode prefetch. Without it SMB episodes never hand off.
            seasonID: season.map { ShareCatalogID.season(seriesKey, $0) },
            libraryID: ShareCatalogID.library(library)
        )
    }
}
