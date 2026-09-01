import CoreModels
import Foundation

/// One title a destination's own watchlist held the last time it was read.
///
/// Evidence, not intent. It records what a server said, and nothing about what
/// the viewer wants — which is why it lives here rather than in the durable
/// ledger, and why nothing in this file is ever published to CloudKit.
public struct NativeWatchlistEntry: Codable, Hashable, Sendable {
    public let aliasID: MediaAliasID
    public let kind: MediaItemKind
    public let presentation: MediaAliasPresentation?
    public let presentationAccountID: String?
    /// Position in the destination's own list, preserved so the union can order
    /// entries the way the server does rather than by hash order.
    public let index: Int
    /// The item in the viewer's OWN library this entry is, as answered by the
    /// server that holds the list.
    ///
    /// Recorded here so deciding "do I own this?" doesn't depend on a
    /// client-side catalogue index being complete, current and published first.
    /// `nil` means the server was asked and said no, or hasn't been asked yet —
    /// both of which correctly present as not-in-library rather than as a
    /// library title with nothing to play.
    public let ownedSource: MediaSourceRef?
    /// Presentation supplied by that owned library copy.
    ///
    /// Separate from `presentation`, which is what the watchlist destination
    /// itself supplied (Plex Discover, Trakt, and so on). Overloading that field
    /// would make a v1 cache ambiguous: an entry with `ownedSource != nil` may
    /// still carry Discover artwork because older builds persisted only the source
    /// ref. Optional so those files decode and self-upgrade on the next refresh.
    public let ownedPresentation: MediaAliasPresentation?

    public init?(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation? = nil,
        presentationAccountID: String? = nil,
        index: Int,
        ownedSource: MediaSourceRef? = nil,
        ownedPresentation: MediaAliasPresentation? = nil
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.aliasID = aliasID
        self.kind = kind
        self.presentation = presentation?.sanitizedForSync()
        self.presentationAccountID = presentationAccountID
        self.index = index
        self.ownedSource = ownedSource
        self.ownedPresentation = ownedPresentation?.sanitizedForSync()
    }

    /// Last-known owned copy, including the presentation the library supplied.
    ///
    /// Kept as a computed value so call sites cannot accidentally separate the
    /// two halves. Older v1 files decode `ownedPresentation` as nil and the
    /// runtime re-asks the server once to fill it.
    public var ownedCopy: WatchlistLibraryCopy? {
        ownedSource.map {
            WatchlistLibraryCopy(source: $0, presentation: ownedPresentation)
        }
    }

    private enum CodingKeys: String, CodingKey {
        case aliasID, kind, presentation, presentationAccountID
        case index, ownedSource, ownedPresentation
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        aliasID = try container.decode(MediaAliasID.self, forKey: .aliasID)
        kind = try container.decode(MediaItemKind.self, forKey: .kind)
        guard kind == .movie || kind == .series else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription:
                    "Native watchlists support movies and series only."
            )
        }
        presentation = try container.decodeIfPresent(
            MediaAliasPresentation.self,
            forKey: .presentation
        )?.sanitizedForSync()
        presentationAccountID = try container.decodeIfPresent(
            String.self,
            forKey: .presentationAccountID
        )
        index = try container.decode(Int.self, forKey: .index)
        ownedSource = try container.decodeIfPresent(
            MediaSourceRef.self,
            forKey: .ownedSource
        )
        ownedPresentation = try container.decodeIfPresent(
            MediaAliasPresentation.self,
            forKey: .ownedPresentation
        )?.sanitizedForSync()
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(aliasID, forKey: .aliasID)
        try container.encode(kind, forKey: .kind)
        try container.encodeIfPresent(
            presentation?.sanitizedForSync(),
            forKey: .presentation
        )
        try container.encodeIfPresent(
            presentationAccountID,
            forKey: .presentationAccountID
        )
        try container.encode(index, forKey: .index)
        try container.encodeIfPresent(ownedSource, forKey: .ownedSource)
        try container.encodeIfPresent(
            ownedPresentation?.sanitizedForSync(),
            forKey: .ownedPresentation
        )
    }
}

/// What one destination last told us, plus whether we could ask.
public struct NativeWatchlistBucket: Codable, Hashable, Sendable {
    public var entries: [NativeWatchlistEntry]
    public var lastSuccessfulReadAt: Date?
    public var identityScope: String?
    /// True when the most recent read FAILED and these entries are being kept
    /// only so a briefly-unreachable server doesn't blank the watchlist.
    public var isStale: Bool

