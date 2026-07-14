import Foundation
import CoreModels

/// Bounds how many candidates a watched-heavy async hero source (Featured/Random)
/// requests so it can refill after filtering without flooding provider detail work.
public enum HeroCandidatePool {
    /// Keep enough candidates to refill a watched-heavy source while bounding
    /// provider detail work and preserving the exact old request when filtering
    /// is disabled.
    public static func requestLimit(finalLimit: Int, hideWatched: Bool) -> Int {
        guard finalLimit > 0 else { return 0 }
        guard hideWatched else { return finalLimit }
        return min(48, max(12, finalLimit * 2))
    }
}

/// Folds live provider watch history onto discovery-only items (e.g. Seerr
/// trending, which carries no per-profile watch state). Identity index membership
/// avoids searches; bounded item-detail fetches supply current profile watch state
/// without allowing multi-server setups to flood networking.
///
/// Pure domain logic: it takes injected `sourceRefs`/`fetch` closures and touches
/// no provider or app-shell types, so it lives beside `HeroCurator` in FeatureHome
/// rather than in the composition root.
public enum HeroCandidateWatchStateEnricher {
    private struct Job: Sendable {
        let itemIndex: Int
        let source: MediaSourceRef
    }

    private struct FetchedState: Sendable {
        let itemIndex: Int
        let source: MediaSourceRef
        let item: MediaItem?
    }

    private static let maxConcurrentFetches = 4

    public static func enrich(
        _ items: [MediaItem],
        enabled: Bool = true,
        sourceRefs: @escaping @Sendable (MediaItem) -> [MediaSourceRef],
        fetch: @escaping @Sendable (MediaSourceRef) async -> MediaItem?
    ) async -> [MediaItem] {
        guard enabled else { return items }
        var jobs: [Job] = []
        for (itemIndex, item) in items.enumerated() where !item.hasBeenPlayed {
            var seen = Set<String>()
            for source in sourceRefs(item) where seen.insert(source.id).inserted {
                jobs.append(Job(itemIndex: itemIndex, source: source))
            }
        }
        guard !jobs.isEmpty else { return items }

        let fetched = await withTaskGroup(
            of: FetchedState.self,
            returning: [[FetchedState]].self
        ) { group in
            let concurrency = min(maxConcurrentFetches, jobs.count)
            var nextJob = 0
            for _ in 0..<concurrency {
                let job = jobs[nextJob]
                nextJob += 1
                group.addTask {
                    FetchedState(
                        itemIndex: job.itemIndex,
                        source: job.source,
                        item: await fetch(job.source)
                    )
                }
            }

            var byItem = Array(repeating: [FetchedState](), count: items.count)
            while let state = await group.next() {
                byItem[state.itemIndex].append(state)
                if nextJob < jobs.count, !Task.isCancelled {
                    let job = jobs[nextJob]
                    nextJob += 1
                    group.addTask {
                        FetchedState(
                            itemIndex: job.itemIndex,
                            source: job.source,
                            item: await fetch(job.source)
                        )
                    }
                }
            }
            return byItem
        }
        guard !Task.isCancelled else { return [] }

        var enriched = items
        for index in enriched.indices where !fetched[index].isEmpty {
            let successful = fetched[index].compactMap(\.item)
            if !successful.isEmpty {
                enriched[index].hasBeenPlayed = enriched[index].hasBeenPlayed
                    || successful.contains(where: \.hasBeenPlayed)
            }
            var refsByID = Dictionary(
                enriched[index].sources.map { ($0.id, $0) },
                uniquingKeysWith: { first, _ in first }
            )
            for state in fetched[index] {
                var ref = state.source
                if let item = state.item {
                    ref.resumePosition = item.resumePosition
                    ref.playedPercentage = item.playedPercentage
                    ref.isPlayed = item.isPlayed
                    ref.hasBeenPlayed = item.hasBeenPlayed
                    ref.isFavorite = item.isFavorite
                    ref.lastPlayedAt = item.lastPlayedAt
                }
                refsByID[ref.id] = ref
            }
            enriched[index].sources = refsByID.values.sorted { $0.id < $1.id }
        }
        return enriched
    }
}
