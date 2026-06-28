import Foundation

/// The single shared keyframe currency every no-Cues / Cues source converges on
/// before it reaches the planner.
///
/// A `KeyframeTable` is a sorted, strictly-increasing list of real IDR keyframe
/// **start times** (seconds, ~0-based, last entry `<= duration`) plus the source
/// duration. It is the one interface Track A's Cues reader, Track C's persisted
/// cache, B6's canonical C discovery, and an opportunistic server keyframe endpoint
/// all produce — so the discovery sources are interchangeable behind
/// `KeyframeProvider`, and all feed the SAME `plozz_remux_apply_keyframes` →
/// `RemuxSegmentPlanner` path (one engine, no per-track muxer fork).
///
/// `byteOffsets` is an OPTIONAL parallel array of source byte offsets for each
/// keyframe, for sources that can supply them cheaply (e.g. Matroska Cues, which
/// carry the keyframe→byte map directly). **Track C always stores `nil`**: its
/// persisted sidecar is times-only / offset-free, because a cached byte offset can
/// land mid-cluster after any re-mux/move and parse-fail — the offsets are instead
/// re-derived at mux time via an `avformat_seek BACKWARD`, which dodges the
/// stale-offset trap. When present, `byteOffsets.count == times.count`.
///
/// Pure value type (no AVFoundation / FFmpeg / Network) so the normalization and
/// validation invariants are unit-testable on any platform.
///
/// CANONICAL HOME (convergence at integration): Track A made
/// `CoreModels.KeyframeTable` the single canonical definition (branch b6b768d4
/// @708f1fb: `public`, `Equatable`, `Sendable`, `+normalized(...)`). This struct is
/// the LocalRemux-local MIRROR with the identical shape (`duration`, `times`,
/// `byteOffsets: [Int64]?`) so Track C compiles standalone pre-merge; it is NOT a
/// second canonical type. At integration this declaration is deleted and replaced
/// by `import CoreModels` (the swarm keeps ONE definition — same lesson as B7
/// owning `plozz_remux_apply_keyframes`); the `isUsable` accessor and the
/// `KeyframeProvider` protocol below stay as LocalRemux extensions on the canonical
/// type. Same struct, different consumers: Track C's persisted cache stores
/// `byteOffsets = nil` (offset-free, re-derived at mux), while the LIVE Cues reader
/// keeps `byteOffsets` POPULATED for B7's no-op forward resolve.
///
/// ⚠️ ATOMIC COLLAPSE: the swarm carries more than one LocalRemux-side mirror — this
/// top-level one, plus a NESTED `MatroskaKeyframeSampler.KeyframeTable` that arrives
/// when B5's current sampler is re-harvested at the producer-wiring step. The
/// collapse to `CoreModels.KeyframeTable` MUST delete ALL LocalRemux mirrors in the
/// SAME commit (and add `import CoreModels` to each file); deleting only one leaves
/// unqualified `KeyframeTable` ambiguous between `CoreModels` and the surviving
/// same-module mirror → ambiguous build. (Today this tree has only this one mirror;
/// the parked sampler is an older copy that emits `[Double]` with no nested type.)
public struct KeyframeTable: Equatable, Sendable {

    /// Total programme duration in seconds (0 when unknown). Carried alongside the
    /// times for the cache content-guard and to clamp/validate the boundary list.
    public var duration: Double

    /// Keyframe start times in seconds: sorted, strictly increasing, finite,
    /// non-negative, `~0-based`, last `<= duration` (when duration is known).
    public var times: [Double]

    /// Optional source byte offset per keyframe (parallel to `times`). `nil` for
    /// offset-free producers like Track C's persisted cache; non-nil only when a
    /// source supplies offsets cheaply and `count == times.count`.
    public var byteOffsets: [Int64]?

    public init(duration: Double, times: [Double], byteOffsets: [Int64]? = nil) {
        self.duration = duration
        self.times = times
        self.byteOffsets = byteOffsets
    }

    /// A table is usable by the planner only with at least two keyframes (one
    /// segment span). Mirrors `plozz_remux_apply_keyframes`'s `count >= 2` contract.
    public var isUsable: Bool { times.count >= 2 }

    /// Builds a normalized table from a raw keyframe-time list: drops non-finite /
    /// negative entries, clamps to `<= duration` (when known), sorts ascending, and
    /// removes near-duplicates closer than `epsilon` (so a corrupt or doubly-sampled
    /// boundary can never produce a zero/negative-span segment downstream). The
    /// exact hygiene `plozz_remux_apply_keyframes` and `KeyframeIndexCache.load`
    /// already assume, applied at the single seam so every provider gets it for free.
    public static func normalized(times raw: [Double], duration: Double,
                                  epsilon: Double = 1e-3) -> KeyframeTable {
        var cleaned = raw.filter { $0.isFinite && $0 >= 0 }
        if duration > 0 {
            cleaned = cleaned.filter { $0 <= duration + epsilon }
        }
        cleaned.sort()
        var out: [Double] = []
        out.reserveCapacity(cleaned.count)
        for t in cleaned {
            if let last = out.last {
                if t > last + epsilon { out.append(t) }
            } else {
                out.append(t)
            }
        }
        return KeyframeTable(duration: duration, times: out)
    }
}

/// Anything that can supply a `KeyframeTable` for a source: Track A's Cues reader,
/// Track C's persisted `KeyframeIndexCache`, B6's canonical C discovery, or a server
/// keyframe endpoint. Lets the open path try providers in priority order
/// (cache → Cues → server → background discovery) without knowing which one
/// answered — they all emit the identical currency consumed by the planner.
public protocol KeyframeProvider {
    /// Returns the source's keyframe table, or `nil` when this provider can't
    /// answer cheaply (e.g. cache miss, no Cues, endpoint unavailable) so the
    /// caller can fall through to the next provider. MUST NOT perform an
    /// unbounded synchronous client scan of a no-Cues file — that is the cardinal
    /// sin of the no-Cues path; expensive discovery belongs on a background build.
    func keyframeTable() -> KeyframeTable?
}
