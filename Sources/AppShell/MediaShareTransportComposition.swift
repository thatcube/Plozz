import Foundation
import CoreModels
import FeatureAuth
import MediaTransportCore
import MediaTransportFTP
import MediaTransportHTTP
import MediaTransportSMB
import MediaTransportWebDAV
import MediaTransportSFTP
import MediaTransportNFS
import ProviderShare

/// Owns all media-share transport construction policy: adapter selection,
/// stored-credential-envelope mapping, session-key assembly, and the transport
/// resolver registry that backs the network-file resolver.
///
/// Extracted from `AppState` so the app-state object holds no
/// adapter/session-key/credential construction policy. The composition is an
/// immutable `Sendable` value: every stored member is `Sendable` and the
/// factories are pure functions of the account store, so it can be captured in
/// provider-registration and playback-resolution closures without hopping the
/// main actor.
struct MediaShareTransportComposition: Sendable {
    let accountStore: any AccountPersisting
    /// Adapters keyed by transport identifier (the endpoint's real scheme), so a
    /// session factory routes each account to the right transport the same way
    /// the playback resolver registry does.
    let adapters: [String: any MediaTransportAdapter]
    /// The playback/scanner resolver registry backing the network-file resolver.
    let resolverRegistry: MediaTransportResolverRegistry

    /// The single default construction path. Builds the adapter set once and
    /// shares it between the routed session factory and the resolver registry.
    static func make(
        accountStore: any AccountPersisting
    ) -> MediaShareTransportComposition {
        let adapterList = Self.makeMediaShareAdapters(accountStore: accountStore)
        let adapters = Dictionary(
            uniqueKeysWithValues: adapterList.map { ($0.transportIdentifier, $0) }
        )
        // Force-try is safe: the adapter identifiers (smb/http/https/…) are
        // distinct compile-time constants, so registration never collides.
        // swiftlint:disable:next force_try
        let registry = try! MediaTransportResolverRegistry(adapters: adapterList)
        return MediaShareTransportComposition(
            accountStore: accountStore,
            adapters: adapters,
            resolverRegistry: registry
        )
    }

