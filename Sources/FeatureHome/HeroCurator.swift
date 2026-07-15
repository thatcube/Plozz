import Foundation
import CoreModels

public typealias HeroArtworkProviding = @Sendable (MediaItem) async -> URL?

public enum HeroArtworkProvider {
    public static let none: HeroArtworkProviding = { _ in nil }
}

/// Confirms a candidate's ordered hero artwork URLs can actually produce a usable
/// full-bleed image before the curator admits its slide. The hero is built
/// entirely around full-screen artwork, so a title whose only "art" is a broken or
/// missing URL must be dropped rather than shown over the bare app background.
public typealias HeroArtworkValidating = @Sendable ([URL]) async -> Bool

public enum HeroArtworkValidator {
    /// Presence-only eligibility: any candidate URL counts. This preserves the
    /// pure curator's original behavior (and keeps tests deterministic); the app
    /// injects a real image-load check so unrenderable art is filtered out.
    public static let presence: HeroArtworkValidating = { !$0.isEmpty }
}

/// Builds the ordered list of items the Home **hero** carousel rotates through,
/// mixing the user's enabled sources (Featured/Seerr, Continue Watching, Random,
/// Watchlist) per their per-profile ``HeroSettings``.
///
/// The *ranking/composition* step is deliberately isolated behind
/// ``HeroRankingStrategy`` so a future "smart"/personalized strategy is a
/// drop-in replacement — the curator's job is only to gather each source's
/// candidates (fetching the async ones concurrently) and hand them to a
/// strategy that interleaves + de-duplicates + caps them. Pure and testable: no
/// SwiftUI, no provider types beyond the injected closures.
public struct HeroCurator: Sendable {
    private let strategy: HeroRankingStrategy

    public init(strategy: HeroRankingStrategy = InterleaveHeroStrategy()) {
        self.strategy = strategy
    }

    /// Produces the ordered hero items.
    ///
    /// - `continueWatching` / `watchlist`: already-aggregated Home content
    ///   (both providers, cross-server merged) — passed in, not fetched.
    /// - `featuredProvider`: the Seerr seam — returns `[]` until Seerr exists.
    /// - `randomLibraries`: the already-loaded, settings-filtered library containers
    ///   available to the Random source.
    /// - `randomProvider`: random-from-library fetch across both providers.
    ///
    /// The featured and random sources are fetched **concurrently** (and only
    /// when their source is enabled) so an offline Seerr or a slow random query
    /// never serializes the other.
    public func curate(
        settings: HeroSettings,
        continueWatching: [MediaItem],
        watchlist: [MediaItem],
        randomLibraries: [HeroRandomLibrary] = [],
        watchMutations: [MediaItemMutation] = [],
        featuredProvider: FeaturedContentProviding = HeroFeaturedProvider.none,
        randomProvider: RandomLibraryContentProviding = HeroRandomProvider.none,
        artworkProvider: @escaping HeroArtworkProviding = HeroArtworkProvider.none,
        artworkValidator: @escaping HeroArtworkValidating = HeroArtworkValidator.presence
    ) async -> [MediaItem] {
        guard settings.isActive else { return [] }
        let limit = settings.maxItems

        // Fetch the async sources up front (concurrently), guarded on being
        // enabled so we never pay for a source the user turned off.
        async let featuredItems: [MediaItem] = settings.isEnabled(.featured)
            ? featuredProvider(limit) : []
        async let randomItems: [MediaItem] = settings.isEnabled(.randomFromLibrary)
            ? randomProvider(randomLibraries, limit) : []

        let featured = await featuredItems
        let random = await randomItems

        // Filter before artwork resolution so rejected watched titles never spend
        // router/cache/network work finding a full-bleed backdrop.
        let perSource: [[MediaItem]] = settings.sources.map { source in
            switch source {
            case .featured: return featured
            case .continueWatching: return continueWatching
            case .randomFromLibrary: return random
            case .watchlist: return watchlist
            }
        }.map {
            HeroWatchEligibility.filter(
                $0,
                settings: settings,
                mutations: watchMutations
            )
        }

        let eligible = await HeroArtworkEligibility.resolve(
            perSource,
            limitPerSource: limit,
            artworkProvider: artworkProvider,
            validate: artworkValidator
        )
        return strategy.compose(eligible, limit: limit)
    }

