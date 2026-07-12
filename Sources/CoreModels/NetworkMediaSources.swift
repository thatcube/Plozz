import Foundation

public enum MediaSourceModelError: Error, Equatable, Sendable {
    case emptyIdentifier(field: String)
    case invalidHost
    case invalidPort
    case invalidRootPath
    case invalidRelativePath
    case invalidFileSize
    case invalidRepresentationIdentity
    case transportOptionsMismatch
    case unsupportedProvider(ProviderKind)
    case unsupportedScheme
    case invalidOrigin
    case missingHost
    case credentialBearingURL
    case sensitiveQueryItem(name: String)
    case urlFragmentNotAllowed
}

public enum MediaShareTransportKind: String, CaseIterable, Hashable, Sendable {
    case smb
    case webDAV
    case nfs
    case sftp
}

public struct SMBTransportOptions: Hashable, Sendable {
    public enum MinimumDialect: String, Hashable, Sendable {
        case smb2
        case smb3
    }

    public let minimumDialect: MinimumDialect
    public let requiresSigning: Bool
    public let requiresEncryption: Bool

    public init(
        minimumDialect: MinimumDialect = .smb2,
        requiresSigning: Bool = false,
        requiresEncryption: Bool = false
    ) {
        self.minimumDialect = minimumDialect
        self.requiresSigning = requiresSigning
        self.requiresEncryption = requiresEncryption
    }
}

public struct WebDAVTransportOptions: Hashable, Sendable {
    public enum Security: String, Hashable, Sendable {
        case https
        case anonymousHTTP
    }

    public let security: Security

    public init(security: Security = .https) {
        self.security = security
    }
}

public struct NFSTransportOptions: Hashable, Sendable {
    public enum PreferredVersion: String, Hashable, Sendable {
        case automatic
        case v3
        case v4
    }

    public let preferredVersion: PreferredVersion

    public init(preferredVersion: PreferredVersion = .automatic) {
        self.preferredVersion = preferredVersion
    }
}

public struct SFTPTransportOptions: Hashable, Sendable {
    public enum AuthenticationMethod: String, Hashable, Sendable {
        case password
        case generatedKey
    }

    public let authenticationMethod: AuthenticationMethod

    public init(authenticationMethod: AuthenticationMethod = .password) {
        self.authenticationMethod = authenticationMethod
    }
}

/// Typed, non-secret connection policy for a media-share endpoint.
public enum MediaShareTransportOptions: Hashable, Sendable {
    case smb(SMBTransportOptions)
    case webDAV(WebDAVTransportOptions)
    case nfs(NFSTransportOptions)
    case sftp(SFTPTransportOptions)

    public var transportKind: MediaShareTransportKind {
        switch self {
        case .smb: return .smb
        case .webDAV: return .webDAV
        case .nfs: return .nfs
        case .sftp: return .sftp
        }
    }
}

/// Normalized, credential-free address and root for one filesystem source.
///
/// Host, port, and root are separate fields so credentials cannot be smuggled
/// through URL userinfo or query items.
public struct MediaShareEndpoint: Hashable, Sendable {
    public let transport: MediaShareTransportKind
    public let host: String
    public let port: Int?
    public let rootPath: String
    public let options: MediaShareTransportOptions

    public init(
        transport: MediaShareTransportKind,
        host: String,
        port: Int? = nil,
        rootPath: String = "/",
        options: MediaShareTransportOptions
    ) throws {
        guard transport == options.transportKind else {
            throw MediaSourceModelError.transportOptionsMismatch
        }
        self.transport = transport
        self.host = try Self.normalizedHost(host)
        if let port {
            guard (1...65_535).contains(port) else {
                throw MediaSourceModelError.invalidPort
            }
        }
        self.port = port
        self.rootPath = try MediaPathPolicy.normalizedRoot(rootPath)
        self.options = options
    }

    private static func normalizedHost(_ value: String) throws -> String {
        var host = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasPrefix("["), host.hasSuffix("]") {
            host.removeFirst()
            host.removeLast()
        }
        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains("@"),
              !host.contains("/"),
              !host.contains("\\"),
              !host.contains("?"),
              !host.contains("#") else {
            throw MediaSourceModelError.invalidHost
        }
        return host.lowercased()
    }
}

public enum RepresentationConsistency: String, Hashable, Sendable {
    case stronglyBound
    case changeDetecting
}

public enum RemoteFileIdentityKind: String, Hashable, Sendable {
    case strongETag
    case fileIdentifier
    case modificationTime
    case snapshot
}

/// Strongest transport-provided identity captured for one remote file.
public struct RemoteFileIdentity: Hashable, Sendable {
    public let kind: RemoteFileIdentityKind
    public let value: String?
    public let modifiedAt: Date?

