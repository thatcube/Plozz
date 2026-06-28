import Foundation

/// Identifies a keyframe source by kind and, via `Comparable`, fixes the
/// open-time selection PRIORITY: the exact, byte-offset-bearing Cues index first;
/// then the (still exact-time) no-Cues cluster walk; then a persisted cache; then
/// an opportunistic server endpoint. Lower `rawValue` == higher priority.
public enum KeyframeSourceKind: Int, Comparable, CaseIterable, Sendable {
    /// Live Matroska Cues read (B5 `readCues`). Exact full-timeline table in ~2
    /// ranged reads; `byteOffsets` POPULATED (CueClusterPosition), so the engine
    /// can no-op its forward-snap resolve.
    case liveCues = 0
    /// No-Cues cluster walk (B5). Exact keyframe times but `byteOffsets == nil`
    /// (the muxer re-derives each offset via a backward seek).
    case noCuesWalk = 1
    /// Persisted cache (Track C). Times recovered from a prior open; `byteOffsets
    /// == nil`.
    case persistedCache = 2
    /// Opportunistic server-provided index (future).
    case serverEndpoint = 3

    public static func < (lhs: KeyframeSourceKind, rhs: KeyframeSourceKind) -> Bool {
        lhs.rawValue < rhs.rawValue
    }
}

/// A source of the shared ``KeyframeTable`` currency. Every open-time keyframe
/// producer — the live-Cues reader, the no-Cues walk, the persisted cache, a
/// server endpoint — conforms, so the selection + Swift→C marshal path is
/// source-agnostic and the producers stay swappable.
///
/// Synchronous to match the underlying readers (e.g. B5's `hasCues()` /
/// `readCues()`), whose `ByteRangeSource` never throws — a failed fetch is an
/// empty read. Callers run resolution off the main actor.
public protocol KeyframeTableSource {
    /// The source's kind, which drives selection priority.
    var kind: KeyframeSourceKind { get }

    /// Cheap availability probe (e.g. a Cues-present check) so the selector can
    /// skip a source without paying for a full load.
    func isAvailable() -> Bool

    /// Produce the table, or `nil` when this source cannot satisfy the open (the
    /// selector then falls through to the next-priority source).
    func loadKeyframeTable() -> KeyframeTable?
}

/// Selects the best available keyframe source at open and yields its table.
///
/// "Best" is the lowest-priority-value (``KeyframeSourceKind/liveCues`` first)
/// source that is both available and yields a non-empty table; sources that are
/// unavailable, throwless-empty, or produce an empty table are skipped so an
/// optimistic-but-absent source never shadows a usable lower-priority one.
public struct KeyframeTableProvider {
    /// Candidate sources in any order; the selector sorts by ``KeyframeSourceKind``.
    public var sources: [any KeyframeTableSource]

    public init(sources: [any KeyframeTableSource]) {
        self.sources = sources
    }

    /// The chosen source kind and its table, or `nil` when no source produced a
    /// usable (non-empty) table.
    public func resolve() -> (kind: KeyframeSourceKind, table: KeyframeTable)? {
        for source in sources.sorted(by: { $0.kind < $1.kind }) {
            guard source.isAvailable() else { continue }
            guard let table = source.loadKeyframeTable(), !table.isEmpty else { continue }
            return (source.kind, table)
        }
        return nil
    }
}

/// The Swift→C hand-off boundary for the full-VOD path. The remux engine (B7)
/// supplies a conformer that forwards the chosen table into
/// `set_full_vod_mode`'s exact-table front-end (short-circuiting
/// `estimate_gop_cadence`). Track A owns *selecting* the table and calling this;
/// the engine owns what the C side does with it.
///
/// Keeping the boundary a protocol means the selection + coordination logic
/// compiles and is unit-testable with no C dependency, and the real bridge drops
/// in without touching this lane.
public protocol FullVODKeyframeSink {
    /// Hand the exact open-time keyframe table to the engine. `byteOffsets`, when
    /// present, lets the engine no-op its forward-snap resolve. Returns whether
    /// the engine accepted the table (so the caller can fall back to the
    /// measured-cadence / provisional path on rejection).
    func applyFullVODKeyframes(_ table: KeyframeTable) -> Bool
}

/// Ties source selection to the engine hand-off behind a default-OFF gate.
///
/// At open, when enabled, it resolves the best available source and marshals the
/// chosen table to the engine sink. When disabled — the shipped default — it does
/// nothing and the existing measured-cadence / provisional full-VOD path is left
/// entirely untouched, so this can land dark and be flipped on per-title or via a
/// register-defaults flag.
public struct FullVODKeyframeCoordinator {
    public var provider: KeyframeTableProvider
    public var sink: FullVODKeyframeSink
    /// Master gate. `false` ⇒ this path is inert (preserves the working seam).
    public var isEnabled: Bool

    public init(provider: KeyframeTableProvider, sink: FullVODKeyframeSink, isEnabled: Bool = false) {
        self.provider = provider
        self.sink = sink
        self.isEnabled = isEnabled
    }

    /// The outcome of an activation attempt, for logging / telemetry.
    public enum Outcome: Equatable, Sendable {
        /// The gate is off; nothing was attempted.
        case disabled
        /// No source produced a usable table; the caller keeps its existing path.
        case noSource
        /// A table was produced but the engine rejected it; fall back.
        case rejected(KeyframeSourceKind)
        /// The engine accepted the table from this source.
        case applied(KeyframeSourceKind)
    }

    /// Resolve + marshal. Returns the outcome; only `.applied` means the exact
    /// table is now driving the full-VOD plan.
    @discardableResult
    public func activateIfAvailable() -> Outcome {
        guard isEnabled else { return .disabled }
        guard let (kind, table) = provider.resolve() else { return .noSource }
        return sink.applyFullVODKeyframes(table) ? .applied(kind) : .rejected(kind)
    }
}
