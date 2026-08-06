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

    public init?(
        aliasID: MediaAliasID,
        kind: MediaItemKind,
        presentation: MediaAliasPresentation? = nil,
        index: Int,
        ownedSource: MediaSourceRef? = nil
    ) {
        guard kind == .movie || kind == .series else { return nil }
        self.aliasID = aliasID
        self.kind = kind
        self.presentation = presentation?.sanitizedForSync()
        self.index = index
        self.ownedSource = ownedSource
    }
}

/// What one destination last told us, plus whether we could ask.
public struct NativeWatchlistBucket: Codable, Hashable, Sendable {
    public var entries: [NativeWatchlistEntry]
    public var lastSuccessfulReadAt: Date?
    /// True when the most recent read FAILED and these entries are being kept
    /// only so a briefly-unreachable server doesn't blank the watchlist.
    public var isStale: Bool

    public init(
        entries: [NativeWatchlistEntry] = [],
        lastSuccessfulReadAt: Date? = nil,
        isStale: Bool = false
    ) {
        self.entries = entries.sorted {
            if $0.index != $1.index { return $0.index < $1.index }
            return $0.aliasID < $1.aliasID
        }
        self.lastSuccessfulReadAt = lastSuccessfulReadAt
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
        at date: Date = Date()
    ) {
        bucketsByDestinationID[destinationID.rawValue] = NativeWatchlistBucket(
            entries: entries,
            lastSuccessfulReadAt: date,
            isStale: false
        )
    }

    /// Records a failed read: keep the last-known entries, but say so.
    ///
    /// The union is what the viewer sees, so a server that is down for a moment
    /// must not empty their watchlist. Nothing is written for a destination that
    /// has never been read successfully — inventing an empty bucket would claim
    /// knowledge we don't have.
    public mutating func applyFailure(destinationID: WatchlistDestinationID) {
        guard var bucket = bucketsByDestinationID[destinationID.rawValue] else {
            return
        }
        guard !bucket.isStale else { return }
        bucket.isStale = true
        bucketsByDestinationID[destinationID.rawValue] = bucket
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
            return .empty
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
