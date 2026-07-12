import XCTest
@testable import CoreModels

private struct DurableFixture: DurableLocalStateValue, Equatable {
    static let durableLocalStateSchemaID = "test.durable-fixture.v1"
    let name: String
    let count: Int
}

final class DurableLocalStateStoreTests: XCTestCase {
    func testRoundTripSurvivesNewStoreInstance() throws {
        let secure = DurableSecureStoreDouble()
        let key = try DurableLocalStateKey(
            collection: .localMediaWatch,
            scope: .source(profileID: "profile-a", sourceID: "source-a")
        )
        let value = DurableFixture(name: "resume", count: 42)

        try DurableLocalStateStore(secureStore: secure).save(value, for: key)

        let relaunched = try DurableLocalStateStore(secureStore: secure)
        XCTAssertEqual(try relaunched.load(DurableFixture.self, for: key), value)
    }

    func testMissingRecordReturnsNil() throws {
        let store = try DurableLocalStateStore(secureStore: DurableSecureStoreDouble())
        let key = try DurableLocalStateKey(
            collection: .watchOutbox,
            scope: .profile(profileID: "profile-a")
        )

        XCTAssertNil(try store.load(DurableFixture.self, for: key))
    }

    func testProfileSourceAccountAndCollectionKeysAreIsolated() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let keys = [
            try DurableLocalStateKey(
                collection: .localMediaWatch,
                scope: .source(profileID: "profile-a", sourceID: "source-a")
            ),
            try DurableLocalStateKey(
                collection: .localMediaWatch,
                scope: .source(profileID: "profile-b", sourceID: "source-a")
            ),
            try DurableLocalStateKey(
                collection: .localMediaWatch,
                scope: .source(profileID: "profile-a", sourceID: "source-b")
            ),
            try DurableLocalStateKey(
                collection: .credentialMutationIndex,
                scope: .account(accountID: "account-a")
            )
        ]

        for (index, key) in keys.enumerated() {
            try store.save(
                DurableFixture(name: "value", count: index),
                for: key
            )
        }

