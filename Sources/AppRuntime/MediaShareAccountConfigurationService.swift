import CoreModels
import FeatureAuthCore
import Foundation
import ProviderShare

public enum MediaShareAccountConfigurationError: LocalizedError, Equatable {
    case invalidAddress
    case invalidShare

    public var errorDescription: String? {
        switch self {
        case .invalidAddress:
            "Invalid network-share address."
        case .invalidShare:
            "Invalid network-share configuration."
        }
    }
}

public enum MediaShareWebDAVAuth: Equatable, Sendable {
    case anonymous
    case password(username: String, password: String)
    case bearer(token: String)

    var principal: String {
        switch self {
        case .anonymous: "anon"
        case let .password(username, _):
            username.trimmingCharacters(in: .whitespaces).isEmpty
                ? "anon"
                : username.trimmingCharacters(in: .whitespaces)
        case .bearer: "bearer"
        }
    }

    var accountUserName: String {
        switch self {
        case .anonymous, .bearer: ""
        case let .password(username, _):
            username.trimmingCharacters(in: .whitespaces)
        }
    }
}

public struct PreparedMediaShareAccount: Sendable {
    public let session: UserSession
    public let account: Account
    public let previousAccount: Account?
    public let credential: MediaShareCredentialEnvelope

    init(
        session: UserSession,
        account: Account,
        previousAccount: Account?,
        credential: MediaShareCredentialEnvelope
    ) {
        self.session = session
        self.account = account
        self.previousAccount = previousAccount
        self.credential = credential
    }
}

public struct MediaShareAccountConfigurationService: Sendable {
    private let accountStore: any AccountPersisting

    public init(accountStore: any AccountPersisting) {
        self.accountStore = accountStore
    }

