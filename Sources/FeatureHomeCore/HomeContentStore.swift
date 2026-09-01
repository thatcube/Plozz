import Foundation
import CoreModels

/// Persists a bounded snapshot of the last successful Home ``HomeViewModel/Content``
/// **per profile**, so the next launch can paint stable rows immediately while
/// volatile Continue Watching remains a geometry-matched placeholder until the
/// fresh multi-server aggregate arrives. Featured-only heroes have their own
/// curated snapshot below; mixed/local heroes wait for complete fresh curation.
/// `DetailSnapshotCache` uses for detail pages.
///
/// Why this makes launch feel instant: image *bytes* already persist across
/// launches (`ArtworkImageCache` + the on-disk `URLCache`), so once the metadata
/// snapshot is cached too a relaunch repaints stable Home content from disk with no
/// network in the critical path. Volatile content publishes once when confirmed.
///
/// Security: only already-displayed, non-secret metadata is stored — the same
/// `MediaItem` / `AggregatedLibrary` values that `DetailSnapshotCache` and the
/// artwork caches already write to the Caches directory. Access tokens continue to
/// live only in the Keychain; every artwork URL is stripped of credentials before
/// encoding and re-signed from the active provider at render time. A decode failure
/// or stale file is treated as a cache miss (Home just does a normal load), so a
/// `MediaItem` coding change can never crash a launch.
public protocol HomeContentStoring: AnyObject, Sendable {
    /// Stable identity for ordering asynchronous writes. On-disk stores use their
    /// profile-scoped file path so replacement view models share one write stream.
    var persistenceScope: String { get }
    /// The last persisted snapshot, or `nil` on a miss (no file / stale / decode
    /// failure / empty). Read **synchronously** so `HomeViewModel` can hydrate its
    /// initial state at construction. `HomeContentStore` memoizes the first decode,
    /// so the repeated `load()` calls SwiftUI triggers by re-evaluating the inline
    /// `HomeViewModel(...)` on each `HomeTab.body` pass stay O(1) after the first.
    func load() -> HomeViewModel.Content?
    /// Persists `content` (bounded) as the newest snapshot. The store operation is
    /// synchronous; callers dispatch it away from interaction-critical actors.
    func save(_ content: HomeViewModel.Content)
    /// Last fully curated hero for the same profile and source configuration.
    /// Kept separate from Home rows because Featured/Random are asynchronous
    /// sources and are not part of ``HomeViewModel/Content``.
    func loadHero(for key: HeroConfigurationKey) -> [MediaItem]?
    func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey)
    /// Discards the hero snapshot.
    ///
    /// `saveHero` refuses to write an empty set, so that a failed refresh cannot
    /// erase a good one. Genuinely running out of content is the opposite case and
    /// has to say so explicitly, or the next launch repaints titles the viewer no
    /// longer has.
    func clearHero()
    /// Discards the snapshot entirely.
    ///
    /// `save` deliberately refuses to overwrite good content with an empty
    /// aggregate, because an empty usually means a server was briefly
    /// unreachable. When the profile has NO sources to aggregate that reasoning
    /// inverts: the emptiness is the answer, and a snapshot of servers the
    /// profile no longer watches would otherwise be repainted at every launch.
    func clear()
}

public extension HomeContentStoring {
    var persistenceScope: String {
        "instance:\(ObjectIdentifier(self))"
    }
}

/// The part of ``HeroSettings`` that decides *what the hero contains* — as
/// opposed to how it presents it.
///
/// This is the line between "the world moved" and "the viewer changed their
/// mind", and everything that has to draw it uses this one type: the persisted
/// launch seed's validity, whether a loaded carousel survives a recomputation,
/// and whether a fresh curation folds into what is showing or replaces it.
/// Content moving is routine and constant; a change to one of these values is a
/// direct instruction and retires what is on screen at once.
///
/// Visual-only settings (trailer behavior, auto-advance timing) are deliberately
/// excluded: changing them does not change which titles can appear, and must not
/// throw away a good carousel.
public struct HeroConfigurationKey: Codable, Hashable, Sendable {
    public var sources: [HeroSourceKind]
    public var maxItems: Int
    public var hideWatched: Bool
    /// The libraries the viewer restricted the Random source to. Empty means "all
    /// currently-visible libraries". Included because narrowing it is a request
    /// for different titles — unlike the *resolved* library list, which changes
    /// whenever a server finishes loading and must not retire anything.
    public var randomLibraryKeys: Set<String>

