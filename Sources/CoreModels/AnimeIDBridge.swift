import Foundation

/// Maps one anime between the id spaces that never meet on their own.
///
/// Anime trackers and media servers do not share an identifier. AniList and
/// MyAnimeList live in their own numbering; Plex and Jellyfin describe the same
/// show with AniDB, TMDb, TVDb and IMDb. Nothing in a watchlist entry from
/// either side can be matched against the other, so the alias ledger — which
/// correctly refuses to merge two records that share no evidence, because
/// guessing would route playback to a different work — keeps them apart. The
/// viewer sees one show twice: once as the copy they own, once as one to go and
/// request.
///
/// A bridge is the only honest fix. The ids are genuinely disjoint, so the
/// mapping has to come from somewhere that knows both, and it has to be exact
/// rather than inferred from titles: "the 2019 one called Dr. Stone" is how you
/// merge two different works by accident.
public struct AnimeIDMapping: Codable, Hashable, Sendable {
    public var aniDB: String?
    public var aniList: String?
    public var myAnimeList: String?
    public var tmdb: String?
    public var tvdb: String?
    public var imdb: String?

    public init(
        aniDB: String? = nil,
        aniList: String? = nil,
        myAnimeList: String? = nil,
        tmdb: String? = nil,
        tvdb: String? = nil,
        imdb: String? = nil
    ) {
        self.aniDB = aniDB
        self.aniList = aniList
        self.myAnimeList = myAnimeList
        self.tmdb = tmdb
        self.tvdb = tvdb
        self.imdb = imdb
    }

    /// Every id in this mapping, as `(namespace, value)` pairs.
    public var identities: [(namespace: ProviderIDNamespace, value: String)] {
        var result: [(ProviderIDNamespace, String)] = []
        if let aniDB { result.append((.aniDB, aniDB)) }
        if let aniList { result.append((.aniList, aniList)) }
        if let myAnimeList { result.append((.myAnimeList, myAnimeList)) }
        if let tmdb { result.append((.tmdb, tmdb)) }
        if let tvdb { result.append((.tvdb, tvdb)) }
        if let imdb { result.append((.imdb, imdb)) }
        return result
    }

    /// Whether this mapping names `value` in `namespace`.
    public func matches(namespace: ProviderIDNamespace, value: String) -> Bool {
        switch namespace {
        case .aniDB, .seriesAniDB: return aniDB == value
        case .aniList, .seriesAniList: return aniList == value
        case .myAnimeList, .seriesMal: return myAnimeList == value
        case .tmdb, .seriesTmdb: return tmdb == value
        case .tvdb, .seriesTvdb: return tvdb == value
        case .imdb, .seriesImdb: return imdb == value
        default: return false
        }
    }
}

/// An index over anime id mappings, answering "what else is this show called?".
///
/// Pure and synchronous: it is consulted while resolving identity, which happens
/// per title, so it must not perform I/O. Loading the mappings is the caller's
/// job (see `AnimeIDBridgeStore`).
public struct AnimeIDBridge: Sendable, Equatable {
    /// `namespace|value` → the mapping row it belongs to.
    private let byIdentity: [String: AnimeIDMapping]

    public static let empty = AnimeIDBridge(mappings: [])

    public init(mappings: [AnimeIDMapping]) {
        var index: [String: AnimeIDMapping] = [:]
        index.reserveCapacity(mappings.count * 4)
        for mapping in mappings {
            for (namespace, value) in mapping.identities {
                // First write wins. A duplicate key means the dataset maps one
                // id to two rows, which it should not; taking the first keeps
                // this deterministic rather than dependent on ordering.
                let key = Self.key(namespace: namespace, value: value)
                if index[key] == nil { index[key] = mapping }
            }
        }
        byIdentity = index
    }

    public var isEmpty: Bool { byIdentity.isEmpty }
    public var count: Int { byIdentity.count }

    /// The mapping naming `value` in `namespace`, if the dataset knows it.
    public func mapping(
        namespace: ProviderIDNamespace,
        value: String
    ) -> AnimeIDMapping? {
        byIdentity[Self.key(namespace: namespace, value: value)]
    }

    /// Every id equivalent to the ones given, EXCLUDING the ones already known.
    ///
    /// Returns nothing when the ids are unknown to the dataset or already
    /// complete, so a caller can treat "no new ids" as "nothing to do" without
    /// checking twice.
    public func bridgedIdentities(
        for known: [(namespace: ProviderIDNamespace, value: String)]
    ) -> [(namespace: ProviderIDNamespace, value: String)] {
        var seen = Set(known.map { Self.key(namespace: $0.namespace, value: $0.value) })
        var result: [(ProviderIDNamespace, String)] = []
        for identity in known {
            guard let mapping = mapping(
                namespace: identity.namespace,
                value: identity.value
            ) else { continue }
            for bridged in mapping.identities {
                let key = Self.key(namespace: bridged.namespace, value: bridged.value)
                guard seen.insert(key).inserted else { continue }
                result.append(bridged)
            }
        }
        return result
    }

    private static func key(
        namespace: ProviderIDNamespace,
        value: String
    ) -> String {
        // Series-scoped namespaces name the same catalogue as their plain
        // counterpart, so they share a key — a show's TVDb id is its TVDb id
        // whether the row describing it is the series or one of its episodes.
        let canonical: ProviderIDNamespace
        switch namespace {
        case .seriesAniDB: canonical = .aniDB
        case .seriesAniList: canonical = .aniList
        case .seriesMal: canonical = .myAnimeList
        case .seriesTmdb: canonical = .tmdb
        case .seriesTvdb: canonical = .tvdb
        case .seriesImdb: canonical = .imdb
        default: canonical = namespace
        }
        return "\(canonical.rawValue)|\(value)"
    }
}

public extension MediaAliasEvidence {
    /// The same evidence, plus every equivalent id the bridge knows.
    ///
    /// Applied where evidence ENTERS the ledger, so both a tracker's row and a
    /// server's row carry the union of ids before anything tries to match them.
    /// That is what lets the resolver merge them on a shared id rather than on a
    /// title, which it rightly refuses to do — merging "Dr. Stone (2019)" with
    /// another show of that name and year is exactly the mistake the strong-id
    /// rule exists to prevent.
    func bridgingAnimeIdentities(using bridge: AnimeIDBridge) -> MediaAliasEvidence {
        guard !bridge.isEmpty, !strong.isEmpty else { return self }
        let known = strong.map {
            (namespace: $0.namespace, value: $0.value)
        }
        let bridged = bridge.bridgedIdentities(for: known)
        guard !bridged.isEmpty else { return self }
        var combined = strong
        for identity in bridged {
            guard let evidence = MediaAliasStrongEvidence(
                kind: kind,
                namespace: identity.namespace,
                value: identity.value
            ) else { continue }
            combined.append(evidence)
        }
        return MediaAliasEvidence(
            kind: kind,
            strong: combined,
            weak: weak,
            presentation: presentation,
            bindingHints: bindingHints,
            locallyValidatedBindings: locallyValidatedBindings
        ) ?? self
    }
}
