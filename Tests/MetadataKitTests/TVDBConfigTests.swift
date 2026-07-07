import XCTest
@testable import MetadataKit

/// Coverage for the bundled TheTVDB tier's configuration + resolver gating. The
/// live v4 login/search aren't exercised here (no network in unit tests); these
/// assert the config contract that decides whether the tier is offered at all.
final class TVDBConfigTests: XCTestCase {
    func testUnconfiguredWhenNoKey() {
        let config = TVDBConfig.resolved(bundle: Bundle(for: Self.self), environment: [:])
        XCTAssertFalse(config.isConfigured, "no key anywhere → tier disabled, keyless base carries enrichment")
        XCTAssertNil(config.apiKey)
    }

    func testConfiguredFromEnvironment() {
        let config = TVDBConfig.resolved(bundle: Bundle(for: Self.self), environment: ["TVDB_API_KEY": "abc-123"])
        XCTAssertTrue(config.isConfigured)
        XCTAssertEqual(config.apiKey, "abc-123")
    }

    func testRejectsUnsubstitutedPlaceholder() {
        // A build with no local secrets leaves the literal build-setting placeholder.
        let config = TVDBConfig(apiKey: "$(TVDB_API_KEY)")
        XCTAssertFalse(config.isConfigured)
        XCTAssertNil(config.apiKey)
    }

    func testTrimsWhitespaceAndRejectsEmpty() {
        XCTAssertNil(TVDBConfig(apiKey: "   ").apiKey)
        XCTAssertEqual(TVDBConfig(apiKey: "  key  ").apiKey, "key")
    }

    func testUnconfiguredClientResolvesNil() async {
        // A client with no key must no-op (not hang / not crash), so enrichment
        // silently falls back to keyless.
        let client = TVDBClient(config: TVDBConfig(apiKey: nil))
        let result = await client.resolve(title: "Inception", year: 2010, isMovie: true)
        XCTAssertNil(result)
    }
}
