import Foundation
import CoreModels
import CoreNetworking

/// The secret-safe *owner* of a scan that ended without earning a completion stamp.
///
/// A forced-relaunch hardware scan that ends partial/cancelled before advancing
/// `scan_counter`/`last_full_scan_at` must be attributable to an exact owner from an
/// authoritative signal recorded *at the point of cancellation* — never guessed from
/// timing. Each coordinator-initiated cancellation stamps its owner before it cancels
/// the scan task, so the two prior physical cancellations become diagnosable.
enum ShareScanCancellationOwner: String, Sendable, Equatable {
    /// The Settings "Scan now" action superseded an in-flight background pass.
    case rescanSuperseded
    /// A credential rotation replaced the scanner (lifecycle replacement).
    case credentialChange
    /// The account was invalidated / removed.
    case accountInvalidation
    /// Playback admission drained the scanner to grant a playback lease.
    case playbackAdmission
    /// A newer scanner/scan generation replaced this one with no explicit owner
    /// (e.g. the store rejected a superseded scan id, or the generation moved while
    /// the walk ran).
    case scannerGenerationReplaced
    /// A genuinely completed / no-op pass whose scanner or credential generation was
    /// already superseded, so it must not stamp the replacement generation.
    case supersededCompletion
    /// Cancelled with no coordinator-attributed owner — e.g. app relaunch / teardown
    /// timing. Kept distinct so it is never mis-attributed to a specific owner.
    case unattributed
}

/// A secret-safe record of a scan that ended without stamping completion.
///
/// Carries only generation identities (random scan-generation UUID, the non-secret
/// credential-revision UUID) and the authoritative owner — never a share-relative
/// path, filename, or any library structure. `owner` is authoritative; timing is not
/// part of the record and must not be used to attribute a cancellation.
struct ShareScanCancellationRecord: Sendable, Equatable {
    let accountKey: String
    let owner: ShareScanCancellationOwner
    let scannerGeneration: UUID?
    let credentialRevision: UUID?
    let outcome: String
}

/// Sink for scan-cancellation diagnostics. Injected so tests can assert the exact
/// owner/generation of each non-completing scan without a device, and so production
/// emits a secret-safe line.
protocol ShareScanDiagnostics: Sendable {
    func recordCancellation(_ record: ShareScanCancellationRecord)
}

/// Production sink: emits one secret-safe boot/telemetry line per non-completing scan.
/// Every field is non-secret (opaque account id + random generation UUIDs + owner);
/// no path or library structure is logged.
struct DefaultShareScanDiagnostics: ShareScanDiagnostics {
    func recordCancellation(_ record: ShareScanCancellationRecord) {
        let scanner = record.scannerGeneration?.uuidString ?? "none"
        let revision = record.credentialRevision?.uuidString ?? "none"
        PlozzLog.boot(
            "share.scan noncompletion owner=\(record.owner.rawValue) "
            + "outcome=\(record.outcome) account=\(record.accountKey) "
            + "scannerGen=\(scanner) credRev=\(revision)"
        )
        BrowseDiagnostics.event(
            "scan! \(record.accountKey) owner=\(record.owner.rawValue) outcome=\(record.outcome)"
        )
    }
}
