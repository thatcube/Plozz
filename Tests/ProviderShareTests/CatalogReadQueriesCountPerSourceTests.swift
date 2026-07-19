import XCTest
import CoreModels
@testable import ProviderShare

/// Locks the Step 6 `metadataCountPerSource` provenance-row counting used by the
/// diagnostics surface.
final class CatalogReadQueriesCountPerSourceTests: XCTestCase {
    private func openConnection() -> (CatalogConnection, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("countq-\(UUID().uuidString).sqlite")
        let conn = CatalogConnection(url: url)
        XCTAssertTrue(conn.ensureOpen(legacyMetadataMigration: { _ in true }))
        return (conn, url)
    }

    private func makeQueries(_ conn: CatalogConnection) -> CatalogReadQueries {
        CatalogReadQueries(
            connection: conn,
            normalizedMetadataReady: true,
            localMetadataPresence: LocalMetadataPresence()
        )
    }

    private func seed(_ conn: CatalogConnection, item: String, field: String, source: String) {
        XCTAssertTrue(conn.exec(
            "INSERT INTO metadata_values(item_id, field, source, value_json) VALUES('\(item)','\(field)','\(source)','\"v\"');"
        ))
    }

    func testEmptyCatalogHasNoCounts() {
        let (conn, _) = openConnection()
        XCTAssertTrue(makeQueries(conn).metadataCountPerSource().isEmpty)
    }

    func testCountsGroupBySource() {
        let (conn, _) = openConnection()
        seed(conn, item: "m:1", field: "title", source: "tvdb")
        seed(conn, item: "m:1", field: "overview", source: "tvdb")
        seed(conn, item: "m:1", field: "posterURL", source: "tmdb")
        seed(conn, item: "m:2", field: "title", source: "localNFO")

        let counts = makeQueries(conn).metadataCountPerSource()
        XCTAssertEqual(counts[.tvdb], 2)
        XCTAssertEqual(counts[.tmdb], 1)
        XCTAssertEqual(counts[.localNFO], 1)
        XCTAssertNil(counts[.anilist])
    }
}
