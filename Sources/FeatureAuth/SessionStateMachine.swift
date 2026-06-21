import Foundation
import CoreModels

/// Explicit auth/session state machine.
///
/// The spec requires session state be modelled explicitly rather than as a
/// scattering of booleans. `AppShell` renders one screen per state and feeds
/// events in; the machine owns all legal transitions in one place.
///
/// ```
/// launching ──restore──▶ authenticated
///     │                       ▲
///     └──noSession──▶ selectingServer ──serverSelected──▶ authenticating
///                          ▲                                   │
///                          └──── signedOut (cancel/success) ◀──┘
/// ```
public enum SessionState: Equatable, Sendable {
    /// App just launched; we haven't checked for a stored session yet.
    case launching
    /// No server chosen / no stored session — show the picker.
    case selectingServer
    /// Server chosen, running Quick Connect.
    case authenticating(MediaServer)
    /// Fully signed in.
    case authenticated(UserSession)
    /// A non-fatal failure surfaced to the user (with recovery options).
    case failed(AppError)
}

/// Events that can drive `SessionState`.
public enum SessionEvent: Sendable {
    /// Result of the launch-time restore attempt.
    case restored(UserSession?)
    case serverSelected(MediaServer)
    case authenticated(UserSession)
    case authenticationFailed(AppError)
    case signedOut
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
        case let (.launching, .restored(session?)):
            return .authenticated(session)
        case (.launching, .restored(nil)):
            return .selectingServer

        case let (.selectingServer, .serverSelected(server)):
            return .authenticating(server)

        case let (.authenticating, .authenticated(session)):
            return .authenticated(session)
        case let (.authenticating, .authenticationFailed(error)):
            return .failed(error)

        // Allow re-selecting a different server while authenticating.
        case let (.authenticating, .serverSelected(server)):
            return .authenticating(server)

        case (.authenticated, .signedOut),
             (.authenticating, .signedOut),
             (.failed, .signedOut):
            return .selectingServer

        case (.failed, .retry):
            return .selectingServer
        case let (.failed, .serverSelected(server)):
            return .authenticating(server)

        default:
            // No legal transition for this (state, event) pair — stay put.
            return state
        }
    }
}
