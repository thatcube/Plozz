#if canImport(SwiftUI)
import SwiftUI
import CoreModels
import CoreUI
import FeatureHome
import FeatureMusic
import FeaturePlayback
import MediaTransportCore
import MetadataKit
import FeatureSearch
import FeatureSettings
import FeatureProfiles
import ProviderTrailers
import RatingsService
import TraktService
import SeerService
import SimklService
import AniListService
import MALService
import LastFmService

/// Bounded, order-independent Random source fan-out. A typical Movies + TV setup
/// now issues both native random queries concurrently instead of serially, while a
/// large multi-server library set cannot flood the interactive networking pool.
enum HeroRandomLibraryLoader {
    private static let maxConcurrentFetches = 4

    static func requestLimit(totalLimit: Int, libraryCount: Int) -> Int {
        guard totalLimit > 0, libraryCount > 0 else { return 0 }
        let desiredPool = max(12, Int((Double(totalLimit) * 1.5).rounded(.up)))
        let distributed = Int((Double(desiredPool) / Double(libraryCount)).rounded(.up))
        return min(max(totalLimit, 12), max(2, distributed))
    }

    static func load(
        libraries: [HeroRandomLibrary],
        limit: Int,
        fetch: @escaping @Sendable (HeroRandomLibrary, Int) async -> [MediaItem]
    ) async -> [MediaItem] {
        guard limit > 0 else { return [] }
        var seen = Set<HeroRandomLibrary>()
        let eligible = libraries.filter { library in
            guard library.kind == .movie || library.kind == .series else { return false }
            return seen.insert(library).inserted
        }
        guard !eligible.isEmpty else { return [] }

        let perLibraryLimit = requestLimit(
            totalLimit: limit,
            libraryCount: eligible.count
        )
        let concurrency = min(maxConcurrentFetches, eligible.count)
        let chunks = await withTaskGroup(
            of: (Int, [MediaItem]).self,
            returning: [[MediaItem]].self
        ) { group in
            var nextIndex = 0
            for _ in 0..<concurrency {
                let index = nextIndex
                nextIndex += 1
                let library = eligible[index]
                group.addTask {
                    (index, await fetch(library, perLibraryLimit))
                }
            }

            var byIndex = Array<[MediaItem]?>(repeating: nil, count: eligible.count)
            while let (index, items) = await group.next() {
                byIndex[index] = items
                if nextIndex < eligible.count, !Task.isCancelled {
                    let queuedIndex = nextIndex
                    nextIndex += 1
                    let library = eligible[queuedIndex]
                    group.addTask {
                        (queuedIndex, await fetch(library, perLibraryLimit))
                    }
                }
            }
            return byIndex.compactMap { $0 }
        }
        guard !Task.isCancelled else { return [] }
        return Array(chunks.flatMap { $0 }.shuffled().prefix(limit))
    }
}
#endif