    public init(
        entries: [NativeWatchlistEntry] = [],
        lastSuccessfulReadAt: Date? = nil,
        identityScope: String? = nil,
        isStale: Bool = false
    ) {
        self.entries = entries.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.aliasID < $1.aliasID
        }
        self.lastSuccessfulReadAt = lastSuccessfulReadAt
        self.identityScope = identityScope
        self.isStale = isStale
    }
}

/// Every enabled destination's last-known native watchlist, for one profile.
///
/// Deliberately separate from `WatchlistIntentStoreState`: keeping evidence in
/// the same record as intent is what made an imported title unretractable, and
/// a separate type in a separate file behind a separate store is what makes it
/// structurally impossible for this to reach `captureSyncRecords`.
public struct NativeWatchlistView: Codable, Hashable, Sendable {
    public static let currentVersion = 1

    public var version: Int
    public var bucketsByDestinationID: [String: NativeWatchlistBucket]
    /// Who these entries were read AS.
    ///
    /// A Plex destination is identified by its account, not by the Home user the
    /// profile plays as — the id is `plex.<accountID>` either way. So switching
    /// "watching as" leaves the previous person's entries sitting under the same
    /// key, and because a failed read deliberately keeps what it has, a switch
    /// followed by an unreachable server would go on showing one child their
    /// sibling's watchlist indefinitely. Stamping the identity makes that
    /// detectable: entries read as somebody else are dropped, not kept.
    public var identityScope: String?

    public init(
        version: Int = currentVersion,
        bucketsByDestinationID: [String: NativeWatchlistBucket] = [:],
        identityScope: String? = nil
    ) {
        self.version = version
        self.bucketsByDestinationID = bucketsByDestinationID
        self.identityScope = identityScope
    }

    /// Keeps the cached entries only if they were read as the CURRENT identity.
    ///
    /// Returns an empty view stamped with `scope` otherwise. Losing the cache is
    /// the right trade: it costs one refresh, where the alternative is showing
    /// somebody else's watchlist.
    public func scoped(to scope: String) -> Self {
        guard identityScope == scope else {
            return NativeWatchlistView(identityScope: scope)
        }
        return self
    }

    public func scoped(
        to scope: String,
        destinationIdentityScopes: [String: String],
        legacyValidatedDestinationIDs: Set<String> = []
    ) -> Self {
        var result = self
        let legacyAggregateScopeMatches = identityScope == scope
        for (destinationID, bucket) in bucketsByDestinationID {
            guard let expectedScope =
                    destinationIdentityScopes[destinationID] else {
                result.bucketsByDestinationID[destinationID] = nil
                continue
            }
            if let bucketScope = bucket.identityScope {
                if bucketScope != expectedScope {
                    result.bucketsByDestinationID[destinationID] = nil
                }
            } else if !legacyAggregateScopeMatches
                        || !legacyValidatedDestinationIDs.contains(destinationID) {
                result.bucketsByDestinationID[destinationID] = nil
            } else {
                var migrated = bucket
                migrated.identityScope = expectedScope
                result.bucketsByDestinationID[destinationID] = migrated
            }
        }
        result.identityScope = scope
        return result
    }

    public static let empty = Self()

    public func bucket(
        for destinationID: WatchlistDestinationID
    ) -> NativeWatchlistBucket? {
        bucketsByDestinationID[destinationID.rawValue]
    }

    /// Records a successful read, replacing what the destination held before —
    /// **including with nothing**.
    ///
    /// An empty successful read is an answer, not a blip: the viewer cleared
    /// that server's watchlist. Home learned the same lesson the expensive way
    /// (see `HomeViewModel`, where treating a deliberate empty as a transient
    /// failure kept a switched-off server's library on screen across relaunches).
    public mutating func applySuccess(
        destinationID: WatchlistDestinationID,
        entries: [NativeWatchlistEntry],
        identityScope: String? = nil,
        at date: Date = Date()
    ) {
        bucketsByDestinationID[destinationID.rawValue] = NativeWatchlistBucket(
            entries: entries,
            lastSuccessfulReadAt: date,
            identityScope: identityScope,
            isStale: false
        )
    }

    /// Records a failed read: keep the last-known entries, but say so.
    ///
    /// The union is what the viewer sees, so a server that is down for a moment
    /// must not empty their watchlist. Nothing is written for a destination that
    /// has never been read successfully — inventing an empty bucket would claim
    /// knowledge we don't have.
    public mutating func applyFailure(
        destinationID: WatchlistDestinationID,
        identityScope: String? = nil
    ) {
        guard var bucket = bucketsByDestinationID[destinationID.rawValue] else {
            return
        }
        if let identityScope,
           bucket.identityScope != identityScope {
            bucketsByDestinationID[destinationID.rawValue] = nil
            return
        }
        guard !bucket.isStale else { return }
        bucket.isStale = true
        bucketsByDestinationID[destinationID.rawValue] = bucket
    }

