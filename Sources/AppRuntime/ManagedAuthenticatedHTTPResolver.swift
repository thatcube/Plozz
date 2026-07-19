import CoreModels
import Foundation
import MediaTransportCore

/// Resolves secret-free managed-provider playback locators against the active
/// account identity and app-held credential.
@MainActor
public final class ManagedAuthenticatedHTTPResolver: AuthenticatedHTTPResourceResolving {
    public struct Context: Sendable {
        public let provider: ProviderKind
        public let accountID: String
        public let credentialRevision: CredentialRevision
        public let baseURL: URL
        public let token: String

        public init(
            provider: ProviderKind,
            accountID: String,
            credentialRevision: CredentialRevision,
            baseURL: URL,
            token: String
        ) {
            self.provider = provider
            self.accountID = accountID
            self.credentialRevision = credentialRevision
            self.baseURL = baseURL
            self.token = token
        }
    }

    public typealias ContextProvider = @MainActor @Sendable (
        AuthenticatedHTTPPlaybackLocator
    ) throws -> Context

    private var contextProvider: ContextProvider?

    public init() {}

    public func configure(contextProvider: @escaping ContextProvider) {
        self.contextProvider = contextProvider
    }

    public func resolve(_ locator: AuthenticatedHTTPPlaybackLocator) async throws -> URL {
        guard let contextProvider else {
            throw MediaTransportError.unsupportedCapability(
                "authenticated HTTP resolver"
            )
        }
        let context = try contextProvider(locator)
        guard context.provider == locator.provider,
              context.accountID == locator.accountID,
              context.credentialRevision == locator.credentialRevision,
              var components = URLComponents(
                  url: context.baseURL,
                  resolvingAgainstBaseURL: false
              ) else {
            throw MediaTransportError.authentication(
                reason: "authenticated HTTP identity mismatch"
            )
        }

        let encodedPath = locator.resource.path
        switch locator.resource.pathBase {
        case .configuredBaseURL:
            let basePath = components.percentEncodedPath.hasSuffix("/")
                ? String(components.percentEncodedPath.dropLast())
                : components.percentEncodedPath
            components.percentEncodedPath = basePath + "/" + encodedPath
        case .serverRoot:
            components.percentEncodedPath = encodedPath
        }

        var queryItems = locator.resource.queryItems.map {
            URLQueryItem(name: $0.name, value: $0.value)
        }
        switch locator.provider {
        case .jellyfin, .emby:
            queryItems.append(URLQueryItem(name: "api_key", value: context.token))
            if let playSessionID = locator.playSessionID {
                queryItems.append(
                    URLQueryItem(name: "playSessionId", value: playSessionID)
                )
            }
        case .plex:
            queryItems.append(URLQueryItem(name: "X-Plex-Token", value: context.token))
            if let playSessionID = locator.playSessionID {
                queryItems.append(URLQueryItem(name: "session", value: playSessionID))
                queryItems.append(
                    URLQueryItem(
                        name: "X-Plex-Session-Identifier",
                        value: playSessionID
                    )
                )
            }
        case .mediaShare:
            throw MediaTransportError.invalidInput(
                reason: "media shares cannot resolve authenticated HTTP resources"
            )
        }
        components.queryItems = queryItems
        guard let url = components.url else {
            throw MediaTransportError.invalidInput(
                reason: "invalid authenticated HTTP resource"
            )
        }
        return url
    }
}