    public init(
        kind: RemoteFileIdentityKind,
        value: String? = nil,
        modifiedAt: Date? = nil
    ) throws {
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind {
        case .strongETag:
            guard let trimmed,
                  trimmed.hasPrefix("\""),
                  trimmed.hasSuffix("\""),
                  !trimmed.lowercased().hasPrefix("w/") else {
                throw MediaSourceModelError.invalidRepresentationIdentity
            }
        case .fileIdentifier, .snapshot:
            guard let trimmed, !trimmed.isEmpty else {
                throw MediaSourceModelError.invalidRepresentationIdentity
            }
        case .modificationTime:
            guard modifiedAt != nil else {
                throw MediaSourceModelError.invalidRepresentationIdentity
            }
        }
        self.kind = kind
        self.value = trimmed
        self.modifiedAt = modifiedAt
    }
}

public struct RemoteFileRepresentation: Hashable, Sendable {
    public let size: Int64
    public let identity: RemoteFileIdentity
    public let consistency: RepresentationConsistency

    public init(
        size: Int64,
        identity: RemoteFileIdentity,
        consistency: RepresentationConsistency
    ) throws {
        guard size >= 0 else {
            throw MediaSourceModelError.invalidFileSize
        }
        self.size = size
        self.identity = identity
        self.consistency = consistency
    }
}

public struct MediaFormatHint: Hashable, Sendable {
    public let container: String?
    public let mimeType: String?

    public init(container: String? = nil, mimeType: String? = nil) {
        self.container = Self.normalized(container, removingLeadingDot: true)
        self.mimeType = Self.normalized(mimeType, removingLeadingDot: false)
    }

    private static func normalized(
        _ value: String?,
        removingLeadingDot: Bool
    ) -> String? {
        var result = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if removingLeadingDot, result?.hasPrefix(".") == true {
            result?.removeFirst()
        }
        return result?.isEmpty == false ? result : nil
    }
}

/// Credential-free identity for a file that a transport resolver can open.
public struct NetworkFileLocator: Hashable, Sendable {
    public let accountID: String
    public let sourceID: String
    public let credentialRevision: CredentialRevision
    public let relativePath: String
    public let representation: RemoteFileRepresentation
    public let formatHint: MediaFormatHint

    public init(
        accountID: String,
        sourceID: String,
        credentialRevision: CredentialRevision,
        relativePath: String,
        representation: RemoteFileRepresentation,
        formatHint: MediaFormatHint = MediaFormatHint()
    ) throws {
        self.accountID = try ModelIdentifier.validated(accountID, field: "accountID")
        self.sourceID = try ModelIdentifier.validated(sourceID, field: "sourceID")
        self.credentialRevision = credentialRevision
        self.relativePath = try MediaPathPolicy.normalizedRelative(relativePath)
        self.representation = representation
        self.formatHint = formatHint
    }
}

public enum AuthenticatedHTTPDeliveryMode: String, Hashable, Sendable {
    case directFile
    case hls
    case dash
    case serverRemux
    case serverTranscode

    public var isManifest: Bool {
        switch self {
        case .hls, .dash, .serverRemux, .serverTranscode: return true
        case .directFile: return false
        }
    }
}

/// Credential-free instructions for resolving a managed provider's stream.
public struct AuthenticatedHTTPPlaybackLocator: Hashable, Sendable {
    public let provider: ProviderKind
    public let accountID: String
    public let credentialRevision: CredentialRevision
    public let itemID: String
    public let mediaSourceID: String?
    public let deliveryMode: AuthenticatedHTTPDeliveryMode
    public let formatHint: MediaFormatHint

    public init(
        provider: ProviderKind,
        accountID: String,
        credentialRevision: CredentialRevision,
        itemID: String,
        mediaSourceID: String? = nil,
        deliveryMode: AuthenticatedHTTPDeliveryMode,
        formatHint: MediaFormatHint = MediaFormatHint()
    ) throws {
        guard provider != .mediaShare else {
            throw MediaSourceModelError.unsupportedProvider(provider)
        }
        self.provider = provider
        self.accountID = try ModelIdentifier.validated(accountID, field: "accountID")
        self.credentialRevision = credentialRevision
        self.itemID = try ModelIdentifier.validated(itemID, field: "itemID")
        self.mediaSourceID = try mediaSourceID.map {
            try ModelIdentifier.validated($0, field: "mediaSourceID")
        }
        self.deliveryMode = deliveryMode
        self.formatHint = formatHint
    }
}

/// Scheme, host, and effective port accepted for one DLNA resource.
public struct NetworkOrigin: Hashable, Sendable {
    public let scheme: String
    public let host: String
    public let port: Int

