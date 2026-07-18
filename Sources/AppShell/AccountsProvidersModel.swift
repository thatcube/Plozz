import Foundation
import Observation
import CoreModels
import CoreNetworking
import FeatureAuth

/// The accounts + providers hub, extracted from `AppState`.
///
/// Owns the multi-account core: the persisted `AccountPersisting` store, the
/// `ProviderRegistry`, the signed-in `accounts` and the active-account subset,
/// and every provider-resolution accessor (`provider(forAccountID:)`,
/// `homeAccounts`, `resolvedActiveAccounts`, …). This is the dependency HUB the
/// Plex-home-user, media-share, profile-flow, and household facets sit downstream
/// of, so it's extracted first and exposes a stable typed interface rather than
/// throwaway closures.
///
/// It depends OUTWARD only through narrow injected seams so the hub never reaches
/// back into the domains that will later be split out of `AppState`:
///  - `tokenResolver` — the effective auth token for an account (Plex Home-user
///    override aware). Wired by `AppState` today; becomes the Plex-home-user
///    facet's responsibility in a later batch.
///  - `credentialRevision` — the effective credential revision (override aware).
///  - `onActiveAccountsChanged` — fired after `reloadAccounts` recomputes the
///    active set, so the media-share runtime can update its preferred-account
///    keys. Keeps the media-share concern out of the hub.
///
/// Kept `@MainActor @Observable` so `accounts` / `activeAccountIDs` observation is
/// identical to when they lived on `AppState`.
@MainActor
@Observable
public final class AccountsProvidersModel {
    /// All signed-in accounts, in stable order.
    public private(set) var accounts: [Account] = []
    /// The subset of `accounts` currently included in the active set. Sourced
    /// from the active profile (falling back to the household-global active set
    /// for the default profile).
    public private(set) var activeAccountIDs: Set<String> = []

    /// The persisted multi-account store (token per account in the Keychain).
    @ObservationIgnored
    public let accountStore: AccountPersisting
    /// Resolves the right `MediaProvider` per account, with a per-account cache.
    @ObservationIgnored
    public let registry: ProviderRegistry

    /// The household's profiles + active selection. Shared reference (the same
    /// instance `AppState` holds); read for the active-set resolution and the
    /// media-share local-media context.
    @ObservationIgnored
    private let profilesModel: ProfilesModel

    /// The auth token to use for an account id, preferring an in-memory Plex
    /// Home-user override over the account's stored (admin) token. Injected so the
    /// hub doesn't own Plex-home-user state.
    @ObservationIgnored
    public var tokenResolver: @MainActor (String) -> String? = { _ in nil }
    /// The effective credential revision for an account (Plex override aware).
    @ObservationIgnored
    public var credentialRevision: @MainActor (Account) -> CredentialRevision = { $0.credentialRevision }
    /// Fired after `reloadAccounts` recomputes the active set, with the resolved
    /// active ids and the full account list, so the media-share runtime can update
    /// its preferred-account keys without the hub knowing about media shares.
    @ObservationIgnored
    public var onActiveAccountsChanged: @MainActor (Set<String>, [Account]) -> Void = { _, _ in }

    public init(
        accountStore: AccountPersisting,
        registry: ProviderRegistry,
        profilesModel: ProfilesModel
    ) {
        self.accountStore = accountStore
        self.registry = registry
        self.profilesModel = profilesModel
    }

    /// This device's stable client identifier.
    public var deviceID: String { accountStore.deviceID() }

    /// The provider for the primary active account — the single-provider Home in
    /// this branch. `nil` when not signed in.
    public var primaryProvider: (any MediaProvider)? {
        guard let account = primaryActiveAccount,
              let token = tokenResolver(account.id) else { return nil }
        return resolveProvider(for: providerResolutionContext(for: account, token: token))
    }

    /// The active account that drives the current single-provider UI.
    public var primaryActiveAccount: Account? {
        accounts.first { activeAccountIDs.contains($0.id) } ?? accounts.first
    }

    /// The active accounts paired with their resolved providers. Multi-account
    /// Home/Search fan out over this list (one provider call per account,
    /// merged by the view model). Tokens are resolved on demand and never
    /// stored on the value.
    public var resolvedActiveAccounts: [ResolvedAccount] {
        accounts.compactMap { account in
            guard activeAccountIDs.contains(account.id),
                  let token = tokenResolver(account.id),
                  let provider = resolveProvider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return ResolvedAccount(account: account, provider: provider)
        }
    }

