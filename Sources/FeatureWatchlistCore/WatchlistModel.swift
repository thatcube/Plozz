import CoreModels
import Foundation
import Observation

public enum WatchlistModelError: Error, Equatable, Sendable {
    case profileNotHydrated(String)
    case profileDeleted(String)
    case malformedRemoteRecord(String)
}

public struct WatchlistNativeImportCandidate: Sendable {
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let presentation: MediaAliasPresentation?
    public let observedAfterConfirmedAbsence: Bool

    public init(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation? = nil,
        observedAfterConfirmedAbsence: Bool = false
    ) {
        self.aliasID = aliasID
        self.kind = kind
        self.presentation = presentation
        self.observedAfterConfirmedAbsence =
            observedAfterConfirmedAbsence
    }
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
        let existing = state.intents.first { $0.aliasID == aliasID }
        let rank = existing?.rank ?? state.nextRank
        if existing == nil { state.nextRank &+= 1 }
        var sources = existing?.metadata.sourceDestinationIDs ?? []
        if let sourceDestinationID {
            sources.append(sourceDestinationID.rawValue)
        }
        let intent = WatchlistIntent(
            aliasID: aliasID,
            kind: kind,
            desiredState: .present,
            rank: rank,
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
        let existing = state.intents.first { $0.aliasID == aliasID }
        let rank = existing?.rank ?? state.nextRank
        if existing == nil { state.nextRank &+= 1 }
        let intent = WatchlistIntent(
            aliasID: aliasID,
            kind: kind,
            desiredState: .absent,
            rank: rank,
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

    /// Additive native import. Explicit Plozz removals stay suppressed until the
    /// reconciler has observed an absence boundary for this destination.
    @discardableResult
    public func importNative(
        profileID: String,
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        destinationID: WatchlistDestinationID,
        presentation: MediaAliasPresentation? = nil,
        observedAfterConfirmedAbsence: Bool = false,
        at changedAt: Date = Date()
    ) throws -> Bool {
        try ensureHydrated(profileID)
        let existing = statesByProfile[profileID]!.intents.first {
            $0.aliasID == aliasID
        }

        if existing?.desiredState == .absent,
           existing?.metadata.lastExplicitRemovalAt != nil,
           !observedAfterConfirmedAbsence {
            return false
        }
        _ = try add(
            profileID: profileID,
            aliasID: aliasID,
            kind: kind,
            presentation: presentation,
            origin: .nativeImport,
            sourceDestinationID: destinationID,
            at: changedAt
        )
        return true
    }

    /// Applies one destination's additive import in memory and persists once.
    @discardableResult
    public func importNativeBatch(
        profileID: String,
        destinationID: WatchlistDestinationID,
        candidates: [WatchlistNativeImportCandidate],
        markImportComplete: Bool = true,
        at changedAt: Date = Date()
    ) throws -> Int {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        var byAlias = Dictionary(
            uniqueKeysWithValues: state.intents.map { ($0.aliasID, $0) }
        )
        var importedCount = 0
        var changed = false

        for candidate in candidates {
            guard candidate.kind == .movie || candidate.kind == .series else {
                continue
            }
            let existing = byAlias[candidate.aliasID]
            if existing?.desiredState == .absent,
               existing?.metadata.lastExplicitRemovalAt != nil,
               !candidate.observedAfterConfirmedAbsence {
                continue
            }
            var sources = existing?.metadata.sourceDestinationIDs ?? []
            sources.append(destinationID.rawValue)
            let isReactivation = existing?.desiredState == .absent
            let intent = WatchlistIntent(
                aliasID: candidate.aliasID,
                kind: candidate.kind,
                desiredState: .present,
                rank: existing?.rank ?? state.nextRank,
                origin: isReactivation || existing == nil
                    ? .nativeImport
                    : existing!.origin,
                changedAt: isReactivation || existing == nil
                    ? changedAt
                    : existing!.changedAt,
                presentation: candidate.presentation ?? existing?.presentation,
                metadata: WatchlistIntentMetadata(
                    sourceDestinationIDs: sources,
                    lastExplicitRemovalAt:
                        existing?.metadata.lastExplicitRemovalAt,
                    lastReconciledAt: isReactivation || existing == nil
                        ? changedAt
                        : existing?.metadata.lastReconciledAt
                )
            )!
            if existing == nil { state.nextRank &+= 1 }
            if intent != existing {
                byAlias[candidate.aliasID] = intent
                changed = true
            }
            if existing == nil || isReactivation { importedCount += 1 }
        }

        if markImportComplete,
           !state.migration.hasCompletedNativeImport(
            destinationID: destinationID.rawValue
           ) {
            var ids = state.migration.completedNativeImportDestinationIDs
            ids.append(destinationID.rawValue)
            state.migration = WatchlistMigrationMetadata(
                legacyHomeSeedCompletedAt:
                    state.migration.legacyHomeSeedCompletedAt,
                completedNativeImportDestinationIDs: ids
            )
            changed = true
        }
        guard changed else { return importedCount }
        state.intents = byAlias.values.sorted { $0.aliasID < $1.aliasID }
        try persist(state, profileID: profileID)
        return importedCount
    }

    public func seedLegacyIfNeeded(
        profileID: String,
        entries: [(MediaAliasID, MediaItemKind, MediaAliasPresentation?)]
    ) throws {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        guard state.migration.legacyHomeSeedCompletedAt == nil else { return }
        for (aliasID, kind, presentation) in entries
        where state.intents.contains(where: { $0.aliasID == aliasID }) == false {
            guard let intent = WatchlistIntent(
                aliasID: aliasID,
                kind: kind,
                desiredState: .present,
                rank: state.nextRank,
                origin: .legacyHomeSeed,
                presentation: presentation
            ) else { continue }
            state.nextRank &+= 1
            state.intents.append(intent)
        }
        state.migration.legacyHomeSeedCompletedAt = Date()
        try persist(state, profileID: profileID)
    }

    public func markNativeImportComplete(
        profileID: String,
        destinationID: WatchlistDestinationID,
        at date: Date = Date()
    ) throws {
        try ensureHydrated(profileID)
        var state = statesByProfile[profileID]!
        var ids = state.migration.completedNativeImportDestinationIDs
        ids.append(destinationID.rawValue)
        state.migration = WatchlistMigrationMetadata(
            legacyHomeSeedCompletedAt:
                state.migration.legacyHomeSeedCompletedAt,
            completedNativeImportDestinationIDs: ids
        )
        for index in state.intents.indices {
            if state.intents[index].metadata.sourceDestinationIDs.contains(
                destinationID.rawValue
            ) {
                state.intents[index].metadata.lastReconciledAt = date
            }
        }
        try persist(state, profileID: profileID)
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
        aliasSnapshot: MediaAliasSnapshot,
        currentItemsByAliasID: [MediaAliasID: MediaItem]
    ) throws -> [WatchlistPresentationEntry] {
        try ensureHydrated(profileID)
        return WatchlistPresentationResolver.resolve(
            snapshot: snapshotsByProfile[profileID] ?? .empty,
            aliasSnapshot: aliasSnapshot,
            currentItemsByAliasID: currentItemsByAliasID
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
            state.nextRank = max(state.nextRank, incoming.rank &+ 1)
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