    /// A **synchronous** seed built only from the already-loaded, non-async
    /// sources (Continue Watching + Watchlist). Featured (Seerr) and Random are
    /// treated as empty here because they require an `await` fetch.
    ///
    /// Home renders this instantly the moment its content is available so the
    /// hero appears in the *same frame* as the rest of the page (no pop-in), then
    /// ``curate(settings:continueWatching:watchlist:featuredProvider:randomProvider:)``
    /// refines it with the async sources. When no async sources are enabled the
    /// seed already equals the final result, so nothing visibly changes.
    public func curateSync(
        settings: HeroSettings,
        continueWatching: [MediaItem],
        watchlist: [MediaItem],
        watchMutations: [MediaItemMutation] = []
    ) -> [MediaItem] {
        guard settings.isActive else { return [] }
        let perSource: [[MediaItem]] = settings.sources.map { source in
            switch source {
            case .featured, .randomFromLibrary: return []
            case .continueWatching: return continueWatching
            case .watchlist: return watchlist
            }
        }.map {
            HeroWatchEligibility.filter(
                $0,
                settings: settings,
                mutations: watchMutations
            )
        }

        return strategy.compose(
            HeroArtworkEligibility.filterDirect(perSource),
            limit: settings.maxItems
        )
    }

    /// Reapplies current watched-state intent to an already-curated Hero while an
    /// async watch-history refresh is in flight. The candidate set and artwork stay
    /// stable, so focus is preserved, but a newly watched title cannot linger.
    public func reconcile(
        _ items: [MediaItem],
        settings: HeroSettings?,
        watchMutations: [MediaItemMutation]
    ) -> [MediaItem] {
        guard let settings, settings.isActive else { return [] }
        return HeroWatchEligibility.filter(
            items,
            settings: settings,
            mutations: watchMutations
        )
    }

    private enum HeroWatchEligibility {
        static func filter(
            _ items: [MediaItem],
            settings: HeroSettings,
            mutations: [MediaItemMutation]
        ) -> [MediaItem] {
            let reconciled = mutations.reduce(items) { current, mutation in
                current.map { mutation.applied(to: $0) }
            }
            guard settings.hideWatched else { return reconciled }
            return reconciled.filter { item in
                switch item.kind {
                case .movie, .series, .episode:
                    return !item.hasBeenPlayed
                default:
                    return true
                }
            }
        }
    }
}

/// Keeps poster-only or artwork-free items out of the full-bleed hero. Parent
/// backdrops remain eligible so episodes can use their series artwork.
private enum HeroArtworkEligibility {
    static func filterDirect(_ perSource: [[MediaItem]]) -> [[MediaItem]] {
        perSource.map { items in
            items.filter(hasDirectHeroArtwork)
        }
    }

    static func resolve(
        _ perSource: [[MediaItem]],
        limitPerSource: Int,
        artworkProvider: @escaping HeroArtworkProviding,
        validate: @escaping HeroArtworkValidating = HeroArtworkValidator.presence
    ) async -> [[MediaItem]] {
        guard limitPerSource > 0 else {
            return Array(repeating: [], count: perSource.count)
        }
        return await withTaskGroup(of: (Int, [MediaItem]).self) { group in
            for (sourceIndex, items) in perSource.enumerated() {
                group.addTask {
                    var eligible: [MediaItem] = []
                    eligible.reserveCapacity(min(items.count, limitPerSource))
                    var seen = Set<String>()

                    for item in items {
                        guard !Task.isCancelled else { break }
                        let tokens = HeroDedupe.tokens(for: item)
                        guard !tokens.contains(where: seen.contains) else { continue }

                        // Admit the slide only if it can actually render a usable
                        // full-bleed image. A non-nil URL isn't proof — a broken or
                        // missing backdrop would leave the hero showing the bare app
                        // background. Try the item's own art first, then the async
                        // provider (TMDb) as a fallback, and drop it when neither
                        // yields a usable hero image.
                        var candidate = item
                        var usable = await validate(heroArtworkURLs(for: candidate))
                        if !usable, let resolvedURL = await artworkProvider(item) {
                            candidate.heroBackdropURL = resolvedURL
                            usable = await validate(heroArtworkURLs(for: candidate))
                        }

                        guard !Task.isCancelled else { break }
                        if usable {
                            seen.formUnion(tokens)
                            eligible.append(candidate)
                            if eligible.count == limitPerSource { break }
                        }
                    }

                    return (sourceIndex, eligible)
                }
            }

            var resolved = Array(repeating: [MediaItem](), count: perSource.count)
            for await (sourceIndex, items) in group {
                resolved[sourceIndex] = items
            }
            return resolved
        }
    }

