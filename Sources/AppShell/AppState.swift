import Foundation
import Observation
import CoreModels
import FeatureAuth
import FeatureDiscovery
import ProviderJellyfin
import RatingsService
import TopShelfKit

/// The app's composition root and single source of truth for session state.
///
/// Owns the **multi-account** model: it persists a list of `Account`s through
/// `AccountStore` (token per account in the Keychain), drives the
/// `SessionStateMachine`, and resolves the right `MediaProvider` per account via
/// a `ProviderRegistry`. `RootView` observes `state` and renders exactly one
/// screen per case.
@MainActor
@Observable
public final class AppState {
    public private(set) var state: SessionState = .launching

    /// All signed-in accounts, in stable order.
    public private(set) var accounts: [Account] = []
    /// The subset of `accounts` currently included in the active set. Branch H
    /// (aggregated Home) fans out over this; this branch uses the primary one.
    public private(set) var activeAccountIDs: Set<String> = []

    /// A Jellyfin item id requested via a Top Shelf deep link
    /// (`plozz://item/<id>`) that the signed-in UI should open for playback.
    /// Set when the app is launched/foregrounded from a Top Shelf card and
    /// cleared once the Home tab has routed to it.
    public var pendingPlayItemID: String?

    public let captionModel: CaptionSettingsModel
    public let spoilerModel: SpoilerSettingsModel
    public let themeModel: ThemeSettingsModel

    /// Provider-agnostic external-ratings enrichment (IMDb/RT/Metacritic via
    /// OMDb when a key is configured; otherwise a no-op). Injected into item
    /// detail so ratings are fetched async without blocking the screen.
    public let ratingsProvider: any ExternalRatingsProviding

    private var machine = SessionStateMachine()
    private let accountStore: AccountPersisting
    private let registry: ProviderRegistry

    public init(
        accountStore: AccountPersisting? = nil,
        registry: ProviderRegistry? = nil,
        captionModel: CaptionSettingsModel? = nil,
        spoilerModel: SpoilerSettingsModel? = nil,
        themeModel: ThemeSettingsModel? = nil,
        ratingsProvider: (any ExternalRatingsProviding)? = nil
    ) {
        self.accountStore = accountStore ?? Self.makeDefaultAccountStore()
        self.registry = registry ?? Self.makeDefaultRegistry()
        self.captionModel = captionModel ?? CaptionSettingsModel()
        self.spoilerModel = spoilerModel ?? SpoilerSettingsModel()
        self.themeModel = themeModel ?? ThemeSettingsModel()
        self.ratingsProvider = ratingsProvider ?? RatingsServiceFactory.make()
    }

    private static func makeDefaultAccountStore() -> AccountPersisting {
        #if canImport(Security)
        return AccountStore()
        #else
        return AccountStore(secureStore: InMemorySecureStore())
        #endif
    }

    /// Registers the providers this build links. Adding Plex (branch G) is a
    /// single additional `register(.plex, …)` here — nothing else in core
    /// changes.
    private static func makeDefaultRegistry() -> ProviderRegistry {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { session in
            JellyfinProvider(session: session)
        }
        return registry
    }

    /// Restores stored accounts on launch (relaunch without re-login), migrating
    /// any legacy single session first.
    public func bootstrap() {
        accountStore.migrateLegacySessionIfNeeded()
        reloadAccounts()
        apply(.restored(accounts))
    }

    /// Stable per-install device id used for Quick Connect + auth.
    public var deviceID: String { accountStore.deviceID() }

    public var lastServerStore: LastServerStoring { UserDefaultsLastServerStore() }

    // MARK: Providers

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        guard let account = primaryActiveAccount,
              let token = accountStore.token(for: account.id) else { return nil }
        return try? registry.provider(for: account.session(token: token))
    }

    /// The active account that drives the current single-provider UI.
    public var primaryActiveAccount: Account? {
        accounts.first { activeAccountIDs.contains($0.id) } ?? accounts.first
    }

    /// ## Aggregation seam (branch H)
    /// The active accounts paired with their resolved providers. Branch H's Home
    /// view model fans out over this list; this branch does not consume it yet
    /// beyond `primaryProvider`. Tokens are resolved on demand and never stored
    /// on the value.
    public var resolvedActiveAccounts: [ResolvedAccount] {
        accounts.compactMap { account in
            guard activeAccountIDs.contains(account.id),
                  let token = accountStore.token(for: account.id),
                  let provider = try? registry.provider(for: account.session(token: token))
            else { return nil }
            return ResolvedAccount(account: account, provider: provider)
        }
    }

    // MARK: Events

    /// Handles an incoming deep link. Recognised `plozz://item/<id>` links queue
    /// the item for playback once the user is signed in.
    public func handle(url: URL) {
        if let id = TopShelf.itemID(from: url) {
            pendingPlayItemID = id
        }
    }

    public func selectServer(_ server: MediaServer) {
        apply(.serverSelected(server))
    }

    /// Persists a freshly-authenticated account and advances the machine.
    public func didAuthenticate(_ session: UserSession) {
        let account = Account(from: session)
        do {
            try accountStore.add(account, token: session.accessToken)
        } catch {
            apply(.authenticationFailed(.unknown("")))
            return
        }
        reloadAccounts()
        apply(.accountAuthenticated)
    }

    /// Begins adding another account from inside the signed-in app.
    public func addAccount() {
        apply(.addAccountRequested)
    }

    public func cancelAuthentication() {
        apply(.cancelOnboarding)
    }

    /// Removes one account; drops to onboarding if it was the last.
    public func removeAccount(id: String) {
        try? accountStore.remove(id: id)
        reloadAccounts()
        apply(.accountsChanged(accounts))
    }

    /// Signs out of the primary active account (the one Settings currently shows).
    public func signOut() {
        if let account = primaryActiveAccount {
            removeAccount(id: account.id)
        }
    }

    /// Removes every account (full reset).
    public func signOutAll() {
        try? accountStore.clearAll()
        reloadAccounts()
        apply(.accountsChanged(accounts))
    }

    public func retry() {
        apply(.retry)
    }

    // MARK: Internals

    private func reloadAccounts() {
        accounts = accountStore.loadAccounts()
        activeAccountIDs = Set(accountStore.activeAccountIDs())
    }

    private func apply(_ event: SessionEvent) {
        machine.apply(event)
        state = machine.state
    }
}
