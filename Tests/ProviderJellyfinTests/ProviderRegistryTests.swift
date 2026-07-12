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

    private func context(provider: ProviderKind) -> ProviderResolutionContext {
        ProviderResolutionContext(
            session: session(provider: provider),
            accountID: "account",
            credentialRevision: CredentialRevision()
        )
    }

    func testResolvesJellyfinProvider() throws {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { JellyfinProvider(session: $0.session) }

        let provider = try registry.provider(for: context(provider: .jellyfin))
        XCTAssertEqual(provider.kind, .jellyfin)
        XCTAssertTrue(provider is JellyfinProvider)
    }

    func testResolvedProviderIsBoundToSession() throws {
        let registry = ProviderRegistry()
        registry.register(.jellyfin) { JellyfinProvider(session: $0.session) }

        let s = session(provider: .jellyfin)
        let context = ProviderResolutionContext(
            session: s,
            accountID: "account",
            credentialRevision: CredentialRevision()
        )
        let provider = try registry.provider(for: context)
        XCTAssertEqual(provider.session, s)
    }

    func testUnregisteredKindThrows() {
        let registry = ProviderRegistry()
        // Only Jellyfin registered; resolving Plex must throw.
        registry.register(.jellyfin) { JellyfinProvider(session: $0.session) }

        XCTAssertThrowsError(try registry.provider(for: context(provider: .plex))) { error in
            XCTAssertEqual(
                error as? ProviderResolutionError,
                .unregisteredProvider(.plex)
            )
        }
    }

    func testEmptyRegistryThrows() {
        let registry = ProviderRegistry()
        XCTAssertThrowsError(try registry.provider(for: context(provider: .jellyfin)))
    }
}
