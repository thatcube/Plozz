import Foundation
import CoreModels

public enum MediaCredentialError: Error, Equatable, Sendable {
    case incompatibleAuthentication
    case incompatibleTrust
    case invalidIdentifier
    case invalidFingerprint
    case malformedEnvelope
    case unsupportedVersion
    case transportMismatch
    case payloadTooLarge
    case unversionedCredentialNotSupported
    case credentialNotFound
    case revisionAlreadyExists
    case childItemAlreadyExists
    case childItemRetired
}

public struct SHA256Fingerprint: Codable, Hashable, Sendable {
    public let bytes: Data

    public init(bytes: Data) throws {
        guard bytes.count == 32 else {
            throw MediaCredentialError.invalidFingerprint
        }
        self.bytes = bytes
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(bytes: container.decode(Data.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(bytes)
    }
}

public struct CredentialChildItemID: Codable, Hashable, Sendable {
    public let rawValue: String

    public init(rawValue: String) throws {
        let value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._:-")
        )
        guard value == rawValue,
              !value.isEmpty,
              value.utf8.count <= 256,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw MediaCredentialError.invalidIdentifier
        }
        self.rawValue = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        try self.init(rawValue: container.decode(String.self))
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(rawValue)
    }
}

public enum MediaShareAuthentication: Equatable, Sendable {
    case anonymous
    case password(username: String, password: String)
    case bearer(token: String)
    case generatedKey(username: String, keyID: CredentialChildItemID)
    case noCredentials

    fileprivate var kind: SerializedAuthentication.Kind {
        switch self {
        case .anonymous: return .anonymous
        case .password: return .password
        case .bearer: return .bearer
        case .generatedKey: return .generatedKey
        case .noCredentials: return .noCredentials
        }
    }
}

extension MediaShareAuthentication: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "MediaShareAuthentication(kind: \(kind.rawValue))"
    }

    public var debugDescription: String { description }
}

public struct MediaShareTrustMaterial: Codable, Equatable, Sendable {
    private static let unpinnedRevision = UUID(
        uuidString: "00000000-0000-0000-0000-000000000000"
    )!

    public let revision: UUID
    public let tlsLeafCertificateSHA256: SHA256Fingerprint?
    public let sshHostKeySHA256: SHA256Fingerprint?

    public init(
        revision: UUID? = nil,
        tlsLeafCertificateSHA256: SHA256Fingerprint? = nil,
        sshHostKeySHA256: SHA256Fingerprint? = nil
    ) {
        let hasPin = tlsLeafCertificateSHA256 != nil || sshHostKeySHA256 != nil
        self.revision = revision ?? (hasPin ? UUID() : Self.unpinnedRevision)
        self.tlsLeafCertificateSHA256 = tlsLeafCertificateSHA256
        self.sshHostKeySHA256 = sshHostKeySHA256
    }
}

/// Version-independent credential value used by transport resolvers.
///
/// It is never stored directly. `MediaShareCredentialCodec` owns the exact
/// prefixed wire format so arbitrary legacy passwords are never parsed as JSON.
public struct MediaShareCredentialEnvelope: Equatable, Sendable {
    public let transport: MediaShareTransportKind
    public let authentication: MediaShareAuthentication
    public let trust: MediaShareTrustMaterial

    public init(
        transport: MediaShareTransportKind,
        authentication: MediaShareAuthentication,
        trust: MediaShareTrustMaterial = MediaShareTrustMaterial()
    ) throws {
        try Self.validate(
            transport: transport,
            authentication: authentication,
            trust: trust
        )
        self.transport = transport
        self.authentication = authentication
        self.trust = trust
    }