        for (index, key) in keys.enumerated() {
            XCTAssertEqual(
                try store.load(DurableFixture.self, for: key)?.count,
                index
            )
        }
        XCTAssertEqual(Set(keys.map(\.storageKey)).count, keys.count)
    }

    func testEnvelopeCannotMoveBetweenScopesInOneCollection() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let source = try DurableLocalStateKey(
            collection: .localMediaWatch,
            scope: .source(profileID: "profile-a", sourceID: "source-a")
        )
        let target = try DurableLocalStateKey(
            collection: .localMediaWatch,
            scope: .source(profileID: "profile-b", sourceID: "source-a")
        )
        try store.save(DurableFixture(name: "source", count: 1), for: source)
        secure.forceSet(
            try XCTUnwrap(secure.string(for: source.storageKey)),
            for: target.storageKey
        )

        XCTAssertThrowsError(try store.load(DurableFixture.self, for: target)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .addressMismatch)
        }
    }

    func testSameShapeDifferentSchemaCannotDecode() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )
        try store.save(DurableFixture(name: "value", count: 1), for: key)

        XCTAssertThrowsError(try store.load(SameShapeFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .schemaMismatch)
        }
    }

    func testInvalidKeyComponentsAreRejected() {
        XCTAssertThrowsError(
            try DurableLocalStateKey(
                collection: .watchOutbox,
                scope: .profile(profileID: " profile")
            )
        )
        XCTAssertThrowsError(
            try DurableLocalStateKey(
                collection: .watchOutbox,
                scope: .profile(profileID: "profile\nid")
            )
        )
        XCTAssertThrowsError(
            try DurableLocalStateKey(
                collection: .watchOutbox,
                scope: .profile(profileID: "profile"),
                recordID: ""
            )
        )
    }

    func testKeyDescriptionsDoNotExposeIdentifiers() throws {
        let key = try DurableLocalStateKey(
            collection: .localMediaWatch,
            scope: .source(
                profileID: "private-profile-name",
                sourceID: "private-source-path"
            )
        )

        XCTAssertFalse(key.description.contains("private-profile-name"))
        XCTAssertFalse(String(reflecting: key).contains("private-source-path"))
    }

    func testPayloadLimitAppliesToWritesAndReads() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(
            secureStore: secure,
            maximumPayloadBytes: 64
        )
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )

        XCTAssertThrowsError(
            try store.save(
                DurableFixture(name: String(repeating: "x", count: 128), count: 1),
                for: key
            )
        ) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .payloadTooLarge)
        }

        secure.forceSet(
            String(repeating: "x", count: 2_000),
            for: key.storageKey
        )
        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .payloadTooLarge)
        }
    }

    func testMalformedAndUnsupportedRecordsFailClosed() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )

        secure.forceSet("not-json", for: key.storageKey)
        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .malformedEnvelope)
        }

        secure.forceSet(#"{"version":2}"#, for: key.storageKey)
        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .unsupportedVersion)
        }
    }

    func testEnvelopeWithUnexpectedFieldsFailsCanonicalValidation() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )
        let payload = try JSONEncoder().encode(DurableFixture(name: "ok", count: 1))
        let object: [String: Any] = [
            "version": 1,
            "collection": DurableLocalStateCollection.migrationMarker.rawValue,
            "address": key.storageKey,
            "schemaID": DurableFixture.durableLocalStateSchemaID,
            "payload": payload.base64EncodedString(),
            "unexpected": true
        ]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        secure.forceSet(try XCTUnwrap(String(data: data, encoding: .utf8)), for: key.storageKey)

        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .malformedEnvelope)
        }
    }

    func testStoredCollectionMustMatchAddressedCollection() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let sourceKey = try DurableLocalStateKey(
            collection: .sourceIdentity,
            scope: .household
        )
        let targetKey = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )
        try store.save(DurableFixture(name: "source", count: 1), for: sourceKey)
        secure.forceSet(
            try XCTUnwrap(secure.string(for: sourceKey.storageKey)),
            for: targetKey.storageKey
        )

        XCTAssertThrowsError(
            try store.load(DurableFixture.self, for: targetKey)
        ) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .collectionMismatch)
        }
    }

    func testMalformedPayloadIsNotTreatedAsMissingState() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )
        try store.save(DurableFixture(name: "value", count: 1), for: key)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let damaged = RawStoredEnvelope(
            version: 1,
            collection: .migrationMarker,
            address: key.storageKey,
            schemaID: DurableFixture.durableLocalStateSchemaID,
            payload: Data("{}".utf8)
        )
        secure.forceSet(
            try XCTUnwrap(String(data: encoder.encode(damaged), encoding: .utf8)),
            for: key.storageKey
        )

        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? DurableLocalStateError, .malformedPayload)
        }
    }

    func testRemoveDeletesRecord() throws {
        let secure = DurableSecureStoreDouble()
        let store = try DurableLocalStateStore(secureStore: secure)
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )
        try store.save(DurableFixture(name: "value", count: 1), for: key)

        try store.remove(key)

        XCTAssertNil(try store.load(DurableFixture.self, for: key))
    }

    func testThrowingReadFailureIsNotTreatedAsMissing() throws {
        let store = try DurableLocalStateStore(
            secureStore: FailingReadSecureStore()
        )
        let key = try DurableLocalStateKey(
            collection: .migrationMarker,
            scope: .household
        )

        XCTAssertThrowsError(try store.load(DurableFixture.self, for: key)) { error in
            XCTAssertEqual(error as? ReadFailure, .unavailable)
        }
    }
}

private struct SameShapeFixture: DurableLocalStateValue {
    static let durableLocalStateSchemaID = "test.same-shape-fixture.v1"
    let name: String
    let count: Int
}

private struct RawStoredEnvelope: Codable {
    let version: Int
    let collection: DurableLocalStateCollection
    let address: String
    let schemaID: String
    let payload: Data
}

private final class DurableSecureStoreDouble: SecureStoring, @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String: String] = [:]

    func setString(_ value: String, for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }

    func string(for key: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return values[key]
    }

    func readString(for key: String) throws -> String? {
        string(for: key)
    }

    func removeValue(for key: String) throws {
        lock.lock()
        defer { lock.unlock() }
        values[key] = nil
    }

    func forceSet(_ value: String, for key: String) {
        lock.lock()
        defer { lock.unlock() }
        values[key] = value
    }
}

private enum ReadFailure: Error, Equatable {
    case unavailable
}

private struct FailingReadSecureStore: SecureStoring {
    func setString(_ value: String, for key: String) throws {}
    func string(for key: String) -> String? { nil }
    func readString(for key: String) throws -> String? { throw ReadFailure.unavailable }
    func removeValue(for key: String) throws {}
}
