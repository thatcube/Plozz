import Foundation
import CoreModels

/// Explicit auth/session state machine for **multi-account** Plozz.
///
/// The spec requires session state be modelled explicitly rather than as a
/// scattering of booleans. `AppShell` renders one screen per state and feeds
/// events in; the machine owns all legal transitions in one place.
///
/// "Authenticated" now means **≥1 account**. Onboarding (`selectingServer` →
/// `authenticating`) is reachable both at first launch (no accounts yet) and
/// from inside the signed-in app ("add another server"). The `canReturnToApp`
/// flag on an onboarding step records whether there is already ≥1 account behind
/// it, so cancelling returns to the app instead of dead-ending.
///
/// ```
/// launching ─restored(≥1)────────────────────────▶ ready
///     │                                              │  ▲
///     └─restored([])─▶ onboarding(selectingServer)   │  │ addAccountRequested
///                          │        ▲   (canReturnToApp reflects account count)
///                  serverSelected   │ cancelOnboarding / authFailed→failed→retry
///                          ▼        │
///                 onboarding(authenticating) ─accountAuthenticated─▶ ready
/// ```
public enum OnboardingStep: Equatable, Sendable {
    /// No server chosen yet — show the picker.
    case selectingServer
    /// Server chosen, running Quick Connect / password sign-in.
    case authenticating(MediaServer)
}

public enum SessionState: Equatable, Sendable {
    /// App just launched; we haven't checked for stored accounts yet.
    case launching
    /// Adding an account. `canReturnToApp` is true when ≥1 account already
    /// exists (i.e. the user is adding *another* server and can cancel back to
    /// the app); false during first-run onboarding.
    case onboarding(OnboardingStep, canReturnToApp: Bool)
    /// Signed in with ≥1 account. `AppState` owns the account list/active set.
    case ready
    /// A non-fatal failure surfaced to the user (with recovery options).
    /// `canReturnToApp` carries the onboarding context forward so retry/cancel
    /// can route correctly.
    case failed(AppError, canReturnToApp: Bool)
}

/// Events that can drive `SessionState`.
public enum SessionEvent: Sendable {
    /// Result of the launch-time restore (the persisted accounts, possibly empty).
    case restored([Account])
    /// User asked to add another account from inside the app.
    case addAccountRequested
    case serverSelected(MediaServer)
    /// An account finished authenticating and was persisted.
    case accountAuthenticated
    case authenticationFailed(AppError)
    /// Back out of onboarding without adding an account.
    case cancelOnboarding
    /// The persisted account set changed (e.g. removal/sign-out); carries the
    /// new list so the machine can decide ready vs. onboarding.
    case accountsChanged([Account])
    case retry
}

public struct SessionStateMachine: Sendable {
    public private(set) var state: SessionState

    public init(state: SessionState = .launching) {
        self.state = state
    }

    /// Applies `event`, mutating `state`. Illegal transitions are ignored so a
    /// late/duplicate event can never corrupt the flow.
    public mutating func apply(_ event: SessionEvent) {
        state = Self.reduce(state: state, event: event)
    }

    /// Pure reducer — easy to unit-test exhaustively.
    public static func reduce(state: SessionState, event: SessionEvent) -> SessionState {
        switch (state, event) {
        // Launch restore.
        case let (.launching, .restored(accounts)):
            return accounts.isEmpty
                ? .onboarding(.selectingServer, canReturnToApp: false)
                : .ready

        // Add-another-account from inside the app.
        case (.ready, .addAccountRequested):
            return .onboarding(.selectingServer, canReturnToApp: true)

        // Server picked during onboarding.
        case let (.onboarding(.selectingServer, canReturn), .serverSelected(server)):
            return .onboarding(.authenticating(server), canReturnToApp: canReturn)
        // Re-select a different server while authenticating.
        case let (.onboarding(.authenticating, canReturn), .serverSelected(server)):
            return .onboarding(.authenticating(server), canReturnToApp: canReturn)

        // Authentication outcomes.
        case (.onboarding(.authenticating, _), .accountAuthenticated):
            return .ready
        case let (.onboarding(.authenticating, canReturn), .authenticationFailed(error)):
            return .failed(error, canReturnToApp: canReturn)

        // Cancelling the Quick Connect / password step steps BACK to the
        // picker (preserving the return-to-app context), so the user lands on
        // the server list they came from — not the Home screen.
        case let (.onboarding(.authenticating, canReturn), .cancelOnboarding):
            return .onboarding(.selectingServer, canReturnToApp: canReturn)

        // Cancelling from the picker itself backs all the way out: return to the
        // app if it has accounts, else stay on the picker (first-run has nowhere
        // to go).
        case let (.onboarding(.selectingServer, canReturn), .cancelOnboarding):
            return canReturn ? .ready : .onboarding(.selectingServer, canReturnToApp: false)

        // Failure recovery.
        case let (.failed(_, canReturn), .retry),
             let (.failed(_, canReturn), .cancelOnboarding):
            return canReturn ? .ready : .onboarding(.selectingServer, canReturnToApp: false)
        case let (.failed(_, canReturn), .serverSelected(server)):
            return .onboarding(.authenticating(server), canReturnToApp: canReturn)

        // Account set changed (removal / sign-out) from anywhere meaningful.
        case let (_, .accountsChanged(accounts)):
            return accounts.isEmpty
                ? .onboarding(.selectingServer, canReturnToApp: false)
                : .ready

        default:
            // No legal transition for this (state, event) pair — stay put.
            return state
        }
    }
}