    public init(settings: HeroSettings?) {
        guard let settings, settings.isActive else {
            sources = []
            maxItems = 0
            hideWatched = false
            randomLibraryKeys = []
            return
        }
        sources = settings.sources
        maxItems = settings.maxItems
        hideWatched = settings.hideWatched
        randomLibraryKeys = settings.isEnabled(.randomFromLibrary)
            ? settings.randomLibraryKeys
            : []
    }

    private enum CodingKeys: String, CodingKey {
        case sources, maxItems, hideWatched, randomLibraryKeys
    }

    /// Lenient, like ``HeroSettings``: a persisted key written before a field
    /// existed reads as that field's default rather than failing the whole decode
    /// and discarding an otherwise usable seed.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sources = try container.decode([HeroSourceKind].self, forKey: .sources)
        maxItems = try container.decode(Int.self, forKey: .maxItems)
        hideWatched = try container.decode(Bool.self, forKey: .hideWatched)
        randomLibraryKeys =
            ((try? container.decodeIfPresent(
                Set<String>.self,
                forKey: .randomLibraryKeys
            )) ?? nil) ?? []
    }
}

/// On-disk (`Caches`) store. Per-profile scoped via `SettingsKey.scoped` so each
/// profile paints its own last Home (the primary profile keeps an un-suffixed
/// file). Schema-versioned via the directory name: bump it whenever `MediaItem` /
/// `AggregatedLibrary` coding changes so old snapshots are simply ignored (a
/// decode miss falls back to the network) and their files are reclaimed.
public final class HomeContentStore: HomeContentStoring, @unchecked Sendable {
    private let fileURL: URL?
    private let heroFileURL: URL?
    private let legacyWatchlistSeedFileURL: URL?
    private let legacyWatchlistSourceFileURL: URL?
    private let maxItemsPerRow: Int
    private let maxWatchlistItems: Int
    private let maxAge: TimeInterval
    private let heroMaxAge: TimeInterval

    public var persistenceScope: String {
        fileURL?.standardizedFileURL.path
            ?? "disabled:\(ObjectIdentifier(self))"
    }

    /// Wire format: the bounded content plus the time it was captured (for
    /// `maxAge`). Kept private so the on-disk shape can evolve behind the protocol.
    private struct Stored: Codable {
        var content: HomeViewModel.Content
        var savedAt: Date
    }

    private struct StoredHero: Codable {
        var key: HeroConfigurationKey
        var items: [MediaItem]
        var savedAt: Date
    }

    private struct StoredLegacyWatchlistSeed: Codable {
        var items: [MediaItem]
        var savedAt: Date
    }

    /// **Bump when `MediaItem` / `AggregatedLibrary` coding changes** so devices
    /// with an older snapshot shape start fresh instead of decode-missing forever.
    /// v2: `MediaSourceRef` gained a `kind` field and the merger now drops
    /// cross-kind source refs — bumping evicts snapshots that froze a stale
    /// episode↔movie twin from a pre-fix build.
    /// v3 removes legacy direct-share relative paths and pre-validation hero
    /// candidates from persisted `MediaItem.artworkSelections`.
    /// v4: Plex episodes cached before the `posterURL` fix carry the SHOW's poster
    /// where the episode's own still belongs — see `DetailSnapshotCache`.
    /// v5: Plex watchlist rows cached before the Discover-artwork fix hold URLs
    /// built against the viewer's own server, which had never heard of those
    /// titles and answered every one of them with the same placeholder — so a
    /// whole watchlist row wore one show's poster. The live read corrects itself
    /// now, but a snapshot painted at launch cannot: it made the row flip between
    /// right and wrong depending on whether the network had answered yet, which
    /// reads as far more broken than being consistently wrong.
    /// v6 removes credentials from every persisted artwork URL (including Plex's
    /// token nested inside a transcoder `url=` parameter). It also evicts Home
    /// items carrying anime ids from the pre-validation fuzzy-search bug; those
    /// snapshots could draw a random anime poster before live server data arrived.
    private static let schemaDirName = "plozz-home-content-v6"
    private static let schemaDirPrefix = "plozz-home-content"
    private static let legacySeedSourceSchemaDirName = "plozz-home-content-v5"
    private static let legacyWatchlistSeedSuffix = "-legacy-watchlist-seed"

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
    private static var heroMemo: [String: StoredHero?] = [:]