    public init(scheme: String, host: String, port: Int? = nil) throws {
        let normalizedScheme = scheme.lowercased()
        guard normalizedScheme == "http" || normalizedScheme == "https" else {
            throw MediaSourceModelError.unsupportedScheme
        }
        self.scheme = normalizedScheme
        self.host = try MediaShareEndpoint(
            transport: .webDAV,
            host: host,
            port: port,
            options: .webDAV(
                WebDAVTransportOptions(
                    security: normalizedScheme == "https" ? .https : .anonymousHTTP
                )
            )
        ).host
        self.port = try Self.effectivePort(scheme: normalizedScheme, port: port)
    }

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            throw MediaSourceModelError.unsupportedScheme
        }
        guard components.user == nil, components.password == nil else {
            throw MediaSourceModelError.credentialBearingURL
        }
        guard components.path.isEmpty || components.path == "/" else {
            throw MediaSourceModelError.invalidOrigin
        }
        guard components.query == nil, components.fragment == nil else {
            throw MediaSourceModelError.credentialBearingURL
        }
        guard let scheme = components.scheme else {
            throw MediaSourceModelError.unsupportedScheme
        }
        guard let host = components.host else {
            throw MediaSourceModelError.missingHost
        }
        try self.init(scheme: scheme, host: host, port: components.port)
    }

    private static func effectivePort(scheme: String, port: Int?) throws -> Int {
        if let port {
            guard (1...65_535).contains(port) else {
                throw MediaSourceModelError.invalidPort
            }
            return port
        }
        return scheme == "https" ? 443 : 80
    }
}

public struct AuthorityGrantRevision: Hashable, Sendable {
    public let rawValue: UUID

    public init(rawValue: UUID = UUID()) {
        self.rawValue = rawValue
    }
}

public enum DLNAResourceDeliveryMode: String, Hashable, Sendable {
    case byteRange
    case timeSeek
    case hls
    case linear

    public var isManifest: Bool { self == .hls }
    public var isSeekable: Bool { self != .linear }
}

public struct DLNAHeaderPolicy: Hashable, Sendable {
    public enum TransferMode: String, Hashable, Sendable {
        case streaming
        case interactive
        case background
    }

    public let transferMode: TransferMode
    public let requestsContentFeatures: Bool
    public let requestsRealtimeInfo: Bool

    public init(
        transferMode: TransferMode = .streaming,
        requestsContentFeatures: Bool = true,
        requestsRealtimeInfo: Bool = false
    ) {
        self.transferMode = transferMode
        self.requestsContentFeatures = requestsContentFeatures
        self.requestsRealtimeInfo = requestsRealtimeInfo
    }
}

public struct DLNAResourceLocator: Hashable, Sendable {
    public let sourceID: String
    public let deviceUDN: String
    public let objectID: String
    public let resourceID: String
    public let acceptedOrigin: NetworkOrigin
    public let authorityGrantRevision: AuthorityGrantRevision
    public let deliveryMode: DLNAResourceDeliveryMode
    public let headerPolicy: DLNAHeaderPolicy
    public let formatHint: MediaFormatHint

    public init(
        sourceID: String,
        deviceUDN: String,
        objectID: String,
        resourceID: String,
        acceptedOrigin: NetworkOrigin,
        authorityGrantRevision: AuthorityGrantRevision,
        deliveryMode: DLNAResourceDeliveryMode,
        headerPolicy: DLNAHeaderPolicy = DLNAHeaderPolicy(),
        formatHint: MediaFormatHint = MediaFormatHint()
    ) throws {
        self.sourceID = try ModelIdentifier.validated(sourceID, field: "sourceID")
        self.deviceUDN = try ModelIdentifier.validated(deviceUDN, field: "deviceUDN")
        self.objectID = try ModelIdentifier.validated(objectID, field: "objectID")
        self.resourceID = try ModelIdentifier.validated(resourceID, field: "resourceID")
        self.acceptedOrigin = acceptedOrigin
        self.authorityGrantRevision = authorityGrantRevision
        self.deliveryMode = deliveryMode
        self.headerPolicy = headerPolicy
        self.formatHint = formatHint
    }
}

/// A validated public URL that cannot carry credentials or signed access.
public struct SecretFreeURLSource: Hashable, Sendable {
    public let url: URL

