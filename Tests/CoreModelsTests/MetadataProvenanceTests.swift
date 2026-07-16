import XCTest
@testable import CoreModels

final class MetadataProvenanceTests: XCTestCase {
    func testSourcedValueAndUnknownIdentifiersRoundTrip() throws {
        let sourceURL = try XCTUnwrap(URL(string: "https://metadata.example/item/42"))
        let sourced = SourcedValue(
            value: "Canonical title",
            source: MetadataSource(rawValue: "futureProvider"),
            sourceURL: sourceURL
        )
        let decoded = try JSONDecoder().decode(
            SourcedValue<String>.self,
            from: JSONEncoder().encode(sourced)
        )

        XCTAssertEqual(decoded, sourced)

        let futureField = MetadataField(rawValue: "futurePlacement")
        let provenance = MetadataProvenance([
            futureField: sourced.attribution
        ])
        let decodedProvenance = try JSONDecoder().decode(
            MetadataProvenance.self,
            from: JSONEncoder().encode(provenance)
        )
        XCTAssertEqual(decodedProvenance[futureField], sourced.attribution)
    }

    func testLegacyMediaItemDecodesWithoutProvenanceOrMetadataLoss() throws {
        let item = MediaItem(
            id: "legacy",
            title: "Legacy title",
            kind: .movie,
            overview: "Legacy overview",
            genres: ["Drama"],
            runtime: 7_200,
            posterURL: URL(string: "https://example.com/poster.jpg"),
            providerIDs: ["Tvdb": "42"]
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "metadataProvenance")

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.title, item.title)
        XCTAssertEqual(decoded.overview, item.overview)
        XCTAssertEqual(decoded.runtime, item.runtime)
        XCTAssertEqual(decoded.genres, item.genres)
        XCTAssertEqual(decoded.posterURL, item.posterURL)
        XCTAssertEqual(decoded.providerIDs, item.providerIDs)
        XCTAssertTrue(decoded.metadataProvenance.isEmpty)
    }

    func testMalformedProvenanceDropsOnlyInvalidEntries() throws {
        let item = MediaItem(
            id: "partial",
            title: "Still readable",
            kind: .movie,
            overview: "Still present",
            posterURL: URL(string: "https://example.com/poster.jpg")
        )
        let encoded = try JSONEncoder().encode(item)
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object["metadataProvenance"] = [
            "overview": ["source": "futureProvider"],
            "posterURL": ["source": 7]
        ]

        let decoded = try JSONDecoder().decode(
            MediaItem.self,
            from: JSONSerialization.data(withJSONObject: object)
        )

        XCTAssertEqual(decoded.title, "Still readable")
        XCTAssertEqual(decoded.overview, "Still present")
        XCTAssertEqual(
            decoded.metadataProvenance[.overview]?.source,
            MetadataSource(rawValue: "futureProvider")
        )
        XCTAssertNil(decoded.metadataProvenance[.posterURL])
    }
}
