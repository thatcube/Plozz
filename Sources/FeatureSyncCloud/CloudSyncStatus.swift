import Foundation
import Observation

// MARK: - CloudSyncStatus
//
// Observable, MainActor-isolated status the UI binds to for a "last synced" line
// and a manual "Sync Now" affordance. The CKSyncEngine actor updates it from its
// event stream (fetch/send begin/end, errors, account changes). Purely advisory —
// sync itself is automatic; this only reflects and, via `syncNow`, nudges it.
@MainActor
@Observable
public final class CloudSyncStatus {
    public enum Phase: Equatable, Sendable {
        case disabled       // feature flag off
        case signedOut      // no usable iCloud account
        case idle           // up to date, nothing in flight
        case syncing        // a fetch or send is in progress
        case error          // last attempt failed (see message)
    }

    public internal(set) var phase: Phase = .disabled
    /// When the last successful send or fetch completed.
    public internal(set) var lastSyncedAt: Date?
    /// Short, non-secret description of the last failure (for the error state).
    public internal(set) var lastErrorMessage: String?
    /// A PERSISTENT diagnostic detail (last CloudKit error), shown until the next
    /// success clears it. Survives the phase flicker so it's actually readable.
    public internal(set) var lastDiagnostic: String?

    public init() {}

    /// A short, user-facing summary line, e.g. "Up to date · synced 2m ago".
    public var summary: String {
        switch phase {
        case .disabled:  return "Off"
        case .signedOut: return "Sign in to iCloud to sync"
        case .syncing:   return "Syncing…"
        case .error:     return lastErrorMessage.map { "Couldn't sync — \($0)" } ?? "Couldn't sync"
        case .idle:
            guard let lastSyncedAt else { return "On" }
            return "Up to date · synced \(Self.relative(lastSyncedAt))"
        }
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
