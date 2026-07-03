import Foundation

/// A record of an **in-progress resume write** the reconciler applied to one server
/// target, retained briefly so Home's Continue Watching overlay can undo a server's
/// drain-time timestamp inflation.
///
/// Plex's `/:/progress` stamps its **own** server-side view timestamp and can't
/// backdate it (see `PlexProvider.setResumePosition`), so an *offline-queued* resume
/// write that drains late converges at the drain clock, not the play's real time —
/// which re-floats a stale title to the top of Continue Watching on the next reload.
/// This record carries both the play's true time (``capturedAt``) and when we wrote
/// it (``appliedAt``) so the overlay can clamp the card's recency back down to the
/// real play time — but only while the record is fresh, so it can never fight a
/// genuine later play the user made on another client.
public struct AppliedResumeRecord: Codable, Sendable, Equatable {
    /// The play's real time (the mutation's `capturedAt`) — what the row should
    /// reflect, in preference to a server's inflated drain-time stamp.
    public var capturedAt: Date
    /// When the reconciler actually applied the write (≈ the server's own stamp for
    /// our write). The device-clock basis for the overlay's freshness gate, so a
    /// stale record is pruned rather than left to override a later legitimate play.
    public var appliedAt: Date

    public init(capturedAt: Date, appliedAt: Date) {
        self.capturedAt = capturedAt
        self.appliedAt = appliedAt
    }
}

/// The full persisted state of the watch-mutation outbox: the queue plus the two
/// bookkeeping maps that make draining safe across relaunches.
///
/// Everything here is plain `Codable` value data so a brand-new install starts from
/// a well-defined **empty** state (no force-unwraps, no migration) and a kill at any
/// point leaves a recoverable file.
public struct WatchOutboxState: Codable, Sendable, Equatable {
    /// Pending mutations, in enqueue order (coalesced by ``WatchMutation/coalesceKey``).
    public var pending: [WatchMutation]
    /// Stale-write clock: highest `capturedAt` accepted per title (`coalesceKey`).
    /// A new mutation older than this is a late/stale write and is dropped.
    public var clock: [String: Date]
    /// Trakt idempotency ledger: key → when we wrote it, pruned by TTL so our own
    /// replays across relaunch don't re-post history.
    public var appliedTrakt: [String: Date]
    /// Simkl idempotency ledger.
    public var appliedSimkl: [String: Date]
    /// AniList idempotency ledger.
    public var appliedAniList: [String: Date]
    /// MAL idempotency ledger.
    public var appliedMAL: [String: Date]
    /// Recently-applied in-progress resume writes, keyed by ``WatchMutationTarget/id``
    /// (`"accountID:itemID"`), used by Home's Continue Watching overlay to clamp a
    /// server's drain-time timestamp inflation back down to the play's real time.
    /// Pruned aggressively by ``AppliedResumeRecord/appliedAt`` so a stale entry can
    /// never override a genuine later play (e.g. one made on another client).
    public var appliedRecency: [String: AppliedResumeRecord]

    public init(
        pending: [WatchMutation] = [],
        clock: [String: Date] = [:],
        appliedTrakt: [String: Date] = [:],
        appliedSimkl: [String: Date] = [:],
        appliedAniList: [String: Date] = [:],
        appliedMAL: [String: Date] = [:],
        appliedRecency: [String: AppliedResumeRecord] = [:]
    ) {
        self.pending = pending
        self.clock = clock
        self.appliedTrakt = appliedTrakt
        self.appliedSimkl = appliedSimkl
        self.appliedAniList = appliedAniList
        self.appliedMAL = appliedMAL
        self.appliedRecency = appliedRecency
    }

    public static let empty = WatchOutboxState()

    // MARK: - Codable (back-compatible)

    private enum CodingKeys: String, CodingKey {
        case pending, clock, appliedTrakt, appliedSimkl, appliedAniList, appliedMAL, appliedRecency
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        pending = (try? container.decodeIfPresent([WatchMutation].self, forKey: .pending)) ?? []
        clock = (try? container.decodeIfPresent([String: Date].self, forKey: .clock)) ?? [:]
        appliedTrakt = (try? container.decodeIfPresent([String: Date].self, forKey: .appliedTrakt)) ?? [:]
        appliedSimkl = (try? container.decodeIfPresent([String: Date].self, forKey: .appliedSimkl)) ?? [:]
        appliedAniList = (try? container.decodeIfPresent([String: Date].self, forKey: .appliedAniList)) ?? [:]
        appliedMAL = (try? container.decodeIfPresent([String: Date].self, forKey: .appliedMAL)) ?? [:]
        appliedRecency = (try? container.decodeIfPresent([String: AppliedResumeRecord].self, forKey: .appliedRecency)) ?? [:]
    }
}

/// Persistence seam for the outbox. Implementations must be cold-start safe:
/// ``load()`` returns ``WatchOutboxState/empty`` (never throws / crashes) when no
/// state exists yet or the file is unreadable.
public protocol WatchMutationStoring: Sendable {
    func load() -> WatchOutboxState
    func save(_ state: WatchOutboxState) throws
}

/// In-memory store for tests and previews — also the safe default so an outbox can
/// always be constructed without touching disk.
public final class InMemoryWatchMutationStore: WatchMutationStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var state: WatchOutboxState

    public init(_ state: WatchOutboxState = .empty) {
        self.state = state
    }

    public func load() -> WatchOutboxState {
        lock.lock(); defer { lock.unlock() }
        return state
    }

    public func save(_ state: WatchOutboxState) throws {
        lock.lock(); defer { lock.unlock() }
        self.state = state
    }
}

/// JSON-file-backed store. Atomic writes; a missing or corrupt file reads as
/// ``WatchOutboxState/empty`` so the very first launch (and a torn write) recover
/// cleanly. The file is profile-scoped by the caller via `namespace`, so each
/// household profile keeps its own queue.
public final class FileWatchMutationStore: WatchMutationStoring, @unchecked Sendable {
    private let url: URL
    private let lock = NSLock()

    /// - Parameters:
    ///   - directory: container dir (defaults to Application Support/Plozz).
    ///   - namespace: profile namespace; `nil` is the default profile.
    public init(directory: URL? = nil, namespace: String? = nil) {
        let base = directory ?? Self.defaultDirectory()
        let suffix = namespace.map { "-\($0)" } ?? ""
        self.url = base.appendingPathComponent("watch-outbox\(suffix).json")
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
    }

    private static func defaultDirectory() -> URL {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        return support.appendingPathComponent("Plozz", isDirectory: true)
    }

    public func load() -> WatchOutboxState {
        lock.lock(); defer { lock.unlock() }
        guard let data = try? Data(contentsOf: url) else { return .empty }
        return (try? JSONDecoder().decode(WatchOutboxState.self, from: data)) ?? .empty
    }

    public func save(_ state: WatchOutboxState) throws {
        lock.lock(); defer { lock.unlock() }
        let data = try JSONEncoder().encode(state)
        try data.write(to: url, options: .atomic)
    }
}