    public init(url: URL) throws {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else {
            throw MediaSourceModelError.unsupportedScheme
        }
        guard components.host?.isEmpty == false else {
            throw MediaSourceModelError.missingHost
        }
        _ = try NetworkOrigin(
            scheme: scheme,
            host: components.host ?? "",
            port: components.port
        )
        guard components.user == nil, components.password == nil else {
            throw MediaSourceModelError.credentialBearingURL
        }
        guard components.fragment == nil else {
            throw MediaSourceModelError.urlFragmentNotAllowed
        }
        for item in components.queryItems ?? [] where SensitiveQueryPolicy.isSensitive(item.name) {
            throw MediaSourceModelError.sensitiveQueryItem(name: item.name)
        }
        self.url = url
    }
}

extension SecretFreeURLSource: CustomStringConvertible {
    public var description: String {
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        else {
            return "PublicURL(<invalid>)"
        }
        let port = components.port.map { ":\($0)" } ?? ""
        return "PublicURL(\(components.scheme ?? "")://\(components.host ?? "")\(port)\(components.path))"
    }
}

public enum PlaybackSource: Hashable, Sendable {
    case publicURL(SecretFreeURLSource)
    case authenticatedHTTP(AuthenticatedHTTPPlaybackLocator)
    case networkFile(NetworkFileLocator)
    case dlnaResource(DLNAResourceLocator)

    public var isManifestStream: Bool {
        switch self {
        case .publicURL(let source):
            let extensionName = source.url.pathExtension.lowercased()
            return extensionName == "m3u8" || extensionName == "mpd"
        case .authenticatedHTTP(let locator):
            return locator.deliveryMode.isManifest
        case .networkFile:
            return false
        case .dlnaResource(let locator):
            return locator.deliveryMode.isManifest
        }
    }

    public var publicURL: URL? {
        guard case .publicURL(let source) = self else { return nil }
        return source.url
    }

    public var redactedLabel: String {
        switch self {
        case .publicURL(let source):
            return source.description
        case .authenticatedHTTP(let locator):
            return "AuthenticatedHTTP(provider: \(locator.provider.rawValue), account: \(locator.accountID), item: \(locator.itemID))"
        case .networkFile(let locator):
            return "NetworkFile(account: \(locator.accountID), source: \(locator.sourceID), format: \(locator.formatHint.container ?? "unknown"))"
        case .dlnaResource(let locator):
            return "DLNA(source: \(locator.sourceID), object: \(locator.objectID), resource: \(locator.resourceID))"
        }
    }
}

private enum ModelIdentifier {
    static func validated(_ value: String, field: String) throws -> String {
        let result = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !result.isEmpty else {
            throw MediaSourceModelError.emptyIdentifier(field: field)
        }
        return result
    }
}

private enum MediaPathPolicy {
    static func normalizedRoot(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let candidate = trimmed.isEmpty ? "/" : trimmed
        guard candidate.hasPrefix("/"), !candidate.contains("\\") else {
            throw MediaSourceModelError.invalidRootPath
        }
        let components = try validatedComponents(
            candidate.split(separator: "/", omittingEmptySubsequences: true),
            error: .invalidRootPath
        )
        return components.isEmpty ? "/" : "/" + components.joined(separator: "/")
    }

    static func normalizedRelative(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("/"),
              !trimmed.contains("\\"),
              !trimmed.contains("?"),
              !trimmed.contains("#") else {
            throw MediaSourceModelError.invalidRelativePath
        }
        let components = try validatedComponents(
            trimmed.split(separator: "/", omittingEmptySubsequences: true),
            error: .invalidRelativePath
        )
        guard !components.isEmpty else {
            throw MediaSourceModelError.invalidRelativePath
        }
        return components.joined(separator: "/")
    }

    private static func validatedComponents(
        _ components: [Substring],
        error: MediaSourceModelError
    ) throws -> [String] {
        try components.map { component in
            let raw = String(component)
            guard let decoded = raw.removingPercentEncoding,
                  decoded != ".",
                  decoded != "..",
                  !decoded.contains("/"),
                  !decoded.contains("\\"),
                  !decoded.contains("\0") else {
                throw error
            }
            return raw
        }
    }
}

private enum SensitiveQueryPolicy {
    private static let exactNames: Set<String> = [
        "access_token",
        "apikey",
        "api_key",
        "api-key",
        "auth",
        "authorization",
        "awsaccesskeyid",
        "credential",
        "expire",
        "expires",
        "jwt",
        "key",
        "key-pair-id",
        "password",
        "passwd",
        "policy",
        "secret",
        "session",
        "session_id",
        "sessionid",
        "sig",
        "signature",
        "ticket",
        "token",
        "x-plex-token"
    ]

    static func isSensitive(_ name: String) -> Bool {
        let normalized = name.lowercased()
        return exactNames.contains(normalized)
            || normalized.contains("token")
            || normalized.contains("signature")
            || normalized.hasPrefix("x-amz-")
            || normalized.hasPrefix("x-goog-")
    }
}
