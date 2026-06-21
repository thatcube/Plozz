import XCTest
import CoreModels
@testable import ProviderJellyfin

/// Verifies the provider-agnostic `ProviderRegistry` resolves the right concrete
/// `MediaProvider` per `ProviderKind` and fails cleanly for unregistered kinds.
final class ProviderRegistryTests: XCTestCase {
    private func session(provider: ProviderKind) -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "https://h")!, provider: provider),
            userID: "u", userName: "A", deviceID: "d", accessToken: "tok"
        )
    }

    func testResolvesJellyfinProvider() throws {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { JellyfinProvider(session: $0) }

        let provider = try registry.provider(for: session(provider: .jellyfin))
        XCTAssertEqual(provider.kind, .jellyfin)
        XCTAssertTrue(provider is JellyfinProvider)
    }

    func testResolvedProviderIsBoundToSession() throws {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { JellyfinProvider(session: $0) }

        let s = session(provider: .jellyfin)
        let provider = try registry.provider(for: s)
        XCTAssertEqual(provider.session, s)
    }

    func testUnregisteredKindThrows() {
        let registry = ProviderRegistry()
        // Only Jellyfin registered; resolving Plex must throw.
        registry.register(.jellyfin) { JellyfinProvider(session: $0) }

        XCTAssertThrowsError(try registry.provider(for: session(provider: .plex))) { error in
            guard case AppError.unknown = error else {
                return XCTFail("Expected AppError.unknown, got \(error)")
            }
        }
    }

    func testEmptyRegistryThrows() {
        let registry = ProviderRegistry()
        XCTAssertThrowsError(try registry.provider(for: session(provider: .jellyfin)))
    }
}