    private static func validate(
        transport: MediaShareTransportKind,
        authentication: MediaShareAuthentication,
        trust: MediaShareTrustMaterial
    ) throws {
        let authenticationAllowed: Bool
        switch (transport, authentication) {
        case (.smb, .anonymous), (.smb, .password),
             (.webDAV, .anonymous), (.webDAV, .password), (.webDAV, .bearer),
             (.sftp, .password), (.sftp, .generatedKey),
             (.nfs, .noCredentials):
            authenticationAllowed = true
        default:
            authenticationAllowed = false
        }
        guard authenticationAllowed else {
            throw MediaCredentialError.incompatibleAuthentication
        }

        switch authentication {
        case .password(let username, _):
            if transport != .smb {
                guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw MediaCredentialError.invalidIdentifier
                }
            }
        case .bearer(let token):
            guard !token.isEmpty else {
                throw MediaCredentialError.invalidIdentifier
            }
        case .generatedKey(let username, _):
            guard !username.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MediaCredentialError.invalidIdentifier
            }
        case .anonymous, .noCredentials:
            break
        }

        if trust.tlsLeafCertificateSHA256 != nil, transport != .webDAV {
            throw MediaCredentialError.incompatibleTrust
        }
        if trust.sshHostKeySHA256 != nil, transport != .sftp {
            throw MediaCredentialError.incompatibleTrust
        }
        if transport == .sftp, trust.sshHostKeySHA256 == nil {
            throw MediaCredentialError.incompatibleTrust
        }
    }
}

extension MediaShareCredentialEnvelope: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        let hasTrust = trust.tlsLeafCertificateSHA256 != nil
            || trust.sshHostKeySHA256 != nil
        return "MediaShareCredentialEnvelope(transport: \(transport.rawValue), authentication: \(authentication.kind.rawValue), trust: \(hasTrust ? "pinned" : "system/default"))"
    }

    public var debugDescription: String { description }
}

public enum MediaShareCredentialCodec {
    public static let prefix = "plozz-share-v1:"
    public static let maximumPayloadBytes = 32 * 1024
    private static let maximumEncodedPayloadBytes = ((maximumPayloadBytes + 2) / 3) * 4

    public static func encode(_ envelope: MediaShareCredentialEnvelope) throws -> String {
        let serialized = SerializedEnvelope(envelope)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(serialized)
        guard data.count <= maximumPayloadBytes else {
            throw MediaCredentialError.payloadTooLarge
        }
        return prefix + data.base64EncodedString()
    }

    /// Decodes the exact prefixed format, or treats an unprefixed SMB value as
    /// the legacy raw password. No other unprefixed value is interpreted.
    public static func decode(
        _ storedValue: String,
        expectedTransport: MediaShareTransportKind,
        legacyUsername: String = ""
    ) throws -> MediaShareCredentialEnvelope {
        guard storedValue.hasPrefix(prefix) else {
            guard expectedTransport == .smb else {
                throw MediaCredentialError.unversionedCredentialNotSupported
            }
            guard storedValue.utf8.count <= maximumPayloadBytes,
                  legacyUsername.utf8.count <= maximumPayloadBytes else {
                throw MediaCredentialError.payloadTooLarge
            }
            let authentication: MediaShareAuthentication =
                legacyUsername.isEmpty && storedValue.isEmpty
                    ? .anonymous
                    : .password(username: legacyUsername, password: storedValue)
            return try MediaShareCredentialEnvelope(
                transport: .smb,
                authentication: authentication
            )
        }

        let encoded = String(storedValue.dropFirst(prefix.count))
        guard encoded.utf8.count <= maximumEncodedPayloadBytes else {
            throw MediaCredentialError.payloadTooLarge
        }
        guard let data = Data(base64Encoded: encoded),
              data.base64EncodedString() == encoded else {
            throw MediaCredentialError.malformedEnvelope
        }
        guard data.count <= maximumPayloadBytes else {
            throw MediaCredentialError.payloadTooLarge
        }
        let decoder = JSONDecoder()
        guard let version = try? decoder.decode(SerializedEnvelopeVersion.self, from: data) else {
            throw MediaCredentialError.malformedEnvelope
        }
        guard version.version == 1 else {
            throw MediaCredentialError.unsupportedVersion
        }
        let serialized: SerializedEnvelope
        do {
            serialized = try decoder.decode(SerializedEnvelope.self, from: data)
        } catch {
            throw MediaCredentialError.malformedEnvelope
        }
        let canonicalEncoder = JSONEncoder()
        canonicalEncoder.outputFormatting = [.sortedKeys]
        guard let canonicalData = try? canonicalEncoder.encode(serialized),
              canonicalData == data else {
            throw MediaCredentialError.malformedEnvelope
        }
        let envelope = try serialized.envelope()
        guard envelope.transport == expectedTransport else {
            throw MediaCredentialError.transportMismatch
        }
        return envelope
    }
}

