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
        pending = try container.decodeIfPresent(
            [WatchMutation].self,
            forKey: .pending
        ) ?? []
        clock = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .clock
        ) ?? [:]
        appliedTrakt = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .appliedTrakt
        ) ?? [:]
        appliedSimkl = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .appliedSimkl
        ) ?? [:]
        appliedAniList = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .appliedAniList
        ) ?? [:]
        appliedMAL = try container.decodeIfPresent(
            [String: Date].self,
            forKey: .appliedMAL
        ) ?? [:]
        appliedRecency = try container.decodeIfPresent(
            [String: AppliedResumeRecord].self,
            forKey: .appliedRecency
        ) ?? [:]
    }
}

extension WatchOutboxState: DurableLocalStateValue {
    public static let durableLocalStateSchemaID =
        "com.plozz.watch-outbox.v1"
}

/// Persistence seam for the outbox. Implementations are cold-start safe:
/// ``load()`` returns ``WatchOutboxState/empty`` when no state exists. A durable
/// implementation that cannot decode existing state must block later writes so
/// corruption is never overwritten with an empty queue.
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

/// User-independent Keychain-backed watch outbox. There is intentionally no
/// file-store migration: tester builds start with a fresh durable queue.
public final class DurableWatchMutationStore:
    WatchMutationStoring,
    @unchecked Sendable
{
    private struct Manifest: DurableLocalStateValue {
        static let durableLocalStateSchemaID =
            "com.plozz.watch-outbox-manifest.v1"

        let generation: String
        let chunkCount: Int
        let revision: UInt64
    }

    private struct Chunk: DurableLocalStateValue {
        static let durableLocalStateSchemaID =
            "com.plozz.watch-outbox-chunk.v1"

        let data: Data
    }

    private static let maximumChunkCount = 32
    private let store: DurableLocalStateStore
    private let scope: DurableLocalStateScope
    private let manifestKey: DurableLocalStateKey
    private let onLoadFailure: @Sendable () -> Void
    private let operationLock: NSLock
    private var loadFailed = false
    private var loadedRevision: UInt64?

    public init(
        store: DurableLocalStateStore,
        profileID: String,
        onLoadFailure: @escaping @Sendable () -> Void = {}
    ) throws {
        self.store = store
        self.onLoadFailure = onLoadFailure
        self.scope = .profile(profileID: profileID)
        self.operationLock = DurableWatchOutboxCoordination.shared.lock(
            for: profileID
        )
        self.manifestKey = try DurableLocalStateKey(
            collection: .watchOutbox,
            scope: self.scope,
            recordID: "manifest"
        )
    }

    public func load() -> WatchOutboxState {
        operationLock.lock()
        do {
            guard let manifest = try store.load(
                Manifest.self,
                for: manifestKey
            ) else {
                loadedRevision = nil
                operationLock.unlock()
                return .empty
            }
            guard (1...Self.maximumChunkCount).contains(
                manifest.chunkCount
            ), manifest.generation == "slot0"
                || manifest.generation == "slot1" else {
                throw DurableLocalStateError.malformedPayload
            }
            var encoded = Data()
            for index in 0..<manifest.chunkCount {
                guard let chunk = try store.load(
                    Chunk.self,
                    for: try chunkKey(
                        generation: manifest.generation,
                        index: index
                    )
                ) else {
                    throw DurableLocalStateError.malformedPayload
                }
                encoded.append(chunk.data)
            }
            do {
                let state = try JSONDecoder().decode(
                    WatchOutboxState.self,
                    from: encoded
                )
                loadedRevision = manifest.revision
                operationLock.unlock()
                return state
            } catch {
                throw DurableLocalStateError.malformedPayload
            }
        } catch {
            loadFailed = true
            operationLock.unlock()
            onLoadFailure()
            return .empty
        }
    }

    public func save(_ state: WatchOutboxState) throws {
        operationLock.lock()
        defer { operationLock.unlock() }
        guard !loadFailed else {
            throw DurableLocalStateError.malformedPayload
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let encoded = try encoder.encode(state)
        let chunkByteCount = max(
            1,
            min(128 * 1_024, store.maximumPayloadBytes * 45 / 100)
        )
        let chunks = stride(
            from: 0,
            to: max(1, encoded.count),
            by: chunkByteCount
        ).map { offset -> Data in
            guard !encoded.isEmpty else { return Data() }
            return encoded.subdata(
                in: offset..<min(offset + chunkByteCount, encoded.count)
            )
        }
        guard chunks.count <= Self.maximumChunkCount else {
            throw DurableLocalStateError.payloadTooLarge
        }

        let previous = try store.load(Manifest.self, for: manifestKey)
        guard previous?.revision == loadedRevision else {
            throw DurableLocalStateError.writeConflict
        }
        let generation = previous?.generation == "slot0"
            ? "slot1"
            : "slot0"
        let revision = (previous?.revision ?? 0) &+ 1
        for (index, data) in chunks.enumerated() {
            let key = try chunkKey(
                generation: generation,
                index: index
            )
            try store.save(Chunk(data: data), for: key)
        }
        try store.save(
            Manifest(
                generation: generation,
                chunkCount: chunks.count,
                revision: revision
            ),
            for: manifestKey
        )
        loadedRevision = revision
    }

    private func chunkKey(
        generation: String,
        index: Int
    ) throws -> DurableLocalStateKey {
        try DurableLocalStateKey(
            collection: .watchOutbox,
            scope: scope,
            recordID: "chunk.\(generation).\(index)"
        )
    }
}

private final class DurableWatchOutboxCoordination: @unchecked Sendable {
    static let shared = DurableWatchOutboxCoordination()

    private let lock = NSLock()
    private var profileLocks: [String: NSLock] = [:]

    func lock(for profileID: String) -> NSLock {
        lock.lock()
        defer { lock.unlock() }
        if let existing = profileLocks[profileID] {
            return existing
        }
        let created = NSLock()
        profileLocks[profileID] = created
        return created
    }
}