    public mutating func discardCachedEntries(
        for destinationID: WatchlistDestinationID,
        unlessIdentityScopeMatches identityScope: String
    ) {
        guard let bucket = bucketsByDestinationID[destinationID.rawValue],
              bucket.identityScope != identityScope else {
            return
        }
        bucketsByDestinationID[destinationID.rawValue] = nil
    }

    /// Drops everything the given destinations contributed.
    ///
    /// This is the whole point of the read-time view: switching a server off for
    /// a profile retracts its contribution for free, with nothing to undo in the
    /// durable ledger.
    public mutating func retainOnly(
        destinationIDs: Set<WatchlistDestinationID>
    ) {
        let keep = Set(destinationIDs.map(\.rawValue))
        bucketsByDestinationID = bucketsByDestinationID.filter {
            keep.contains($0.key)
        }
    }
}

public protocol NativeWatchlistViewStoring: Sendable {
    func load() throws -> NativeWatchlistView
    func save(_ view: NativeWatchlistView) throws
    func destructiveRemove() throws
}

public final class InMemoryNativeWatchlistViewStore:
    NativeWatchlistViewStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var value: NativeWatchlistView

    public init(_ value: NativeWatchlistView = .empty) {
        self.value = value
    }

    public func load() throws -> NativeWatchlistView {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    public func save(_ view: NativeWatchlistView) throws {
        lock.lock()
        defer { lock.unlock() }
        value = view
    }

    public func destructiveRemove() throws {
        lock.lock()
        defer { lock.unlock() }
        value = .empty
    }
}

/// Atomic, profile-scoped file store for the native view.
///
/// Corruption is not fatal here and is treated as such: unlike the intent store,
/// which blocks writes after a failed decode so a user's own removals can never
/// be silently replaced, this holds a cache of what servers said. The worst a
/// discarded file costs is one refresh.
public final class AtomicNativeWatchlistViewStore:
    NativeWatchlistViewStoring, @unchecked Sendable {
    private let fileManager: FileManager
    public let fileURL: URL
    private let lock = NSLock()

    public init(
        directoryURL: URL,
        profileID: String,
        fileManager: FileManager = .default
    ) throws {
        guard !profileID.isEmpty,
              profileID == profileID.trimmingCharacters(
                in: .whitespacesAndNewlines
              )
        else { throw DurableLocalStateError.invalidKey }
        self.fileManager = fileManager
        let encoded = Data(profileID.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
        fileURL = directoryURL
            .appendingPathComponent("v1", isDirectory: true)
            .appendingPathComponent(encoded, isDirectory: true)
            .appendingPathComponent("native-view.json")
    }

    public func load() throws -> NativeWatchlistView {
        lock.lock()
        defer { lock.unlock() }
        guard fileManager.fileExists(atPath: fileURL.path) else { return .empty }
        guard let data = try? Data(
            contentsOf: fileURL,
            options: [.mappedIfSafe]
        ), let value = try? JSONDecoder().decode(
            NativeWatchlistView.self,
            from: data
        ), value.version == NativeWatchlistView.currentVersion else {
            try fileManager.removeItem(at: fileURL)
            return .empty
        }
        // Decoding sanitizes every presentation URL, including credentials nested
        // inside Plex's transcoder `url=` parameter. Rewrite once when an older
        // cache differs so the secret is removed from disk immediately rather
        // than waiting for a successful network refresh to happen to save later.
        if let cleaned = CanonicalJSON.encode(value), cleaned != data {
            do {
                try fileManager.createDirectory(
                    at: fileURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try cleaned.write(to: fileURL, options: [.atomic])
            } catch {
                try? fileManager.removeItem(at: fileURL)
                throw error
            }
        }
        return value
    }

    public func save(_ view: NativeWatchlistView) throws {
        lock.lock()
        defer { lock.unlock() }
        guard let data = CanonicalJSON.encode(view) else {
            throw DurableLocalStateError.malformedPayload
        }
        try fileManager.createDirectory(
            at: fileURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: fileURL, options: [.atomic])
    }

    public func destructiveRemove() throws {
        lock.lock()
        defer { lock.unlock() }
        if fileManager.fileExists(atPath: fileURL.path) {
            try fileManager.removeItem(at: fileURL)
        }
    }
}
