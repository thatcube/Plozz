import CoreModels
import Foundation
import RatingsService

/// Hydrates sparse hero list records before they are published to a carousel.
///
/// List endpoints omit fields such as taglines and overviews. Waiting until a
/// slide becomes selected to fetch those fields makes its visible description
/// change after arrival, so both platform shells run this bounded enrichment
/// before merging a fresh curation into the live set.
public struct HeroMetadataEnricher: Sendable {
    private struct Enrichment: Sendable {
        let root: MediaItem
        let playTarget: MediaItem?
    }

    private let providersByAccount: [String: any MediaProvider]
    private let targetSelector: @Sendable (MediaItem) -> MediaItem
    private let ratingsProvider: any ExternalRatingsProviding

    public init(
        accounts: [ResolvedAccount],
        targetSelector: @escaping @Sendable (MediaItem) -> MediaItem,
        ratingsProvider: any ExternalRatingsProviding = DisabledRatingsProvider()
    ) {
        providersByAccount = Dictionary(
            accounts.map { ($0.account.id, $0.provider) },
            uniquingKeysWith: { first, _ in first }
        )
        self.targetSelector = targetSelector
        self.ratingsProvider = ratingsProvider
    }

    public func enrich(_ items: [MediaItem]) async -> [MediaItem] {
        let targets = Dictionary(
            uniqueKeysWithValues: items.indices.compactMap { index -> (Int, MediaItem)? in
                let item = items[index]
                guard item.kind == .series
                        || item.kind == .episode
                        || item.officialRating?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty != false
                        || item.productionYear == nil
                        || item.overview?
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty != false
                        || item.taglines.isEmpty else {
                    return nil
                }
                let target = targetSelector(item)
                guard let accountID = target.sourceAccountID,
                      providersByAccount[accountID] != nil else {
                    return nil
                }
                return (index, target)
            }
        )
        let candidates = targets.keys.sorted()
        guard !candidates.isEmpty else {
            return await applyingCachedRatings(to: items)
        }

        let concurrency = min(4, candidates.count)
        let details = await withTaskGroup(
            of: (Int, Enrichment?).self,
            returning: [Int: Enrichment].self
        ) { group in
            var next = 0
            for _ in 0..<concurrency {
                let index = candidates[next]
                next += 1
                guard let target = targets[index],
                      let accountID = target.sourceAccountID,
                      let provider = providersByAccount[accountID] else {
                    continue
                }
                group.addTask {
                    (
                        index,
                        await resolve(
                            target: target,
                            provider: provider,
                            accountID: accountID
                        )
                    )
                }
            }

            var result: [Int: Enrichment] = [:]
            while let (index, detail) = await group.next() {
                if let detail {
                    result[index] = detail
                }
                if next < candidates.count, !Task.isCancelled {
                    let queuedIndex = candidates[next]
                    next += 1
                    guard let target = targets[queuedIndex],
                          let accountID = target.sourceAccountID,
                          let provider = providersByAccount[accountID] else {
                        continue
                    }
                    group.addTask {
                        (
                            queuedIndex,
                            await resolve(
                                target: target,
                                provider: provider,
                                accountID: accountID
                            )
                        )
                    }
                }
            }
            return result
        }
        guard !Task.isCancelled else {
            return items
        }

        var enriched = items
        for (index, detail) in details {
            let originalProviderIDs = enriched[index].providerIDs
            let originalCarriesSeriesIDs = enriched[index].kind == .series
            if var playTarget = detail.playTarget {
                if playTarget.sourceAccountID == nil,
                   let sourceAccountID = detail.root.sourceAccountID {
                    playTarget = playTarget.taggingSource(sourceAccountID)
                }
                enriched[index] = playTarget
            }
            let root = detail.root
            if enriched[index].kind == .episode {
                enriched[index].providerIDs.mergeSeriesProviderIDs(
                    from: root.providerIDs
                )
                enriched[index].providerIDs.mergeSeriesProviderIDs(
                    from: originalProviderIDs,
                    promotingBaseIDs: originalCarriesSeriesIDs
                )
                enriched[index].parentTitle = root.title
                enriched[index].seriesID = root.id
                enriched[index].officialRating = root.officialRating
                enriched[index].genres = root.genres
                enriched[index].overview = root.overview
                enriched[index].taglines = root.taglines
                enriched[index].ratings = root.ratings
                enriched[index].people = root.people
                enriched[index].studios = root.studios
                enriched[index].logoURL = root.logoURL
                enriched[index].heroBackdropURL = root.heroBackdropURL
                enriched[index].backdropURL = root.backdropURL
                enriched[index].fallbackArtworkURL = root.fallbackArtworkURL
                enriched[index].artworkSelections = root.artworkSelections
                continue
            }
            if enriched[index].officialRating?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false {
                enriched[index].officialRating = root.officialRating
            }
            if enriched[index].productionYear == nil {
                enriched[index].productionYear = root.productionYear
            }
            if enriched[index].releaseDate == nil {
                enriched[index].releaseDate = root.releaseDate
            }
            if enriched[index].genres.isEmpty {
                enriched[index].genres = root.genres
            }
            if enriched[index].overview?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .isEmpty != false {
                enriched[index].overview = root.overview
            }
            if enriched[index].taglines.isEmpty {
                enriched[index].taglines = root.taglines
            }
            if enriched[index].ratings.isEmpty {
                enriched[index].ratings = root.ratings
            }
            if enriched[index].people.isEmpty {
                enriched[index].people = root.people
            }
            if enriched[index].studios.isEmpty {
                enriched[index].studios = root.studios
            }
        }
        return await applyingCachedRatings(to: enriched)
    }

