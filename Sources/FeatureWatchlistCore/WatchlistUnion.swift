import CoreModels
import Foundation

/// One row of the watchlist as the viewer sees it.
public struct WatchlistUnionEntry: Identifiable, Hashable, Sendable {
    public var id: MediaAliasID { aliasID }
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let presentation: MediaAliasPresentation?
    /// True when a durable intent puts this here — the viewer asked for it.
    /// False when it is here only because an enabled server's own list holds it.
    public let isExplicit: Bool
    /// The viewer's own copy, as answered by the server that holds the list.
    /// See `NativeWatchlistEntry.ownedSource`.
    public let ownedSource: MediaSourceRef?

    public init(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation?,
        isExplicit: Bool,
        ownedSource: MediaSourceRef? = nil
    ) {
        self.aliasID = aliasID
        self.kind = kind
        self.presentation = presentation
        self.isExplicit = isExplicit
        self.ownedSource = ownedSource
    }
}

/// The watchlist the viewer sees: durable intent, plus what the servers they
/// have switched ON currently hold, minus what they have explicitly removed.
///
/// The universal watchlist used to IMPORT native lists — every native entry
/// became a durable `.present` intent in the profile's ledger. That conflated
/// two different statements: "server X's list holds this title right now"
/// (evidence, which changes when a server is switched off) and "the viewer wants
/// this title" (intent, which is deliberately server-independent). Because only
/// intent was modelled, an imported title could not be taken back: switching the
/// server off left everything it had contributed behind, and the only way out
/// was deleting each title by hand.
///
/// So evidence is no longer promoted. Only what the viewer explicitly acts on is
/// written down; everything else is recomputed here, at read time, over the
/// destinations that are enabled right now. Switching a server off retracts its
/// contribution for free, because there was never anything to retract.
public struct WatchlistUnion: Sendable, Equatable {
    public let orderedEntries: [WatchlistUnionEntry]
    public let activeAliasIDs: Set<MediaAliasID>
    /// True when at least one enabled destination is showing stale entries
    /// because its last read failed. Callers use it to explain a watchlist that
    /// may be incomplete rather than silently presenting it as the whole truth.
    public let hasStaleDestinations: Bool

    public static let empty = WatchlistUnion(
        snapshot: .empty,
        nativeView: .empty,
        aliasSnapshot: .empty,
        enabledDestinationIDs: []
    )

    /// - Parameter aliasSnapshot: the DURABLE alias ledger, which is the only
    ///   thing that knows the whole redirect graph.
    ///
    ///   `WatchlistSnapshot` carries a redirect table too, but it is built from
    ///   the intents it holds — and `WatchlistModel.hydrate` builds it with an
    ///   EMPTY alias snapshot, so on the common path it knows almost nothing. A
    ///   native-only title has no intent, so resolving it through there left it
    ///   on its pre-merge id while the same title arriving as a live library item
    ///   resolved to the canonical one. Two ids for one title is precisely what
    ///   the alias ledger exists to prevent: the row couldn't match its own
    ///   library copy ("not in your library — request it") and the page it opened
    ///   couldn't find it on the watchlist.
    public init(
        snapshot: WatchlistSnapshot,
        nativeView: NativeWatchlistView,
        aliasSnapshot: MediaAliasSnapshot,
        enabledDestinationIDs: Set<WatchlistDestinationID>
    ) {
        var entries: [WatchlistUnionEntry] = []
        var seen: Set<MediaAliasID> = []

        // Explicit intent first, in the order the viewer arranged it. Adds
        // allocate at the front, so this is already the list they built.
        // What each server said it owns, keyed by alias, so an explicit intent
        // that a server ALSO holds still picks up the owned copy.
        var ownedByAlias: [MediaAliasID: MediaSourceRef] = [:]
        for (rawID, bucket) in nativeView.bucketsByDestinationID {
            guard let destinationID = WatchlistDestinationID(rawValue: rawID),
                  enabledDestinationIDs.contains(destinationID) else { continue }
            for entry in bucket.entries where entry.ownedSource != nil {
                let aliasID = aliasSnapshot.resolvedAliasID(for: entry.aliasID)
                    ?? entry.aliasID
                if ownedByAlias[aliasID] == nil {
                    ownedByAlias[aliasID] = entry.ownedSource
                }
            }
        }

        for intent in snapshot.orderedEntries {
            let aliasID = aliasSnapshot.resolvedAliasID(for: intent.aliasID)
                ?? snapshot.resolvedAliasID(for: intent.aliasID)
            guard seen.insert(aliasID).inserted else { continue }
            entries.append(WatchlistUnionEntry(
                aliasID: aliasID,
                kind: intent.kind,
                presentation: intent.presentation,
                isExplicit: true,
                ownedSource: ownedByAlias[aliasID]
            ))
        }

        // Then the servers'. Sorted by destination so two devices reading the
        // same set agree, and by the destination's own list position within it
        // so the order doesn't shuffle between reads.
        var stale = false
        var native: [(WatchlistDestinationID, NativeWatchlistEntry)] = []
        for (rawID, bucket) in nativeView.bucketsByDestinationID {
            guard let destinationID = WatchlistDestinationID(rawValue: rawID),
                  enabledDestinationIDs.contains(destinationID) else { continue }
            if bucket.isStale { stale = true }
            for entry in bucket.entries { native.append((destinationID, entry)) }
        }
        native.sort {
            if $0.0.rawValue != $1.0.rawValue {
                return $0.0.rawValue < $1.0.rawValue
            }
            if $0.1.index != $1.1.index { return $0.1.index < $1.1.index }
            return $0.1.aliasID < $1.1.aliasID
        }

        for (_, entry) in native {
            let aliasID = aliasSnapshot.resolvedAliasID(for: entry.aliasID)
                ?? snapshot.resolvedAliasID(for: entry.aliasID)
            guard seen.insert(aliasID).inserted else { continue }
            // A removal the viewer made here outranks a server that still lists
            // the title. Without this, deleting something that lives on Plex
            // would simply come back on the next read.
            if let intent = snapshot.intent(for: aliasID),
               intent.desiredState == .absent,
               intent.metadata.suppressesNativePresence {
                continue
            }
            entries.append(WatchlistUnionEntry(
                aliasID: aliasID,
                kind: entry.kind,
                presentation: entry.presentation,
                isExplicit: false,
                ownedSource: entry.ownedSource ?? ownedByAlias[aliasID]
            ))
        }

        orderedEntries = entries
        activeAliasIDs = Set(entries.map(\.aliasID))
        hasStaleDestinations = stale
    }

    public func contains(aliasID: MediaAliasID) -> Bool {
        activeAliasIDs.contains(aliasID)
    }

    /// A cheap value that changes whenever the union would. Callers cache
    /// membership against it rather than recomputing per card; every input is
    /// O(1) on purpose, because this is read once per item.
    public var revision: UInt64 {
        var hasher = Hasher()
        hasher.combine(orderedEntries.count)
        hasher.combine(activeAliasIDs.count)
        hasher.combine(hasStaleDestinations)
        return UInt64(bitPattern: Int64(hasher.finalize()))
    }
}
