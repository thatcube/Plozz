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
    private let enrichmentBaseline: MetadataEnrichmentConfig
    private let settingsStore: any MetadataProviderSettingsStoring
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
        cache: MetadataDiskCache = .shared,
        enrichmentBaseline: MetadataEnrichmentConfig = .resolved(),
        settingsStore: any MetadataProviderSettingsStoring = MetadataProviderSettingsStore()
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.enrichmentBaseline = enrichmentBaseline
        self.settingsStore = settingsStore
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
        let providers = configuredProviders(for: query, kind: kind)
        guard !providers.isEmpty else { return nil }
        let cache = self.cache

        let answers = await withTaskGroup(
            of: (Int, SourcedValue<URL>?).self,
            returning: [(Int, SourcedValue<URL>?)].self
        ) { group in
            for (index, entry) in providers.enumerated() {
                group.addTask {
                    let key = Self.providerCacheKey(
                        query: query,
                        kind: kind,
                        source: entry.source
                    )
                    if let hit = await cache.cached(key) {
                        return (
                            index,
                            hit.map { SourcedValue(value: $0, source: entry.source) }
                        )
                    }
                    let url = await entry.provider.artworkURL(kind, for: query)
                    await cache.store(url, for: key)
                    return (
                        index,
                        url.map { SourcedValue(value: $0, source: entry.source) }
                    )
                }
            }
            var completed = Array<SourcedValue<URL>??>(
                repeating: nil,
                count: providers.count
            )
            var nextPriority = 0
            while let (index, answer) = await group.next() {
                completed[index] = .some(answer)
                while nextPriority < completed.count,
                      let priorityAnswer = completed[nextPriority] {
                    if let priorityAnswer {
                        group.cancelAll()
                        return [(nextPriority, priorityAnswer)]
                    }
                    nextPriority += 1
                }
            }
            return []
        }
        return answers.sorted { $0.0 < $1.0 }.compactMap(\.1).first
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
    /// This one also supplies the deterministic Home/detail pair. Enabled providers
    /// race concurrently; results are put back into configured priority order before
    /// selection, so a slow high-priority source cannot serialize the whole chain.
    ///
    /// Results are memoised for the process, so returning to a title is free.
    public func sourcedArtworkURLs(
        _ kind: ArtworkKind,
        for query: MetadataQuery,
        limit: Int = 2
    ) async -> [SourcedValue<URL>] {
        guard limit > 0 else { return [] }
        let providers = configuredProviders(for: query, kind: kind)
        let sourceFingerprint = providers.map(\.source.rawValue).joined(separator: ",")
        let key = "\(query.cacheKey(for: kind))|candidates|\(sourceFingerprint)"
        if let hit = heroCandidates[key] { return hit }

        let batches = await withTaskGroup(
            of: (Int, MetadataSource, [URL]).self,
            returning: [(Int, MetadataSource, [URL])].self
        ) { group in
            for (index, entry) in providers.enumerated() {
                group.addTask {
                    let offered = await entry.provider.artworkURLs(kind, for: query, limit: limit)
                    return (index, entry.source, offered)
                }
            }
            var completed = Array<[URL]?>(repeating: nil, count: providers.count)
            var nextPriority = 0
            while let (index, _, offered) = await group.next() {
                completed[index] = offered
                while nextPriority < completed.count,
                      let priorityAnswer = completed[nextPriority] {
                    if !priorityAnswer.isEmpty {
                        group.cancelAll()
                        return completed.enumerated().compactMap { index, urls in
                            urls.map { (index, providers[index].source, $0) }
                        }
                    }
                    nextPriority += 1
                }
            }
            return []
        }

        var found: [SourcedValue<URL>] = []
        var asked: [String] = []
        for (_, source, offered) in batches.sorted(by: { $0.0 < $1.0 }) {
            asked.append("\(source.rawValue):\(offered.count)")
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

    /// Deterministic Home/detail picks from one online candidate pool. Detail uses
    /// the runner-up when available, preserving the deliberate two-hero design.
    public func heroArtworkURL(
        for item: MediaItem,
        placement: ArtworkPlacement
    ) async -> URL? {
        let candidates = await sourcedArtworkURLs(.hero, for: item, limit: 4)
        return Self.heroCandidate(from: candidates, placement: placement)
    }

    static func heroCandidate(
        from candidates: [SourcedValue<URL>],
        placement: ArtworkPlacement
    ) -> URL? {
        guard placement == .detailBackdrop else { return candidates.first?.value }
        return candidates.dropFirst().first?.value ?? candidates.first?.value
    }

    private func configuredProviders(
        for query: MetadataQuery,
        kind: ArtworkKind
    ) -> [(source: MetadataSource, provider: any ArtworkProvider)] {
        let config = enrichmentBaseline.merged(withUserOverrides: settingsStore.load())
        return config.orderedSources(for: Self.field(for: kind), query: query).compactMap { source in
            provider(for: source).map { (source, $0) }
        }
    }

    private static func field(for kind: ArtworkKind) -> MetadataField {
        switch kind {
        case .poster: .posterURL
        case .hero: .backdropURL
        case .thumbnail: .episodeThumbnail
        case .logo: .logoURL
        }
    }

    static func providerCacheKey(
        query: MetadataQuery,
        kind: ArtworkKind,
        source: MetadataSource
    ) -> String {
        "\(query.cacheKey(for: kind))|provider:\(source.rawValue)"
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