    public func prepareSMB(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedShare = share.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedShare.isEmpty else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        var components = URLComponents()
        components.scheme = "smb"
        components.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        components.port = port
        components.path = "/" + trimmedShare
        guard let baseURL = components.url else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let authentication: MediaShareAuthentication =
            trimmedUsername.isEmpty && password.isEmpty
                ? .anonymous
                : .password(username: trimmedUsername, password: password)
        let credential = try MediaShareCredentialEnvelope(
            transport: .smb,
            authentication: authentication
        )
        let serverID = Self.smbID(
            host: trimmedHost,
            port: port,
            share: trimmedShare,
            username: trimmedUsername
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(
                    path: trimmedShare,
                    host: trimmedHost,
                    transport: .smb
                )
                : trimmedName,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let session = UserSession(
            server: server,
            userID: trimmedUsername.isEmpty ? "guest" : trimmedUsername,
            userName: trimmedUsername,
            deviceID: accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        return PreparedMediaShareAccount(
            session: session,
            account: account,
            previousAccount: accountStore.loadAccounts().first { $0.id == account.id },
            credential: credential
        )
    }

    public func saveSMB(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareSMB(
            host: host,
            port: port,
            share: share,
            username: username,
            password: password,
            displayName: displayName
        )
        try persist(prepared)
        return prepared
    }

    public func prepareWebDAV(
        baseURL: URL,
        auth: MediaShareWebDAVAuth,
        trustPin: SHA256Fingerprint?,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        guard let components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        let host = components.host,
        !host.isEmpty,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        trustPin == nil || scheme == "https" else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let authentication: MediaShareAuthentication
        switch auth {
        case .anonymous:
            authentication = .anonymous
        case let .password(username, password):
            authentication = .password(
                username: username.trimmingCharacters(in: .whitespaces),
                password: password
            )
        case let .bearer(token):
            authentication = .bearer(token: token)
        }
        let credential = try MediaShareCredentialEnvelope(
            transport: .webDAV,
            authentication: authentication,
            trust: MediaShareTrustMaterial(tlsLeafCertificateSHA256: trustPin)
        )
        let path = components.percentEncodedPath.isEmpty
            ? "/"
            : components.percentEncodedPath
        let serverID = Self.webDAVID(
            scheme: scheme,
            host: host,
            port: components.port,
            path: path,
            principal: auth.principal
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(path: path, host: host, transport: .webDAV)
                : trimmedName,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let session = UserSession(
            server: server,
            userID: auth.principal,
            userName: auth.accountUserName,
            deviceID: accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        return PreparedMediaShareAccount(
            session: session,
            account: account,
            previousAccount: accountStore.loadAccounts().first { $0.id == account.id },
            credential: credential
        )
    }

    public func saveWebDAV(
        baseURL: URL,
        auth: MediaShareWebDAVAuth,
        trustPin: SHA256Fingerprint?,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareWebDAV(
            baseURL: baseURL,
            auth: auth,
            trustPin: trustPin,
            displayName: displayName
        )
        try persist(prepared)
        return prepared
    }

    public func prepareSFTP(
        host: String,
        port: Int?,
        path: String,
        username: String,
        password: String,
        hostKeyPin: SHA256Fingerprint,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUser = username.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty, !trimmedUser.isEmpty else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let normalizedPath = Self.normalizedFilesystemPath(path)
        var components = URLComponents()
        components.scheme = "sftp"
        components.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        components.port = port
        components.path = normalizedPath
        guard let baseURL = components.url else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let credential: MediaShareCredentialEnvelope
        do {
            credential = try MediaShareCredentialEnvelope(
                transport: .sftp,
                authentication: .password(
                    username: trimmedUser,
                    password: password
                ),
                trust: MediaShareTrustMaterial(
                    sshHostKeySHA256: hostKeyPin
                )
            )
        } catch {
            throw MediaShareAccountConfigurationError.invalidShare
        }

        let serverID = Self.filesystemID(
            scheme: "sftp",
            host: trimmedHost,
            port: port,
            path: normalizedPath,
            principal: trimmedUser
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(
                    path: normalizedPath,
                    host: trimmedHost,
                    transport: .sftp
                )
                : trimmedName,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let session = UserSession(
            server: server,
            userID: trimmedUser,
            userName: trimmedUser,
            deviceID: accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        return PreparedMediaShareAccount(
            session: session,
            account: account,
            previousAccount: accountStore.loadAccounts().first { $0.id == account.id },
            credential: credential
        )
    }

    public func saveSFTP(
        host: String,
        port: Int?,
        path: String,
        username: String,
        password: String,
        hostKeyPin: SHA256Fingerprint,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareSFTP(
            host: host,
            port: port,
            path: path,
            username: username,
            password: password,
            hostKeyPin: hostKeyPin,
            displayName: displayName
        )
        try persist(prepared)
        return prepared
    }

    public func prepareNFS(
        host: String,
        port: Int?,
        exportPath: String,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let normalizedPath = Self.normalizedFilesystemPath(exportPath)
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        components.port = port
        components.path = normalizedPath
        guard let baseURL = components.url else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let credential: MediaShareCredentialEnvelope
        do {
            credential = try MediaShareCredentialEnvelope(
                transport: .nfs,
                authentication: .noCredentials
            )
        } catch {
            throw MediaShareAccountConfigurationError.invalidShare
        }

        let serverID = Self.filesystemID(
            scheme: "nfs",
            host: trimmedHost,
            port: port,
            path: normalizedPath,
            principal: "anon"
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(
                    path: normalizedPath,
                    host: trimmedHost,
                    transport: .nfs
                )
                : trimmedName,
            baseURL: baseURL,
            provider: .mediaShare
        )
        let session = UserSession(
            server: server,
            userID: "anon",
            userName: "",
            deviceID: accountStore.deviceID(),
            accessToken: ""
        )
        let account = Account(id: server.id, from: session)
        return PreparedMediaShareAccount(
            session: session,
            account: account,
            previousAccount: accountStore.loadAccounts().first { $0.id == account.id },
            credential: credential
        )
    }

    public func persist(_ prepared: PreparedMediaShareAccount) throws {
        try accountStore.addMediaShare(
            prepared.account,
            credential: prepared.credential,
            generatedPrivateKey: nil
        )
    }

    public func saveNFS(
        host: String,
        port: Int?,
        exportPath: String,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareNFS(
            host: host,
            port: port,
            exportPath: exportPath,
            displayName: displayName
        )
        try persist(prepared)
        return prepared
    }

    public static func filesystemID(
        scheme: String,
        host: String,
        port: Int?,
        path: String,
        principal: String
    ) -> String {
        let normalizedScheme = scheme.lowercased()
        let portKey = port.map { ":\($0)" } ?? ""
        var normalizedPath = path.isEmpty ? "/" : path
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }

        return "share:\(normalizedScheme)://\(host.lowercased())\(portKey)\(normalizedPath)#\(principal)"
    }

    public static func smbID(
        host: String,
        port: Int?,
        share: String,
        username: String
    ) -> String {
        let portKey = port.map { ":\($0)" } ?? ""
        let normalizedUser = username.trimmingCharacters(in: .whitespaces).lowercased()
        let user = normalizedUser.isEmpty ? "guest" : normalizedUser
        return "share:\(host.lowercased())\(portKey)/\(share.lowercased())#\(user)"
    }

    public static func webDAVID(
        scheme: String,
        host: String,
        port: Int?,
        path: String,
        principal: String
    ) -> String {
        let normalizedScheme = scheme.lowercased()
        let defaultPort = normalizedScheme == "https" ? 443 : 80
        let portKey = (port == nil || port == defaultPort) ? "" : ":\(port!)"
        var normalizedPath = path.isEmpty ? "/" : path
        if normalizedPath.count > 1, normalizedPath.hasSuffix("/") {
            normalizedPath.removeLast()
        }
        return "share:\(normalizedScheme)://\(host.lowercased())\(portKey)\(normalizedPath)#\(principal)"
    }

    public static func defaultShareName(
        path: String,
        host: String,
        transport: MediaShareTransportKind
    ) -> String {
        let lastComponent = path
            .split(separator: "/", omittingEmptySubsequences: true)
            .last
            .map(String.init)
        let base = lastComponent ?? host
        return "\(base) (\(transport.badgeLabel))"
    }

    public static func normalizedFilesystemPath(_ path: String) -> String {
        let trimmed = path.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty { return "/" }
        return trimmed.hasPrefix("/") ? trimmed : "/" + trimmed
    }
}
