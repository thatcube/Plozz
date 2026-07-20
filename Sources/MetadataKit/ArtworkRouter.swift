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
    /// Bundled TheTVDB tier. The router holds the underlying ``TVDBClient`` directly
    /// (not just via ``TVDBArtworkProvider``) so the original-language chain can call
    /// its transient-aware `originalLanguageOutcome` lookups when TMDb is off.
    private let tvdbClient = TVDBClient(config: .resolved())
    /// Keyless TVmaze client for the TV-only original-language fallback (last in the
    /// chain — TVmaze carries no movies).
    private let tvmazeClient = TVmazeClient()
    /// Bundled TheTVDB backdrop tier (hero art only). Nil-safe when unconfigured.
    private let tvdb: TVDBArtworkProvider
    private let cache: MetadataDiskCache

    /// Test-only override for the exact-ID original-language lookup. `nil` in
    /// production, where ``resolveExactOriginalLanguage(_:)`` walks the live provider
    /// chain; injected by tests to exercise the cache/normalization/keying (and the
    /// authoritative-vs-transient caching rule) without a network call.
    private let injectedOriginalLanguageResolver: (@Sendable (MetadataQuery) async -> OriginalLanguageOutcome)?

    /// Test-only override for the PER-PROVIDER original-language outcome. `nil` in
    /// production, where each source hits its live provider; injected by tests to
    /// drive the chain's ordering, fall-through and whole-chain-miss caching (which
    /// source wins, a transient falling through, a movie skipping TVmaze) against the
    /// real ``CurrentMetadataPriority`` ordering, without any network. Returning
    /// `nil` for a source means "not applicable" (the chain skips it).
    private let injectedProviderOutcomes: (@Sendable (MetadataSource, MetadataQuery) async -> OriginalLanguageOutcome?)?

    /// Positive + negative in-memory cache of resolved original languages, keyed by
    /// the query's show-level external-id identity so every episode of a show — and
    /// every re-play — share a single lookup. A cached `.some(nil)` means "looked
    /// AUTHORITATIVELY, found nothing" so a real miss is never re-fetched within a
    /// run. **Transient failures are never written here** — only authoritative
    /// answers land, so one flaky play can't pin the container default for the run.
    private var originalLanguageCache: [String: String?] = [:]

    /// In-flight lookups, keyed identically to ``originalLanguageCache``, so
    /// concurrent first-plays of the same show (the current load and the next-
    /// episode prefetch) coalesce onto one request instead of firing duplicates.
    private var originalLanguageTasks: [String: Task<String?, Never>] = [:]

    public init(
        config: MetadataProviderConfig = .resolved(),
        cache: MetadataDiskCache = .shared
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.tvdb = TVDBArtworkProvider(client: tvdbClient)
        self.injectedOriginalLanguageResolver = nil
        self.injectedProviderOutcomes = nil
    }

    /// Testing seam: injects the exact-ID original-language resolver so unit tests
    /// can drive ``originalLanguage(for:)``'s cache/normalization/keying and the
    /// authoritative-vs-transient caching rule without a live TMDb request.
    init(
        config: MetadataProviderConfig = MetadataProviderConfig(tmdb: .disabled),
        cache: MetadataDiskCache = .shared,
        exactOriginalLanguageResolver: @escaping @Sendable (MetadataQuery) async -> OriginalLanguageOutcome
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.tvdb = TVDBArtworkProvider(client: tvdbClient)
        self.injectedOriginalLanguageResolver = exactOriginalLanguageResolver
        self.injectedProviderOutcomes = nil
    }

    /// Testing seam: injects a PER-PROVIDER original-language outcome so unit tests
    /// can drive the multi-provider chain — ordering, transient fall-through, movies
    /// skipping TVmaze, and whole-chain-miss caching — against the real
    /// ``CurrentMetadataPriority`` ordering without any network.
    init(
        config: MetadataProviderConfig = MetadataProviderConfig(tmdb: .disabled),
        cache: MetadataDiskCache = .shared,
        providerOriginalLanguageOutcomes: @escaping @Sendable (MetadataSource, MetadataQuery) async -> OriginalLanguageOutcome?
    ) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
        self.cache = cache
        self.tvdb = TVDBArtworkProvider(client: tvdbClient)
        self.injectedOriginalLanguageResolver = nil
        self.injectedProviderOutcomes = providerOriginalLanguageOutcomes
    }

    /// Reconfigures the TMDb tier at runtime (e.g. after the user sets a proxy).
    public func reconfigure(_ config: MetadataProviderConfig) {
        self.tmdb = TMDbMetadataProvider(access: config.tmdb)
    }

    /// `true` when the optional TMDb tier is configured (proxy or local token).
    public var isTMDbEnabled: Bool { tmdb.isEnabled }

    // MARK: - Original language (audio "prefer original" policy)

    /// Best-effort ISO-639-1 original language for a SERVER-backed `item` whose
    /// provider gave none (Plex/Jellyfin/Emby never fill `original_language`),
    /// resolved from an ordered chain of FREE providers — TMDb (exact id, or IMDB via
    /// `/find`), then TheTVDB (exact id, then title+year search), then TVmaze for TV —
    /// returning the first authoritative value, normalized to ISO-639-1, and cached.
    /// Because TheTVDB is the always-on bundled key, this resolves even when the
    /// optional TMDb tier is disabled/down (the bug where a disabled TMDb pinned the
    /// container default). Returns `nil` when the item is music, it carries no usable
    /// identity, or every provider authoritatively found nothing — the caller then
    /// defers to the container default.
    ///
    /// Only **authoritative** answers are cached: a transient failure on any provider
    /// (offline, timeout, 429, 5xx, …) returns `nil` for this call but is NOT written,
    /// and an authoritative miss is cached only once the WHOLE chain is exhausted, so
    /// a later play retries instead of being pinned to the container default. Reuses
    /// the same shared, self-configuring, provider-id-keyed external-metadata seam
    /// the artwork path already uses for server items, rather than a parallel
    /// subsystem, so the "prefer original language" audio policy works for server
    /// items exactly as it already does for direct-share items.
    public func originalLanguage(for item: MediaItem) async -> String? {
        await originalLanguage(for: MetadataQuery(item))
    }

    /// Lower-level entry point taking a prebuilt ``MetadataQuery``.
    public func originalLanguage(for query: MetadataQuery) async -> String? {
        let key = Self.originalLanguageCacheKey(for: query)
        // An authoritative result (incl. a real miss) is served straight from cache.
        if let hit = originalLanguageCache[key] { return hit }
        // Coalesce concurrent first-plays of the same show onto one lookup.
        if let inFlight = originalLanguageTasks[key] { return await inFlight.value }

        let task = Task { await self.resolveAndCacheOriginalLanguage(query, key: key) }
        originalLanguageTasks[key] = task
        let resolved = await task.value
        originalLanguageTasks[key] = nil
        return resolved
    }

    /// Runs the exact-ID lookup and, **only for an authoritative outcome**, writes
    /// the normalized value (or an authoritative `nil`) into the cache. A transient
    /// failure returns `nil` without caching so the next play can retry.
    private func resolveAndCacheOriginalLanguage(_ query: MetadataQuery, key: String) async -> String? {
        switch await resolveExactOriginalLanguage(query) {
        case .authoritative(let raw):
            let normalized = OriginalLanguageNormalizer.normalized(raw)
            originalLanguageCache[key] = normalized
            return normalized
        case .transient:
            return nil
        }
    }

    private func resolveExactOriginalLanguage(_ query: MetadataQuery) async -> OriginalLanguageOutcome {
        if let injectedOriginalLanguageResolver {
            return await injectedOriginalLanguageResolver(query)
        }
        // Walk the content-type-specific provider chain (movie `[.tmdb, .tvdb]`;
        // tvShow/anime/unknown `[.tmdb, .tvdb, .tvmaze]`) and return the FIRST
        // authoritative value — so the fill resolves even when TMDb is disabled/down
        // (TheTVDB, the always-on bundled key, then satisfies it). Each provider is
        // transient-aware: a transient failure falls THROUGH to the next provider and
        // is never cached; an authoritative miss is only cached once the WHOLE chain
        // is authoritatively exhausted (every provider returned a reachable "none").
        var sawTransient = false
        for source in CurrentMetadataPriority.originalLanguageSources(for: query.contentType) {
            guard let outcome = await originalLanguageOutcome(from: source, for: query) else { continue }
            switch outcome {
            case .authoritative(let raw):
                if let raw, !raw.isEmpty { return .authoritative(raw) }   // first authoritative value wins
            case .transient:
                sawTransient = true                                        // remember, but keep trying
            }
        }
        return sawTransient ? .transient : .authoritative(nil)
    }

    /// One provider's transient-aware original-language outcome, or `nil` when the
    /// source doesn't participate for this query (so the chain skips it).
    private func originalLanguageOutcome(
        from source: MetadataSource,
        for query: MetadataQuery
    ) async -> OriginalLanguageOutcome? {
        if let injectedProviderOutcomes {
            return await injectedProviderOutcomes(source, query)
        }
        switch source {
        case .tmdb: return await tmdb.originalLanguageOutcome(forExactMatchOf: query)
        case .tvdb: return await tvdbOriginalLanguageOutcome(for: query)
        case .tvmaze: return await tvmazeClient.originalLanguageOutcome(for: query)
        default: return nil
        }
    }

    /// TheTVDB's transient-aware original-language outcome: prefer an EXACT
    /// show-level TheTVDB id (an episode uses its `SeriesTvdb`, never the per-episode
    /// id), then fall back to a title+year search. A by-id authoritative value wins;
    /// otherwise the two attempts combine so any unreachable attempt yields
    /// `.transient` (never a cached miss) and an authoritative miss requires both to
    /// have reachably found nothing.
    private func tvdbOriginalLanguageOutcome(for query: MetadataQuery) async -> OriginalLanguageOutcome {
        let isMovie = !query.isTV
        let tvdbID = query.providerIDs.providerID(.seriesTvdb)
            ?? ((!query.isTV || query.kind == .series) ? query.providerIDs.providerID(.tvdb) : nil)

        var sawTransient = false
        if let tvdbID, !tvdbID.isEmpty {
            switch await tvdbClient.originalLanguageOutcome(byTVDBID: tvdbID, isMovie: isMovie) {
            case .authoritative(let raw):
                if let raw, !raw.isEmpty { return .authoritative(raw) }
            case .transient:
                sawTransient = true
            }
        }
        switch await tvdbClient.originalLanguageOutcome(titles: [query.title], year: query.year, isMovie: isMovie) {
        case .authoritative(let raw):
            if let raw, !raw.isEmpty { return .authoritative(raw) }
        case .transient:
            sawTransient = true
        }
        return sawTransient ? .transient : .authoritative(nil)
    }

    /// Awaits `operation` but returns `nil` if it doesn't finish within `timeout`,
    /// **without cancelling it** — so a slow lookup still runs to completion and
    /// warms the cache for the next call. Keeps the playback bring-up path from
    /// stalling on a degraded network (where a single request can take the full
    /// transport timeout): a first uncached play proceeds with the container default
    /// and the next play/episode gets the resolved language from the warmed cache.
    ///
    /// Uses a first-result race (not `withTaskGroup`, which would defer the return
    /// until the slow child finished): the operation runs as an independent,
    /// non-cancelled task and the timeout is a separate task; whichever resolves
    /// first wins, and the loser is never awaited.
    public static func boundedValue<V: Sendable>(
        within timeout: Duration,
        of operation: @escaping @Sendable () async -> V?
    ) async -> V? {
        let race = FirstResultBox<V>()
        // Independent task: dropping the handle does NOT cancel it, so the operation
        // always runs to completion and warms the cache even after we stop waiting.
        Task { await race.resolve(await operation()) }
        let timeoutTask = Task {
            try? await Task.sleep(for: timeout)
            await race.resolve(nil)
        }
        let result = await race.awaitFirst()
        timeoutTask.cancel()
        return result
    }

    /// Stable identity for the original-language cache: a concrete **show-level**
    /// external id when present (so all episodes of a show and every re-play share
    /// one entry), else a normalized title+year. Never keyed on a per-episode id.
    static func originalLanguageCacheKey(for query: MetadataQuery) -> String {
        var parts: [String] = ["origlang", query.contentType.rawValue]
        let showTMDb: String? = query.providerIDs.providerID(.seriesTmdb)
            ?? ((!query.isTV || query.kind == .series) ? query.providerIDs.providerID(.tmdb) : nil)
        if let showTMDb {
            parts.append("tmdb:\(showTMDb)")
        } else if let imdb = query.providerIDs.providerID(.imdb) {
            parts.append("imdb:\(imdb)")
        } else {
            parts.append("t:\(query.title.lowercased())|y:\(query.year.map(String.init) ?? "")")
        }
        return parts.joined(separator: "|")
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

    /// The ordered provider chain for a content type + artwork kind. Keyless,
    /// per-IP providers come first (they scale infinitely and cover anime/episodes
    /// best); the optional TMDb tier backs them up for heroes/logos/stills.
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

/// A single-shot "first result wins" mailbox used by ``ArtworkRouter/boundedValue``
/// to race a lookup against a timeout. The first `resolve` sets the value and wakes
/// any awaiter; later `resolve` calls (the loser of the race) are no-ops, so the
/// slow lookup can complete harmlessly after the timeout already returned.
private actor FirstResultBox<V: Sendable> {
    private var resolved: V??
    private var waiter: CheckedContinuation<V?, Never>?

    func resolve(_ value: V?) {
        guard resolved == nil else { return }
        resolved = .some(value)
        if let waiter {
            self.waiter = nil
            waiter.resume(returning: value)
        }
    }

    func awaitFirst() async -> V? {
        if case let .some(value) = resolved { return value }
        return await withCheckedContinuation { continuation in
            if case let .some(value) = resolved {
                continuation.resume(returning: value)
            } else {
                waiter = continuation
            }
        }
    }
}
