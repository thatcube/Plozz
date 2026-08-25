import Foundation
import CoreModels

/// The single front door for resolving external artwork — the piece that makes the
/// provider set *scalable and content-aware*.
///
/// Given a ``MediaItem`` and an ``ArtworkKind``, the router:
///   1. classifies the item's ``ContentType`` (anime / movie / tvShow / music),
///   2. runs an ordered, content-type-specific fallback chain of providers
///      (keyless per-IP APIs first, the optional TMDb tier as backup),
///   3. memoizes the resolved URL in the persistent ``MetadataDiskCache`` so the
///      whole library is enriched with a small one-time burst of calls, then
///      effectively none — which is what lets the keyless backbone serve any
///      number of users without ever straining a shared quota.
///
/// It self-configures from the app bundle, so call sites just use
/// ``ArtworkRouter/shared`` without any app wiring.
public actor ArtworkRouter {
    public static let shared = ArtworkRouter()

    private let anilist = AniListArtworkProvider()
    private let kitsu = KitsuArtworkProvider()
    private let tvmaze = TVmazeArtworkProvider()
    private let wikidata = WikidataArtworkProvider()
    private let wikipedia = WikipediaArtworkProvider()
    private let deezer = DeezerMusicProvider()
    private let musicBrainz = MusicBrainzArtworkProvider()
    private var tmdb: TMDbMetadataProvider
    /// Bundled TheTVDB backdrop tier (hero art only). Nil-safe when unconfigured.
    private let tvdb = TVDBArtworkProvider(client: TVDBClient(config: .resolved()))
    private let cache: MetadataDiskCache
    /// Original language is show/movie-level metadata, so every episode in a
    /// series shares one answer. Keep positive and negative results separately:
    /// a plain `[String: String?]` cannot retain nil (assigning nil removes the
    /// entry), which would repeat the network lookup on every episode.
    private var originalLanguages: [String: String] = [:]
    private var missingOriginalLanguages = Set<String>()
    /// Candidate lists, memoised for the process.
    ///
    /// Not the persistent cache: that stores one URL per key and a list has no
    /// representation in it. A title's candidates are cheap to recompute once per
    /// run, and holding them here is what makes returning to a page free. Capped
    /// because a large library would otherwise grow this without bound; dropping
    /// the lot costs one recomputation, which is far better than leaking.
    private var heroCandidates: [String: [SourcedValue<URL>]] = [:]
    private static let heroCandidatesCap = 600

    public init(
        config: MetadataProviderConfig = .resolved(),
        cache: MetadataDiskCache = .shared
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
    }

    /// Reconfigures the TMDb tier at runtime (e.g. after the user sets a proxy).
    public func reconfigure(_ config: MetadataProviderConfig) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
    }

    /// `true` when the optional TMDb tier is configured (proxy or local token).
    public var isTMDbEnabled: Bool { tmdb.isEnabled }

    /// Best available original spoken language for playback policy.
    ///
    /// Anime has a local, stronger answer (`ja`) and never needs a network call.
    /// Other video asks TMDb once per title; a miss stays a miss for this router
    /// session so episode hand-offs never add repeated metadata latency.
    public func originalAudioLanguage(for item: MediaItem) async -> String? {
        if let classified = ContentClassifier.originalAudioLanguage(for: item) {
            return classified
        }
        let query = MetadataQuery(item).seriesScoped
        let key = Self.originalLanguageCacheKey(for: item, query: query)
        if let cached = originalLanguages[key] { return cached }
        if missingOriginalLanguages.contains(key) { return nil }
        guard let language = await tmdb.originalLanguage(for: query) else {
            missingOriginalLanguages.insert(key)
            return nil
        }
        originalLanguages[key] = language
        return language
    }

    static func originalLanguageCacheKey(
        for item: MediaItem,
        query: MetadataQuery? = nil
    ) -> String {
        let query = query ?? MetadataQuery(item).seriesScoped
        if item.kind == .episode || item.kind == .season {
            let namespaces: [ProviderIDNamespace] = [
                .seriesTmdb, .seriesTvdb, .seriesImdb, .seriesTvmaze,
                .seriesAniList, .seriesMal, .seriesAniDB,
            ]
            for namespace in namespaces {
                if let value = item.providerID(namespace) {
                    return "original-language|\(namespace.canonicalKey.lowercased()):\(value)"
                }
            }
        }
        return "original-language|\(query.cacheKey(for: .poster))"
    }

    // MARK: - Video artwork

    /// Resolves a `kind` artwork URL for `item`, trying the content-type-specific
    /// provider chain and caching the (positive or negative) result. Never throws.
    public func artworkURL(_ kind: ArtworkKind, for item: MediaItem) async -> URL? {
        let query = MetadataQuery(item)
        return await artworkURL(kind, for: query)
    }

    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for item: MediaItem
    ) async -> SourcedValue<URL>? {
        await sourcedArtworkURL(kind, for: MetadataQuery(item))
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func artworkURL(_ kind: ArtworkKind, for query: MetadataQuery) async -> URL? {
        await sourcedArtworkURL(kind, for: query)?.value
    }

    /// Resolves artwork together with the provider that supplied it.
    public func sourcedArtworkURL(
        _ kind: ArtworkKind,
        for query: MetadataQuery
    ) async -> SourcedValue<URL>? {
        let key = query.cacheKey(for: kind)
        if let hit = await cache.cached(key) {
            guard let hit else { return nil }
            // The pre-provenance URL cache does not retain which provider won.
            return SourcedValue(value: hit, source: .legacyUnknown)
        }

        for provider in chain(for: query.contentType, kind: kind) {
            if let url = await provider.artworkURL(kind, for: query) {
                await cache.store(url, for: key)
                return SourcedValue(
                    value: url,
                    source: MetadataSource(rawValue: provider.id)
                )
            }
        }
        await cache.store(nil, for: key)
        return nil
    }

    /// Ordered artwork candidates for `item`. See the ``MetadataQuery`` overload.
    public func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for item: MediaItem,
        limit: Int = 2
    ) async -> [SourcedValue<URL>] {
        await sourcedArtworkURLs(kind, for: MetadataQuery(item), limit: limit)
    }

    /// Ordered artwork candidates for `kind`, best first, across the provider chain.
    ///
    /// Deliberately a **separate** entry point rather than a change to
    /// ``sourcedArtworkURL(_:for:)``. That one stops at the first provider which
    /// answers, and Home depends on it doing exactly that — widening it to gather
    /// candidates would ask providers that would never otherwise have been called,
    /// on the browse path, which is precisely the wrong place to spend a request.
    ///
    /// This one is for the detail page, which wants a *second* picture. It costs no
    /// more than the single lookup did for the providers that matter: TMDb reads
    /// all of a title's backdrops out of the one `/images` response it already
    /// fetches, and any provider holding a single image falls back to the protocol
    /// default, which is the same call as before. It also stops the moment it has
    /// `limit`, so a chain is never walked further than it needs to be.
    ///
    /// Results are memoised for the process, so returning to a title is free.
    public func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        limit: Int = 2
    ) async -> [SourcedValue<URL>] {
        guard limit > 0 else { return [] }
        let key = "\(query.cacheKey(for: kind))|candidates"
        if let hit = heroCandidates[key] { return hit }

        var found: [SourcedValue<URL>] = []
        var asked: [String] = []
        for provider in chain(for: query.contentType, kind: kind) {
            let source = MetadataSource(rawValue: provider.id)
            let offered = await provider.artworkURLs(kind, for: query, limit: limit - found.count)
            asked.append("\(provider.id):\(offered.count)")
            for url in offered {
                guard !found.contains(where: { $0.value == url }) else { continue }
                found.append(SourcedValue(value: url, source: source))
                if found.count >= limit { break }
            }
            if found.count >= limit { break }
        }
        HeroArtDiagnostics.emit(
            "router candidates kind=\(kind) title=\(query.title) type=\(query.contentType) "
            + "asked=[\(asked.joined(separator: " "))] got=\(found.count) "
            + "urls=[\(found.map { HeroArtDiagnostics.brief($0.value) }.joined(separator: " , "))]"
        )
        if heroCandidates.count >= Self.heroCandidatesCap { heroCandidates.removeAll(keepingCapacity: true) }
        heroCandidates[key] = found
        return found
    }

    private func chain(for type: ContentType, kind: ArtworkKind) -> [any ArtworkProvider] {
        CurrentMetadataPriority.artworkSources(for: type, kind: kind).compactMap {
            provider(for: $0)
        }
    }

    private func provider(for source: MetadataSource) -> (any ArtworkProvider)? {
        switch source {
        case .anilist: anilist
        case .kitsu: kitsu
        case .tvmaze: tvmaze
        case .wikidata: wikidata
        case .wikipedia: wikipedia
        case .tmdb: tmdb
        case .tvdb: tvdb
        default: nil
        }
    }

    // MARK: - Music artwork (separate model path)

    /// A large artist image for a music hero/background. Keyless (Deezer).
    public func artistImageURL(artist: String) async -> URL? {
        let key = "music|artist|\(artist.lowercased())"
        if let hit = await cache.cached(key) { return hit }
        let url = await deezer.artistImageURL(artist: artist)
        await cache.store(url, for: key)
        return url
    }

    /// A large album cover, trying Deezer then MusicBrainz/Cover Art Archive.
    public func albumCoverURL(artist: String?, album: String) async -> URL? {
        let key = "music|album|\((artist ?? "").lowercased())|\(album.lowercased())"
        if let hit = await cache.cached(key) { return hit }
        if let url = await deezer.albumCoverURL(artist: artist, album: album) {
            await cache.store(url, for: key)
            return url
        }
        let fallback = await musicBrainz.albumCoverURL(artist: artist, album: album)
        await cache.store(fallback, for: key)
        return fallback
    }
}
