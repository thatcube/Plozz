import CoreModels
import Foundation

public enum MediaTransportRole: String, CaseIterable, Hashable, Sendable {
    case scanner
    case playback
    case metadata
    case artwork
}

/// Normalized, credential-free identity for a transport endpoint.
public struct MediaTransportEndpointIdentity: Hashable, Sendable, CustomStringConvertible {
    public let transportIdentifier: String
    public let host: String
    public let port: Int?
    public let rootPath: String

    public init(
        transportIdentifier: String,
        host: String,
        port: Int? = nil,
        rootPath: String = "/"
    ) throws {
        let transport = transportIdentifier.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let allowedTransportCharacters = CharacterSet(
            charactersIn: "abcdefghijklmnopqrstuvwxyz0123456789+.-"
        )
        guard !transport.isEmpty,
              transport.unicodeScalars.allSatisfy(allowedTransportCharacters.contains),
              !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              !host.contains("@"), !host.contains("/"), !host.contains("\\"),
              !host.contains("?"), !host.contains("#") else {
            throw MediaTransportError.invalidInput(reason: "invalid endpoint")
        }
        if let port, !(1...65_535).contains(port) {
            throw MediaTransportError.invalidInput(reason: "invalid port")
        }
        self.transportIdentifier = transport
        self.host = host
        self.port = port
        self.rootPath = try Self.normalizeRoot(rootPath)
    }

    public var description: String {
        let displayedHost = host.contains(":") ? "[\(host)]" : host
        let portText = port.map { ":\($0)" } ?? ""
        return "\(transportIdentifier)://\(displayedHost)\(portText)\(rootPath)"
    }

    private static func normalizeRoot(_ value: String) throws -> String {
        let replaced = value.replacingOccurrences(of: "\\", with: "/")
        guard replaced.hasPrefix("/"), !replaced.contains("\0") else {
            throw MediaTransportError.invalidInput(reason: "invalid root")
        }
        var result: [String] = []
        for component in replaced.split(separator: "/", omittingEmptySubsequences: true) {
            guard component != ".", component != ".." else {
                throw MediaTransportError.invalidInput(reason: "root traversal")
            }
            result.append(String(component))
        }
        return result.isEmpty ? "/" : "/" + result.joined(separator: "/")
    }
}

public struct MediaTransportSessionKey: Hashable, Sendable, CustomStringConvertible {
    public let accountID: String
    public let credentialRevision: CredentialRevision
    public let endpoint: MediaTransportEndpointIdentity
    public let trustRevision: UUID
    public let role: MediaTransportRole

    public init(
        accountID: String,
        credentialRevision: CredentialRevision,
        endpoint: MediaTransportEndpointIdentity,
        trustRevision: UUID,
        role: MediaTransportRole
    ) {
        self.accountID = accountID
        self.credentialRevision = credentialRevision
        self.endpoint = endpoint
        self.trustRevision = trustRevision
        self.role = role
    }

    public var description: String {
        "MediaTransportSessionKey(account: \(accountID), endpoint: \(endpoint), role: \(role.rawValue), " +
        "credentialRevision: \(credentialRevision.rawValue.uuidString), trustRevision: \(trustRevision.uuidString))"
    }
}

public protocol MediaTransportConnection: AnyObject, Sendable {
    var key: MediaTransportSessionKey { get }
    func shutdown() async
}

public protocol MediaTransportSession: MediaTransportConnection {
    var fileSystem: any MediaTransportFileSystem { get }
}

public protocol MediaTransportAdapter: Sendable {
    var transportIdentifier: String { get }
    func connect(for key: MediaTransportSessionKey) async throws -> any MediaTransportSession
}

public protocol MediaTransportResolving: Sendable {
    func lease(for key: MediaTransportSessionKey) async throws -> MediaTransportResolverLease
}
