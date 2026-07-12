import Foundation
import CoreModels
import CoreNetworking

/// Local, on-device watch state for a media share.
///
/// Plex/Jellyfin keep watched/resume state on the server, but a plain file share
/// has no such backend — so the app is the source of truth. This actor persists a
/// bounded durable record per playable item (keyed by its share item id, e.g.
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
/// Scope: one Keychain envelope per share account and Plozz profile. Watch state
/// on a local
/// share is device-local, but profiles never read or overwrite each other's state.
public actor ShareWatchStore {
    /// One item's persisted watch state.
    public struct Record: Codable, Sendable, Equatable {
        /// Resume position in seconds (`0` ⇒ start / cleared).
        public var position: TimeInterval
        /// Whether the item is fully watched.
        public var played: Bool
        /// When the play that produced this state happened (ordering + recency).
        public var updatedAt: Date
        /// Total media duration in seconds, captured during playback, so a
        /// Continue Watching card can render a progress bar (`position / duration`).
        /// `nil` for records written before duration was known (a bare resume drain
        /// with no live player) — the bar is simply omitted until the next play
        /// re-learns it. Missing in legacy JSON decodes to `nil` automatically.
        public var duration: TimeInterval?

        public init(position: TimeInterval, played: Bool, updatedAt: Date, duration: TimeInterval? = nil) {
            self.position = position
            self.played = played
            self.updatedAt = updatedAt
            self.duration = duration
        }
    }

    private struct PersistedState: DurableLocalStateValue {
        static let durableLocalStateSchemaID =
            "com.plozz.local-media-watch.v1"

        var records: [String: Record]
    }

    private static let maximumRecordCount = 2_000
    private let durableStore: DurableLocalStateStore?
    private let durableKey: DurableLocalStateKey?
    private var records: [String: Record]?
    private var loadFailed = false

    public init(
        localMediaContext: LocalMediaContext,
        durableStore: DurableLocalStateStore? = nil
    ) {
        self.durableStore = durableStore
        do {
            self.durableKey = try DurableLocalStateKey(
                collection: .localMediaWatch,
                scope: .source(
                    profileID: localMediaContext.profileID,
                    sourceID: localMediaContext.accountID
                )
            )
        } catch {
            self.durableKey = nil
            PlozzLog.playback.error(
                "Durable share watch address invalid; using memory only"
            )
        }

    }

    @available(
        *,
        deprecated,
        message: "Inject DurableLocalStateStore; file-backed watch state is retired"
    )
    public init(accountKey: String, directory: URL? = nil) {
        self.init(
            localMediaContext: LocalMediaContext(
                accountID: accountKey,
                profileID: ProfileStore.defaultProfileID,
                profileNamespace: nil
            ),
            durableStore: nil
        )
    }

    init(
        accountKey: String,
        durableStore: DurableLocalStateStore,
        profileID: String = ProfileStore.defaultProfileID
    ) {
        self.init(
            localMediaContext: LocalMediaContext(
                accountID: accountKey,
                profileID: profileID,
                profileNamespace: nil
            ),
            durableStore: durableStore
        )
    }

    // MARK: - Reads

    /// The stored state for an item id, or `nil` when it was never played.
    public func record(for itemID: String) -> Record? {
        loaded()[itemID]
    }

    /// Immutable snapshot for batch canonicalization. A share page can stamp all
    /// cards with one disk/load read, then fold legacy file ids in memory instead
    /// of issuing catalog queries per visible item.
    func recordsSnapshot() -> [String: Record] {
        loaded()
    }

    /// Selected records without copying/iterating the whole watch history at the
    /// provider layer. Used by grid/detail stamping after the catalog supplies the
    /// small set of canonical + legacy aliases relevant to those items.
    func records<S: Sequence>(for itemIDs: S) -> [String: Record] where S.Element == String {
        let all = loaded()
        var result: [String: Record] = [:]
        for id in itemIDs {
            if let record = all[id] { result[id] = record }
        }
        return result
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
    public func setResume(_ seconds: TimeInterval, itemID: String, capturedAt: Date, duration: TimeInterval? = nil) {
        var all = loaded()
        if let existing = all[itemID], capturedAt < existing.updatedAt { return }
        let position = max(0, seconds)
        let played = position > 1 ? false : (all[itemID]?.played ?? false)
        // Keep a previously-learned duration when this write doesn't carry one (a
        // resume drained from the outbox has no live player), so the progress bar
        // survives resume ticks that lack duration.
        let resolvedDuration = (duration.map { $0 > 0 ? $0 : nil } ?? nil) ?? all[itemID]?.duration
        all[itemID] = Record(position: position, played: played, updatedAt: capturedAt, duration: resolvedDuration)
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
        guard let durableStore, let durableKey else {
            records = [:]
            return [:]
        }
        do {
            let loaded = try durableStore.load(
                PersistedState.self,
                for: durableKey
            )?.records ?? [:]
            records = loaded
            return loaded
        } catch {
            loadFailed = true
            records = [:]
            PlozzLog.playback.error(
                "Durable share watch state unavailable; refusing to overwrite it"
            )
            return [:]
        }
    }

    private func persist(_ all: [String: Record]) {
        let bounded = Self.boundedRecords(
            all,
            maximumPayloadBytes: durableStore?.maximumPayloadBytes
        )
        records = bounded
        guard !loadFailed else {
            PlozzLog.playback.error(
                "Durable share watch write blocked after load failure"
            )
            return
        }
        guard let durableStore, let durableKey else { return }
        do {
            try durableStore.save(
                PersistedState(records: bounded),
                for: durableKey
            )
            PlozzLog.playback.info(
                "Durable share watch state wrote \(bounded.count) record(s)"
            )
        } catch {
            PlozzLog.playback.error(
                "Durable share watch state write failed"
            )
        }
    }

    private static func boundedRecords(
        _ all: [String: Record],
        maximumPayloadBytes: Int?
    ) -> [String: Record] {
        let ordered = all.sorted {
            $0.value.updatedAt > $1.value.updatedAt
        }
        let countLimit = min(maximumRecordCount, ordered.count)
        guard let maximumPayloadBytes else {
            return Dictionary(
                uniqueKeysWithValues: ordered.prefix(countLimit).map {
                    ($0.key, $0.value)
                }
            )
        }

        let byteBudget = max(1, maximumPayloadBytes - 1_024)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        var lower = 0
        var upper = countLimit
        var best: [String: Record] = [:]
        while lower <= upper {
            let midpoint = lower + (upper - lower) / 2
            let candidate = Dictionary(
                uniqueKeysWithValues: ordered.prefix(midpoint).map {
                    ($0.key, $0.value)
                }
            )
            let size = (try? encoder.encode(
                PersistedState(records: candidate)
            ).count) ?? Int.max
            if size <= byteBudget {
                best = candidate
                lower = midpoint + 1
            } else {
                upper = midpoint - 1
            }
        }
        return best
    }
}
