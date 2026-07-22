import XCTest
@testable import CoreModels

/// Step 9 — the household-global TMDB BYOK key store round-trips through a secure
/// store, treats blanks as opt-out, and removes cleanly.
final class TMDBUserKeyStoreTests: XCTestCase {
    private final class InMemorySecureStoringDouble: SecureStoring, @unchecked Sendable {
        private var storage: [String: String] = [:]
        func setString(_ value: String, for key: String) throws { storage[key] = value }
        func string(for key: String) -> String? { storage[key] }
        func readString(for key: String) throws -> String? { storage[key] }
        func removeValue(for key: String) throws { storage[key] = nil }
    }

    func testRoundTrip() throws {
        let secure = InMemorySecureStoringDouble()
        let store = TMDBUserKeyStore(secureStore: secure)
        XCTAssertNil(store.load(), "No key by default")

        try store.save("my-tmdb-v4-token")
        XCTAssertEqual(store.load(), "my-tmdb-v4-token")
        // Stored under the fixed account key in the injected secure store only.
        XCTAssertEqual(secure.string(for: TMDBUserKeyStore.account), "my-tmdb-v4-token")
    }

    func testSaveTrimsWhitespace() throws {
        let store = TMDBUserKeyStore(secureStore: InMemorySecureStoringDouble())
        try store.save("  spaced-token \n")
        XCTAssertEqual(store.load(), "spaced-token")
    }

    func testBlankSaveOptsOut() throws {
        let store = TMDBUserKeyStore(secureStore: InMemorySecureStoringDouble())
        try store.save("token")
        try store.save("   ")
        XCTAssertNil(store.load(), "A blank save removes the key (opt out)")
    }

    func testRemove() throws {
        let store = TMDBUserKeyStore(secureStore: InMemorySecureStoringDouble())
        try store.save("token")
        try store.remove()
        XCTAssertNil(store.load())
    }
}
