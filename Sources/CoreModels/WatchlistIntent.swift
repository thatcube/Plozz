import Foundation

public enum WatchlistDesiredState: String, Codable, Hashable, Sendable {
    case present
    case absent
}

public enum WatchlistIntentOrigin: String, Codable, Hashable, Sendable {
    case local
    case legacyHomeSeed
    case nativeImport
    case cloud
}

public struct WatchlistIntentMetadata: Codable, Hashable, Sendable {
    public var sourceDestinationIDs: [String]
    public var lastExplicitRemovalAt: Date?
    public var lastReconciledAt: Date?
    /// When a native list added this title back AFTER the reconciler confirmed
    /// the explicit removal had been applied there.
    ///
    /// A tombstone must outlive a server that still lists the title, or removing
    /// something that lives on Plex would reappear on the next read. But a
    /// genuine later re-add on the server is a new statement, not the old one
    /// echoing back, and the viewer expects it to show up. This marks the
    /// removal as answered rather than resurrecting the record as `.present`:
    /// presence then comes from the native view, so disabling that server still
    /// takes it away again.
    ///
    /// Deleting the tombstone instead was rejected. Deletion propagates, and a
    /// peer that re-delivered the old `.absent` record would restore the
    /// suppression with no absence boundary left to clear it — hiding the title
    /// permanently, on one device only.
    public var removalSupersededAt: Date?

    public init(
        sourceDestinationIDs: [String] = [],
        lastExplicitRemovalAt: Date? = nil,
        lastReconciledAt: Date? = nil,
        removalSupersededAt: Date? = nil
    ) {
        self.sourceDestinationIDs = Array(Set(
            sourceDestinationIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )).sorted()
        self.lastExplicitRemovalAt = lastExplicitRemovalAt
        self.lastReconciledAt = lastReconciledAt
        self.removalSupersededAt = removalSupersededAt
    }

    /// Whether this metadata's removal still hides the title.
    ///
    /// Only meaningful on an `.absent` intent. A removal with no recorded
    /// timestamp (older records, and tombstones that arrived over sync) counts
    /// as live, because the alternative — treating an unknown removal as
    /// already answered — un-hides titles the viewer deleted.
    public var suppressesNativePresence: Bool {
        guard let removalSupersededAt else { return true }
        guard let lastExplicitRemovalAt else { return false }
        return removalSupersededAt <= lastExplicitRemovalAt
    }
}

/// Durable, profile-owned user intent. `.absent` values are semantic tombstones
/// and are intentionally retained rather than represented by record deletion.
public struct WatchlistIntent: Codable, Hashable, Identifiable, Sendable {
    public var id: MediaAliasID { aliasID }
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public var desiredState: WatchlistDesiredState
    public var rank: UInt64
    /// Signed presentation order. Older records omit this and retain their
    /// original ascending `rank`; explicit user adds allocate below the current
    /// minimum while native imports allocate above the maximum.
    public var orderingRank: Int64?
    public var origin: WatchlistIntentOrigin
    public var changedAt: Date
    public var presentation: MediaAliasPresentation?
    public var metadata: WatchlistIntentMetadata

    public init?(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        desiredState: WatchlistDesiredState,
        rank: UInt64,
        orderingRank: Int64? = nil,
        origin: WatchlistIntentOrigin,
        changedAt: Date = Date(),
        presentation: MediaAliasPresentation? = nil,
        metadata: WatchlistIntentMetadata = .init()
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.aliasID = aliasID
        self.kind = kind
        self.desiredState = desiredState
        self.rank = rank
        self.orderingRank = orderingRank
        self.origin = origin
        self.changedAt = changedAt
        self.presentation = presentation?.sanitizedForSync()
        self.metadata = metadata
    }

    public var effectiveOrderingRank: Int64 {
        orderingRank ?? (
            rank > UInt64(Int64.max) ? Int64.max : Int64(rank)
        )
    }

