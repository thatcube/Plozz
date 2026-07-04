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
    /// initial state at construction; the file is bounded (small) so this is cheap.
    func load() -> HomeViewModel.Content?
    /// Persists `content` (bounded) as the newest snapshot. Fire-and-forget: the
    /// write runs off the caller's thread so it never blocks a load or the UI.
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
    private static let schemaDirName = "plozz-home-content-v1"
    private static let schemaDirPrefix = "plozz-home-content"

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
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        Self.removeSupersededCaches(besideSchemaDirIn: directory)
        // Per-profile filename: default profile keeps the un-suffixed base.
        let name = SettingsKey.scoped("home-content", namespace: namespace)
        let safe = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        self.fileURL = dir.appendingPathComponent(safe).appendingPathExtension("json")
    }

    public func load() -> HomeViewModel.Content? {
        guard let fileURL,
              let data = try? Data(contentsOf: fileURL),
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
        // Written synchronously (like `HomeLayoutStore`): the payload is bounded
        // (small) and `save` is only called once per successful load — never on a
        // scroll/animation hot path — so the atomic write is a negligible, one-off
        // cost, and keeping it synchronous makes the store trivially testable.
        let stored = Stored(content: content.bounded(perRow: maxItemsPerRow), savedAt: Date())
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    /// Drops sibling schema dirs left by earlier versions so a bump reclaims their
    /// files instead of leaking them (mirrors `DetailSnapshotCache`).
    private static func removeSupersededCaches(besideSchemaDirIn parent: URL) {
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
