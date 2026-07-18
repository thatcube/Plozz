import Foundation

/// The explicit result of a single scan pass.
///
/// Replaces the old `Void` return from `ShareScanner.scan()`/`scanIfStale()` so the
/// coordinator can decide *deterministically* whether the pass earned a background
/// completion timestamp — which suppresses the next needed scan for the coalesce
/// window — instead of stamping completion unconditionally (finding A5). A scan that
/// was cancelled, superseded, or invalidated mid-walk must never suppress the next
/// needed scan.
///
/// Non-success cases carry only a secret-safe random scan-generation UUID; they never
/// carry a share-relative path or any library structure, so a cancellation record can
/// be logged for diagnosis without leaking the tree.
enum ShareScanOutcome: Sendable, Equatable {
    /// No walk ran: a pass was already in flight, or the staleness throttle (an
    /// unchanged parser + local-inventory version and a recent completion) made the
    /// walk a guaranteed no-op. Completion is legitimately current, so this coalesces.
    case freshNoOp

    /// A full pass completed and pruned — every directory listed cleanly.
    case completedClean

    /// A full pass completed but at least one directory listing failed, so pruning was
    /// deliberately skipped (a partial walk must not delete temporarily unreachable
    /// content). Still a *completed* pass under the approved partial throttle: one
    /// permanently-inaccessible folder must not trigger a perpetual re-scan storm.
    case completedPartial

    /// The pass observed task cancellation before starting or mid-walk. It did not
    /// prune and must not suppress the next needed scan.
    case cancelled(scanGeneration: UUID?)

    /// The scanner was invalidated (account removed, credentials rotated, or a newer
    /// scan generation superseded this one after it began). Never stamps completion.
    case invalidated

    /// The walk could not acquire a current scan id — a newer scan generation had
    /// already superseded this one before the walk began. Nothing was written.
    case failedToStart

    /// Whether this outcome represents a genuinely completed or no-op pass that is
    /// eligible (subject to the coordinator's task/scanner/credential generation
    /// check) to record a background-scan completion timestamp.
    var earnsCompletionStamp: Bool {
        switch self {
        case .completedClean, .completedPartial, .freshNoOp:
            return true
        case .cancelled, .invalidated, .failedToStart:
            return false
        }
    }

    /// A short, secret-safe label for diagnostics. Contains no path or library detail.
    var diagnosticLabel: String {
        switch self {
        case .freshNoOp: return "freshNoOp"
        case .completedClean: return "completedClean"
        case .completedPartial: return "completedPartial"
        case .cancelled: return "cancelled"
        case .invalidated: return "invalidated"
        case .failedToStart: return "failedToStart"
        }
    }
}
