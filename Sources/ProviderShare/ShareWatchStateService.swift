import Foundation
import CoreModels
import CoreNetworking

/// Owns all device-local watch-state policy for a share: overlaying saved
/// resume/played state onto freshly-built items (stamping), folding several
/// legacy version records onto one canonical id, and persisting progress/played
/// writes. `ShareProvider` delegates here so the facade keeps only browse/
/// playback orchestration and this type has one reason to change.
///
/// A value type over a `ShareWatchStore` actor + the catalog reader; holds no
/// mutable state of its own.
struct ShareWatchStateService: Sendable {
    private let watchStore: ShareWatchStore
    private let catalog: @Sendable () async -> any ShareCatalogReading
    private let accountID: String

    init(
        watchStore: ShareWatchStore,
        accountID: String,
        catalog: @escaping @Sendable () async -> any ShareCatalogReading
    ) {
        self.watchStore = watchStore
        self.accountID = accountID
        self.catalog = catalog
    }

    // MARK: Stamping

    /// Overlay saved resume/played state onto a freshly-built item so the detail
    /// Play button shows "Resume" and cards show a checkmark / progress.
    func stamp(_ item: MediaItem) async -> MediaItem {
        // Only leaf playables carry watch state; containers (folders, series,
        // seasons, collections) have no resume/played record, so skip the lookup.
        switch item.kind {
        case .folder, .collection, .series, .season:
            return item
        default:
            break
        }
        let records = await records(for: [item.id])
        let canonicalID = await catalog().canonicalItemID(item.id)
        let record = records[canonicalID]
        return Self.stamped(item, with: record)
    }

    func stamp(_ items: [MediaItem]) async -> [MediaItem] {
        let playableIDs = items.compactMap { item -> String? in
            switch item.kind {
            case .folder, .collection, .series, .season: return nil
            default: return item.id
            }
        }
        let records = await records(for: playableIDs)
        let catalog = await self.catalog()
        var stamped: [MediaItem] = []
        stamped.reserveCapacity(items.count)
        for item in items {
            switch item.kind {
            case .folder, .collection, .series, .season:
                stamped.append(item)
            default:
                let canonical = await catalog.canonicalItemID(item.id)
                stamped.append(Self.stamped(item, with: records[canonical]))
            }
        }
        return stamped
    }

    /// Apply a resolved record onto an item (pure). Exposed so Continue Watching,
    /// which already folds all records itself, can stamp its rebuilt items.
    static func stamped(_ item: MediaItem, with record: ShareWatchStore.Record?) -> MediaItem {
        guard let record else { return item }
        var copy = item
        copy.isPlayed = record.played
        copy.resumePosition = (!record.played && record.position > 1) ? record.position : nil
        copy.lastPlayedAt = record.updatedAt
        // Carry the learned duration onto the item (a share item has no runtime
        // until it's played once) and derive the played fraction the Continue
        // Watching / poster progress bar renders. Only in-progress records get a
        // fraction — a finished (played) or unstarted item shows no bar.
        if let duration = record.duration, duration > 0 {
            if copy.runtime == nil { copy.runtime = duration }
            if !record.played, record.position > 1 {
                copy.playedPercentage = min(max(record.position / duration, 0), 1)
            }
        }
        return copy
    }

    // MARK: Record lookup

    /// Full-history fold used only by Continue Watching, which inherently needs all
    /// resumable state before sorting/limiting.
    func allCanonicalRecords() async -> [String: ShareWatchStore.Record] {
        let snapshot = await watchStore.recordsSnapshot()
        let catalog = await self.catalog()
        var result: [String: ShareWatchStore.Record] = [:]
        for (id, record) in snapshot {
            let canonical = await catalog.canonicalItemID(id)
            if let existing = result[canonical], existing.updatedAt >= record.updatedAt {
                continue
            }
            result[canonical] = record
        }
        return result
    }

    /// Bounded watch lookup for normal item/page operations. The catalog returns
    /// only aliases relevant to requested ids; the watch store then performs direct
    /// dictionary lookups for that small set.
    func records(for itemIDs: [String]) async -> [String: ShareWatchStore.Record] {
        let catalog = await self.catalog()
        let aliases = await catalog.watchStateAliases(for: itemIDs)
        let stored = await watchStore.records(for: aliases.keys)
        var result: [String: ShareWatchStore.Record] = [:]
        for (storedID, canonicalID) in aliases {
            guard let record = stored[storedID] else { continue }
            if let existing = result[canonicalID], existing.updatedAt >= record.updatedAt { continue }
            result[canonicalID] = record
        }
        return result
    }

    // MARK: Writes

    /// Persist live playback progress locally (a share has no server to report to).
    func recordPlayback(_ progress: PlaybackProgress, event: PlaybackEvent) async {
        // A share reports `.stop` with the final position too (the outbox — which
        // owns the played-vs-resume decision that needs duration — may not even
        // target a local share), so `.stop` persists the resume directly here. A
        // later `setPlayed(true)` drained from the outbox (newer `capturedAt`) still
        // supersedes it and clears the resume, so a fully-watched title doesn't
        // linger in Continue Watching.
        PlozzLog.playback.info("share.reportPlayback event=\(String(describing: event)) item=\(progress.itemID) pos=\(Int(progress.positionSeconds)) account=\(accountID)")
        switch event {
        case .progress, .pause, .stop:
            let id = await catalog().canonicalItemID(progress.itemID)
            await watchStore.setResume(progress.positionSeconds, itemID: id, capturedAt: Date(), duration: progress.durationSeconds)
        case .start, .unpause:
            break
        }
    }

    func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async {
        await watchStore.setPlayed(played, itemID: await catalog().canonicalItemID(itemID), capturedAt: capturedAt)
    }

    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async {
        await watchStore.setResume(seconds, itemID: await catalog().canonicalItemID(itemID), capturedAt: capturedAt)
    }
}
