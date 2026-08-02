import CoreModels
import Foundation
import Observation

public struct MediaAliasRemoteChange: Sendable {
    public let key: MediaStateRecordKey
    public let value: Data?

    public init(key: MediaStateRecordKey, value: Data?) {
        self.key = key
        self.value = value
    }
}

public struct MediaAliasRemoteApplyReport: Equatable, Sendable {
    public let rejectedRecordNames: [String]
    public let forwardCompatibleRecordNames: [String]
    public let ignoredDeletedProfileRecordNames: [String]

    public init(
        rejectedRecordNames: [String] = [],
        forwardCompatibleRecordNames: [String] = [],
        ignoredDeletedProfileRecordNames: [String] = []
    ) {
        self.rejectedRecordNames = rejectedRecordNames.sorted()
        self.forwardCompatibleRecordNames = forwardCompatibleRecordNames.sorted()
        self.ignoredDeletedProfileRecordNames = ignoredDeletedProfileRecordNames.sorted()
    }

    public static let empty = Self()
}

@MainActor
@Observable
public final class MediaAliasLedgerModel {
    private struct DeletedProfilesState: Codable {
        static let currentVersion = 1

        let version: Int
        let profileIDs: [String]
    }

    public private(set) var snapshotsByProfile: [String: MediaAliasSnapshot] = [:]
    public private(set) var activeProfileID: String?
    public private(set) var deletionStateRecoveryOccurred = false

    private let legacyDurableStore: DurableLocalStateStore?
    private let storageDirectory: URL?
    private var ledgersByProfile: [String: MediaAliasLedger] = [:]
    private var loadingLedgersByProfile: [
        String: Task<MediaAliasLedger, Error>
    ] = [:]
    private var removedProfileIDs: Set<String> = []
    private var pendingPurgeProfileIDs: Set<String> = []

    public init(
        durableStore: DurableLocalStateStore? = nil,
        storageDirectory: URL? = nil
    ) {
        legacyDurableStore = durableStore
        let resolvedStorageDirectory: URL?
        if let storageDirectory {
            resolvedStorageDirectory = storageDirectory
        } else if durableStore != nil {
            resolvedStorageDirectory = Self.defaultStorageDirectory()
        } else {
            resolvedStorageDirectory = nil
        }
        self.storageDirectory = resolvedStorageDirectory

        guard let resolvedStorageDirectory else { return }
        let deletionURL = Self.deletionStateURL(in: resolvedStorageDirectory)
        guard FileManager.default.fileExists(atPath: deletionURL.path) else {
            return
        }
        do {
            let data = try Data(contentsOf: deletionURL)
            removedProfileIDs = try Self.deletedProfileIDs(from: data)
            pendingPurgeProfileIDs = removedProfileIDs
        } catch {
            deletionStateRecoveryOccurred = true
            Self.quarantineCorruptDeletionState(at: deletionURL)
        }
    }

    public var activeSnapshot: MediaAliasSnapshot {
        guard let activeProfileID else { return .empty }
        return snapshotsByProfile[activeProfileID] ?? .empty
    }

    public func activate(profileID: String) async throws {
        try reviveProfiles([profileID])
        let ledger = try await ledger(for: profileID)
        snapshotsByProfile[profileID] = await ledger.snapshot()
        activeProfileID = profileID
    }

    public func loadProfiles(_ profileIDs: [String]) async throws {
        let profileIDs = Set(profileIDs)
        try reviveProfiles(profileIDs)
        for profileID in profileIDs.sorted() {
            let ledger = try await ledger(for: profileID)
            snapshotsByProfile[profileID] = await ledger.snapshot()
        }
    }

    public func lookup(
        profileID: String,
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil
    ) async throws -> MediaAliasID? {
        try ensureDeletionStateAvailable()
        guard !removedProfileIDs.contains(profileID) else { return nil }
        let ledger = try await ledger(for: profileID)
        return await ledger.lookup(
            evidence: evidence,
            preferredAliasID: preferredAliasID
        )
    }

    @discardableResult
    public func resolveOrCreate(
        profileID: String,
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID? = nil
    ) async throws -> MediaAliasID {
        try reviveProfiles([profileID])
        let ledger = try await ledger(for: profileID)
        let id = try await ledger.resolveOrCreate(
            evidence: evidence,
            preferredAliasID: preferredAliasID
        )
        snapshotsByProfile[profileID] = await ledger.snapshot()
        return id
    }

