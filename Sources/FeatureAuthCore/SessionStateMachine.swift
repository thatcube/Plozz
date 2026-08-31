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
    /// One or more accounts were just added — pick which of each new server's
    /// libraries appear on Home. Shown on every add (first run and later),
    /// after any Plex-user pick, before profile setup / entering the app.
    case selectLibraries
    /// Plex account with 2+ Home users just signed in — pick which Home user
    /// this profile watches as ("Which Plex user are you?"). Shown the first
    /// time a profile encounters a given Plex account (both first run and later
    /// adds); the choice is remembered on the profile afterward.
    case selectPlexUser
    /// First-ever account was just added on a brand-new install; confirm (or
    /// edit) the profile we seeded from the sign-in before entering the app.
    case confirmProfile
    /// First run: optionally connect Seerr and choose the active profile's acting
    /// user before entering the app.
    case selectSeerr
    /// Brand-new install only: after the profile is confirmed, pick the app's
    /// theme before entering the app.
    case selectTheme
    /// Brand-new install only: choose the active profile's navigation chrome after
    /// its theme. Existing installs receive the same picker through feature
    /// onboarding instead of re-entering the account setup state machine.
    case selectNavigation
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
    /// The *first-ever* account finished authenticating on a brand-new install;
    /// detour through the one-time profile confirm step before the app.
    case accountAuthenticatedNeedsProfile
    /// A signed-in Plex account has 2+ Home users and this profile hasn't bound
    /// one yet — show the "Which Plex user are you?" picker.
    case plexUserSelectionRequired
    /// One or more accounts were persisted — show the per-server "choose your
    /// libraries" step before continuing onboarding.
    case librarySelectionRequired
    /// The user confirmed (or edited) their seeded profile on first run.
    case profileConfirmed
    case seerrSelected
    /// The user picked an app theme on the one-time first-run theme step.
    case themeSelected
    /// The user confirmed a navigation style on first run.
    case navigationSelected
    case authenticationFailed(AppError)
    /// Back out of onboarding without adding an account.
    case cancelOnboarding
    /// Cancel an add-user authentication flow that was launched from an existing
    /// screen (e.g. Profile setup → Watching as), returning directly to that
    /// still-mounted origin instead of the generic server picker.
    case cancelOnboardingToApp
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
        // A Plex account with 2+ Home users needs the "Which Plex user are you?"
        // step. Plex resolves its server inside the provider flow, so it can
        // arrive here directly from the provider picker without materialising a
        // throwaway `.authenticating` page.
        case (.onboarding(.selectingServer, _), .plexUserSelectionRequired),
             (.onboarding(.authenticating, _), .plexUserSelectionRequired):
            return .onboarding(.selectPlexUser, canReturnToApp: true)
        // One or more accounts were persisted — show the "choose your libraries"
        // step. Plex can resolve directly from the provider picker; Jellyfin
        // arrives from its dedicated authentication page.
        case (.onboarding(.selectingServer, _), .librarySelectionRequired),
             (.onboarding(.authenticating, _), .librarySelectionRequired),
             (.onboarding(.selectPlexUser, _), .librarySelectionRequired):
            return .onboarding(.selectLibraries, canReturnToApp: true)
        // Leaving the library step: first-ever account on a fresh install detours
        // through the one-time profile confirm step; a later add drops straight
        // into the app.
        case (.onboarding(.selectLibraries, _), .accountAuthenticatedNeedsProfile):
            return .onboarding(.confirmProfile, canReturnToApp: true)
        case (.onboarding(.selectLibraries, _), .accountAuthenticated):
            return .ready
        // First-ever account on a fresh install: detour through the one-time
        // profile confirm step before entering the app. There is now ≥1 account
        // behind it, so `canReturnToApp` is true. Reachable straight from auth
        // (Jellyfin, or Plex with <2 Home users) or after the Plex-user pick.
        case (.onboarding(.authenticating, _), .accountAuthenticatedNeedsProfile),
             (.onboarding(.selectPlexUser, _), .accountAuthenticatedNeedsProfile):
            return .onboarding(.confirmProfile, canReturnToApp: true)
        case let (.onboarding(.selectingServer, canReturn), .authenticationFailed(error)),
             let (.onboarding(.authenticating, canReturn), .authenticationFailed(error)):
            return .failed(error, canReturnToApp: canReturn)

        // Plex-user pick on a *later* add (not first run) goes straight to the app.
        case (.onboarding(.selectPlexUser, _), .accountAuthenticated):
            return .ready

        // First profile: choose Seerr request identity, then theme.
        case (.onboarding(.confirmProfile, _), .profileConfirmed):
            return .onboarding(.selectSeerr, canReturnToApp: true)
        case (.onboarding(.selectSeerr, _), .seerrSelected):
            return .onboarding(.selectTheme, canReturnToApp: true)

        // Appearance choices finish with navigation, then enter the app.
        case (.onboarding(.selectTheme, _), .themeSelected):
            return .onboarding(.selectNavigation, canReturnToApp: true)
        case (.onboarding(.selectNavigation, _), .navigationSelected):
            return .ready

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

        case (.onboarding, .cancelOnboardingToApp):
            return .ready

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
