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
    ///
    /// Path encoding is transport-specific: HTTP-family transports (WebDAV)
    /// address resources by the **percent-encoded** URL path — using the
    /// decoded `URL.path` would double-decode a folder whose name literally
    /// contains a `%XX` sequence and would drop a trailing slash the WebDAV
    /// module relies on. Filesystem transports (SMB) use **literal, decoded**
    /// share/path names, so they keep `URL.path`.
    static func endpoint(for server: MediaServer) throws -> MediaTransportEndpointIdentity {
        guard let components = URLComponents(url: server.baseURL, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              let host = components.host, !host.isEmpty else {
            throw MediaTransportError.invalidInput(reason: "invalid media-share endpoint")
        }
        let rawPath: String
        switch scheme {
        case "http", "https":
            rawPath = components.percentEncodedPath
        default:
            rawPath = components.path
        }
        return try MediaTransportEndpointIdentity(
            transportIdentifier: scheme,
            host: host,
            port: components.port,
            rootPath: rawPath.isEmpty ? "/" : rawPath
        )
    }
}
