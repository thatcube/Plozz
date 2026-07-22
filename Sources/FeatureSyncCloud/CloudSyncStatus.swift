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

    /// Debounces error display: a transient conflict that self-heals on the engine's
    /// own retry shouldn't flash a scary "Couldn't sync". The error is only shown if
    /// it's still pending after a short grace period without a success/syncing update.
    @ObservationIgnored private var pendingErrorTask: Task<Void, Never>?

    public init() {}

    /// Non-error phase update (idle/syncing/signedOut/disabled). Cancels any pending
    /// debounced error, since we've made forward progress.
    func setPhase(_ newPhase: Phase, syncedNow: Bool = false) {
        pendingErrorTask?.cancel(); pendingErrorTask = nil
        phase = newPhase
        if syncedNow { lastSyncedAt = Date(); lastDiagnostic = nil; lastErrorMessage = nil }
    }

    /// Record an error, but only surface it after a grace period — so a blip that
    /// the engine immediately resolves (a following idle) never shows red.
    func setError(_ message: String, diagnostic: String?) {
        pendingErrorTask?.cancel()
        pendingErrorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard !Task.isCancelled, let self else { return }
            self.phase = .error
            self.lastErrorMessage = message
            if let diagnostic { self.lastDiagnostic = diagnostic }
        }
    }

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
