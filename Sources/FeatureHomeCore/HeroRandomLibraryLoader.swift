import CoreModels
import Foundation

/// Bounded, order-independent Random source fan-out shared by every Home UI.
public enum HeroRandomLibraryLoader {
    private static let maxConcurrentFetches = 4

    public static func requestLimit(
        totalLimit: Int,
        libraryCount: Int
    ) -> Int {
        guard totalLimit > 0, libraryCount > 0 else { return 0 }
        let desiredPool = max(12, Int((Double(totalLimit) * 1.5).rounded(.up)))
        let distributed = Int(
            (Double(desiredPool) / Double(libraryCount)).rounded(.up)
        )
        return min(max(totalLimit, 12), max(2, distributed))
    }

    public static func load(
        libraries: [HeroRandomLibrary],
        limit: Int,
        fetch: @escaping @Sendable (HeroRandomLibrary, Int) async -> [MediaItem]
    ) async -> [MediaItem] {
        guard limit > 0 else { return [] }
        var seen = Set<HeroRandomLibrary>()
        let eligible = libraries.filter { library in
            guard library.kind == .movie || library.kind == .series else {
                return false
            }
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

            var byIndex = Array<[MediaItem]?>(
                repeating: nil,
                count: eligible.count
            )
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