    public func enrich(
        profileID: String,
        aliasID: MediaAliasID,
        evidence: MediaAliasEvidence
    ) async throws {
        try ensureDeletionStateAvailable()
        guard !removedProfileIDs.contains(profileID) else {
            throw MediaAliasLedgerError.profileDeleted(profileID)
        }
        let ledger = try await ledger(for: profileID)
        try await ledger.enrich(aliasID: aliasID, with: evidence)
        snapshotsByProfile[profileID] = await ledger.snapshot()
    }

    public func captureAllAliasSyncRecords(
        profileIDs: [String],
        fallback: [SyncRecordID: Data] = [:]
    ) async throws -> [SyncRecordID: Data] {
        try ensureDeletionStateAvailable()
        for profileID in pendingPurgeProfileIDs.sorted() {
            try await purgeProfileStorage(profileID)
            pendingPurgeProfileIDs.remove(profileID)
        }
        try await loadProfiles(profileIDs)
        var captured: [SyncRecordID: Data] = [:]
        for profileID in ledgersByProfile.keys.sorted()
        where !removedProfileIDs.contains(profileID) {
            guard let ledger = ledgersByProfile[profileID] else { continue }
            for dto in await ledger.captureSyncDTOs() {
                let key = MediaStateRecordKey(profileID: profileID, aliasID: dto.id)
                guard let localBytes = CanonicalJSON.encode(dto) else { continue }
                if let fallbackBytes = fallback[key.recordName],
                   let fallbackDTO = CanonicalJSON.decode(
                       MediaAliasSyncDTO.self,
                       from: fallbackBytes
                   ),
                   fallbackDTO.id == dto.id,
                   fallbackDTO == dto {
                    captured[key.recordName] = fallbackBytes
                } else {
                    captured[key.recordName] = localBytes
                }
            }
        }
        for (recordName, bytes) in fallback where captured[recordName] == nil {
            guard let key = MediaStateRecordKey.parse(recordName),
                  !removedProfileIDs.contains(key.profileID) else {
                continue
            }
            captured[recordName] = bytes
        }
        return captured
    }

    @discardableResult
    public func applyRemoteChanges(
        _ changes: [MediaStateRecordKey: Data?]
    ) async throws -> MediaAliasRemoteApplyReport {
        try await applyRemoteChanges(changes.map {
            MediaAliasRemoteChange(key: $0.key, value: $0.value)
        })
    }

    @discardableResult
    public func applyRemoteChanges(
        _ changes: [MediaAliasRemoteChange]
    ) async throws -> MediaAliasRemoteApplyReport {
        try ensureDeletionStateAvailable()
        var rejectedRecordNames: [String] = []
        var forwardCompatibleRecordNames: [String] = []
        var ignoredDeletedProfileRecordNames: [String] = []
        let grouped = Dictionary(grouping: changes, by: { $0.key.profileID })
        for profileID in grouped.keys.sorted() {
            if removedProfileIDs.contains(profileID) {
                ignoredDeletedProfileRecordNames.append(
                    contentsOf: grouped[profileID, default: []].map(\.key.recordName)
                )
                continue
            }
            let ledger = try await ledger(for: profileID)
            var incoming: [MediaAliasSyncDTO] = []
            var deleted: Set<MediaAliasID> = []
            for change in grouped[profileID, default: []] {
                let key = change.key
                let payload = change.value
                guard let payload else {
                    deleted.insert(key.aliasID)
                    continue
                }
                guard let dto = CanonicalJSON.decode(
                    MediaAliasSyncDTO.self,
                    from: payload
                ), dto.id == key.aliasID else {
                    rejectedRecordNames.append(key.recordName)
                    continue
                }
                if CanonicalJSON.encode(dto) != payload {
                    forwardCompatibleRecordNames.append(key.recordName)
                }
                incoming.append(dto)
            }
            try await ledger.mergeRemote(
                records: incoming,
                deletedAliasIDs: deleted
            )
            snapshotsByProfile[profileID] = await ledger.snapshot()
        }
        return MediaAliasRemoteApplyReport(
            rejectedRecordNames: rejectedRecordNames,
            forwardCompatibleRecordNames: forwardCompatibleRecordNames,
            ignoredDeletedProfileRecordNames: ignoredDeletedProfileRecordNames
        )
    }

    public func removeProfile(_ profileID: String) async throws {
        try ensureDeletionStateAvailable()
        if removedProfileIDs.insert(profileID).inserted {
            do {
                try persistDeletionState()
            } catch {
                removedProfileIDs.remove(profileID)
                throw error
            }
        }
        pendingPurgeProfileIDs.insert(profileID)
        try await purgeProfileStorage(profileID)
        pendingPurgeProfileIDs.remove(profileID)
        ledgersByProfile[profileID] = nil
        snapshotsByProfile[profileID] = nil
        if activeProfileID == profileID {
            activeProfileID = nil
        }
    }

