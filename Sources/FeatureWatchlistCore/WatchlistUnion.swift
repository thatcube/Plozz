import CoreModels
import Foundation

/// One row of the watchlist as the viewer sees it.
public struct WatchlistUnionEntry: Identifiable, Hashable, Sendable {
    public var id: MediaAliasID { aliasID }
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let presentation: MediaAliasPresentation?
    public let artworkSourceAccountID: String?
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
        ownedSource: MediaSourceRef? = nil,
        artworkSourceAccountID: String? = nil
    ) {
        self.aliasID = aliasID
        self.kind = kind
        self.presentation = presentation
        self.artworkSourceAccountID = artworkSourceAccountID
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
    public let revision: UInt64

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
        var ownedPresentationByAlias:
            [MediaAliasID: MediaAliasPresentation] = [:]
        var ownedArtworkAccountByAlias: [MediaAliasID: String] = [:]
        var ownedEntryByTitleKey: [String: NativeWatchlistEntry] = [:]
        for (rawID, bucket) in nativeView.bucketsByDestinationID {
            guard let destinationID = WatchlistDestinationID(rawValue: rawID),
                  enabledDestinationIDs.contains(destinationID) else { continue }
            for entry in bucket.entries where entry.ownedSource != nil {
                let aliasID = aliasSnapshot.resolvedAliasID(for: entry.aliasID)
                    ?? entry.aliasID
                if ownedByAlias[aliasID] == nil {
                    ownedByAlias[aliasID] = entry.ownedSource
                    ownedPresentationByAlias[aliasID] =
                        entry.ownedPresentation
                    if entry.ownedPresentation != nil {
                        ownedArtworkAccountByAlias[aliasID] =
                            entry.ownedSource?.accountID
                    }
                }
                if let key = Self.titleKey(
                    kind: entry.kind,
                    presentation: entry.presentation
                ), ownedEntryByTitleKey[key] == nil {
                    ownedEntryByTitleKey[key] = entry
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
                // An explicit intent determines order and membership, not which
                // poster is best. When a server has proved the owned copy, keep
                // its presentation with the source so the badge and artwork
                // upgrade together.
                presentation:
                    ownedPresentationByAlias[aliasID] ?? intent.presentation,
                isExplicit: true,
                ownedSource: ownedByAlias[aliasID],
                artworkSourceAccountID:
                    ownedArtworkAccountByAlias[aliasID]
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

        for (destinationID, originalEntry) in native {
            var entry = originalEntry
            var aliasID = aliasSnapshot.resolvedAliasID(for: entry.aliasID)
                ?? snapshot.resolvedAliasID(for: entry.aliasID)
            // Keep the first server slot, but render it with the owned copy a
            // later destination supplied. Ownership is presentation evidence,
            // not a reason to reorder the viewer's server list.
            if entry.ownedSource == nil,
               let key = Self.titleKey(
                kind: entry.kind,
                presentation: entry.presentation
               ),
               let ownedEntry = ownedEntryByTitleKey[key] {
                entry = ownedEntry
                aliasID = aliasSnapshot.resolvedAliasID(for: ownedEntry.aliasID)
                    ?? snapshot.resolvedAliasID(for: ownedEntry.aliasID)
            }
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
                presentation:
                    entry.ownedPresentation ?? entry.presentation,
                isExplicit: false,
                ownedSource: entry.ownedSource ?? ownedByAlias[aliasID],
                artworkSourceAccountID: entry.ownedPresentation != nil
                    ? entry.ownedSource?.accountID
                    : entry.presentationAccountID
                        ?? Self.presentationAccountID(
                            from: destinationID
                        )
            ))
        }

        orderedEntries = entries
        activeAliasIDs = Set(entries.map(\.aliasID))
        hasStaleDestinations = stale
        var hasher = Hasher()
        hasher.combine(entries)
        hasher.combine(stale)
        revision = UInt64(bitPattern: Int64(hasher.finalize()))
    }

    private static func presentationAccountID(
        from destinationID: WatchlistDestinationID
    ) -> String? {
        for prefix in ["plex.", "mediabrowser."]
        where destinationID.rawValue.hasPrefix(prefix) {
            let accountID = String(destinationID.rawValue.dropFirst(prefix.count))
            return accountID.isEmpty ? nil : accountID
        }
        return nil
    }

    /// A conservative "same title" key for suppressing an unowned duplicate.
    /// `nil` when there isn't enough to be sure — no title, or no year — so a
    /// sparse entry is never suppressed on a guess.
    public static func titleKey(
        kind: MediaItemKind,
        presentation: MediaAliasPresentation?
    ) -> String? {
        guard let presentation, let year = presentation.year else { return nil }
        let title = MediaItemIdentity.normalizedTitle(presentation.title)
        guard !title.isEmpty else { return nil }
        return "\(kind.rawValue)|\(title)|\(year)"
    }

    public func contains(aliasID: MediaAliasID) -> Bool {
        activeAliasIDs.contains(aliasID)
    }

}
