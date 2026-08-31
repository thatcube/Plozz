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
        let canonicalID = await watchItemID(for: item.id)
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
                let canonical = await watchItemID(for: item.id, catalog: catalog)
                stamped.append(Self.stamped(item, with: records[canonical]))
            }
        }
        return stamped
    }

    /// Season containers with their episodes' watch state rolled up onto them.
    ///
    /// Share seasons are synthetic (a `GROUP BY` over the assets table), so
    /// `stamp` skips them — there is no record under a season's own id and never
    /// will be. That left every share season permanently unplayed, which is not
    /// cosmetic: the season chips showed no progress, and anything resolving
    /// "which season is the viewer on" over the season containers always answered
    /// "the first unwatched one" — Season 1 — however far into the show they were.
    ///
    /// Two round trips regardless of season count: one query for the series'
    /// episode identities, one batched record lookup.
    ///
    /// Note the store keeps a bounded history
    /// (`ShareWatchStore.maximumRecordCount`), so a very old, very large library
    /// can have episode records evicted. That makes a completed season
    /// under-report as partly watched — never the reverse, which is the safe
    /// direction: the viewer is offered an episode they have seen rather than
    /// being told a show is finished when it is not.
    func stampSeasons(_ seasons: [MediaItem], seriesKey: String) async -> [MediaItem] {
        guard !seasons.isEmpty else { return seasons }
        let identities = await catalog().episodeWatchIdentities(seriesKey: seriesKey)
        guard !identities.isEmpty else { return seasons }

        let records = await watchStore.records(for: Set(identities.map(\.fileID)))
        guard !records.isEmpty else { return seasons }

        // season → logical episode → the records of every file backing it
        var bySeason: [Int: [String: [ShareWatchStore.Record]]] = [:]
        for identity in identities {
            var episodes = bySeason[identity.season] ?? [:]
            var found = episodes[identity.logicalKey] ?? []
            if let record = records[identity.fileID] { found.append(record) }
            episodes[identity.logicalKey] = found
            bySeason[identity.season] = episodes
        }

        return seasons.map { season in
            guard let number = season.seasonNumber,
                  let episodes = bySeason[number],
                  !episodes.isEmpty
            else { return season }

            // A logical episode counts as watched when ANY of its files is —
            // watching the 1080p rip means you have seen the episode.
            let played = episodes.values.filter { $0.contains(where: \.played) }.count
            let inProgress = episodes.values.contains { versions in
                versions.contains { !$0.played && $0.position > 1 }
            }
            let latest = episodes.values.flatMap { $0 }.map(\.updatedAt).max()

            var copy = season
            copy.isPlayed = played == episodes.count
            copy.playedPercentage = played > 0
                ? min(1, Double(played) / Double(episodes.count))
                : nil
            copy.hasBeenPlayed = played > 0 || inProgress
            copy.lastPlayedAt = latest
            return copy
        }
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
            if ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(id) {
                continue
            }
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
        var aliases = await catalog.watchStateAliases(for: itemIDs)
        for id in itemIDs {
            if ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(id) {
                aliases[id] = id
            }
        }
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
        guard await mayPersistWatchState(for: progress.itemID) else { return }
        switch event {
        case .progress, .pause, .stop:
            let id = await watchItemID(for: progress.itemID)
            await watchStore.setResume(progress.positionSeconds, itemID: id, capturedAt: Date(), duration: progress.durationSeconds)
        case .start, .unpause:
            break
        }
    }

    func setPlayed(_ played: Bool, itemID: String, capturedAt: Date) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        await watchStore.setPlayed(played, itemID: await watchItemID(for: itemID), capturedAt: capturedAt)
    }

    func setResumePosition(_ seconds: TimeInterval, itemID: String, capturedAt: Date) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        await watchStore.setResume(seconds, itemID: await watchItemID(for: itemID), capturedAt: capturedAt)
    }

    func dismissFromContinueWatching(itemID: String, at date: Date = Date()) async {
        guard await mayPersistWatchState(for: itemID) else { return }
        await watchStore.dismissFromContinueWatching(itemID: await watchItemID(for: itemID), at: date)
    }

    private func mayPersistWatchState(for itemID: String) async -> Bool {
        let stored = await catalog().extraResumeBehavior(fileID: itemID)
        return stored
            ?? ShareExtraDiscoveryPolicy.resumeBehavior(forItemID: itemID)
            ?? true
    }

    private func watchItemID(for itemID: String) async -> String {
        let catalog = await self.catalog()
        return await watchItemID(for: itemID, catalog: catalog)
    }

    private func watchItemID(
        for itemID: String,
        catalog: any ShareCatalogReading
    ) async -> String {
        if ShareExtraDiscoveryPolicy.isRecognizedExtraItemID(itemID) { return itemID }
        return await catalog.canonicalItemID(itemID)
    }
}