    /// The candidate's ordered hero backdrop URLs, mirroring the view's
    /// `primaryBackdropURLs`: server hero art, then wide backdrop, then the
    /// parent/fallback backdrop an episode borrows from its series.
    private static func heroArtworkURLs(for item: MediaItem) -> [URL] {
        [item.heroBackdropURL, item.backdropURL, item.fallbackArtworkURL].compactMap { $0 }
    }

    private static func hasDirectHeroArtwork(_ item: MediaItem) -> Bool {
        item.heroBackdropURL != nil ||
            item.backdropURL != nil ||
            item.fallbackArtworkURL != nil
    }
}

/// The composition/ranking step of hero curation. Swappable so a future
/// "smart"/personalized ordering can replace the default without touching the
/// curator or its call sites.
public protocol HeroRankingStrategy: Sendable {
    /// Composes the final ordered hero list from per-source candidate lists
    /// (already in the user's configured source order), de-duplicating across
    /// sources and capping at `limit`.
    func compose(_ perSource: [[MediaItem]], limit: Int) -> [MediaItem]
}

/// Default strategy: **round-robin interleave** across sources so every enabled
/// source gets fair, near-the-top representation (source 0's first item, then
/// source 1's first, …, then source 0's second, …), de-duplicated across
/// sources and capped at `limit`. When only one source has content (e.g. only
/// Seerr `.featured` is populated) the result is simply that source's items.
public struct InterleaveHeroStrategy: HeroRankingStrategy {
    public init() {}

    public func compose(_ perSource: [[MediaItem]], limit: Int) -> [MediaItem] {
        guard limit > 0 else { return [] }
        var result: [MediaItem] = []
        var seen = Set<String>()
        let maxLen = perSource.map(\.count).max() ?? 0
        for offset in 0..<maxLen {
            for source in perSource where offset < source.count {
                let item = source[offset]
                let tokens = HeroDedupe.tokens(for: item)
                if tokens.contains(where: seen.contains) { continue }
                seen.formUnion(tokens)
                result.append(item)
                if result.count == limit { return result }
            }
        }
        return result
    }
}

/// Cross-source de-duplication for the hero, reusing the app's one shared
/// identity definition (``MediaItemIdentity``) so the same title appearing in,
/// say, both Continue Watching and Watchlist collapses to a single hero slide.
enum HeroDedupe {
    /// Identity tokens for `item`: its strong external / title identities plus a
    /// raw-id fallback (so items with no resolvable identity still de-dupe with
    /// an exact same-server twin). Two items are "the same" when any token
    /// overlaps.
    static func tokens(for item: MediaItem) -> Set<String> {
        let accountScope = item.sourceAccountID ?? "unscoped"
    var tokens: Set<String> = ["id:\(item.kind.rawValue):\(accountScope):\(item.id)"]
        for identity in MediaItemIdentity.identities(for: item) {
            switch identity {
            case let .external(source, value):
                tokens.insert("ext:\(item.kind.rawValue):\(source):\(value)")
            case let .title(normalizedTitle, year, kind):
                tokens.insert("title:\(normalizedTitle):\(year.map(String.init) ?? "?"):\(kind.rawValue)")
            case let .sameItemID(value):
                tokens.insert("id:\(item.kind.rawValue):\(value)")
            }
        }
        return tokens
    }
}
