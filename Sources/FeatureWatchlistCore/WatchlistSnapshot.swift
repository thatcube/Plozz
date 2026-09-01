import CoreModels
import Foundation

public struct WatchlistSnapshot: Sendable, Equatable {
    public let orderedEntries: [WatchlistIntent]
    public let intentsByAliasID: [MediaAliasID: WatchlistIntent]
    public let activeAliasIDs: Set<MediaAliasID>
    public let resolvedAliasesByID: [MediaAliasID: MediaAliasID]
    public let tombstoneCount: Int

    public init(
        intents: [WatchlistIntent],
        aliasSnapshot: MediaAliasSnapshot = .empty
    ) {
        var redirects = aliasSnapshot.redirectsByID
        var merged: [MediaAliasID: WatchlistIntent] = [:]
        for intent in intents {
            let winner = aliasSnapshot.resolvedAliasID(for: intent.aliasID) ?? intent.aliasID
            redirects[intent.aliasID] = winner
            var rekeyed = intent
            if winner != intent.aliasID,
               let value = WatchlistIntent(
                aliasID: winner,
                kind: intent.kind,
                desiredState: intent.desiredState,
                rank: intent.rank,
                orderingRank: intent.orderingRank,
                origin: intent.origin,
                changedAt: intent.changedAt,
                presentation: intent.presentation,
                metadata: intent.metadata
               ) {
                rekeyed = value
            }
            if let existing = merged[winner] {
                merged[winner] = Self.merge(existing, rekeyed)
            } else {
                merged[winner] = rekeyed
            }
        }
        intentsByAliasID = merged
        resolvedAliasesByID = redirects
        activeAliasIDs = Set(merged.values.lazy.filter {
            $0.desiredState == .present
        }.map(\.aliasID))
        orderedEntries = merged.values.filter {
            $0.desiredState == .present
        }.sorted {
            if $0.effectiveOrderingRank != $1.effectiveOrderingRank {
                return $0.effectiveOrderingRank < $1.effectiveOrderingRank
            }
            if $0.changedAt != $1.changedAt {
                return $0.changedAt > $1.changedAt
            }
            return $0.aliasID < $1.aliasID
        }
        tombstoneCount = merged.values.lazy.filter {
            $0.desiredState == .absent
        }.count
    }

    public static let empty = WatchlistSnapshot(intents: [])

    public func resolvedAliasID(for aliasID: MediaAliasID) -> MediaAliasID {
        resolvedAliasesByID[aliasID] ?? aliasID
    }

    public func contains(aliasID: MediaAliasID) -> Bool {
        activeAliasIDs.contains(resolvedAliasID(for: aliasID))
    }

    public func intent(for aliasID: MediaAliasID) -> WatchlistIntent? {
        intentsByAliasID[resolvedAliasID(for: aliasID)]
    }

    static func merge(
        _ lhs: WatchlistIntent,
        _ rhs: WatchlistIntent
    ) -> WatchlistIntent {
        let newest: WatchlistIntent
        if lhs.changedAt != rhs.changedAt {
            newest = lhs.changedAt > rhs.changedAt ? lhs : rhs
        } else {
            let left = CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: lhs)) ?? Data()
            let right = CanonicalJSON.encode(WatchlistIntentSyncDTO(intent: rhs)) ?? Data()
            newest = left.lexicographicallyPrecedes(right) ? rhs : lhs
        }
        let orderingRank: Int64
        if newest.desiredState == .present {
            orderingRank = [lhs, rhs].filter {
                $0.desiredState == .present
            }.map(\.effectiveOrderingRank).min()
                ?? newest.effectiveOrderingRank
        } else {
            orderingRank = min(
                lhs.effectiveOrderingRank,
                rhs.effectiveOrderingRank
            )
        }
        return WatchlistIntent(
            aliasID: lhs.aliasID,
            kind: lhs.kind,
            desiredState: newest.desiredState,
            rank: min(lhs.rank, rhs.rank),
            orderingRank: orderingRank,
            origin: newest.origin,
            changedAt: newest.changedAt,
            presentation: newest.presentation ?? lhs.presentation ?? rhs.presentation,
            metadata: WatchlistIntentMetadata(
                sourceDestinationIDs:
                    lhs.metadata.sourceDestinationIDs
                    + rhs.metadata.sourceDestinationIDs,
                lastExplicitRemovalAt: [
                    lhs.metadata.lastExplicitRemovalAt,
                    rhs.metadata.lastExplicitRemovalAt
                ].compactMap { $0 }.max(),
                lastReconciledAt: [
                    lhs.metadata.lastReconciledAt,
                    rhs.metadata.lastReconciledAt
                ].compactMap { $0 }.max(),
                removalSupersededAt: [
                    lhs.metadata.removalSupersededAt,
                    rhs.metadata.removalSupersededAt
                ].compactMap { $0 }.max()
            )
        )!
    }
}
