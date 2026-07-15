import Foundation

/// Immutable identity required by providers that own Plozz-local media state.
///
/// The account and profile are both explicit so delayed work never consults
/// whichever profile happens to be active when it eventually executes.
public struct LocalMediaContext: Hashable, Sendable {
    public let accountID: String
    public let profileID: String
    public let profileNamespace: String?

    public init(accountID: String, profileID: String, profileNamespace: String?) {
        self.accountID = accountID
        self.profileID = profileID
        self.profileNamespace = profileNamespace
    }
}

/// Complete, immutable input used to construct one provider instance.
///
/// `session` carries runtime-only credential material. Cache identity comes only
/// from the stable account id, random credential revision, and relevant local
/// profile id; secrets are never interpolated into a key or description.
public struct ProviderResolutionContext: Equatable, Sendable {
    public let session: UserSession
    public let accountID: String
    public let credentialRevision: CredentialRevision
    public let localMediaContext: LocalMediaContext?

    public init(
        session: UserSession,
        accountID: String,
        credentialRevision: CredentialRevision,
        localMediaContext: LocalMediaContext? = nil
    ) {
        self.session = session
        self.accountID = accountID
        self.credentialRevision = credentialRevision
        self.localMediaContext = localMediaContext
    }
}

extension ProviderResolutionContext: CustomStringConvertible {
    public var description: String {
        let profile = localMediaContext?.profileID ?? "<none>"
        return "ProviderResolutionContext(account: \(accountID), revision: \(credentialRevision.rawValue), profile: \(profile), session: <redacted>)"
    }
}

public enum ProviderResolutionError: Error, Equatable, Sendable {
    case unregisteredProvider(ProviderKind)
    case contextChangedWithoutRevision(accountID: String)
    case localContextAccountMismatch(accountID: String, localAccountID: String)
    case localMediaContextRequired(ProviderKind)
}

/// Resolves immutable account/profile context into a concrete `MediaProvider`.
///
/// This is the indirection that lets the composition root stay
/// provider-agnostic: feature code and `AppShell` ask a resolver for "the
/// provider for this context" without importing any specific provider module.
public protocol ProviderResolving: Sendable {
    func provider(for context: ProviderResolutionContext) throws -> any MediaProvider
}

/// Optional capability a provider adopts to release long-lived connection state
/// (open sockets, an SMB session) when the registry evicts it — on account
/// removal, a token refresh, or a factory re-registration. Detected via
/// `provider as? ProviderTeardown`; providers that hold no such state (or whose
/// state is released by ARC) simply don't conform and are dropped as before.
public protocol ProviderTeardown: Sendable {
    /// Best-effort release of connection state. Safe to call more than once.
    func teardown() async
}

/// A registry mapping `ProviderKind` → provider factory.
///
/// The composition root (`AppShell`) registers the concrete factories it links
/// (today: `.jellyfin`, `.emby`, `.plex`, and `.mediaShare`). Adding another backend is a one-line
/// `register(.someKind, …)` at the composition root — **no change** to this
/// type, `AppState`, or any feature module.
public final class ProviderRegistry: ProviderResolving, @unchecked Sendable {
    public typealias Factory = @Sendable (ProviderResolutionContext) throws -> any MediaProvider

    private struct CacheKey: Hashable {
        let accountID: String
        let credentialRevision: CredentialRevision
        let localProfileID: String?
    }

    private struct CacheEntry {
        let context: ProviderResolutionContext
        let provider: any MediaProvider
    }

    private var factories: [ProviderKind: Factory] = [:]
    /// Vending the *same* provider instance for a context is essential, not just
    /// an optimization:
    /// a provider owns long-lived connection state (e.g. Plex's resolved/cached
    /// base URL). Rebuilding it on every `provider(for:)` call — which happens
    /// constantly as SwiftUI reads `AppState`'s computed provider properties —
    /// would re-run connection discovery (a burst of reachability probes) on
    /// every screen open, accumulating sockets until the connection pool chokes.
    private var cache: [CacheKey: CacheEntry] = [:]
    private let lock = NSLock()

    public init() {}

