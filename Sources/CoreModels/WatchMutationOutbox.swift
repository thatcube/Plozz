import Foundation

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

    public init(
        pending: [WatchMutation] = [],
        clock: [String: Date] = [:],
        appliedTrakt: [String: Date] = [:]
    ) {
        self.pending = pending
        self.clock = clock
        self.appliedTrakt = appliedTrakt
    }

    public static let empty = WatchOutboxState()
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