/// Immutable Keychain entries addressed by account plus credential revision.
public final class MediaCredentialVault: @unchecked Sendable {
    private let secureStore: SecureStore
    private let lock = NSLock()
    private let credentialPrefix = "com.plozz.media-credential.v1."
    private let childPrefix = "com.plozz.media-credential-child.v1."
    private let retiredChildPrefix = "com.plozz.media-credential-child-retired.v1."

    public init(secureStore: SecureStore) {
        self.secureStore = secureStore
    }

    public func store(
        _ envelope: MediaShareCredentialEnvelope,
        accountID: String,
        revision: CredentialRevision
    ) throws {
        let key = try credentialKey(accountID: accountID, revision: revision)
        let encoded = try MediaShareCredentialCodec.encode(envelope)
        lock.lock()
        defer { lock.unlock() }
        if let existing = secureStore.string(for: key) {
            guard existing == encoded else {
                throw MediaCredentialError.revisionAlreadyExists
            }
            return
        }
        if case .generatedKey(_, let keyID) = envelope.authentication,
           !hasActivePrivateKey(keyID) {
            throw MediaCredentialError.credentialNotFound
        }
        guard try secureStore.insertStringIfAbsent(encoded, for: key) else {
            guard secureStore.string(for: key) == encoded else {
                throw MediaCredentialError.revisionAlreadyExists
            }
            return
        }
    }

    public func credential(
        accountID: String,
        revision: CredentialRevision,
        expectedTransport: MediaShareTransportKind
    ) throws -> MediaShareCredentialEnvelope {
        let key = try credentialKey(accountID: accountID, revision: revision)
        lock.lock()
        defer { lock.unlock() }
        guard let encoded = secureStore.string(for: key) else {
            throw MediaCredentialError.credentialNotFound
        }
        let envelope = try MediaShareCredentialCodec.decode(
            encoded,
            expectedTransport: expectedTransport
        )
        if case .generatedKey(_, let keyID) = envelope.authentication,
           !hasActivePrivateKey(keyID) {
            throw MediaCredentialError.credentialNotFound
        }
        return envelope
    }

    public func remove(accountID: String, revision: CredentialRevision) throws {
        let key = try credentialKey(accountID: accountID, revision: revision)
        lock.lock()
        defer { lock.unlock() }
        try secureStore.removeValue(for: key)
    }

    public func storePrivateKey(_ privateKey: String, id: CredentialChildItemID) throws {
        guard let privateKeySize = privateKey.data(using: .utf8)?.count,
              privateKeySize > 0,
              privateKeySize <= 128 * 1024 else {
            throw MediaCredentialError.payloadTooLarge
        }
        let key = childKey(id)
        lock.lock()
        defer { lock.unlock() }
        guard secureStore.string(for: retiredChildKey(id)) == nil else {
            throw MediaCredentialError.childItemRetired
        }
        if let existing = secureStore.string(for: key) {
            guard existing == privateKey else {
                throw MediaCredentialError.childItemAlreadyExists
            }
            return
        }
        guard try secureStore.insertStringIfAbsent(privateKey, for: key) else {
            guard secureStore.string(for: key) == privateKey else {
                throw MediaCredentialError.childItemAlreadyExists
            }
            return
        }
        if secureStore.string(for: retiredChildKey(id)) != nil {
            try secureStore.removeValue(for: key)
            throw MediaCredentialError.childItemRetired
        }
    }

    public func privateKey(id: CredentialChildItemID) throws -> String {
        lock.lock()
        defer { lock.unlock() }
        guard secureStore.string(for: retiredChildKey(id)) == nil else {
            throw MediaCredentialError.credentialNotFound
        }
        guard let value = secureStore.string(for: childKey(id)) else {
            throw MediaCredentialError.credentialNotFound
        }
        guard !value.isEmpty, value.utf8.count <= 128 * 1024 else {
            throw MediaCredentialError.payloadTooLarge
        }
        return value
    }

