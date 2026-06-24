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
    private let lock = NSLock()

    public init() {}

    /// Registers (or replaces) the factory for `kind`.
    public func register(_ kind: ProviderKind, factory: @escaping Factory) {
        lock.lock(); defer { lock.unlock() }
        factories[kind] = factory
    }

    public func provider(for session: UserSession) throws -> any MediaProvider {
        let kind = session.server.provider
        lock.lock()
        let factory = factories[kind]
        lock.unlock()
        guard let factory else {
            throw AppError.unknown("No provider registered for \(kind.displayName)")
        }
        return factory(session)
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
