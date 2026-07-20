import Foundation
import CoreModels

/// Owns the media-share-specific account lifecycle mechanics that `AppState`
/// used to inline: deciding which accounts are media shares, and routing
/// credential retirement and catalog invalidation through the one
/// ``MediaShareRuntime`` that vended those accounts' provider/resolver/playback
/// capabilities.
///
/// `AppState` keeps its observable orchestration — reloading published
/// account/profile state, updating scan-status models, Plex Home-user override
/// bookkeeping, the identity index, and `apply(.accountsChanged:)`. This service
/// only removes the media-share transport/catalog teardown policy from AppState,
/// so there is a single seam that always retires and invalidates against the
/// same runtime generation.
///
/// Retirement and invalidation are dispatched as detached asynchronous work,
/// exactly as AppState previously wrapped them in `Task { … }`, preserving the
/// established non-blocking removal/sign-out ordering.
public struct MediaShareAccountService: Sendable {
    private let runtime: any MediaShareRuntime

    public init(runtime: any MediaShareRuntime) {
        self.runtime = runtime
    }

    /// The media-share account key for one account (its id), or `nil` if the
    /// account is not a media share.
    public func mediaShareAccountKey(for account: Account?) -> String? {
        guard let account, account.server.provider == .mediaShare else { return nil }
        return account.id
    }

    /// The media-share account keys within a set of accounts, in order.
    public func mediaShareAccountKeys(in accounts: [Account]) -> [String] {
        accounts
            .filter { $0.server.provider == .mediaShare }
            .map(\.id)
    }

    /// Tears down the transport sessions bound to a media-share account's
    /// credential revision. A no-op for non-media-share accounts. Used both on a
    /// real credential rotation (retire the previous revision) and on account
    /// removal.
    public func retireCredential(for account: Account) {
        guard account.server.provider == .mediaShare else { return }
        let runtime = self.runtime
        let accountID = account.id
        let credentialRevision = account.credentialRevision
        Task {
            await runtime.retire(
                accountID: accountID,
                credentialRevision: credentialRevision
            )
        }
    }

    /// Invalidates all cached catalog/scan/playback state for a removed
    /// media-share account key against the vending runtime generation.
    public func invalidate(shareAccountKey: String) {
        let runtime = self.runtime
        Task {
            await runtime.invalidate(accountKey: shareAccountKey)
        }
    }
}
