import Foundation

/// Marker for non-secret values that may be persisted in durable local state.
///
/// Credentials, private keys, authorization headers, and signed URLs must use
/// their dedicated credential stores instead of conforming to this protocol.
public protocol DurableLocalStateValue: Codable, Sendable {
    /// Stable, developer-owned schema identity. Never derive this from a Swift
    /// type name, which can change after a module or symbol rename.
    static var durableLocalStateSchemaID: String { get }
}

public enum DurableLocalStateCollection: String, Codable, CaseIterable, Sendable {
    case accountRemovalJournal
    case credentialMutationIndex
    case localMediaWatch
    case migrationMarker
    case sourceIdentity
    case sourceReclaim
    case watchOutbox
}

public enum DurableLocalStateScope: Hashable, Sendable {
    case household
    case account(accountID: String)
    case profile(profileID: String)
    case source(profileID: String, sourceID: String)

    fileprivate var kind: String {
        switch self {
        case .household: return "household"
        case .account: return "account"
        case .profile: return "profile"
        case .source: return "source"
        }
    }

    fileprivate var identifiers: [String] {
        switch self {
        case .household:
            return []
        case .account(let accountID):
            return [accountID]
        case .profile(let profileID):
            return [profileID]
        case .source(let profileID, let sourceID):
            return [profileID, sourceID]
        }
    }
}

public enum DurableLocalStateError: Error, Equatable, Sendable {
    case collectionMismatch
    case addressMismatch
    case invalidKey
    case malformedEnvelope
    case malformedPayload
    case payloadTooLarge
    case schemaMismatch
    case unsupportedVersion
}

public struct DurableLocalStateKey: Hashable, Sendable {
    public let collection: DurableLocalStateCollection
    public let scope: DurableLocalStateScope
    public let recordID: String

    public init(
        collection: DurableLocalStateCollection,
        scope: DurableLocalStateScope,
        recordID: String = "state"
    ) throws {
        try Self.validate(recordID)
        for identifier in scope.identifiers {
            try Self.validate(identifier)
        }
        self.collection = collection
        self.scope = scope
        self.recordID = recordID
    }

    var storageKey: String {
        let components = [collection.rawValue, scope.kind]
            + scope.identifiers.map(Self.encodedComponent)
            + [Self.encodedComponent(recordID)]
        // This address format is permanent. Payload schema evolution belongs in
        // the versioned envelope, not in the Keychain lookup key.
        return "com.plozz.local-state." + components.joined(separator: ".")
    }

    private static func validate(_ value: String) throws {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == value,
              !value.isEmpty,
              value.utf8.count <= 512,
              value.unicodeScalars.allSatisfy({
                  !CharacterSet.controlCharacters.contains($0)
              }) else {
            throw DurableLocalStateError.invalidKey
        }
    }

