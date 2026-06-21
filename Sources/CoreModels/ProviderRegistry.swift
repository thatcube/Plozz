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
/// (Phase 1: `.jellyfin`). Adding Plex (branch G) is a one-line `register(.plex,
/// …)` at the composition root — **no change** to this type, `AppState`, or any
/// feature module.
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
/// ## Aggregation seam (branch H)
/// Multi-account aggregation (a customizable, combined Home across several
/// servers) is **not** built in this branch. The seam is: `AppState` exposes the
/// active accounts as `[ResolvedAccount]`, and a future Home view model fans out
/// over that list (one provider call per account, merged by the VM). This branch
/// only consumes the *primary* active account for the existing single-provider
/// Home; nothing else needs to change in core when branch H lands.
public struct ResolvedAccount: Sendable {
    public let account: Account
    public let provider: any MediaProvider

    public init(account: Account, provider: any MediaProvider) {
        self.account = account
        self.provider = provider
    }
}
