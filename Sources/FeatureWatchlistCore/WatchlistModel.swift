import CoreModels
import Foundation
import Observation

public enum WatchlistModelError: Error, Equatable, Sendable {
    case profileNotHydrated(String)
    case profileDeleted(String)
    case malformedRemoteRecord(String)
}

public struct WatchlistRemoteApplyReport: Equatable, Sendable {
    public let appliedRecordNames: [String]
    public let rejectedRecordNames: [String]
    public let ignoredDeletedProfileRecordNames: [String]

    public init(
        appliedRecordNames: [String] = [],
        rejectedRecordNames: [String] = [],
        ignoredDeletedProfileRecordNames: [String] = []
    ) {
        self.appliedRecordNames = appliedRecordNames.sorted()
        self.rejectedRecordNames = rejectedRecordNames.sorted()
        self.ignoredDeletedProfileRecordNames =
            ignoredDeletedProfileRecordNames.sorted()
    }

    public var appliedCount: Int { appliedRecordNames.count }
    public var rejectedCount: Int { rejectedRecordNames.count }
}

@MainActor
@Observable
public final class WatchlistModel {
    private struct DeletedProfilesState: Codable {
        static let currentVersion = 1
        let version: Int
        let profileIDs: [String]
    }

    public private(set) var snapshotsByProfile: [String: WatchlistSnapshot] = [:]
    public private(set) var activeProfileID: String?
    public private(set) var deletionStateRecoveryOccurred = false

    @ObservationIgnored private let storageDirectory: URL?
    @ObservationIgnored private let customStoreFactory:
        ((String) throws -> any WatchlistIntentStoring)?
    @ObservationIgnored private var storesByProfile:
        [String: any WatchlistIntentStoring] = [:]
    @ObservationIgnored private var statesByProfile:
        [String: WatchlistIntentStoreState] = [:]
    @ObservationIgnored private var removedProfileIDs: Set<String> = []

