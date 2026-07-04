import XCTest
import CoreModels
import CoreNetworking
@testable import ProviderJellyfin

/// Verifies the Jellyfin alphabet fast-scroll index issues the right count
/// queries. The stub matches by path suffix only (it can't vary a response by
/// query param), so the *offset math* is proven in `CoreModelsTests`; here we
/// assert the request **shape**: a name sort fans out one `NameLessThan` count
/// per letter A–Z, and non-name sorts issue nothing at all.
final class JellyfinLetterIndexTests: XCTestCase {
    private func makeSession() -> UserSession {
        UserSession(
            server: MediaServer(id: "s", name: "Home", baseURL: URL(string: "http://host:8096")!, provider: .jellyfin),
            userID: "u1", userName: "Alice", deviceID: "d1", accessToken: "TOKEN"
        )
    }

    func testNameSortIssuesNameLessThanCountPerLetter() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[],"TotalRecordCount":50}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        _ = try await provider.letterIndex(
            in: "lib1", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .name, direction: .ascending)
        )

        // Every letter A…Z must be probed with a NameLessThan count query.
        let nameLessThanValues = stub.sentQueryItems
            .compactMap { items in items.first(where: { $0.name == "NameLessThan" })?.value }
        let expected = (UnicodeScalar("A").value...UnicodeScalar("Z").value)
            .compactMap { UnicodeScalar($0).map(String.init) }
        XCTAssertEqual(Set(nameLessThanValues), Set(expected))
        XCTAssertEqual(nameLessThanValues.count, 26)

        // Plus exactly one total-count query (no NameLessThan) for the upper bound.
        let totalQueries = stub.sentQueryItems.filter { items in
            !items.contains(where: { $0.name == "NameLessThan" })
        }
        XCTAssertEqual(totalQueries.count, 1)

        // Count queries must scope to the library and request no rows.
        for items in stub.sentQueryItems {
            XCTAssertTrue(items.contains(URLQueryItem(name: "ParentId", value: "lib1")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "Limit", value: "0")))
            XCTAssertTrue(items.contains(URLQueryItem(name: "EnableTotalRecordCount", value: "true")))
        }
    }

    func testNonNameSortIssuesNoRequestsAndReturnsEmpty() async throws {
        let stub = StubHTTPClient()
        stub.stub(pathSuffix: "/Items", json: #"{"Items":[],"TotalRecordCount":50}"#)
        let provider = JellyfinProvider(session: makeSession(), http: stub)

        let entries = try await provider.letterIndex(
            in: "lib1", kind: .movie,
            sort: CoreModels.SortDescriptor(field: .dateAdded, direction: .descending)
        )
        XCTAssertTrue(entries.isEmpty)
        XCTAssertTrue(stub.sentPaths.isEmpty, "Non-name sorts must not issue any count queries")
    }
}
