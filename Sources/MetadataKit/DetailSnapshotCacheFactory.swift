import Foundation

/// Maps a ``DetailSnapshotCacheScope`` to exactly one ``DetailSnapshotCache``
/// instance, memoized by the scope's directory digest.
///
/// A single factory is owned for the lifetime of the app shell (as SwiftUI
/// `@State`), so every detail destination that asks for the *same* scope receives
/// the *same* cache instance — the caches are not reconstructed on each view
/// re-render, and a burst of detail opens under one identity share one prune
/// lifecycle. Asking for a *different* scope lazily creates a new cache rooted at
/// that scope's own `plozz-detail-cache-v3/<digest>` subdirectory, so identities
/// stay isolated on disk.
///
/// `@MainActor`-isolated: the memoization map is mutated only from the main actor
/// (the app shell), so it needs no additional locking.
@MainActor
public final class DetailSnapshotCacheFactory {
    private let baseDirectory: URL?
    private let makeCache: (URL?, String) -> DetailSnapshotCache
    private var caches: [String: DetailSnapshotCache] = [:]

    public init(baseDirectory: URL? = DetailSnapshotCache.defaultDirectory()) {
        self.baseDirectory = baseDirectory
        self.makeCache = { base, scope in
            DetailSnapshotCache(directory: base, scope: scope)
        }
    }

    /// Test seam: inject the cache constructor so a test can observe scoping /
    /// memoization without touching the real caches directory.
    init(
        baseDirectory: URL?,
        makeCache: @escaping (URL?, String) -> DetailSnapshotCache
    ) {
        self.baseDirectory = baseDirectory
        self.makeCache = makeCache
    }

    /// The cache for `scope`, creating (and memoizing) one on first request.
    /// Repeated calls with an equal scope return the identical instance.
    public func cache(for scope: DetailSnapshotCacheScope) -> DetailSnapshotCache {
        if let existing = caches[scope.directoryComponent] {
            return existing
        }
        let cache = makeCache(baseDirectory, scope.directoryComponent)
        caches[scope.directoryComponent] = cache
        return cache
    }
}