    public init(
        storageDirectory: URL? = nil,
        storeFactory: ((String) throws -> any WatchlistIntentStoring)? = nil
    ) {
        self.storageDirectory = storageDirectory
        customStoreFactory = storeFactory
        guard let storageDirectory else { return }
        let url = Self.deletionStateURL(in: storageDirectory)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            let data = try Data(contentsOf: url)
            let value = try JSONDecoder().decode(
                DeletedProfilesState.self,
                from: data
            )
            guard value.version == DeletedProfilesState.currentVersion,
                  value.profileIDs.allSatisfy(Self.isValidProfileID)
            else { throw DurableLocalStateError.malformedPayload }
            removedProfileIDs = Set(value.profileIDs)
        } catch {
            deletionStateRecoveryOccurred = true
            let quarantine = url.deletingPathExtension()
                .appendingPathExtension("corrupt-\(UUID().uuidString).json")
            try? FileManager.default.moveItem(at: url, to: quarantine)
        }
    }

    public var activeSnapshot: WatchlistSnapshot {
        guard let activeProfileID else { return .empty }
        return snapshotsByProfile[activeProfileID] ?? .empty
    }

    public func hydrate(profileIDs: [String]) throws {
        for profileID in Set(profileIDs).sorted() {
            try hydrate(profileID: profileID)
        }
    }

    public func hydrate(profileID: String) throws {
        guard !removedProfileIDs.contains(profileID) else {
            throw WatchlistModelError.profileDeleted(profileID)
        }
        guard statesByProfile[profileID] == nil else { return }
        let store = try store(for: profileID)
        let state = try store.load()
        statesByProfile[profileID] = state
        snapshotsByProfile[profileID] = WatchlistSnapshot(intents: state.intents)
    }

    public func activate(profileID: String) throws {
        if removedProfileIDs.remove(profileID) != nil {
            do {
                try persistDeletionState()
            } catch {
                removedProfileIDs.insert(profileID)
                throw error
            }
        }
        try hydrate(profileID: profileID)
        activeProfileID = profileID
    }

    @discardableResult
    public func add(
        profileID: String,
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation? = nil,
        origin: WatchlistIntentOrigin = .local,
        sourceDestinationID: WatchlistDestinationID? = nil,
        at changedAt: Date = Date()
    ) throws -> WatchlistIntent {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        prepareOrderingSpace(in: &state)
        let existing = state.intents.first { $0.aliasID == aliasID }
        let rank = existing?.rank ?? allocateLegacyRank(in: &state)
        let orderingRank = nextFrontOrderingRank(in: state)
        var sources = existing?.metadata.sourceDestinationIDs ?? []
        if let sourceDestinationID {
            sources.append(sourceDestinationID.rawValue)
        }
        let intent = WatchlistIntent(
            aliasID: aliasID,
            kind: kind,
            desiredState: .present,
            rank: rank,
            orderingRank: orderingRank,
            origin: origin,
            changedAt: changedAt,
            presentation: presentation ?? existing?.presentation,
            metadata: WatchlistIntentMetadata(
                sourceDestinationIDs: sources,
                lastExplicitRemovalAt: existing?.metadata.lastExplicitRemovalAt,
                lastReconciledAt: existing?.metadata.lastReconciledAt
            )
        )!
        replace(intent, in: &state)
        try persist(state, profileID: profileID)
        return intent
    }

    @discardableResult
    public func remove(
        profileID: String,
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation? = nil,
        at changedAt: Date = Date()
    ) throws -> WatchlistIntent {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        prepareOrderingSpace(in: &state)
        let existing = state.intents.first { $0.aliasID == aliasID }
        let rank = existing?.rank ?? allocateLegacyRank(in: &state)
        let intent = WatchlistIntent(
            aliasID: aliasID,
            kind: kind,
            desiredState: .absent,
            rank: rank,
            orderingRank: existing?.orderingRank,
            origin: .local,
            changedAt: changedAt,
            presentation: presentation ?? existing?.presentation,
            metadata: WatchlistIntentMetadata(
                sourceDestinationIDs: existing?.metadata.sourceDestinationIDs ?? [],
                lastExplicitRemovalAt: changedAt,
                lastReconciledAt: existing?.metadata.lastReconciledAt
            )
        )!
        replace(intent, in: &state)
        try persist(state, profileID: profileID)
        return intent
    }

    public func seedLegacyIfNeeded(
        profileID: String,
        entries: [(MediaAliasID, MediaItemKind, MediaAliasPresentation?)]
    ) throws {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        prepareOrderingSpace(
            in: &state,
            additionalSlots: entries.count
        )
        guard state.migration.legacyHomeSeedCompletedAt == nil else { return }
        var nextBackRank = nextBackOrderingRank(in: state)
        for (aliasID, kind, presentation) in entries
        where state.intents.contains(where: { $0.aliasID == aliasID }) == false {
            guard let intent = WatchlistIntent(
                aliasID: aliasID,
                kind: kind,
                desiredState: .present,
                rank: allocateLegacyRank(in: &state),
                orderingRank: nextBackRank,
                origin: .legacyHomeSeed,
                presentation: presentation
            ) else { continue }
            nextBackRank += 1
            state.intents.append(intent)
        }
        state.migration.legacyHomeSeedCompletedAt = Date()
        try persist(state, profileID: profileID)
    }

    /// Drops the intents the old native IMPORT wrote, once per profile.
    ///
    /// The import used to write every native entry as a durable `.present`
    /// intent, which conflated "server X's list holds this" with "the viewer
    /// wants this" and so could not be undone: switching the server off left
    /// everything it had contributed behind forever. Native lists are a
    /// read-time view now, so these records are evidence sitting in an
    /// intent-only store and have to go.
    ///
    /// Dropping them is self-healing. A server that is still enabled re-supplies
    /// its titles through the union on the next refresh; one that is switched
    /// off correctly stops — which is the behaviour that was missing.
    ///
    /// `.legacyHomeSeed` is deliberately left alone. It came from the old cached
    /// Home row, not from a live server, so there may be no native source left to
    /// restore it and dropping it would silently lose titles. It is already inert:
    /// only `.local` intents are ever written back out to a server.
    ///
    /// No `.nativeImport` record can be a removal — `remove` always writes
    /// `origin: .local` — so this cannot discard something the viewer deleted.
    ///
    /// - Returns: how many intents were dropped.
    @discardableResult
    public func retireNativeImports(
        profileID: String,
        at date: Date = Date()
    ) throws -> Int {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        guard state.migration.nativeImportRetiredAt == nil else { return 0 }
        let before = state.intents.count
        state.intents.removeAll { $0.origin == .nativeImport }
        state.migration.nativeImportRetiredAt = date
        try persist(state, profileID: profileID)
        return before - state.intents.count
    }

    /// Marks an explicit removal as answered by a later native re-add.
    ///
    /// Called when the reconciler has confirmed the removal reached a
    /// destination and that destination's list has since added the title back.
    /// The tombstone stays — deleting it would let a peer re-deliver the old
    /// `.absent` record and hide the title permanently — but it stops
    /// suppressing, so the union shows the title on the evidence of the server
    /// that holds it. Switching that server off therefore still takes it away.
    @discardableResult
    public func markRemovalSuperseded(
        profileID: String,
        aliasID: MediaAliasID,
        at date: Date = Date()
    ) throws -> Bool {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        guard let index = state.intents.firstIndex(where: {
            $0.aliasID == aliasID
        }), state.intents[index].desiredState == .absent,
            state.intents[index].metadata.suppressesNativePresence
        else { return false }
        state.intents[index].metadata.removalSupersededAt = date
        state.intents[index].changedAt = date
        try persist(state, profileID: profileID)
        return true
    }

    public func migrationMetadata(
        profileID: String
    ) throws -> WatchlistMigrationMetadata {
        try ensureHydrated(profileID)
        return statesByProfile[profileID]!.migration
    }

    /// Canonically rekeys redirected aliases. Duplicate intents merge with oldest
    /// rank retained and latest desired state winning.
    public func reconcileAliases(
        profileID: String,
        aliasSnapshot: MediaAliasSnapshot
    ) throws {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        let snapshot = WatchlistSnapshot(
            intents: state.intents,
            aliasSnapshot: aliasSnapshot
        )
        let rekeyed = snapshot.intentsByAliasID.values.sorted {
            $0.aliasID < $1.aliasID
        }
        guard rekeyed != state.intents else {
            snapshotsByProfile[profileID] = snapshot
            return
        }
        state.intents = rekeyed
        try persist(state, profileID: profileID, aliasSnapshot: aliasSnapshot)
    }

    public func presentationSnapshot(
        profileID: String,
        union: WatchlistUnion,
        aliasSnapshot: MediaAliasSnapshot,
        currentItemsByAliasID: [MediaAliasID: MediaItem],
        indexedSources: ((MediaItem) -> [MediaSourceRef])? = nil,
        capabilities: MediaCapabilities? = nil
    ) throws -> [WatchlistPresentationEntry] {
        try ensureHydrated(profileID)
        let entries = WatchlistPresentationResolver.resolve(
            union: union,
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: currentItemsByAliasID,
            indexedSources: indexedSources,
            capabilities: capabilities
        )
        if ContinueWatchingDiagnostics.isEnabled {
            var line = "watchlist presentation profile=\(profileID) count=\(entries.count)"
            for (position, entry) in entries.prefix(30).enumerated() {
                let item = entry.item
                line += "\n  \(position). \"\(item.title)\""
                if let poster = item.posterURL {
                    line += "\n      art=\(poster.host ?? "?")\(poster.path)"
                } else {
                    line += "\n      art=none"
                }
                line += "\n      item=\(item.id)"
                line += " validated=\(item.locallyValidatedPlayableSource)"
                line += " availability=\(String(describing: item.availability))"
                line += " alias=\(entry.aliasID)"
            }
            ContinueWatchingDiagnostics.emit(line)
        }
        return entries
    }

    /// The watchlist as the viewer sees it: durable intent, plus what the
    /// destinations they have switched ON currently hold, minus explicit
    /// removals. See `WatchlistUnion`.
    public func union(
        profileID: String,
        nativeView: NativeWatchlistView,
        aliasSnapshot: MediaAliasSnapshot,
        enabledDestinationIDs: Set<WatchlistDestinationID>
    ) -> WatchlistUnion {
        WatchlistUnion(
            snapshot: snapshotsByProfile[profileID] ?? .empty,
            nativeView: nativeView,
            aliasSnapshot: aliasSnapshot,
            enabledDestinationIDs: enabledDestinationIDs
        )
    }

    public func captureSyncRecords(
        profileID: String,
        fallback: [SyncRecordID: Data] = [:]
    ) throws -> [SyncRecordID: Data] {
        try ensureHydrated(profileID)
        var result: [SyncRecordID: Data] = [:]
        for intent in statesByProfile[profileID]!.intents {
            let key = WatchlistMediaStateRecordKey(
                profileID: profileID,
                aliasID: intent.aliasID
            )
            let dto = WatchlistIntentSyncDTO(intent: intent)
            guard let bytes = CanonicalJSON.encode(dto) else { continue }
            if let existing = fallback[key.recordName],
               CanonicalJSON.decode(
                WatchlistIntentSyncDTO.self,
                from: existing
               ) == dto {
                result[key.recordName] = existing
            } else {
                result[key.recordName] = bytes
            }
        }
        return result
    }

    @discardableResult
    public func applyRemoteSyncRecords(
        profileID: String,
        changes: [WatchlistMediaStateRecordKey: Data]
    ) throws -> WatchlistRemoteApplyReport {
        if removedProfileIDs.contains(profileID) {
            return WatchlistRemoteApplyReport(
                ignoredDeletedProfileRecordNames:
                    changes.keys.map(\.recordName)
            )
        }
        try hydrate(profileID: profileID)
        var state = statesByProfile[profileID]!
        var applied: [String] = []
        var rejected: [String] = []
        for (key, bytes) in changes.sorted(by: {
            $0.key.recordName < $1.key.recordName
        }) {
            guard key.profileID == profileID,
                  let dto = CanonicalJSON.decode(
                    WatchlistIntentSyncDTO.self,
                    from: bytes
                  ),
                  dto.aliasID == key.aliasID,
                  let incoming = dto.makeIntent()
            else {
                rejected.append(key.recordName)
                continue
            }
            // SyncLedger already resolved the logical-clock conflict. Apply its
            // winning canonical value exactly so capture(apply(bytes)) == bytes.
            replace(incoming, in: &state)
            state.nextRank = max(
                state.nextRank,
                incoming.rank == UInt64.max
                    ? UInt64.max
                    : incoming.rank + 1
            )
            applied.append(key.recordName)
        }
        if !applied.isEmpty {
            try persist(state, profileID: profileID)
        }
        return WatchlistRemoteApplyReport(
            appliedRecordNames: applied,
            rejectedRecordNames: rejected
        )
    }

    public func removeProfile(_ profileID: String) throws {
        if removedProfileIDs.insert(profileID).inserted {
            do {
                try persistDeletionState()
            } catch {
                removedProfileIDs.remove(profileID)
                throw error
            }

        }
        let store = try store(for: profileID)
        try store.destructiveRemove()
        storesByProfile[profileID] = nil
        statesByProfile[profileID] = nil
        snapshotsByProfile[profileID] = nil
        if activeProfileID == profileID { activeProfileID = nil }
    }

    public func isProfileDeleted(_ profileID: String) -> Bool {
        removedProfileIDs.contains(profileID)
    }

    private func persistDeletionState() throws {
        guard let storageDirectory else { return }
        let value = DeletedProfilesState(
            version: DeletedProfilesState.currentVersion,
            profileIDs: removedProfileIDs.sorted()
        )
        guard let data = CanonicalJSON.encode(value) else {
            throw DurableLocalStateError.malformedPayload
        }
        let url = Self.deletionStateURL(in: storageDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: [.atomic])
    }

    private static func deletionStateURL(in directory: URL) -> URL {
        directory.appendingPathComponent("deleted-profiles-v1.json")
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty
            && profileID == profileID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    private func ensureHydrated(_ profileID: String) throws {
        guard !removedProfileIDs.contains(profileID) else {
            throw WatchlistModelError.profileDeleted(profileID)
        }
        guard statesByProfile[profileID] != nil else {
            throw WatchlistModelError.profileNotHydrated(profileID)
        }
    }

    private func replace(
        _ intent: WatchlistIntent,
        in state: inout WatchlistIntentStoreState
    ) {
        state.intents.removeAll { $0.aliasID == intent.aliasID }
        state.intents.append(intent)
    }

    /// Rebalances only at numeric exhaustion. Existing persisted ranks otherwise
    /// remain untouched, so migration/relaunch cannot reshuffle the row.
    private func prepareOrderingSpace(
        in state: inout WatchlistIntentStoreState,
        additionalSlots: Int = 1
    ) {
        let count = state.intents.count
        guard count > 0 else {
            if state.nextRank == UInt64.max { state.nextRank = 0 }
            return
        }
        let minimum = state.intents.map(\.effectiveOrderingRank).min()!
        let maximum = state.intents.map(\.effectiveOrderingRank).max()!
        let margin = Int64(min(
            count + max(1, additionalSlots) + 2,
            Int(Int64.max)
        ))
        let needsRebalance = state.nextRank == UInt64.max
            || minimum <= Int64.min + margin
            || maximum >= Int64.max - margin
        guard needsRebalance else { return }

        let ordered = state.intents.indices.sorted {
            let lhs = state.intents[$0]
            let rhs = state.intents[$1]
            if lhs.effectiveOrderingRank != rhs.effectiveOrderingRank {
                return lhs.effectiveOrderingRank < rhs.effectiveOrderingRank
            }
            return lhs.aliasID < rhs.aliasID
        }
        for (position, index) in ordered.enumerated() {
            state.intents[index].rank = UInt64(position)
            state.intents[index].orderingRank = Int64(position)
        }
        state.nextRank = UInt64(count)
    }

    private func allocateLegacyRank(
        in state: inout WatchlistIntentStoreState
    ) -> UInt64 {
        prepareOrderingSpace(in: &state)
        let rank = state.nextRank
        state.nextRank += 1
        return rank
    }

    private func nextFrontOrderingRank(
        in state: WatchlistIntentStoreState
    ) -> Int64 {
        guard let minimum = state.intents.map(\.effectiveOrderingRank).min()
        else { return 0 }
        return minimum - 1
    }

    private func nextBackOrderingRank(
        in state: WatchlistIntentStoreState
    ) -> Int64 {
        guard let maximum = state.intents.map(\.effectiveOrderingRank).max()
        else { return 0 }
        return maximum + 1
    }

    private func persist(
        _ state: WatchlistIntentStoreState,
        profileID: String,
        aliasSnapshot: MediaAliasSnapshot = .empty
    ) throws {
        let canonical = WatchlistIntentStoreState(
            version: state.version,
            nextRank: state.nextRank,
            intents: state.intents,
            migration: state.migration
        )
        let store = try store(for: profileID)
        try store.save(canonical)
        statesByProfile[profileID] = canonical
        snapshotsByProfile[profileID] = WatchlistSnapshot(
            intents: canonical.intents,
            aliasSnapshot: aliasSnapshot
        )
    }

    private func store(
        for profileID: String
    ) throws -> any WatchlistIntentStoring {
        if let existing = storesByProfile[profileID] { return existing }
        let created: any WatchlistIntentStoring
        if let customStoreFactory {
            created = try customStoreFactory(profileID)
        } else if let storageDirectory {
            created = try AtomicWatchlistIntentStore(
                directoryURL: storageDirectory,
                profileID: profileID
            )
        } else {
            created = InMemoryWatchlistIntentStore()
        }
        storesByProfile[profileID] = created
        return created
    }
}