    private func resolve(
        target: MediaItem,
        provider: any MediaProvider,
        accountID: String
    ) async -> Enrichment? {
        guard var hydratedTarget = try? await provider.item(id: target.id) else {
            return nil
        }
        if hydratedTarget.sourceAccountID == nil {
            hydratedTarget = hydratedTarget.taggingSource(accountID)
        }

        if hydratedTarget.kind == .season {
            guard let seriesID = hydratedTarget.seriesID,
                  var root = try? await provider.item(id: seriesID) else {
                return nil
            }
            if root.sourceAccountID == nil {
                root = root.taggingSource(accountID)
            }
            var playTarget = await HeroPlayTargetResolver.resolve(
                item: hydratedTarget,
                provider: provider
            )
            if playTarget?.sourceAccountID == nil {
                playTarget = playTarget?.taggingSource(accountID)
            }
            return Enrichment(root: root, playTarget: playTarget)
        }

        if hydratedTarget.kind == .episode {
            guard let seriesID = hydratedTarget.seriesID,
                  var root = try? await provider.item(id: seriesID) else {
                return nil
            }
            if root.sourceAccountID == nil {
                root = root.taggingSource(accountID)
            }
            return Enrichment(root: root, playTarget: hydratedTarget)
        }

        if hydratedTarget.kind.needsPlaybackTargetResolution {
            var playTarget = await HeroPlayTargetResolver.resolve(
                item: hydratedTarget,
                provider: provider
            )
            if playTarget?.sourceAccountID == nil {
                playTarget = playTarget?.taggingSource(accountID)
            }
            return Enrichment(root: hydratedTarget, playTarget: playTarget)
        }

        return Enrichment(root: hydratedTarget, playTarget: nil)
    }

    private func applyingCachedRatings(to items: [MediaItem]) async -> [MediaItem] {
        guard let cachedProvider =
            ratingsProvider as? any CachedExternalRatingsProviding else {
            return items
        }
        var enriched = items
        for index in enriched.indices {
            guard let cached = await cachedProvider.cachedRatings(for: enriched[index]),
                  !cached.isEmpty else {
                continue
            }
            enriched[index].ratings =
                enriched[index].ratings.mergedWithAuthoritative(cached)
        }
        return enriched
    }
}
