import XCTest
@testable import CoreModels

/// Persistence safety for the watch outbox's new identity-expansion fields:
/// ``MediaIdentity`` must round-trip through Codable (it's persisted on a queued
/// ``WatchMutation`` so a drain can re-resolve the index union after relaunch),
/// and an outbox written before the field existed must still decode.
final class MediaIdentityCodableTests: XCTestCase {
    func testMediaIdentityRoundTrips() throws {
        let identities: [MediaIdentity] = [
            .external(source: "imdb", value: "tt6718170"),
            .external(source: "tmdb", value: "502356"),
            .title(normalizedTitle: "super mario bros movie", year: 2023, kind: .movie)
        ]
        let data = try JSONEncoder().encode(identities)
        let decoded = try JSONDecoder().decode([MediaIdentity].self, from: data)
        XCTAssertEqual(decoded, identities)
    }

    func testWatchMutationCarriesIdentitiesThroughCodable() throws {
        let mutation = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            canonicalMediaID: "imdb:tt6718170",
            resumePosition: 1647,
            targets: [WatchMutationTarget(accountID: "a", itemID: "420")],
            expansionPending: true,
            identities: [.external(source: "imdb", value: "tt6718170")]
        )
        let data = try JSONEncoder().encode(mutation)
        let decoded = try JSONDecoder().decode(WatchMutation.self, from: data)
        XCTAssertEqual(decoded.identities, mutation.identities)
        XCTAssertTrue(decoded.expansionPending)
    }

    func testLegacyOutboxDecodesWithEmptyIdentities() throws {
        let modern = WatchMutation(
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            canonicalMediaID: "imdb:tt1",
            played: true,
            clearResume: true,
            targets: [WatchMutationTarget(accountID: "a", itemID: "a1")]
        )
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(modern)) as! [String: Any]
        json.removeValue(forKey: "identities")
        let legacyData = try JSONSerialization.data(withJSONObject: json)

        let decoded = try JSONDecoder().decode(WatchMutation.self, from: legacyData)
        XCTAssertEqual(decoded.identities, [], "A pre-field outbox entry decodes to no identities")
        XCTAssertFalse(decoded.expansionPending)
    }
}
