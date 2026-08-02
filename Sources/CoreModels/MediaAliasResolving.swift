import Foundation

public protocol MediaAliasResolving: Sendable {
    associatedtype Snapshot: Sendable

    func snapshot() async -> Snapshot
    func lookup(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID?
    ) async -> MediaAliasID?
    func resolveOrCreate(
        evidence: MediaAliasEvidence,
        preferredAliasID: MediaAliasID?
    ) async throws -> MediaAliasID
    func enrich(aliasID: MediaAliasID, with evidence: MediaAliasEvidence) async throws
    func mergeRemote(
        records: [MediaAliasSyncDTO],
        deletedAliasIDs: Set<MediaAliasID>
    ) async throws
}
