import Foundation

/// Serial-queue executor that owns **all** blocking filesystem and
/// (de)serialization work for `MetadataDiskCache`, keeping the cache actor's own
/// executor free of synchronous disk I/O.
///
/// Superseded-cache cleanup, directory reads, JSON decode, JSON encode, budget
/// pruning, and atomic writes all run here — on one private serial queue, in
/// submission order. Because every job hops onto the same serial queue:
///
///  * The first load performs cleanup **then** read in that exact order; they
///    cannot race.
///  * Writes cannot interleave. A monotonically increasing revision guard drops
///    any write whose snapshot is older than one already persisted, so a late
///    completion can never clobber newer actor state.
///
/// The actor awaits these `async` methods, so a blocked disk call parks a
/// continuation on this queue rather than stalling the actor — unrelated actors
/// and cooperative tasks stay schedulable.
final class MetadataCacheFileIO: @unchecked Sendable {
    /// Label of the dedicated serial queue. Tests assert filesystem callbacks run
    /// here (and not on the actor/caller executor) by comparing the current
    /// queue label against this value.
    static let queueLabel = "com.plozz.metadatakit.metadata-cache-io"

    /// Set on the dedicated queue so code running inside a filesystem callback can
    /// prove (via `DispatchQueue.getSpecific`) that it executes on this executor's
    /// serial queue rather than the actor/caller executor.
    static let queueMarker = DispatchSpecificKey<Bool>()

    struct LoadResult: Sendable {
        var entries: [String: MetadataDiskCache.Entry]
        /// Raw byte size of the file that was read (0 when absent/unreadable).
        var byteCount: Int
        /// The on-disk file already exceeded the byte budget and should be
        /// rewritten (pruned) once loaded.
        var wasOversized: Bool
    }

    struct WriteResult: Sendable {
        /// Keys removed by budget pruning during THIS write, so the actor can
        /// reconcile its in-memory map when the snapshot is still current.
        var evicted: [String]
        /// Whether this write actually landed. `false` means it was superseded by
        /// a newer revision and skipped.
        var didWrite: Bool
        /// Number of whole-map encodes this write performed (bounded to <= 3).
        var wholeMapEncodeCount: Int
    }

    private let queue = DispatchQueue(label: MetadataCacheFileIO.queueLabel)
    private let fileIO: any MetadataDiskCache.FileIO
    private let coding: any MetadataDiskCache.Coding
    private let policy: MetadataCacheBudgetPolicy
    /// Confined to `queue`; the monotonic high-water mark of persisted revisions.
    private var lastWrittenRevision = Int.min

    init(
        fileIO: any MetadataDiskCache.FileIO,
        coding: any MetadataDiskCache.Coding,
        policy: MetadataCacheBudgetPolicy = MetadataCacheBudgetPolicy()
    ) {
        self.fileIO = fileIO
        self.coding = coding
        self.policy = policy
        queue.setSpecific(key: Self.queueMarker, value: true)
    }

    /// Superseded-cache cleanup followed by the current-file read + decode, in
    /// that order, on the serial queue. Expired entries are dropped on load.
    func firstLoad(
        directory: URL?,
        fileURL: URL?,
        currentFileName: String,
        filePrefix: String,
        maxBytes: Int,
        now: Date = Date()
    ) async -> LoadResult {
        await withCheckedContinuation { continuation in
            queue.async {
                if let directory {
                    self.fileIO.removeSupersededCaches(
                        in: directory,
                        currentFileName: currentFileName,
                        filePrefix: filePrefix
                    )
                }
                guard let fileURL,
                      let data = self.fileIO.read(from: fileURL),
                      let decoded = self.coding.decode(data) else {
                    continuation.resume(returning: LoadResult(entries: [:], byteCount: 0, wasOversized: false))
                    return
                }
                let fresh = decoded.filter { $0.value.expires > now }
                continuation.resume(returning: LoadResult(
                    entries: fresh,
                    byteCount: data.count,
                    wasOversized: data.count > maxBytes
                ))
            }
        }
    }