    /// Resolves specific account ids into `ResolvedAccount`s for the onboarding
    /// "choose your libraries" step (which fans a library-listing call out over
    /// the just-added accounts). Tokens are resolved on demand.
    public func resolvedAccounts(withIDs ids: [String]) -> [ResolvedAccount] {
        ids.compactMap { id in
            guard let account = accounts.first(where: { $0.id == id }),
                  let token = tokenResolver(account.id),
                  let provider = resolveProvider(
                      for: providerResolutionContext(for: account, token: token)
                  )
            else { return nil }
            return ResolvedAccount(account: account, provider: provider)
        }
    }

    /// The accounts the unified Home/Search fan out over. Normally the active
    /// set; falls back to the primary account so the signed-in UI is never empty
    /// even if the active-id set is somehow empty.
    public var homeAccounts: [ResolvedAccount] {
        let active = resolvedActiveAccounts
        if !active.isEmpty { return active }
        guard let account = primaryActiveAccount,
              let token = tokenResolver(account.id),
              let provider = resolveProvider(
                  for: providerResolutionContext(for: account, token: token)
              )
        else { return [] }
        return [ResolvedAccount(account: account, provider: provider)]
    }

    /// Resolves the provider for a specific account id — used to route a tapped
    /// library/item from the merged Home back to its owning provider. Tokens are
    /// resolved on demand and never stored on the value.
    public func provider(forAccountID id: String) -> (any MediaProvider)? {
        guard let account = accounts.first(where: { $0.id == id }),
              let token = tokenResolver(account.id)
        else { return nil }
        return resolveProvider(for: providerResolutionContext(for: account, token: token))
    }

    /// Builds the provider-resolution context for an account + resolved token.
    public func providerResolutionContext(
        for account: Account,
        token: String
    ) -> ProviderResolutionContext {
        let localMediaContext = account.server.provider == .mediaShare
            ? LocalMediaContext(
                accountID: account.id,
                profileID: profilesModel.activeProfileID,
                profileNamespace: profilesModel.activeNamespace
            )
            : nil
        return ProviderResolutionContext(
            session: account.session(token: token),
            accountID: account.id,
            credentialRevision: credentialRevision(account),
            localMediaContext: localMediaContext
        )
    }

    /// Resolves a provider through the registry, logging any resolution error
    /// (unregistered provider, missing/stale credential revision, local-media
    /// context mismatch) instead of silently swallowing it. Returns `nil` on
    /// failure exactly as the previous `try?` did, so the observable resolution
    /// behavior is unchanged — the only new effect is a diagnostic log line so
    /// config/state bugs aren't invisible.
    private func resolveProvider(for context: ProviderResolutionContext) -> (any MediaProvider)? {
        do {
            return try registry.provider(for: context)
        } catch {
            PlozzLog.app.error("Provider resolution failed for account \(context.accountID): \(error)")
            return nil
        }
    }

    /// The active account ids for a specific profile, filtered to accounts that
    /// are still signed in, falling back to the household-global active set.
    public func activeAccountIDs(forProfile id: String) -> [String] {
        let known = Set(accounts.map(\.id))
        return profilesModel
            .activeAccountIDs(for: id, fallback: accountStore.activeAccountIDs())
            .filter { known.contains($0) }
    }

    /// Reloads accounts from the store and recomputes the active set for the
    /// active profile. Invalidates the provider cache first, then fires
    /// `onActiveAccountsChanged` so the media-share runtime can update its
    /// preferred-account keys.
    public func reloadAccounts() {
        registry.invalidateCache()
        accounts = accountStore.loadAccounts()
        let known = Set(accounts.map(\.id))
        // The household-global active set is the fallback for a profile that has
        // never chosen a subset (default profile / upgrade path).
        let globalActive = accountStore.activeAccountIDs()
        let resolved: Set<String>
        if let stored = profilesModel.storedActiveAccountIDs(for: profilesModel.activeProfileID) {
            // The profile made an *explicit* choice. Honor it exactly — including
            // an intentional empty set ("watch nothing"), which is what turning
            // the last server off produces and must not be silently re-expanded
            // to every account (that's what made the master server toggle appear
            // to do nothing). Only fall back if every chosen account has since
            // gone stale (e.g. the servers were signed out household-wide), so a
            // profile isn't left permanently blank by a removal it didn't make.
            let valid = Set(stored.filter { known.contains($0) })
            if valid.isEmpty && !stored.isEmpty {
                resolved = Set(globalActive.filter { known.contains($0) })
            } else {
                resolved = valid
            }
        } else {
            // Never chose → default to the household-global active set.
            resolved = Set(globalActive.filter { known.contains($0) })
        }
        activeAccountIDs = resolved
        onActiveAccountsChanged(resolved, accounts)
    }
}
