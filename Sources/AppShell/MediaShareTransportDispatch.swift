import CoreModels
import Foundation
import MediaTransportCore

/// Transport-neutral routing for media-share accounts.
///
/// The account's real `baseURL` scheme is the single discriminator — `smb://`
/// routes to the SMB adapter, `http`/`https` to the WebDAV adapter (registered
/// under both), and later `sftp`/`nfs` to theirs. This builds the credential-
/// free endpoint identity that BOTH the scanner session factory and the
/// playback resolver need, replacing the previously duplicated
/// `baseURL.scheme == "smb"` checks. Adding a transport is: register its
/// adapter under its scheme + teach onboarding to persist that scheme — no
/// change here.
enum MediaShareTransportDispatch {
    /// The sentinel trust revision for an endpoint with no pinned TLS leaf
    /// (SMB, or WebDAV over system trust). Matches the vault's unpinned
    /// `MediaShareTrustMaterial.revision`.
    static let unpinnedTrustRevision = UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))

    /// Builds the credential-free `MediaTransportEndpointIdentity` for a media
    /// share from its persisted `MediaServer`. The `transportIdentifier` is the
    /// URL scheme, which is exactly what the resolver registry routes on and
    /// what each adapter registers under.
    static func endpoint(for server: MediaServer) throws -> MediaTransportEndpointIdentity {
        guard let scheme = server.baseURL.scheme?.lowercased(),
              let host = server.baseURL.host, !host.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "invalid media-share endpoint")
        }
        let path = server.baseURL.path
        return try MediaTransportEndpointIdentity(
            transportIdentifier: scheme,
            host: host,
            port: server.baseURL.port,
            rootPath: path.isEmpty ? "/" : path
        )
    }
}