    /// Encodes `snapshot` (pruning to `maxBytes` if needed) and atomically writes
    /// it, unless a newer revision has already been persisted.
    func write(
        snapshot: [String: MetadataDiskCache.Entry],
        revision: Int,
        fileURL: URL,
        maxBytes: Int
    ) async -> WriteResult {
        await withCheckedContinuation { continuation in
            queue.async {
                guard revision >= self.lastWrittenRevision else {
                    continuation.resume(returning: WriteResult(evicted: [], didWrite: false, wholeMapEncodeCount: 0))
                    return
                }
                let (data, evicted, encodeCount) = self.encodeToBudget(snapshot, maxBytes: maxBytes)
                guard let data else {
                    continuation.resume(returning: WriteResult(evicted: [], didWrite: false, wholeMapEncodeCount: encodeCount))
                    return
                }
                self.fileIO.write(data, to: fileURL)
                self.lastWrittenRevision = revision
                continuation.resume(returning: WriteResult(evicted: evicted, didWrite: true, wholeMapEncodeCount: encodeCount))
            }
        }
    }

    // MARK: - Budget pruning (queue-confined)

    /// Serializes `entries`, pruning oldest-expiring entries when over budget.
    /// Performs at most three whole-map encodes: one initial measurement, one for
    /// the estimate-selected survivors, and at most one bounded correction encode
    /// when the estimate under-counted. Never loops per entry over whole-map
    /// encodes.
    private func encodeToBudget(
        _ entries: [String: MetadataDiskCache.Entry],
        maxBytes: Int
    ) -> (Data?, [String], Int) {
        var encodeCount = 0
        guard var data = encode(entries, &encodeCount) else { return (nil, [], encodeCount) }
        guard data.count > maxBytes else { return (data, [], encodeCount) }

        // Over budget: select survivors from cheap per-entry estimates (encode #2).
        var survivors = entries
        var evicted = Set(policy.evictionKeys(sized(entries), maxBytes: maxBytes))
        for key in evicted { survivors[key] = nil }
        guard let selected = encode(survivors, &encodeCount) else { return (nil, Array(evicted), encodeCount) }
        data = selected

        // Estimator correction: if the real encode is still over, rescale the
        // per-entry estimates by the observed ratio and evict once more (encode #3).
        if data.count > maxBytes && !survivors.isEmpty {
            let survivorSized = sized(survivors)
            let estimatedTotal = max(1, survivorSized.reduce(0) { $0 + $1.estimatedSize })
            let scale = Double(data.count) / Double(estimatedTotal)
            let rescaled = survivorSized.map {
                MetadataCacheBudgetPolicy.SizedEntry(
                    key: $0.key,
                    expires: $0.expires,
                    estimatedSize: Int((Double($0.estimatedSize) * scale).rounded(.up)) + 1
                )
            }
            let extra = policy.evictionKeys(rescaled, maxBytes: maxBytes)
            for key in extra {
                survivors[key] = nil
                evicted.insert(key)
            }
            if let corrected = encode(survivors, &encodeCount) { data = corrected }
        }
        return (data, Array(evicted), encodeCount)
    }

    private func sized(_ entries: [String: MetadataDiskCache.Entry]) -> [MetadataCacheBudgetPolicy.SizedEntry] {
        entries.map { key, entry in
            MetadataCacheBudgetPolicy.SizedEntry(
                key: key,
                expires: entry.expires,
                estimatedSize: Self.estimatedSize(key: key, entry: entry)
            )
        }
    }

    private func encode(_ entries: [String: MetadataDiskCache.Entry], _ count: inout Int) -> Data? {
        count += 1
        return coding.encode(entries)
    }

    /// Cheap per-entry byte estimate for `"key":{"url":"...","expires":...},`.
    /// Intentionally over-counts slightly so the real encode rarely needs the
    /// correction pass.
    static func estimatedSize(key: String, entry: MetadataDiskCache.Entry) -> Int {
        key.utf8.count + (entry.url?.utf8.count ?? 0) + 48
    }
}