    public func canonicalized() -> Self {
        var value = self
        value.presentation = presentation?.sanitizedForSync()
        value.metadata = WatchlistIntentMetadata(
            sourceDestinationIDs: metadata.sourceDestinationIDs,
            lastExplicitRemovalAt: metadata.lastExplicitRemovalAt,
            lastReconciledAt: metadata.lastReconciledAt,
            removalSupersededAt: metadata.removalSupersededAt
        )
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case aliasID, kind, desiredState, rank, orderingRank, origin, changedAt, presentation
        case metadata
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let value = WatchlistIntent(
            aliasID: try container.decode(MediaAliasID.self, forKey: .aliasID),
            kind: try container.decode(MediaItemKind.self, forKey: .kind),
            desiredState: try container.decode(
                WatchlistDesiredState.self,
                forKey: .desiredState
            ),
            rank: try container.decode(UInt64.self, forKey: .rank),
            orderingRank: try container.decodeIfPresent(
                Int64.self,
                forKey: .orderingRank
            ),
            origin: try container.decode(WatchlistIntentOrigin.self, forKey: .origin),
            changedAt: try container.decode(Date.self, forKey: .changedAt),
            presentation: try container.decodeIfPresent(
                MediaAliasPresentation.self,
                forKey: .presentation
            ),
            metadata: try container.decodeIfPresent(
                WatchlistIntentMetadata.self,
                forKey: .metadata
            ) ?? .init()
        ) else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Watchlist intents support movies and series only."
            )
        }
        self = value
    }

    public func encode(to encoder: Encoder) throws {
        let value = canonicalized()
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(value.aliasID, forKey: .aliasID)
        try container.encode(value.kind, forKey: .kind)
        try container.encode(value.desiredState, forKey: .desiredState)
        try container.encode(value.rank, forKey: .rank)
        try container.encodeIfPresent(value.orderingRank, forKey: .orderingRank)
        try container.encode(value.origin, forKey: .origin)
        try container.encode(value.changedAt, forKey: .changedAt)
        try container.encodeIfPresent(value.presentation, forKey: .presentation)
        try container.encode(value.metadata, forKey: .metadata)
    }
}

public struct WatchlistMigrationMetadata: Codable, Hashable, Sendable {
    public var legacyHomeSeedCompletedAt: Date?
    /// When this profile's imported native entries were retired from the ledger.
    ///
    /// The import used to write every native entry as a durable `.present`
    /// intent, which made it unretractable: disabling the server left everything
    /// it had contributed behind forever. Native lists are now a read-time view,
    /// so those records are dropped once — a still-enabled server re-supplies
    /// them through the union, and a disabled one correctly stops.
    public var nativeImportRetiredAt: Date?

    public init(
        legacyHomeSeedCompletedAt: Date? = nil,
        nativeImportRetiredAt: Date? = nil
    ) {
        self.legacyHomeSeedCompletedAt = legacyHomeSeedCompletedAt
        self.nativeImportRetiredAt = nativeImportRetiredAt
    }
}

public struct WatchlistIntentSyncDTO: Codable, Hashable, Sendable {
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let desiredState: WatchlistDesiredState
    public let rank: UInt64
    public let orderingRank: Int64?
    public let origin: WatchlistIntentOrigin
    public let changedAt: Date
    public let presentation: MediaAliasPresentation?
    public let metadata: WatchlistIntentMetadata

    public init(intent: WatchlistIntent) {
        let value = intent.canonicalized()
        aliasID = value.aliasID
        kind = value.kind
        desiredState = value.desiredState
        rank = value.rank
        orderingRank = value.orderingRank
        origin = value.origin
        changedAt = value.changedAt
        presentation = value.presentation
        metadata = value.metadata
    }

    public func makeIntent() -> WatchlistIntent? {
        WatchlistIntent(
            aliasID: aliasID,
            kind: kind,
            desiredState: desiredState,
            rank: rank,
            orderingRank: orderingRank,
            origin: origin,
            changedAt: changedAt,
            presentation: presentation,
            metadata: metadata
        )
    }
}