    /// Registers (or replaces) the factory for `kind`, evicting only providers
    /// built by that kind.
    public func register(_ kind: ProviderKind, factory: @escaping Factory) {
        lock.lock()
        factories[kind] = factory
        let staleKeys = cache.compactMap { key, entry in
            entry.context.session.server.provider == kind ? key : nil
        }
        let evicted = staleKeys.compactMap { cache.removeValue(forKey: $0)?.provider }
        lock.unlock()
        Self.teardown(evicted)
    }

    public func provider(for context: ProviderResolutionContext) throws -> any MediaProvider {
        if let local = context.localMediaContext, local.accountID != context.accountID {
            throw ProviderResolutionError.localContextAccountMismatch(
                accountID: context.accountID,
                localAccountID: local.accountID
            )
        }

        let kind = context.session.server.provider
        let key = CacheKey(
            accountID: context.accountID,
            credentialRevision: context.credentialRevision,
            localProfileID: context.localMediaContext?.profileID
        )
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            guard cached.context == context else {
                throw ProviderResolutionError.contextChangedWithoutRevision(
                    accountID: context.accountID
                )
            }
            return cached.provider
        }
        let factory = factories[kind]
        lock.unlock()
        guard let factory else {
            throw ProviderResolutionError.unregisteredProvider(kind)
        }
        let provider = try factory(context)

        lock.lock()
        // Another thread may have built it while we were unlocked.
        if let existing = cache[key] {
            lock.unlock()
            guard existing.context == context else {
                Self.teardown([provider])
                throw ProviderResolutionError.contextChangedWithoutRevision(
                    accountID: context.accountID
                )
            }
            Self.teardown([provider])
            return existing.provider
        }
        // A credential revision supersedes every older profile-scoped provider
        // for the account. Same-revision providers for distinct local profiles
        // remain isolated and may coexist.
        var evicted: [any MediaProvider] = []
        let staleKeys = cache.keys.filter {
            $0.accountID == context.accountID
                && $0.credentialRevision != context.credentialRevision
        }
        for staleKey in staleKeys {
            if let stale = cache.removeValue(forKey: staleKey) {
                evicted.append(stale.provider)
            }
        }
        cache[key] = CacheEntry(context: context, provider: provider)
        lock.unlock()
        Self.teardown(evicted)
        return provider
    }

    /// Drops all memoized providers. Call when the signed-in account set changes
    /// so removed accounts don't retain provider/connection state.
    public func invalidateCache() {
        lock.lock()
        let evicted = cache.values.map(\.provider)
        cache.removeAll()
        lock.unlock()
        Self.teardown(evicted)
    }

    /// Drops memoized providers for one account without disturbing unrelated
    /// servers. Used when a runtime-derived identity such as a Plex Home user
    /// changes without replacing the account's persisted credential.
    public func invalidate(accountID: String) {
        lock.lock()
        let staleKeys = cache.keys.filter { $0.accountID == accountID }
        let evicted = staleKeys.compactMap { cache.removeValue(forKey: $0)?.provider }
        lock.unlock()
        Self.teardown(evicted)
    }

    /// Fire-and-forget teardown of providers dropped from the cache, so a removed
    /// account's SMB session (or any other connection state) is actively closed
    /// rather than left to a `deinit` that may never release the socket.
    private static func teardown(_ providers: [any MediaProvider]) {
        let closeables = providers.compactMap { $0 as? ProviderTeardown }
        guard !closeables.isEmpty else { return }
        Task.detached {
            for closeable in closeables { await closeable.teardown() }
        }
    }
}

/// A runtime pairing of an `Account` with its resolved `MediaProvider`.
///
/// Multi-account aggregation (Home & Search fanning out across several
/// servers) consumes `[ResolvedAccount]` — `AppState` exposes the active set
/// and feature view-models (`HomeAggregator`, `SearchViewModel`, …) merge per
/// account via the `MediaProvider` protocol, so adding/removing accounts
/// never requires changes to core.
public struct ResolvedAccount: Sendable {
    public let account: Account
    public let provider: any MediaProvider

    public init(account: Account, provider: any MediaProvider) {
        self.account = account
        self.provider = provider
    }
}
