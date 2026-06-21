import Foundation
import Observation
import CoreModels
import FeatureAuth
import FeatureDiscovery
import ProviderJellyfin

/// The app's composition root and single source of truth for session state.
///
/// Wraps the `SessionStateMachine`, persists sessions through `SessionStore`,
/// and vends the active `MediaProvider`. `RootView` observes `state` and renders
/// exactly one screen per case.
@MainActor
@Observable
public final class AppState {
    public private(set) var state: SessionState = .launching

    public let captionModel: CaptionSettingsModel
    private var machine = SessionStateMachine()
    private let sessionStore: SessionPersisting

    public init(
        sessionStore: SessionPersisting? = nil,
        captionModel: CaptionSettingsModel? = nil
    ) {
        self.sessionStore = sessionStore ?? Self.makeDefaultSessionStore()
        self.captionModel = captionModel ?? CaptionSettingsModel()
    }

    private static func makeDefaultSessionStore() -> SessionPersisting {
        #if canImport(Security)
        return SessionStore()
        #else
        return SessionStore(secureStore: InMemorySecureStore())
        #endif
    }

    /// Restores any stored session on launch (relaunch without re-login).
    public func bootstrap() {
        let restored = sessionStore.loadSession()
        apply(.restored(restored))
    }

    /// Stable per-install device id used for Quick Connect + auth.
    public var deviceID: String { sessionStore.deviceID() }

    /// The active provider, when authenticated.
    public var provider: (any MediaProvider)? {
        guard case let .authenticated(session) = state else { return nil }
        return JellyfinProvider(session: session)
    }

    public var lastServerStore: LastServerStoring { UserDefaultsLastServerStore() }

    // MARK: Events

    public func selectServer(_ server: MediaServer) {
        apply(.serverSelected(server))
    }

    /// Persists a freshly-authenticated session and advances the machine.
    public func didAuthenticate(_ session: UserSession) {
        do {
            try sessionStore.save(session)
        } catch {
            apply(.authenticationFailed(.unknown("")))
            return
        }
        apply(.authenticated(session))
    }

    public func cancelAuthentication() {
        // Back out of Quick Connect to the picker.
        apply(.signedOut)
    }

    public func signOut() {
        try? sessionStore.clear()
        apply(.signedOut)
    }

    public func retry() {
        apply(.retry)
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
