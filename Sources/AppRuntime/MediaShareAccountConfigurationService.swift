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