    private static func encodedComponent(_ value: String) -> String {
        Data(value.utf8).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

extension DurableLocalStateKey: CustomStringConvertible, CustomDebugStringConvertible {
    public var description: String {
        "DurableLocalStateKey(collection: \(collection.rawValue), scope: \(scope.kind))"
    }

    public var debugDescription: String { description }
}

/// Bounded, versioned storage for non-recreatable local state.
///
/// Production injects a user-independent `KeychainStore` configured with
/// `keychainService`, keeping this non-secret state physically separate from
/// credentials. Missing records return `nil`; corrupt or unsupported records
/// throw so callers cannot silently replace durable state with an empty value.
public final class DurableLocalStateStore: @unchecked Sendable {
    public static let keychainService = "com.plozz.app.local-state"
    public static let defaultMaximumPayloadBytes = 256 * 1024

    private let secureStore: SecureStoring
    private let maximumPayloadBytes: Int
    private let lock = NSLock()

    public init(
        secureStore: SecureStoring,
        maximumPayloadBytes: Int = defaultMaximumPayloadBytes
    ) throws {
        guard (1...Self.defaultMaximumPayloadBytes).contains(maximumPayloadBytes) else {
            throw DurableLocalStateError.payloadTooLarge
        }
        self.secureStore = secureStore
        self.maximumPayloadBytes = maximumPayloadBytes
    }

    public func load<Value: DurableLocalStateValue>(
        _ type: Value.Type = Value.self,
        for key: DurableLocalStateKey
    ) throws -> Value? {
        try Self.validateSchemaID(Value.durableLocalStateSchemaID)
        lock.lock()
        defer { lock.unlock() }

        guard let stored = try secureStore.readString(for: key.storageKey) else {
            return nil
        }
        guard stored.utf8.count <= maximumEnvelopeBytes(for: key),
              let data = stored.data(using: .utf8) else {
            throw DurableLocalStateError.payloadTooLarge
        }

        let decoder = JSONDecoder()
        guard let header = try? decoder.decode(StoredEnvelopeVersion.self, from: data) else {
            throw DurableLocalStateError.malformedEnvelope
        }
        guard header.version == 1 else {
            throw DurableLocalStateError.unsupportedVersion
        }
        guard let envelope = try? decoder.decode(StoredEnvelope.self, from: data) else {
            throw DurableLocalStateError.malformedEnvelope
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let canonical = try? encoder.encode(envelope), canonical == data else {
            throw DurableLocalStateError.malformedEnvelope
        }
        guard envelope.collection == key.collection else {
            throw DurableLocalStateError.collectionMismatch
        }
        guard envelope.address == key.storageKey else {
            throw DurableLocalStateError.addressMismatch
        }
        guard envelope.schemaID == Value.durableLocalStateSchemaID else {
            throw DurableLocalStateError.schemaMismatch
        }
        guard envelope.payload.count <= maximumPayloadBytes else {
            throw DurableLocalStateError.payloadTooLarge
        }
        do {
            return try decoder.decode(Value.self, from: envelope.payload)
        } catch {
            throw DurableLocalStateError.malformedPayload
        }
    }

    public func save<Value: DurableLocalStateValue>(
        _ value: Value,
        for key: DurableLocalStateKey
    ) throws {
        try Self.validateSchemaID(Value.durableLocalStateSchemaID)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let payload = try encoder.encode(value)
        guard payload.count <= maximumPayloadBytes else {
            throw DurableLocalStateError.payloadTooLarge
        }
        let envelope = StoredEnvelope(
            version: 1,
            collection: key.collection,
            address: key.storageKey,
            schemaID: Value.durableLocalStateSchemaID,
            payload: payload
        )
        let data = try encoder.encode(envelope)
        guard data.count <= maximumEnvelopeBytes(for: key),
              let stored = String(data: data, encoding: .utf8) else {
            throw DurableLocalStateError.payloadTooLarge
        }

        lock.lock()
        defer { lock.unlock() }
        try secureStore.setString(stored, for: key.storageKey)
    }

    public func remove(_ key: DurableLocalStateKey) throws {
        lock.lock()
        defer { lock.unlock() }
        try secureStore.removeValue(for: key.storageKey)
    }

    private static func validateSchemaID(_ value: String) throws {
        let allowed = CharacterSet.alphanumerics.union(
            CharacterSet(charactersIn: "._-")
        )
        guard !value.isEmpty,
              value.utf8.count <= 128,
              value.unicodeScalars.allSatisfy(allowed.contains) else {
            throw DurableLocalStateError.invalidKey
        }
    }

    private func maximumEnvelopeBytes(for key: DurableLocalStateKey) -> Int {
        ((maximumPayloadBytes + 2) / 3) * 4
            + key.storageKey.utf8.count
            + 1_024
    }
}

private struct StoredEnvelopeVersion: Decodable {
    let version: Int
}

private struct StoredEnvelope: Codable {
    let version: Int
    let collection: DurableLocalStateCollection
    let address: String
    let schemaID: String
    let payload: Data
}
