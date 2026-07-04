import Foundation

/// Resolves an authenticated `UserSession` into a concrete `MediaProvider`.
///
/// This is the indirection that lets the composition root stay
/// provider-agnostic: feature code and `AppShell` ask a resolver for "the
/// provider for this session" without importing any specific provider module.
public protocol ProviderResolving: Sendable {
    /// Vends the provider for `session.server.provider`.
    /// - Throws: `AppError.unknown` if no factory is registered for that kind.
    func provider(for session: UserSession) throws -> any MediaProvider
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
/// (today: `.jellyfin` and `.plex`). Adding another backend is a one-line
/// `register(.someKind, …)` at the composition root — **no change** to this
/// type, `AppState`, or any feature module.
public final class ProviderRegistry: ProviderResolving, @unchecked Sendable {
    public typealias Factory = @Sendable (UserSession) -> any MediaProvider

    private var factories: [ProviderKind: Factory] = [:]
    /// Memoized providers keyed by `server.id|userID|token`. Vending the *same*
    /// provider instance for a session is essential, not just an optimization:
    /// a provider owns long-lived connection state (e.g. Plex's resolved/cached
    /// base URL). Rebuilding it on every `provider(for:)` call — which happens
    /// constantly as SwiftUI reads `AppState`'s computed provider properties —
    /// would re-run connection discovery (a burst of reachability probes) on
    /// every screen open, accumulating sockets until the connection pool chokes.
    private var cache: [String: any MediaProvider] = [:]
    private let lock = NSLock()

    public init() {}

    /// Registers (or replaces) the factory for `kind`. Clears any cached
    /// providers of that kind so the new factory takes effect.
    public func register(_ kind: ProviderKind, factory: @escaping Factory) {
        lock.lock()
        factories[kind] = factory
        let evicted = Array(cache.values)
        cache.removeAll()
        lock.unlock()
        Self.teardown(evicted)
    }

    public func provider(for session: UserSession) throws -> any MediaProvider {
        let kind = session.server.provider
        let identity = "\(session.server.id)|\(session.userID)"
        let key = "\(identity)|\(session.accessToken)"
        lock.lock()
        if let cached = cache[key] {
            lock.unlock()
            return cached
        }
        let factory = factories[kind]
        lock.unlock()
        guard let factory else {
            throw AppError.unknown("No provider registered for \(kind.displayName)")
        }
        let provider = factory(session)
        lock.lock()
        // Another thread may have built it while we were unlocked.
        if let existing = cache[key] {
            lock.unlock()
            return existing
        }
        // Evict any prior entry for the same server+user (e.g. a refreshed token)
        // so the cache holds exactly one live provider per account.
        var evicted: [any MediaProvider] = []
        for staleKey in cache.keys where staleKey.hasPrefix("\(identity)|") {
            if let stale = cache.removeValue(forKey: staleKey) { evicted.append(stale) }
        }
        cache[key] = provider
        lock.unlock()
        Self.teardown(evicted)
        return provider
    }

    /// Drops all memoized providers. Call when the signed-in account set changes
    /// so removed accounts don't retain provider/connection state.
    public func invalidateCache() {
        lock.lock()
        let evicted = Array(cache.values)
        cache.removeAll()
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
