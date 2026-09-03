import CoreModels
import FeatureAuthCore
import Foundation
import ProviderShare

public enum MediaShareAccountConfigurationError: LocalizedError, Equatable {
    case invalidAddress
    case invalidShare

    public var errorDescription: LocalizedStringResource? {
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

public enum MediaShareFTPAuth: Equatable, Sendable {
    case anonymous
    case password(username: String, password: String)

    var principal: String {
        switch self {
        case .anonymous:
            return "anon"
        case let .password(username, _):
            let trimmed = username.trimmingCharacters(in: .whitespaces)
            return trimmed.isEmpty ? "anon" : trimmed
        }
    }

    var accountUserName: String {
        switch self {
        case .anonymous:
            ""
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
        displayName: String,
        subpath: String = ""
    ) throws -> PreparedMediaShareAccount {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        let trimmedUsername = username.trimmingCharacters(in: .whitespaces)
        guard port.map({ (1...65_535).contains($0) }) ?? true else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        let canonicalPort = port == 445 ? nil : port
        let enteredShare = try Self.normalizedRelativeFilesystemPath(
            share,
            allowEmpty: false
        )
        let shareComponents = enteredShare.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard !trimmedHost.isEmpty, let shareName = shareComponents.first else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        let embeddedSubpath = shareComponents.dropFirst().joined(separator: "/")
        let explicitSubpath = try Self.normalizedRelativeFilesystemPath(
            subpath,
            allowEmpty: true
        )
        let selectedSubpath = [embeddedSubpath, explicitSubpath]
            .filter { !$0.isEmpty }
            .joined(separator: "/")
        let selectedRoot = ([String(shareName)] + (selectedSubpath.isEmpty
            ? []
            : [selectedSubpath])).joined(separator: "/")

        var components = URLComponents()
        components.scheme = "smb"
        components.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        components.port = canonicalPort
        components.path = "/" + selectedRoot
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
        let canonicalServerID = Self.smbID(
            host: trimmedHost,
            port: canonicalPort,
            share: String(shareName),
            subpath: selectedSubpath,
            username: trimmedUsername
        )
        var legacyServerIDs: Set<String> = [
            Self.legacySMBID(
                host: trimmedHost,
                port: canonicalPort,
                path: selectedRoot,
                username: trimmedUsername
            ),
        ]
        if port == nil || port == 445 {
            legacyServerIDs.insert(Self.legacySMBID(
                host: trimmedHost,
                port: 445,
                path: selectedRoot,
                username: trimmedUsername
            ))
        }
        let existingAccount = accountStore.loadAccounts().first {
            if $0.id == canonicalServerID { return true }
            return legacyServerIDs.contains($0.id)
                && Self.smbURL(
                    $0.server.baseURL,
                    matchesHost: trimmedHost,
                    port: canonicalPort,
                    share: String(shareName),
                    subpath: selectedSubpath
                )
        }
        let serverID = existingAccount?.id ?? canonicalServerID
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(
                    path: selectedRoot,
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
            previousAccount: existingAccount,
            credential: credential
        )
    }

    public func saveSMB(
        host: String,
        port: Int?,
        share: String,
        username: String,
        password: String,
        displayName: String,
        subpath: String = ""
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareSMB(
            host: host,
            port: port,
            share: share,
            username: username,
            password: password,
            displayName: displayName,
            subpath: subpath
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

        let normalizedPath = try Self.validatedFilesystemPath(path)
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

    public func prepareFTP(
        baseURL: URL,
        auth: MediaShareFTPAuth,
        trustPin: SHA256Fingerprint? = nil,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        guard var components = URLComponents(
            url: baseURL,
            resolvingAgainstBaseURL: false
        ),
        let scheme = components.scheme?.lowercased(),
        scheme == "ftp" || scheme == "ftps",
        let host = components.host,
        !host.isEmpty,
        components.user == nil,
        components.password == nil,
        components.query == nil,
        components.fragment == nil,
        trustPin == nil || scheme == "ftps" else {
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
        }
        let credential: MediaShareCredentialEnvelope
        do {
            credential = try MediaShareCredentialEnvelope(
                transport: .ftp,
                authentication: authentication,
                trust: MediaShareTrustMaterial(
                    tlsLeafCertificateSHA256: trustPin
                )
            )
        } catch {
            throw MediaShareAccountConfigurationError.invalidShare
        }

        let normalizedPath = try Self.validatedFilesystemPath(components.path)
        components.path = normalizedPath == "/" ? "" : normalizedPath
        guard let normalizedURL = components.url else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        let serverID = Self.filesystemID(
            scheme: scheme,
            host: host,
            port: components.port,
            path: normalizedPath,
            principal: auth.principal
        )
        let trimmedName = displayName.trimmingCharacters(in: .whitespaces)
        let server = MediaServer(
            id: serverID,
            name: trimmedName.isEmpty
                ? Self.defaultShareName(
                    path: normalizedPath,
                    host: host,
                    transport: .ftp
                )
                : trimmedName,
            baseURL: normalizedURL,
            provider: .mediaShare
        )
        let session = UserSession(
            server: server,
            userID: auth.accountUserName.isEmpty ? "anon" : auth.accountUserName,
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

    public func saveFTP(
        baseURL: URL,
        auth: MediaShareFTPAuth,
        trustPin: SHA256Fingerprint? = nil,
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareFTP(
            baseURL: baseURL,
            auth: auth,
            trustPin: trustPin,
            displayName: displayName
        )
        try persist(prepared)
        return prepared
    }

    public func prepareNFS(
        host: String,
        port: Int?,
        exportPath: String,
        subpath: String = "",
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let trimmedHost = host.trimmingCharacters(in: .whitespaces)
        guard !trimmedHost.isEmpty,
              port.map({ (1...65_535).contains($0) }) ?? true else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        let canonicalPort = port == 2_049 ? nil : port

        let normalizedExportPath = try Self.validatedFilesystemPath(exportPath)
        let normalizedSubpath = try Self.normalizedRelativeFilesystemPath(
            subpath,
            allowEmpty: true
        )
        let normalizedPath = Self.joinedFilesystemPath(
            root: normalizedExportPath,
            subpath: normalizedSubpath
        )
        var components = URLComponents()
        components.scheme = "nfs"
        components.host = ShareProvider.bracketedHostIfIPv6(trimmedHost)
        components.port = canonicalPort
        components.path = normalizedPath
        guard let baseURL = components.url else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }

        let credential: MediaShareCredentialEnvelope
        do {
            credential = try MediaShareCredentialEnvelope(
                transport: .nfs,
                authentication: .noCredentials,
                transportRootPath: normalizedSubpath.isEmpty
                    ? nil
                    : normalizedExportPath
            )
        } catch {
            throw MediaShareAccountConfigurationError.invalidShare
        }

        let canonicalServerID = Self.filesystemID(
            scheme: "nfs",
            host: trimmedHost,
            port: canonicalPort,
            path: normalizedPath,
            principal: "anon"
        )
        let legacyDefaultPortID = Self.filesystemID(
            scheme: "nfs",
            host: trimmedHost,
            port: 2_049,
            path: normalizedPath,
            principal: "anon"
        )
        let equivalentServerIDs: Set<String> = port == nil || port == 2_049
            ? [canonicalServerID, legacyDefaultPortID]
            : [canonicalServerID]
        let existingAccount = accountStore.loadAccounts().first {
            equivalentServerIDs.contains($0.id)
        }
        let serverID = existingAccount?.id ?? canonicalServerID
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
            previousAccount: existingAccount,
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
        subpath: String = "",
        displayName: String
    ) throws -> PreparedMediaShareAccount {
        let prepared = try prepareNFS(
            host: host,
            port: port,
            exportPath: exportPath,
            subpath: subpath,
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
        subpath: String = "",
        username: String
    ) -> String {
        let canonicalPort = port == 445 ? nil : port
        let normalizedSubpath = (try? normalizedRelativeFilesystemPath(
            subpath,
            allowEmpty: true
        )) ?? ""
        guard !normalizedSubpath.isEmpty else {
            return legacySMBID(
                host: host,
                port: canonicalPort,
                path: share,
                username: username
            )
        }
        let portKey = canonicalPort.map { ":\($0)" } ?? ""
        let normalizedUser = username.trimmingCharacters(in: .whitespaces).lowercased()
        let user = normalizedUser.isEmpty ? "guest" : normalizedUser
        return "share:smb://\(host.lowercased())\(portKey)/\(share.lowercased())/\(normalizedSubpath)#\(user)"
    }

    private static func legacySMBID(
        host: String,
        port: Int?,
        path: String,
        username: String
    ) -> String {
        let portKey = port.map { ":\($0)" } ?? ""
        let normalizedUser = username.trimmingCharacters(in: .whitespaces).lowercased()
        let user = normalizedUser.isEmpty ? "guest" : normalizedUser
        return "share:\(host.lowercased())\(portKey)/\(path.lowercased())#\(user)"
    }

    private static func smbURL(
        _ url: URL,
        matchesHost host: String,
        port: Int?,
        share: String,
        subpath: String
    ) -> Bool {
        guard let components = URLComponents(
            url: url,
            resolvingAgainstBaseURL: false
        ), components.scheme?.lowercased() == "smb",
           ShareProvider.unbracketedHost(components.host ?? "")
            .caseInsensitiveCompare(
                ShareProvider.unbracketedHost(host)
            ) == .orderedSame else {
            return false
        }
        let existingPort = components.port == 445 ? nil : components.port
        guard existingPort == port else { return false }
        let pathComponents = components.path.split(
            separator: "/",
            omittingEmptySubsequences: true
        ).map(String.init)
        guard let existingShare = pathComponents.first,
              existingShare.caseInsensitiveCompare(share) == .orderedSame else {
            return false
        }
        return pathComponents.dropFirst().joined(separator: "/") == subpath
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

    private static func validatedFilesystemPath(_ path: String) throws -> String {
        let relative = try normalizedRelativeFilesystemPath(
            path,
            allowEmpty: true
        )
        return relative.isEmpty ? "/" : "/" + relative
    }

    private static func normalizedRelativeFilesystemPath(
        _ path: String,
        allowEmpty: Bool
    ) throws -> String {
        let trimmed = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.contains("\\"),
              !trimmed.contains("\0") else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        let components = trimmed.split(
            separator: "/",
            omittingEmptySubsequences: true
        )
        guard components.allSatisfy({ $0 != "." && $0 != ".." }),
              allowEmpty || !components.isEmpty else {
            throw MediaShareAccountConfigurationError.invalidAddress
        }
        return components.joined(separator: "/")
    }

    private static func joinedFilesystemPath(
        root: String,
        subpath: String
    ) -> String {
        guard !subpath.isEmpty else { return root }
        return root == "/" ? "/\(subpath)" : "\(root)/\(subpath)"
    }
}
