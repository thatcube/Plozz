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
        lock.lock(); defer { lock.unlock() }
        factories[kind] = factory
        cache.removeAll()
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
        for staleKey in cache.keys where staleKey.hasPrefix("\(identity)|") {
            cache.removeValue(forKey: staleKey)
        }
        cache[key] = provider
        lock.unlock()
        return provider
    }

    /// Drops all memoized providers. Call when the signed-in account set changes
    /// so removed accounts don't retain provider/connection state.
    public func invalidateCache() {
        lock.lock(); defer { lock.unlock() }
        cache.removeAll()
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
