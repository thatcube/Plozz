import Foundation
import CoreModels

/// Persists a bounded snapshot of the last successful Home ``HomeViewModel/Content``
/// **per profile**, so the next launch can paint the hero + Continue Watching (and
/// the rest of Home) *instantly* from the last-known content and then silently
/// refresh from the network — the same stale-while-revalidate pattern
/// `DetailSnapshotCache` uses for detail pages.
///
/// Why this makes launch feel instant: image *bytes* already persist across
/// launches (`ArtworkImageCache` + the on-disk `URLCache`), so once the metadata
/// snapshot is cached too a relaunch repaints Home from disk with no network in
/// the critical path. The live aggregate then swaps fresh content in place with no
/// skeleton flash.
///
/// Security: only already-displayed, non-secret metadata is stored — the same
/// `MediaItem` / `AggregatedLibrary` values that `DetailSnapshotCache` and the
/// artwork caches already write to the Caches directory. Access tokens continue to
/// live only in the Keychain; any token embedded in a Plex *art URL* is already
/// persisted on disk by those existing caches, so this adds no new exposure. A
/// decode failure or a stale file is treated as a cache miss (Home just does a
/// normal load), so a `MediaItem` coding change can never crash a launch.
public protocol HomeContentStoring: Sendable {
    /// The last persisted snapshot, or `nil` on a miss (no file / stale / decode
    /// failure / empty). Read **synchronously** so `HomeViewModel` can hydrate its
    /// initial state at construction. `HomeContentStore` memoizes the first decode,
    /// so the repeated `load()` calls SwiftUI triggers by re-evaluating the inline
    /// `HomeViewModel(...)` on each `HomeTab.body` pass stay O(1) after the first.
    func load() -> HomeViewModel.Content?
    /// Persists `content` (bounded) as the newest snapshot. Synchronous (like
    /// `HomeLayoutStore`): bounded payload, called only a handful of times per
    /// session (never on a scroll/animation hot path), so the atomic write is a
    /// negligible one-off cost and a subsequent `load()` reads it back reliably.
    func save(_ content: HomeViewModel.Content)
}

/// On-disk (`Caches`) store. Per-profile scoped via `SettingsKey.scoped` so each
/// profile paints its own last Home (the primary profile keeps an un-suffixed
/// file). Schema-versioned via the directory name: bump it whenever `MediaItem` /
/// `AggregatedLibrary` coding changes so old snapshots are simply ignored (a
/// decode miss falls back to the network) and their files are reclaimed.
public final class HomeContentStore: HomeContentStoring, @unchecked Sendable {
    private let fileURL: URL?
    private let maxItemsPerRow: Int
    private let maxAge: TimeInterval

    /// Wire format: the bounded content plus the time it was captured (for
    /// `maxAge`). Kept private so the on-disk shape can evolve behind the protocol.
    private struct Stored: Codable {
        var content: HomeViewModel.Content
        var savedAt: Date
    }

    /// **Bump when `MediaItem` / `AggregatedLibrary` coding changes** so devices
    /// with an older snapshot shape start fresh instead of decode-missing forever.
    /// v2: `MediaSourceRef` gained a `kind` field and the merger now drops
    /// cross-kind source refs — bumping evicts snapshots that froze a stale
    /// episode↔movie twin from a pre-fix build.
    private static let schemaDirName = "plozz-home-content-v2"
    private static let schemaDirPrefix = "plozz-home-content"

    /// Process-wide guards. `HomeContentStore` is (re)constructed inline in
    /// `RootView.body` and its `load()` re-run on every `HomeTab.body` pass (the
    /// inline `HomeViewModel(...)` argument is re-evaluated even though `@State`
    /// keeps only the first instance). To stop that from repeatedly hitting the
    /// main-thread filesystem, we (a) run the one-time superseded-schema cleanup
    /// only once per process, and (b) memoize the decoded snapshot per file path —
    /// the first `load()` reads disk, the rest are O(1). Serving the first decode on
    /// repeat calls is correct: only the very first `load()` (first VM construction)
    /// is ever used; later ones are discarded by `@State`.
    private static let lock = NSLock()
    private static var didCleanup = false
    private static var memo: [String: HomeViewModel.Content?] = [:]

