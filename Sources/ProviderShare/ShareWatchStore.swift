import Foundation

/// Local, on-device watch state for a media share.
///
/// Plex/Jellyfin keep watched/resume state on the server, but a plain file share
/// has no such backend — so the app is the source of truth. This actor persists a
/// small JSON record per playable item (keyed by its share item id, e.g.
/// `"f:TV Shows/Show/S01E01.mkv"`) so a share can answer "resume from here" and
/// "already watched" across relaunches, and surface a Continue Watching row.
///
/// It is written from two seams that already exist in the app:
///  * the durable cross-server **watch outbox**, which drains `setResumePosition`
///    / `setPlayed` to whichever provider owns the played item (a share included,
///    now that `ShareProvider` conforms to the capability protocols). These are
///    authoritative — the outbox has already factored playback *duration* into the
///    played-vs-resume decision (≥90% ⇒ played).
///  * the live `reportPlayback` progress ticks, which persist the current position
///    mid-play so a hard app kill still leaves a usable resume point.
///
/// Writes are ordered by `capturedAt`: an older (e.g. late-draining queued) write
/// never clobbers a newer one, so a stale resume can't resurrect an item a newer
/// `setPlayed` marked finished.
///
/// Scope: one file per share account. Watch state on a local share is inherently
/// device-local; per-*profile* scoping is a future refinement (documented in the
/// media-share plan).
public actor ShareWatchStore {
    /// One item's persisted watch state.
    public struct Record: Codable, Sendable, Equatable {
        /// Resume position in seconds (`0` ⇒ start / cleared).
        public var position: TimeInterval
        /// Whether the item is fully watched.
        public var played: Bool
        /// When the play that produced this state happened (ordering + recency).
        public var updatedAt: Date
    }

    private let url: URL
    /// Lazily loaded so constructing a provider (which happens constantly as
    /// SwiftUI reads `AppState`) never touches disk until watch state is used.
    private var records: [String: Record]?

    /// - Parameters:
    ///   - accountKey: stable per-account id (the share's `server.id`), used to
    ///     name the file so two shares/accounts keep separate state.
    ///   - directory: container dir (defaults to Application Support/Plozz).
    public init(accountKey: String, directory: URL? = nil) {
        let base = directory ?? Self.defaultDirectory()
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        self.url = base.appendingPathComponent("share-watch-\(Self.sanitize(accountKey)).json")
    }

    // MARK: - Reads

    /// The stored state for an item id, or `nil` when it was never played.
    public func record(for itemID: String) -> Record? {
        loaded()[itemID]
    }

    /// The resumable items — started but not finished — newest first, capped at
    /// `limit`. Backs the share's Continue Watching row.
    public func resumable(limit: Int) -> [(itemID: String, record: Record)] {
        guard limit > 0 else { return [] }
        let entries = loaded()
            .filter { !$0.value.played && $0.value.position > 1 }
            .sorted { $0.value.updatedAt > $1.value.updatedAt }
            .prefix(limit)
        return entries.map { (itemID: $0.key, record: $0.value) }
    }

    // MARK: - Writes

    /// Persist a resume position. A newer positive position marks the item
    /// in-progress (un-plays a previously-finished item that's being re-watched);
    /// a position of `0` clears the resume point without changing played state.
    /// Ignored when an existing record is *newer* than `capturedAt` (stale drain).
    public func setResume(_ seconds: TimeInterval, itemID: String, capturedAt: Date) {
        var all = loaded()
        if let existing = all[itemID], capturedAt < existing.updatedAt { return }
        let position = max(0, seconds)
        let played = position > 1 ? false : (all[itemID]?.played ?? false)
        all[itemID] = Record(position: position, played: played, updatedAt: capturedAt)
        persist(all)
    }

    /// Mark an item played / unplayed. Either way the resume point is cleared
    /// (a finished item resumes from the start; an explicitly-unwatched one too).
    /// Ignored when an existing record is *newer* than `capturedAt`.
    public func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) {
        var all = loaded()
        if let existing = all[itemID], capturedAt < existing.updatedAt { return }
        all[itemID] = Record(position: 0, played: played, updatedAt: capturedAt)
        persist(all)
    }

    // MARK: - Persistence

    private func loaded() -> [String: Record] {
        if let records { return records }
        let decoded: [String: Record]
        if let data = try? Data(contentsOf: url),
           let map = try? JSONDecoder().decode([String: Record].self, from: data) {
            decoded = map
        } else {
            decoded = [:]
        }
        records = decoded
        return decoded
    }

    private func persist(_ all: [String: Record]) {
        records = all
        guard let data = try? JSONEncoder().encode(all) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Plozz", isDirectory: true)
    }

    /// Reduce an arbitrary account id to a filesystem-safe file-name fragment.
    /// Uses a *stable* hash (FNV-1a) — `String.hashValue` is seeded per process
    /// launch, which would change the file name every launch and orphan the
    /// saved state.
    private static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics
        let mapped = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // Keep it bounded and collision-resistant even after the char mapping.
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in raw.utf8 {
            hash = (hash ^ UInt64(byte)) &* 0x100000001b3
        }
        return "\(mapped.prefix(80))-\(String(hash, radix: 16))"
    }
}