    public func removePrivateKey(id: CredentialChildItemID) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try secureStore.insertStringIfAbsent("retired", for: retiredChildKey(id))
        try secureStore.removeValue(for: childKey(id))
    }

    private func credentialKey(
        accountID: String,
        revision: CredentialRevision
    ) throws -> String {
        let account = try encodedKeyComponent(accountID)
        return credentialPrefix + account + "." + revision.rawValue.uuidString.lowercased()
    }

    private func childKey(_ id: CredentialChildItemID) -> String {
        childPrefix + Data(id.rawValue.utf8).base64URLEncodedString()
    }

    private func retiredChildKey(_ id: CredentialChildItemID) -> String {
        retiredChildPrefix + Data(id.rawValue.utf8).base64URLEncodedString()
    }

    private func hasActivePrivateKey(_ id: CredentialChildItemID) -> Bool {
        secureStore.string(for: retiredChildKey(id)) == nil
            && secureStore.string(for: childKey(id)) != nil
    }

    private func encodedKeyComponent(_ value: String) throws -> String {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !trimmed.isEmpty,
              trimmed.utf8.count <= 512 else {
            throw MediaCredentialError.invalidIdentifier
        }
        return Data(trimmed.utf8).base64URLEncodedString()
    }
}

private struct SerializedEnvelopeVersion: Decodable {
    let version: Int
}

private struct SerializedEnvelope: Codable {
    let version: Int
    let transport: MediaShareTransportKind
    let authentication: SerializedAuthentication
    let trust: MediaShareTrustMaterial

    init(_ envelope: MediaShareCredentialEnvelope) {
        version = 1
        transport = envelope.transport
        authentication = SerializedAuthentication(envelope.authentication)
        trust = envelope.trust
    }

    func envelope() throws -> MediaShareCredentialEnvelope {
        try MediaShareCredentialEnvelope(
            transport: transport,
            authentication: authentication.authentication(),
            trust: trust
        )
    }
}

fileprivate struct SerializedAuthentication: Codable {
    enum Kind: String, Codable {
        case anonymous
        case password
        case bearer
        case generatedKey
        case noCredentials
    }

    let kind: Kind
    let username: String?
    let secret: String?
    let keyID: CredentialChildItemID?

    init(_ authentication: MediaShareAuthentication) {
        switch authentication {
        case .anonymous:
            self.init(kind: .anonymous)
        case .password(let username, let password):
            self.init(kind: .password, username: username, secret: password)
        case .bearer(let token):
            self.init(kind: .bearer, secret: token)
        case .generatedKey(let username, let keyID):
            self.init(kind: .generatedKey, username: username, keyID: keyID)
        case .noCredentials:
            self.init(kind: .noCredentials)
        }
    }

    init(
        kind: Kind,
        username: String? = nil,
        secret: String? = nil,
        keyID: CredentialChildItemID? = nil
    ) {
        self.kind = kind
        self.username = username
        self.secret = secret
        self.keyID = keyID
    }

    func authentication() throws -> MediaShareAuthentication {
        switch kind {
        case .anonymous:
            guard username == nil, secret == nil, keyID == nil else {
                throw MediaCredentialError.malformedEnvelope
            }
            return .anonymous
        case .password:
            guard let username, let secret, keyID == nil else {
                throw MediaCredentialError.malformedEnvelope
            }
            return .password(username: username, password: secret)
        case .bearer:
            guard username == nil, let secret, keyID == nil else {
                throw MediaCredentialError.malformedEnvelope
            }
            return .bearer(token: secret)
        case .generatedKey:
            guard let username, secret == nil, let keyID else {
                throw MediaCredentialError.malformedEnvelope
            }
            return .generatedKey(username: username, keyID: keyID)
        case .noCredentials:
            guard username == nil, secret == nil, keyID == nil else {
                throw MediaCredentialError.malformedEnvelope
            }
            return .noCredentials
        }
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