    private func ledger(for profileID: String) async throws -> MediaAliasLedger {
        try ensureDeletionStateAvailable()
        guard !removedProfileIDs.contains(profileID) else {
            throw MediaAliasLedgerError.profileDeleted(profileID)
        }
        if let existing = ledgersByProfile[profileID] {
            return existing
        }
        if let loading = loadingLedgersByProfile[profileID] {
            return try await loading.value
        }
        let store = try makeStore(for: profileID)
        let loading = Task.detached(priority: .userInitiated) {
            try MediaAliasLedger(profileID: profileID, store: store)
        }
        loadingLedgersByProfile[profileID] = loading
        let created: MediaAliasLedger
        do {
            created = try await loading.value
        } catch {
            loadingLedgersByProfile[profileID] = nil
            throw error
        }
        loadingLedgersByProfile[profileID] = nil
        guard !removedProfileIDs.contains(profileID) else {
            try await created.removeForProfileDeletion()
            throw MediaAliasLedgerError.profileDeleted(profileID)
        }
        ledgersByProfile[profileID] = created
        return created
    }

    private func makeStore(for profileID: String) throws -> any MediaAliasStoring {
        if let storageDirectory {
            let legacyStore: (any MediaAliasStoring)?
            if let legacyDurableStore {
                legacyStore = try DurableMediaAliasStore(
                    store: legacyDurableStore,
                    profileID: profileID
                )
            } else {
                legacyStore = nil
            }
            return try AtomicFileMediaAliasStore(
                directoryURL: storageDirectory,
                profileID: profileID,
                legacyStore: legacyStore
            )
        } else if legacyDurableStore != nil {
            throw DurableLocalStateError.storageUnavailable
        } else {
            return InMemoryMediaAliasStore()
        }
    }

    private func purgeProfileStorage(_ profileID: String) async throws {
        if let ledger = ledgersByProfile[profileID] {
            try await ledger.removeForProfileDeletion()
        } else {
            try makeStore(for: profileID).destructiveRemove()
        }
        ledgersByProfile[profileID] = nil
        snapshotsByProfile[profileID] = nil
    }

    private func reviveProfiles(_ profileIDs: Set<String>) throws {
        try ensureDeletionStateAvailable()
        let revived = removedProfileIDs.intersection(profileIDs)
        guard !revived.isEmpty else { return }
        removedProfileIDs.subtract(revived)
        pendingPurgeProfileIDs.subtract(revived)
        do {
            try persistDeletionState()
        } catch {
            removedProfileIDs.formUnion(revived)
            pendingPurgeProfileIDs.formUnion(revived)
            throw error
        }
    }

    private func ensureDeletionStateAvailable() throws {
        // Kept as the single gate for future storage-health checks.
    }

    private func persistDeletionState() throws {
        guard let storageDirectory else { return }
        let state = DeletedProfilesState(
            version: DeletedProfilesState.currentVersion,
            profileIDs: removedProfileIDs.sorted()
        )
        let data = try MediaAliasEncodingMetrics.canonicalData(state)
        let url = Self.deletionStateURL(in: storageDirectory)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }

    private static func deletionStateURL(in directory: URL) -> URL {
        directory.appendingPathComponent(
            "deleted-profiles-v1.json",
            isDirectory: false
        )
    }

    private static func deletedProfileIDs(from data: Data) throws -> Set<String> {
        let state = try JSONDecoder().decode(DeletedProfilesState.self, from: data)
        guard state.version >= DeletedProfilesState.currentVersion,
              state.profileIDs.allSatisfy(isValidProfileID) else {
            throw DurableLocalStateError.malformedPayload
        }
        return Set(state.profileIDs)
    }

    private static func isValidProfileID(_ profileID: String) -> Bool {
        !profileID.isEmpty
            && profileID == profileID.trimmingCharacters(
                in: .whitespacesAndNewlines
            )
    }

    private static func quarantineCorruptDeletionState(at url: URL) {
        let quarantineURL = url.deletingPathExtension()
            .appendingPathExtension("corrupt-\(UUID().uuidString).json")
        try? FileManager.default.moveItem(at: url, to: quarantineURL)
    }

    private static func defaultStorageDirectory() -> URL? {
        FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first?
            .appendingPathComponent("Plozz", isDirectory: true)
            .appendingPathComponent("MediaAliasLedger", isDirectory: true)
    }
}
