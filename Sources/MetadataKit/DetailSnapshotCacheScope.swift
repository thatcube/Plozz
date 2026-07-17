import Foundation
import CryptoKit

/// An immutable, non-secret identity for one complete "active content identity" —
/// the profile plus the exact set of accounts (and their effective credentials /
/// Plex Home-user identity) whose sources and watch state feed the detail pages.
///
/// `DetailSnapshotCache` snapshots are scoped by this value so a snapshot written
/// under one identity can never paint under another: switching profile, switching
/// Plex Home user, enabling/disabling an account, rotating an account's
/// credentials, or removing and re-adding an account all produce a *different*
/// scope and therefore a different on-disk cache directory.
///
/// The `directoryComponent` is a SHA-256 digest of the (already order-normalized)
/// non-secret identity material, so it is a stable, bounded, filesystem-safe path
/// segment that contains no token, PIN, server address, share path, username, or
/// display name — only a one-way hash of profile/account IDs and non-secret
/// credential revisions.
public struct DetailSnapshotCacheScope: Equatable, Sendable {
    /// The active profile identity. Retained alongside the digest for observability
    /// and testing; it is also folded into the digest so two profiles never collide.
    public let profileID: String

    /// A hex SHA-256 digest of `profileID` + the identity material. Doubles as the
    /// scoped cache subdirectory name.
    public let digest: String

    /// The on-disk subdirectory (under `plozz-detail-cache-v3`) for this identity.
    public var directoryComponent: String { digest }

    /// Builds a scope from a profile identity and a caller-composed, non-secret
    /// identity material string (e.g. the app's existing sorted account/credential
    /// scope key). The material MUST already be order-normalized by the caller so
    /// order-only changes do not churn the cache; this initializer only hashes.
    public init(profileID: String, identityMaterial: String) {
        self.profileID = profileID
        var hasher = SHA256()
        hasher.update(data: Data(profileID.utf8))
        hasher.update(data: Data([0x1f]))
        hasher.update(data: Data(identityMaterial.utf8))
        self.digest = hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
