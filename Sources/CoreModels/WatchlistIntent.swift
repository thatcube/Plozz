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

    public init(
        sourceDestinationIDs: [String] = [],
        lastExplicitRemovalAt: Date? = nil,
        lastReconciledAt: Date? = nil
    ) {
        self.sourceDestinationIDs = Array(Set(
            sourceDestinationIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )).sorted()
        self.lastExplicitRemovalAt = lastExplicitRemovalAt
        self.lastReconciledAt = lastReconciledAt
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
    public var origin: WatchlistIntentOrigin
    public var changedAt: Date
    public var presentation: MediaAliasPresentation?
    public var metadata: WatchlistIntentMetadata

    public init?(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        desiredState: WatchlistDesiredState,
        rank: UInt64,
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
        self.origin = origin
        self.changedAt = changedAt
        self.presentation = presentation?.sanitizedForSync()
        self.metadata = metadata
    }

    public func canonicalized() -> Self {
        var value = self
        value.presentation = presentation?.sanitizedForSync()
        value.metadata = WatchlistIntentMetadata(
            sourceDestinationIDs: metadata.sourceDestinationIDs,
            lastExplicitRemovalAt: metadata.lastExplicitRemovalAt,
            lastReconciledAt: metadata.lastReconciledAt
        )
        return value
    }

    private enum CodingKeys: String, CodingKey {
        case aliasID, kind, desiredState, rank, origin, changedAt, presentation
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
        try container.encode(value.origin, forKey: .origin)
        try container.encode(value.changedAt, forKey: .changedAt)
        try container.encodeIfPresent(value.presentation, forKey: .presentation)
        try container.encode(value.metadata, forKey: .metadata)
    }
}

public struct WatchlistMigrationMetadata: Codable, Hashable, Sendable {
    public var legacyHomeSeedCompletedAt: Date?
    public var completedNativeImportDestinationIDs: [String]

    public init(
        legacyHomeSeedCompletedAt: Date? = nil,
        completedNativeImportDestinationIDs: [String] = []
    ) {
        self.legacyHomeSeedCompletedAt = legacyHomeSeedCompletedAt
        self.completedNativeImportDestinationIDs = Array(Set(
            completedNativeImportDestinationIDs.map {
                $0.trimmingCharacters(in: .whitespacesAndNewlines)
            }.filter { !$0.isEmpty }
        )).sorted()
    }

    public func hasCompletedNativeImport(destinationID: String) -> Bool {
        completedNativeImportDestinationIDs.binarySearch(destinationID)
    }
}

public struct WatchlistIntentSyncDTO: Codable, Hashable, Sendable {
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let desiredState: WatchlistDesiredState
    public let rank: UInt64
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
            origin: origin,
            changedAt: changedAt,
            presentation: presentation,
            metadata: metadata
        )
    }
}

private extension Array where Element == String {
    func binarySearch(_ value: String) -> Bool {
        var lower = startIndex
        var upper = endIndex
        while lower < upper {
            let middle = index(lower, offsetBy: distance(from: lower, to: upper) / 2)
            if self[middle] == value { return true }
            if self[middle] < value {
                lower = index(after: middle)
            } else {
                upper = middle
            }
        }
        return false
    }
}