    public init(
        namespace: String? = nil,
        directory: URL? = HomeContentStore.defaultDirectory(),
        maxItemsPerRow: Int = 30,
        maxWatchlistItems: Int = 10_000,
        maxAge: TimeInterval = 60 * 60 * 24 * 14,
        heroMaxAge: TimeInterval = 60 * 60 * 24
    ) {
        self.maxItemsPerRow = maxItemsPerRow
        self.maxWatchlistItems = maxWatchlistItems
        self.maxAge = maxAge
        self.heroMaxAge = heroMaxAge
        guard let directory else {
            self.fileURL = nil
            self.heroFileURL = nil
            self.legacyWatchlistSeedFileURL = nil
            self.legacyWatchlistSourceFileURL = nil
            return
        }
        let dir = directory.appendingPathComponent(Self.schemaDirName, isDirectory: true)
        // Per-profile filename: default profile keeps the un-suffixed base.
        let name = SettingsKey.scoped("home-content", namespace: namespace)
        let safe = Data(name.utf8).base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        self.fileURL = dir.appendingPathComponent(safe).appendingPathExtension("json")
        self.heroFileURL = dir
            .appendingPathComponent(safe + "-hero")
            .appendingPathExtension("json")
        self.legacyWatchlistSeedFileURL = dir
            .appendingPathComponent(
                safe + Self.legacyWatchlistSeedSuffix
            )
            .appendingPathExtension("json")
        self.legacyWatchlistSourceFileURL = directory
            .appendingPathComponent(
                Self.legacySeedSourceSchemaDirName,
                isDirectory: true
            )
            .appendingPathComponent(safe)
            .appendingPathExtension("json")
        // Run the superseded-schema cleanup at most once per process (it's a global
        // one-time cleanup, not per-instance), so repeated construction never
        // re-enumerates the Caches directory on the main thread. Before deleting
        // v5, it moves each profile's credential-free Watchlist into a small v6
        // sidecar so the one-shot universal-watchlist migration can still consume
        // it. The ordinary v6 Home directory otherwise remains lazy.
        Self.cleanupSupersededCachesOnce(besideSchemaDirIn: directory)
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

    /// The v5 Watchlist retained solely for the one-shot universal-watchlist
    /// migration. It is never presented as v6 Home content.
    public func loadLegacyWatchlistSeed() -> [MediaItem]? {
        guard let legacyWatchlistSeedFileURL,
              let data = try? Data(contentsOf: legacyWatchlistSeedFileURL),
              let stored = try? JSONDecoder().decode(
                  StoredLegacyWatchlistSeed.self,
                  from: data
              )
        else { return nil }
        guard Date().timeIntervalSince(stored.savedAt) < maxAge else {
            try? FileManager.default.removeItem(
                at: legacyWatchlistSeedFileURL
            )
            return []
        }
        return stored.items
    }

    /// Removes the migration sidecar only after the durable Watchlist accepted it.
    public func clearLegacyWatchlistSeed() {
        guard let legacyWatchlistSeedFileURL else { return }
        try? FileManager.default.removeItem(at: legacyWatchlistSeedFileURL)
    }

    /// True when v5 still holds this profile's source snapshot, or a sidecar
    /// exists but cannot be decoded. The universal migration must retry rather
    /// than recording an empty migration as complete in either case.
    public var hasPendingLegacyWatchlistSeed: Bool {
        if let legacyWatchlistSeedFileURL,
           FileManager.default.fileExists(
               atPath: legacyWatchlistSeedFileURL.path
           ) {
            return loadLegacyWatchlistSeed() == nil
        }
        guard let legacyWatchlistSourceFileURL else { return false }
        return FileManager.default.fileExists(
            atPath: legacyWatchlistSourceFileURL.path
        )
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

    public func clear() {
        guard let fileURL else { return }
        Self.lock.lock()
        Self.memo[fileURL.path] = .some(nil)
        if let heroFileURL {
            Self.heroMemo[heroFileURL.path] = .some(nil)
        }
        Self.lock.unlock()
        try? FileManager.default.removeItem(at: fileURL)
        if let heroFileURL { try? FileManager.default.removeItem(at: heroFileURL) }
    }

    public func save(_ content: HomeViewModel.Content) {
        guard let fileURL else { return }
        let stored = Stored(
            content: content
                .bounded(
                    perRow: maxItemsPerRow,
                    watchlistLimit: maxWatchlistItems
                )
                .sanitizedForPersistence(),
            savedAt: Date()
        )
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

    public func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? {
        guard let heroFileURL else { return nil }
        let path = heroFileURL.path
        Self.lock.lock()
        let memoized = Self.heroMemo[path]
        Self.lock.unlock()

        let stored: StoredHero?
        if let memoized {
            stored = memoized
        } else {
            stored = readHero(at: heroFileURL)
            Self.lock.lock()
            Self.heroMemo.updateValue(stored, forKey: path)
            Self.lock.unlock()
        }
        guard let stored else { return nil }
        guard Date().timeIntervalSince(stored.savedAt) < heroMaxAge else {
            try? FileManager.default.removeItem(at: heroFileURL)
            Self.lock.lock()
            Self.heroMemo.updateValue(nil, forKey: path)
            Self.lock.unlock()
            return nil
        }
        guard stored.key == key, !stored.items.isEmpty else { return nil }
        return stored.items
    }

    public func clearHero() {
        guard let heroFileURL else { return }
        try? FileManager.default.removeItem(at: heroFileURL)
        Self.lock.lock()
        Self.heroMemo.updateValue(nil, forKey: heroFileURL.path)
        Self.lock.unlock()
    }

    public func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {
        guard let heroFileURL, !items.isEmpty else { return }
        let stored = StoredHero(
            key: key,
            items: Array(items.prefix(max(key.maxItems, 1))).map {
                $0.sanitizingArtworkCredentials()
            },
            savedAt: Date()
        )
        guard let data = try? JSONEncoder().encode(stored) else { return }
        try? FileManager.default.createDirectory(
            at: heroFileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: heroFileURL, options: .atomic)
        Self.lock.lock()
        // Re-read after a save instead of optimistically memoizing what we tried to
        // write. If the cache write failed, the old on-disk snapshot remains truth.
        Self.heroMemo.removeValue(forKey: heroFileURL.path)
        Self.lock.unlock()
    }

    private func readHero(at fileURL: URL) -> StoredHero? {
        guard let data = try? Data(contentsOf: fileURL),
              let stored = try? JSONDecoder().decode(StoredHero.self, from: data)
        else { return nil }
        guard Date().timeIntervalSince(stored.savedAt) < heroMaxAge else {
            try? FileManager.default.removeItem(at: fileURL)
            return nil
        }
        return stored
    }

    /// Drops sibling schema dirs left by earlier versions so a bump reclaims their
    /// files instead of leaking them (mirrors `DetailSnapshotCache`). Runs at most
    /// once per process.
    private static func cleanupSupersededCachesOnce(besideSchemaDirIn parent: URL) {
        lock.lock()
        if didCleanup { lock.unlock(); return }
        didCleanup = true
        lock.unlock()
        cleanupSupersededCaches(besideSchemaDirIn: parent)
    }

    /// Performs the loss-safe v5 Watchlist extraction and schema cleanup. Internal
    /// so the migration ordering can be exercised with an isolated test directory.
    static func cleanupSupersededCaches(besideSchemaDirIn parent: URL) {
        guard let dirs = try? FileManager.default.contentsOfDirectory(
            at: parent, includingPropertiesForKeys: nil
        ) else { return }
        for dir in dirs where dir.lastPathComponent != schemaDirName
            && dir.lastPathComponent.hasPrefix(schemaDirPrefix) {
            if dir.lastPathComponent == legacySeedSourceSchemaDirName {
                let current = parent.appendingPathComponent(
                    schemaDirName,
                    isDirectory: true
                )
                guard migrateLegacyWatchlistSeeds(
                    from: dir,
                    to: current
                ) else {
                    continue
                }
            }
            try? FileManager.default.removeItem(at: dir)
        }
    }

    /// Copies every decodable profile Watchlist from v5 into a credential-free v6
    /// sidecar before v5 is deleted. A failed write keeps the entire source
    /// directory for a retry on the next launch.
    private static func migrateLegacyWatchlistSeeds(
        from legacyDirectory: URL,
        to currentDirectory: URL
    ) -> Bool {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: legacyDirectory,
            includingPropertiesForKeys: nil
        ) else { return false }

        var succeeded = true
        for file in files where file.pathExtension == "json" {
            let stem = file.deletingPathExtension().lastPathComponent
            if stem.hasSuffix("-hero") {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    succeeded = false
                }
                continue
            }
            guard let data = try? Data(contentsOf: file),
                  let stored = try? JSONDecoder().decode(Stored.self, from: data)
            else {
                succeeded = false
                continue
            }

            let destination = currentDirectory
                .appendingPathComponent(
                    stem + legacyWatchlistSeedSuffix
                )
                .appendingPathExtension("json")
            var sidecarIsValid = false
            if FileManager.default.fileExists(atPath: destination.path) {
                if let existing = try? Data(contentsOf: destination),
                   (try? JSONDecoder().decode(
                       StoredLegacyWatchlistSeed.self,
                       from: existing
                   )) != nil {
                    sidecarIsValid = true
                }
            }
            if !sidecarIsValid {
                let seed = StoredLegacyWatchlistSeed(
                    items: stored.content.watchlist
                        .filter { $0.kind == .movie || $0.kind == .series }
                        .map { $0.sanitizingArtworkCredentials() },
                    savedAt: stored.savedAt
                )
                guard let encoded = try? JSONEncoder().encode(seed) else {
                    succeeded = false
                    continue
                }
                do {
                    try FileManager.default.createDirectory(
                        at: currentDirectory,
                        withIntermediateDirectories: true
                    )
                    try encoded.write(to: destination, options: .atomic)
                    sidecarIsValid = true
                } catch {
                    succeeded = false
                }
            }
            if sidecarIsValid {
                do {
                    try FileManager.default.removeItem(at: file)
                } catch {
                    succeeded = false
                }
            }
        }
        return succeeded
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
    private var hero: (key: HeroConfigurationKey, items: [MediaItem])?

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

    public func clear() {
        lock.lock(); defer { lock.unlock() }
        content = nil
        hero = nil
    }

    public func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? {
        lock.lock(); defer { lock.unlock() }
        guard hero?.key == key else { return nil }
        return hero?.items
    }

    public func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {
        lock.lock(); defer { lock.unlock() }
        hero = items.isEmpty ? nil : (key, items)
    }

    public func clearHero() {
        lock.lock(); defer { lock.unlock() }
        hero = nil
    }
}

/// No-op store: never reads or writes. The default for `HomeViewModel` so tests
/// and previews stay isolated (production explicitly injects a `HomeContentStore`).
public final class NoOpHomeContentStore: HomeContentStoring, @unchecked Sendable {
    public init() {}
    public func load() -> HomeViewModel.Content? { nil }
    public func save(_ content: HomeViewModel.Content) {}
    public func loadHero(for key: HeroConfigurationKey) -> [MediaItem]? { nil }
    public func saveHero(_ items: [MediaItem], for key: HeroConfigurationKey) {}
    public func clearHero() {}
    public func clear() {}
}