    /// Builds the credential-free, adapter-routed share transport session
    /// factory for one media-share account/endpoint. Resolves the endpoint and
    /// adapter eagerly so a misrouted endpoint fails at registration time, not
    /// mid-scan.
    func makeSessionFactory(
        server: MediaServer,
        accountID: String,
        credentialRevision: CredentialRevision
    ) throws -> ShareTransportSessionFactory {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server)
        guard let adapter = adapters[endpoint.transportIdentifier] else {
            throw MediaTransportError.unsupportedCapability("media-share transport")
        }
        let accountStore = self.accountStore
        return { role in
            let key = try Self.mediaShareSessionKey(
                server: server,
                accountID: accountID,
                credentialRevision: credentialRevision,
                role: role,
                accountStore: accountStore
            )
            return try await adapter.connect(for: key)
        }
    }

    // MARK: - Session keys

    /// Builds the credential-free playback/scanner session key for a media
    /// share, transport-neutrally. The endpoint's `transportIdentifier` is the
    /// account's real scheme (so the registry routes to the right adapter), and
    /// the trust revision is read from the stored envelope so a TLS-pinned
    /// WebDAV endpoint's key matches the pinned trust policy the adapter builds
    /// (the HTTP session registry rejects a `.pinnedLeaf` policy whose revision
    /// disagrees with the key's). Any missing/invalid credential surfaces as a
    /// `MediaTransportError`.
    static func mediaShareSessionKey(
        for account: Account,
        role: MediaTransportRole,
        accountStore: any AccountPersisting
    ) throws -> MediaTransportSessionKey {
        try mediaShareSessionKey(
            server: account.server,
            accountID: account.id,
            credentialRevision: account.credentialRevision,
            role: role,
            accountStore: accountStore
        )
    }

    static func mediaShareSessionKey(
        server: MediaServer,
        accountID: String,
        credentialRevision: CredentialRevision,
        role: MediaTransportRole,
        accountStore: any AccountPersisting
    ) throws -> MediaTransportSessionKey {
        let endpoint = try MediaShareTransportDispatch.endpoint(for: server)
        let trustRevision: UUID
        do {
            let envelope = try accountStore.mediaShareCredential(
                for: accountID,
                revision: credentialRevision
            )
            // Unpinned envelopes carry the all-zero sentinel revision, matching
            // the SMB/system-trust case; a TLS pin carries a real revision.
            trustRevision = envelope.trust.revision
        } catch {
            throw MediaTransportError.authentication(reason: "media-share credential unavailable")
        }
        return MediaTransportSessionKey(
            accountID: accountID,
            credentialRevision: credentialRevision,
            endpoint: endpoint,
            trustRevision: trustRevision,
            role: role
        )
    }

    // MARK: - Adapters

    /// The set of media-share transport adapters, keyed by the scheme
    /// (`transportIdentifier`) their endpoints use.
    static func makeMediaShareAdapters(
        accountStore: any AccountPersisting
    ) -> [any MediaTransportAdapter] {
        [
            makeSMBAdapter(accountStore: accountStore),
            makeWebDAVAdapter(scheme: .http, accountStore: accountStore),
            makeWebDAVAdapter(scheme: .https, accountStore: accountStore),
            makeSFTPAdapter(accountStore: accountStore),
            makeNFSAdapter(),
            makeFTPAdapter(scheme: .ftp, accountStore: accountStore),
            makeFTPAdapter(scheme: .ftps, accountStore: accountStore),
        ]
    }

    /// The NFS adapter is credential-free (`AUTH_UNIX`, no password — the vault
    /// stores `.noCredentials`), so unlike SMB/WebDAV it needs no per-account
    /// credential provider.
    private static func makeNFSAdapter() -> NFSMediaTransportAdapter {
        NFSMediaTransportAdapter()
    }

    private static func makeSMBAdapter(
        accountStore: any AccountPersisting
    ) -> SMBMediaTransportAdapter {
        SMBMediaTransportAdapter { accountID, revision in
            let envelope = try accountStore.mediaShareCredential(
                for: accountID,
                revision: revision
            )
            guard envelope.transport == .smb else {
                throw MediaTransportError.unsupportedCapability("non-SMB credential")
            }
            let credential: SMBMediaTransportCredential
            switch envelope.authentication {
            case .anonymous:
                credential = .anonymous
            case let .password(username, password):
                credential = .password(username: username, password: password)
            case .bearer, .generatedKey, .noCredentials:
                throw MediaTransportError.unsupportedCapability("SMB authentication")
            }
            return SMBMediaTransportConfiguration(credential: credential)
        }
    }

    /// Builds a WebDAV adapter for one HTTP scheme (http/https). The resolver
    /// registry routes on the account's real scheme, so both are registered.
    private static func makeWebDAVAdapter(
        scheme: WebDAVScheme,
        accountStore: any AccountPersisting
    ) -> WebDAVMediaTransportAdapter {
        WebDAVMediaTransportAdapter(scheme: scheme) { accountID, revision in
            // Load the envelope inside the provider so a missing/incompatible
            // credential surfaces as a MediaTransportError (never a raw vault
            // error, which ShareTransportBrowser would treat as transient and
            // retry-loop on).
            let envelope: MediaShareCredentialEnvelope
            do {
                envelope = try accountStore.mediaShareCredential(for: accountID, revision: revision)
            } catch {
                throw MediaTransportError.authentication(reason: "WebDAV credential unavailable")
            }
            guard envelope.transport == .webDAV else {
                throw MediaTransportError.unsupportedCapability("non-WebDAV credential")
            }
            return try Self.webDAVConfiguration(from: envelope)
        }
    }

    /// Maps a stored credential envelope to the transport-layer WebDAV
    /// configuration (credential + TLS trust policy).
    static func webDAVConfiguration(
        from envelope: MediaShareCredentialEnvelope
    ) throws -> WebDAVMediaTransportConfiguration {
        let credential: WebDAVCredential
        switch envelope.authentication {
        case .anonymous:
            credential = .anonymous
        case let .password(username, password):
            credential = .password(username: username, password: password, policy: .automatic)
        case let .bearer(token):
            credential = .bearerToken(token)
        case .generatedKey, .noCredentials:
            throw MediaTransportError.unsupportedCapability("WebDAV authentication")
        }

        let trustPolicy: TrustPolicy
        if let pin = envelope.trust.tlsLeafCertificateSHA256 {
            trustPolicy = .pinnedLeaf(sha256: pin.bytes, revision: envelope.trust.revision)
        } else {
            trustPolicy = .system
        }
        return WebDAVMediaTransportConfiguration(credential: credential, trustPolicy: trustPolicy)
    }

    /// Builds the SFTP adapter. Loads the envelope inside the provider so a
    /// missing/incompatible credential surfaces as a `MediaTransportError` (never
    /// a raw vault error, which `ShareTransportBrowser` would retry-loop on), and
    /// maps the vault's mandatory `.sftp` host-key pin into the transport's
    /// trust policy.
    private static func makeSFTPAdapter(
        accountStore: any AccountPersisting
    ) -> SFTPMediaTransportAdapter {
        SFTPMediaTransportAdapter { accountID, revision in
            let envelope: MediaShareCredentialEnvelope
            do {
                envelope = try accountStore.mediaShareCredential(for: accountID, revision: revision)
            } catch {
                throw MediaTransportError.authentication(reason: "SFTP credential unavailable")
            }
            guard envelope.transport == .sftp else {
                throw MediaTransportError.unsupportedCapability("non-SFTP credential")
            }
            return try Self.sftpConfiguration(from: envelope)
        }
    }

    /// Maps a stored credential envelope to the transport-layer SFTP
    /// configuration (credential + SSH host-key pin). The vault guarantees every
    /// `.sftp` envelope carries a host-key SHA-256 pin, so its absence is a hard
    /// error rather than a silent fall-through to unpinned trust.
    static func sftpConfiguration(
        from envelope: MediaShareCredentialEnvelope
    ) throws -> SFTPMediaTransportConfiguration {
        let credential: SFTPMediaTransportCredential
        switch envelope.authentication {
        case let .password(username, password):
            credential = .password(username: username, password: password)
        case .generatedKey:
            // The generated private key is resolved from the vault by key id and
            // wired up by the credential/keygen ("Discovery UX") work; this
            // headless transport ships password auth. Fail closed until then.
            throw MediaTransportError.unsupportedCapability("SFTP key authentication")
        case .anonymous, .bearer, .noCredentials:
            throw MediaTransportError.unsupportedCapability("SFTP authentication")
        }

        guard let pin = envelope.trust.sshHostKeySHA256 else {
            throw MediaTransportError.trust(reason: "SFTP host key pin missing")
        }
        return SFTPMediaTransportConfiguration(
            credential: credential,
            hostKeyPolicy: .pinned(sha256: Array(pin.bytes))
        )
    }

    /// Builds an FTP adapter for one scheme (`ftp` plaintext / `ftps` implicit
    /// TLS). The resolver registry routes on the account's real scheme, so both
    /// are registered — mirroring the WebDAV http/https pair.
    private static func makeFTPAdapter(
        scheme: FTPScheme,
        accountStore: any AccountPersisting
    ) -> FTPMediaTransportAdapter {
        FTPMediaTransportAdapter(scheme: scheme) { accountID, revision in
            // Load the envelope inside the provider so a missing/incompatible
            // credential surfaces as a MediaTransportError (never a raw vault
            // error, which ShareTransportBrowser would treat as transient and
            // retry-loop on).
            let envelope: MediaShareCredentialEnvelope
            do {
                envelope = try accountStore.mediaShareCredential(for: accountID, revision: revision)
            } catch {
                throw MediaTransportError.authentication(reason: "FTP credential unavailable")
            }
            guard envelope.transport == .ftp else {
                throw MediaTransportError.unsupportedCapability("non-FTP credential")
            }
            return try Self.ftpConfiguration(from: envelope, scheme: scheme)
        }
    }

    /// Maps a stored credential envelope to the transport-layer FTP
    /// configuration. Security is derived from the scheme: `ftps` → implicit
    /// TLS, `ftp` → plaintext. (Explicit `AUTH TLS` has no distinct scheme and
    /// is unsupported on tvOS, so it is never produced here.)
    static func ftpConfiguration(
        from envelope: MediaShareCredentialEnvelope,
        scheme: FTPScheme
    ) throws -> FTPMediaTransportConfiguration {
        let credential: FTPCredential
        switch envelope.authentication {
        case .anonymous:
            credential = .anonymous
        case let .password(username, password):
            credential = .password(username: username, password: password)
        case .bearer, .generatedKey, .noCredentials:
            throw MediaTransportError.unsupportedCapability("FTP authentication")
        }

        let security: FTPSecurity = scheme == .ftps ? .implicitTLS : .plaintext
        let trustPolicy: FTPTrustPolicy
        if let pin = envelope.trust.tlsLeafCertificateSHA256 {
            trustPolicy = .pinnedLeaf(sha256: Array(pin.bytes), revision: envelope.trust.revision)
        } else {
            trustPolicy = .system
        }
        return FTPMediaTransportConfiguration(
            credential: credential,
            security: security,
            trustPolicy: trustPolicy
        )
    }
}