    public init(
        namespace: String? = nil,
        directory: URL? = HomeContentStore.defaultDirectory(),
        maxItemsPerRow: Int = 30,
        maxAge: TimeInterval = 60 * 60 * 24 * 14
    ) {
        self.maxItemsPerRow = maxItemsPerRow
        self.maxAge = maxAge
        guard let directory else {
            self.fileURL = nil
            return
        }
        let dir = directory.appendingPathComponent(Self.schemaDirName, isDirectory: true)
        // Run the superseded-schema cleanup at most once per process (it's a global
        // one-time cleanup, not per-instance), so repeated construction never
        // re-enumerates the Caches directory on the main thread. The live directory
        // is created lazily in `save()` (a `load()` on a missing dir just misses).
        Self.cleanupSupersededCachesOnce(besideSchemaDirIn: directory)
        // Per-profile filename: default profile keeps the un-suffixed base.
        let name = SettingsKey.scoped("home-content", namespace: namespace)
        let safe = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        self.fileURL = dir.appendingPathComponent(safe).appendingPathExtension("json")
    }

    public func load() -> HomeViewModel.Content? {
        guard let fileURL else { return nil }
        let key = fileURL.path
        Self.lock.lock()
        if let cached = Self.memo[key] {
            Self.lock.unlock()
            return cached
        }
        Self.lock.unlock()

        let result = readSnapshot(at: fileURL)
        Self.lock.lock()
        // `updateValue` (not `memo[key] = result`) so a MISS is stored as a present
        // entry with a nil value — a bare `memo[key] = nil` would instead remove the
        // key and re-miss forever. Distinguishing "cached miss" from "never loaded"
        // is what makes repeated misses O(1) too.
        Self.memo.updateValue(result, forKey: key)
        Self.lock.unlock()
        return result
    }

    /// The one genuine disk read+decode for `load()`. Honors `maxAge` (deleting a
    /// stale file) and treats an empty snapshot as a miss.
    private func readSnapshot(at fileURL: URL) -> HomeViewModel.Content? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(Stored.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(stored.savedAt) < maxAge else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return stored.content.isEmpty ? nil : stored.content
    }

    public func save(_ content: HomeViewModel.Content) {
        guard let fileURL else { return }
        let stored = Stored(content: content.bounded(perRow: maxItemsPerRow), savedAt: Date())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        // Create the schema dir lazily here (not per-init), then write atomically.
        try? FileManager.default.createDirectory(
            at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try? data.write(to: fileURL, options: .atomic)
        // Invalidate the memo so the next `load()` re-reads the fresh snapshot from
        // disk (rather than serving a stale cached decode). Repeated loads WITHOUT
        // an intervening save still hit the memo — that's the hot path we optimize.
        Self.lock.lock()
        Self.memo.removeValue(forKey: fileURL.path)
        Self.lock.unlock()
    }

    /// Drops sibling schema dirs left by earlier versions so a bump reclaims their
    /// files instead of leaking them (mirrors `DetailSnapshotCache`). Runs at most
    /// once per process.
    private static func cleanupSupersededCachesOnce(besideSchemaDirIn parent: URL) {
        lock.lock()
        if didCleanup { lock.unlock(); return }
        didCleanup = true
        lock.unlock()
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { return }
        for dir in dirs where dir.lastPathComponent != schemaDirName
            && dir.lastPathComponent.hasPrefix(schemaDirPrefix) {
            try? FileManager.default.removeItem(at: dir)
        }
    }

    public static func defaultDirectory() -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    }
}

/// In-memory store for tests and previews — round-trips within the instance but
/// never touches disk.
public final class InMemoryHomeContentStore: HomeContentStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var content: HomeViewModel.Content?

    public init(_ initial: HomeViewModel.Content? = nil) {
        self.content = initial
    }

    public func load() -> HomeViewModel.Content? {
        lock.lock(); defer { lock.unlock() }
        return content.flatMap { $0.isEmpty ? nil : $0 }
    }

    public func save(_ content: HomeViewModel.Content) {
        lock.lock(); defer { lock.unlock() }
        self.content = content
    }
}

/// No-op store: never reads or writes. The default for `HomeViewModel` so tests
/// and previews stay isolated (production explicitly injects a `HomeContentStore`).
public final class NoOpHomeContentStore: HomeContentStoring, @unchecked Sendable {
    public init() {}
    public func load() -> HomeViewModel.Content? { nil }
    public func save(_ content: HomeViewModel.Content) {}
}
