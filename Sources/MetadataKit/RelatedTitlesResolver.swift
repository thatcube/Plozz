import CoreModels
import Foundation

/// Wraps ``TMDbMetadataProvider`` as a related-titles source.
public struct TMDbRelatedProvider: RelatedTitlesProviding {
    public let id: MetadataSource = .tmdb
    private let provider: TMDbMetadataProvider

    public init(provider: TMDbMetadataProvider) {
        self.provider = provider
    }

    public var isEnabled: Bool { provider.isEnabled }

    public func relatedTitles(for query: MetadataQuery, limit: Int) async -> [RelatedTitle] {
        await provider.relatedTitles(for: query, limit: limit)
    }
}

/// Resolves the titles related to one the viewer is looking at, from a ranked chain
/// of providers.
///
/// Chained rather than single-sourced for two reasons. Anime is the obvious one:
/// only AniList models sequels and side stories as real relations, so it leads
/// there and can say "this show has a sequel" instead of merely "here's something
/// similar". The other is that no single provider should be load-bearing — the app
/// ships bundled keys under free, non-commercial terms, and a feature resting
/// entirely on one of them is one policy change away from disappearing.
///
/// Every source needs **no user account**: AniList requires no key at all, TMDb
/// uses the built-in one, and Trakt's `related` is public app-level data (signing
/// in is only for a viewer's own history). So this works on a fresh install.
///
/// Order is chosen for how each provider's limits behave **at scale**, not just for
/// quality. TMDb rate-limits by requesting IP rather than by key, which its staff
/// state plainly, so every household gets its own budget however many people run
/// the app. Trakt's ordinary quota also appears to be app+IP, but its client id
/// carries a shared blast radius — Trakt has firewall-blocked a distributed app's
/// key outright over runaway traffic from a couple of installs, which would take
/// every user down at once. So Trakt sits second, answering only where TMDb has
/// nothing, which keeps aggregate traffic on it low.
public struct RelatedTitlesResolver: Sendable {
    private let providers: [any RelatedTitlesProviding]

    public init(providers: [any RelatedTitlesProviding]) {
        self.providers = providers
    }

    /// Related titles for `query`, continuations first.
    ///
    /// Providers are tried in order and their results **merged**, not raced: a
    /// provider that contributes only relations (AniList) shouldn't stop a later one
    /// contributing recommendations. Stops early once `limit` is met so an ordinary
    /// show costs a single request.
    public func relatedTitles(for query: MetadataQuery, limit: Int = 24) async -> [RelatedTitle] {
        guard limit > 0 else { return [] }
        let active = providers.filter(\.isEnabled)
        guard !active.isEmpty else { return [] }

        // Every provider is asked, concurrently, and the results merged — the chain
        // does NOT stop at the first one that fills the row.
        //
        // Stopping early looked like a saving and was actually a defect: AniList
        // answers an anime query with AniList/MAL ids, but a Shoko- or Jellyfin-
        // managed library stores AniDB and TMDb ones, so nothing could be verified
        // against the viewer's copies — and because AniList had filled the row,
        // TMDb (whose ids *do* match) was never asked. Anime got an empty row while
        // the data to fill it sat one provider away.
        //
        // So the cost is a handful of parallel requests per title instead of one,
        // cached for a week. Which provider can be *verified* against a particular
        // library isn't knowable here, and guessing it was the bug.
        let perProvider: [[RelatedTitle]] = await withTaskGroup(
            of: (Int, [RelatedTitle]).self
        ) { group in
            for (index, provider) in active.enumerated() {
                group.addTask { (index, await provider.relatedTitles(for: query, limit: limit)) }
            }
            var byIndex: [Int: [RelatedTitle]] = [:]
            for await (index, titles) in group { byIndex[index] = titles }
            return active.indices.map { byIndex[$0] ?? [] }
        }

        let seedIDs = Self.identityTokens(for: query)
        var seen = Set<String>()
        var continuations: [RelatedTitle] = []
        var recommendations: [RelatedTitle] = []

        // Interleaved round-robin rather than concatenated, so one provider can't
        // monopolise the row — and, more importantly, can't monopolise the library
        // lookups the caller then spends on it.
        let depth = perProvider.map(\.count).max() ?? 0
        for offset in 0..<depth {
            for titles in perProvider where offset < titles.count {
                let candidate = titles[offset]
                // The seed can come back as its own relation (AniList lists a parent
                // both ways round); dropping it keeps the row from linking to the
                // page it is already on.
                guard !seedIDs.contains(where: Self.tokens(for: candidate).contains) else { continue }
                guard seen.insert(candidate.id).inserted else { continue }
                if candidate.isContinuation {
                    continuations.append(candidate)
                } else {
                    recommendations.append(candidate)
                }
            }
        }

        // Continuations lead: someone on a show they love wants to know there's more
        // of *it* before they want a lookalike.
        return Array((continuations + recommendations).prefix(limit))
    }

    /// Identity tokens for a related title, in the same shape as the seed's, so the
    /// two can be compared without knowing which provider produced either.
    static func tokens(for title: RelatedTitle) -> Set<String> {
        var tokens: Set<String> = []
        for namespace in Self.comparableNamespaces {
            if let value = title.providerIDs.providerID(namespace) {
                tokens.insert("\(namespace.canonicalKey.lowercased()):\(value)")
            }
        }
        return tokens
    }

    static func identityTokens(for query: MetadataQuery) -> Set<String> {
        var tokens: Set<String> = []
        for namespace in Self.comparableNamespaces {
            if let value = query.providerIDs.providerID(namespace) {
                tokens.insert("\(namespace.canonicalKey.lowercased()):\(value)")
            }
        }
        if let anilist = query.animeIDs.anilist {
            tokens.insert("\(ProviderIDNamespace.aniList.canonicalKey.lowercased()):\(anilist)")
        }
        if let mal = query.animeIDs.mal {
            tokens.insert("\(ProviderIDNamespace.myAnimeList.canonicalKey.lowercased()):\(mal)")
        }
        return tokens
    }

    static let comparableNamespaces: [ProviderIDNamespace] = [
        .tmdb, .imdb, .tvdb, .aniList, .myAnimeList,
    ]
}

public extension RelatedTitlesResolver {
    /// The production chain.
    ///
    /// `traktClientID` is the app-level registration bundled in every build; passing
    /// `nil` simply drops Trakt from the chain, which is what a third-party build
    /// without the key gets.
    static func production(
        providerConfig: MetadataProviderConfig = .resolved(),
        traktClientID: String? = nil
    ) -> RelatedTitlesResolver {
        RelatedTitlesResolver(providers: [
            // Anime first: only AniList knows a show *has* a sequel.
            AniListRelatedProvider(),
            TMDbRelatedProvider(provider: TMDbMetadataProvider(access: providerConfig.tmdb)),
            TraktRelatedProvider(clientID: traktClientID),
        ])
    }
}
